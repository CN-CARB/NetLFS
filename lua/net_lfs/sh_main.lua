NetLFS.Cache.ReceivedFilesRecord = NetLFS.Cache.ReceivedFilesRecord or {}
NetLFS.Cache.UploadedFilesRecord = NetLFS.Cache.UploadedFilesRecord or {}

NetLFS.Cache.PendingAcks = NetLFS.Cache.PendingAcks or {}
NetLFS.Cache.AckCounter = NetLFS.Cache.AckCounter or 0

NetLFS.Cache.Receivers = NetLFS.Cache.Receivers or {}

local ReceivedFilesRecord = NetLFS.Cache.ReceivedFilesRecord
local UploadedFilesRecord = NetLFS.Cache.UploadedFilesRecord

local Receivers = NetLFS.Cache.Receivers
local PendingAcks = NetLFS.Cache.PendingAcks

local TIME_ONE_DAY = 24 * 60 * 60
local TIME_UPLOAD_CACHE_EXPIRE = 12 * 60 * 60
local TIME_ACK_EXPIRE = 5 * 60

file.CreateDir("net_lfs_cache")

for _, cache in ipairs(select(1, file.Find("net_lfs_cache/*", "DATA"))) do
    local path = "net_lfs_cache/" .. cache
    local time = file.Time(path, "DATA")

    if os.time() - time > TIME_ONE_DAY then
        file.Delete(path)
    else
        -- Restore the record from files that survived the cleanup
        local hash = string.match(cache, "^(%x+)%.dat$")

        if hash then
            ReceivedFilesRecord[hash] = true
        end
    end
end

local function getCachePath(hash)
    return "net_lfs_cache/" .. hash .. ".dat"
end

--- @param id string The ID of the receiver
--- @param callback fun(file_id: string, file_hash: string) The callback to run when a file is received
--- @param shouldReceiveFile? fun(file_id: string, file_hash: string, player: Player, size: number): boolean Optional function to determine if the file should be received, size is the file size in bytes reported by the server
function NetLFS.RegisterReceiver(id, callback, shouldReceiveFile)
    Receivers[id] = {callback, shouldReceiveFile}
end

function NetLFS.GetReceiver(id)
    return Receivers[id]
end

function NetLFS.GetReceivers()
    return Receivers
end

-- MARK: Target acknowledgement

--- Registers onTargetReceived and returns the AckID to send with the file, 0 when no callback is given.
local function registerAck(target, onTargetReceived)
    if not onTargetReceived then return 0 end

    local now = os.time()

    for id, pending in pairs(PendingAcks) do
        if pending.ExpireAt <= now then
            PendingAcks[id] = nil
        end
    end

    -- 1 ~ 4294967295, 0 is reserved for "no ack"
    local ack_id = NetLFS.Cache.AckCounter % 0xFFFFFFFF + 1

    NetLFS.Cache.AckCounter = ack_id

    -- Server: every player the file is sent to acknowledges separately
    local pending_players

    if SERVER then
        local players = target or player.GetAll()

        pending_players = {}

        if isentity(players) then
            pending_players[players] = true
        else
            for _, ply in ipairs(players) do
                pending_players[ply] = true
            end
        end
    end

    PendingAcks[ack_id] = {
        Callback = onTargetReceived,
        PendingPlayers = pending_players,
        ExpireAt = now + TIME_ACK_EXPIRE
    }

    return ack_id
end

--- Tells the sender that the file has been handled. player is the sender (server only).
local function sendAck(ack_id, player)
    if not ack_id or ack_id == 0 then return end

    RiceLib.Protobuf.Send("NetLFS.File.Ack", {
        AckID = ack_id
    }, player)
end

-- MARK: File transfer

local MAX_FETCH_RETRIES = 2
local TIME_FETCH_RETRY_DELAY = 1

--- http.Fetch that retries after a short delay when the request itself fails (not on HTTP error codes)
local function fetchWithRetry(url, onSuccess, onFailure, attempt)
    attempt = attempt or 0

    http.Fetch(url, onSuccess, function(err)
        if attempt >= MAX_FETCH_RETRIES then
            onFailure(err)

            return
        end

        timer.Simple(TIME_FETCH_RETRY_DELAY, function()
            fetchWithRetry(url, onSuccess, onFailure, attempt + 1)
        end)
    end)
end

local MAX_UNAUTHORIZED_RETRIES = 1

-- Client only: requests rejected with 401 wait here until a new token arrives from the server
NetLFS.Cache.ClientRequestQueue = NetLFS.Cache.ClientRequestQueue or {}

local ClientRequestQueue = NetLFS.Cache.ClientRequestQueue

--- Runs request(token, onUnauthorized) with a valid token.
--- onUnauthorized must be called by the request when it gets a 401.
--- Server: requests are queued while the token is invalid; a 401 invalidates the token
--- and the request is retried (once) after the refresh.
--- Client: a 401 queues the request until the server sends a new token (NetLFS.Token), at most
--- MAX_UNAUTHORIZED_RETRIES times; new requests are not blocked meanwhile. If the token the request
--- used is no longer the current one, the retry count is reset and it is retried with the new token.
local function runAuthorizedRequest(request, retries)
    retries = retries or 0

    local function run(token)
        request(token, function()
            if CLIENT then
                local current_token = NetLFS.Cache.Token_Client

                if token ~= current_token then
                    retries = 0

                    run(current_token)

                    return
                end

                if retries >= MAX_UNAUTHORIZED_RETRIES then
                    RiceLib.Error("Request rejected: token invalid or expired", "NetLFS")

                    return
                end

                retries = retries + 1

                table.insert(ClientRequestQueue, run)

                return
            end

            if retries >= MAX_UNAUTHORIZED_RETRIES then
                RiceLib.Error("Request rejected: token invalid or expired", "NetLFS")

                return
            end

            NetLFS.InvalidateToken(token)

            runAuthorizedRequest(request, retries + 1)
        end)
    end

    if CLIENT then
        local token = NetLFS.Cache.Token_Client

        -- No token yet: wait in the queue until the server sends one
        if token == nil then
            table.insert(ClientRequestQueue, run)

            return
        end

        run(token)

        return
    end

    NetLFS.QueueRequest(run)
end

--- @param target_receiver string The ID of the receiver
--- @param data string The raw data to send
--- @param target Player|nil The target player (server only)
--- @param onUploaded fun(file_id, file_hash)|nil Optional callback when the file has been successfully uploaded
--- @param onTargetReceived fun(player: Player|nil)|nil Optional callback when the target has received and handled the file (player is the acknowledging client on the server)
function NetLFS.SendRaw(target_receiver, data, target, onUploaded, onTargetReceived)
    if CLIENT and target then
        RiceLib.Warn("Target should not be specified on the client side.", "NetLFS")
    end

    if #data < 64000 then
        RiceLib.Protobuf.Send("NetLFS.File.NetPayload", {
            Receiver = target_receiver,
            Payload = data,
            AckID = registerAck(target, onTargetReceived)
        }, target)

        return
    end

    local file_hash = util.SHA256(data)

    local function onSuccess(_, body)
        local response = util.JSONToTable(body) or {}
        local file_id = response.id

        if not file_id then
            RiceLib.Error("Empty response or missing file ID", "NetLFS")

            return
        end

        if onUploaded then
            onUploaded(file_id, file_hash)
        end

        if not UploadedFilesRecord[file_hash] then
            UploadedFilesRecord[file_hash] = {
                Body = body,
                ExpireAt = os.time() + TIME_UPLOAD_CACHE_EXPIRE
            }
        end

        RiceLib.Protobuf.Send("NetLFS.File.Receive", {
            Receiver = target_receiver,
            FileID = file_id,
            FileHash = file_hash,
            AckID = registerAck(target, onTargetReceived)
        }, target)
    end

    local uploaded = UploadedFilesRecord[file_hash]

    if uploaded then
        if uploaded.ExpireAt > os.time() then
            onSuccess(200, uploaded.Body)

            return
        end

        UploadedFilesRecord[file_hash] = nil
    end

    local function onFailure(error)
        RiceLib.Error("Failed to send file: " .. error, "NetLFS")
    end

    runAuthorizedRequest(function(token, onUnauthorized)
        HTTP{
            method = "POST",
            url = Format("%s/write/%s", NetLFS.EndPoint, token),

            body = data,

            success = function(code, body, headers)
                if code == 401 then
                    onUnauthorized()

                    return
                end

                if code ~= 200 then
                    onFailure("HTTP " .. code)

                    return
                end

                onSuccess(code, body, headers)
            end,

            failed = onFailure,

            headers = {
                ["Content-Type"] = "application/octet-stream",
                ["Content-Length"] = #data,
                ["Accept"] = "application/json"
            },

            type = "application/octet-stream",
            timeout = 60
        }
    end)
end

RiceLib.Protobuf.Receive("NetLFS.File.NetPayload", function(data, player)
    local receiver = data.Receiver

    local callback = Receivers[receiver]

    if not callback then
        RiceLib.Error("No receiver registered for: " .. receiver, "NetLFS")

        return
    end

    callback[1](data.Payload, player)

    sendAck(data.AckID, player)
end)

RiceLib.Protobuf.Receive("NetLFS.File.Receive", function(data, player)
    local receiver = data.Receiver
    local file_id = data.FileID
    local file_hash = data.FileHash

    local callback = Receivers[receiver]

    if not callback then
        RiceLib.Error("No receiver registered for: " .. receiver, "NetLFS")

        return
    end

    if ReceivedFilesRecord[file_hash] then
        local cached = file.Read(getCachePath(file_hash), "DATA")

        if cached and util.SHA256(cached) == file_hash then
            callback[1](cached, player)

            sendAck(data.AckID, player)

            return
        end

        ReceivedFilesRecord[file_hash] = nil
    end

    local function onFetchFailure(err)
        RiceLib.Error(Format("Failed to fetch file %s: %s", file_id, err), "NetLFS")
    end

    local function downloadFile()
        runAuthorizedRequest(function(token, onUnauthorized)
            fetchWithRetry(Format("%s/read/%s/%s", NetLFS.EndPoint, token, file_id), function(body, _, _, code)
                if code == 401 then
                    onUnauthorized()

                    return
                end

                if code ~= 200 then
                    RiceLib.Error(Format("Failed to fetch file %s: HTTP %d", file_id, code), "NetLFS")

                    return
                end

                if util.SHA256(body) == file_hash then
                    file.Write(getCachePath(file_hash), body)

                    ReceivedFilesRecord[file_hash] = true

                    callback[1](body, player)

                    sendAck(data.AckID, player)

                    return
                end

                RiceLib.Error(Format("File hash mismatch for file %s", file_id), "NetLFS")
            end, onFetchFailure)
        end)
    end

    local shouldReceiveFile = callback[2]

    -- Without shouldReceiveFile there is nothing to decide, download directly
    if not shouldReceiveFile then
        downloadFile()

        return
    end

    -- Ask the server for the file size first, so shouldReceiveFile can reject it before downloading
    runAuthorizedRequest(function(token, onUnauthorized)
        fetchWithRetry(Format("%s/size/%s/%s", NetLFS.EndPoint, token, file_id), function(body, _, _, code)
            if code == 401 then
                onUnauthorized()

                return
            end

            if code ~= 200 then
                RiceLib.Error(Format("Failed to get size of file %s: HTTP %d", file_id, code), "NetLFS")

                return
            end

            -- {} means the file was not found
            local response = util.JSONToTable(body)
            local size = response and tonumber(response.size)

            if not size then
                RiceLib.Error(Format("File %s not found", file_id), "NetLFS")

                return
            end

            if not shouldReceiveFile(file_id, file_hash, player, size) then
                return
            end

            downloadFile()
        end, onFetchFailure)
    end)
end)

RiceLib.Protobuf.Receive("NetLFS.File.Ack", function(data, player)
    local pending = PendingAcks[data.AckID]

    if not pending then return end

    local pending_players = pending.PendingPlayers

    if SERVER then
        -- Only players the file was sent to may acknowledge it, once each
        if not pending_players[player] then return end

        pending_players[player] = nil

        if next(pending_players) == nil then
            PendingAcks[data.AckID] = nil
        end
    else
        PendingAcks[data.AckID] = nil
    end

    pending.Callback(player)
end)

if CLIENT then
    RiceLib.Protobuf.Receive("NetLFS.Token", function(data)
        local token = data.Token

        NetLFS.Cache.Token_Client = token

        -- Take the whole queue first so requests rejected again wait for the next token
        local pending = table.Copy(ClientRequestQueue)

        table.Empty(ClientRequestQueue)

        for _, run in ipairs(pending) do
            local success, err = pcall(run, token)

            if not success then
                RiceLib.Error("Queued request failed: " .. tostring(err), "NetLFS")
            end
        end
    end)
end

-- Records belong to the previous endpoint, drop them when it changes
hook.Add("NetLFS_RefreshEndPoint", "NetLFS_ClearFileRecords", function()
    table.Empty(ReceivedFilesRecord)
    table.Empty(UploadedFilesRecord)
end)
