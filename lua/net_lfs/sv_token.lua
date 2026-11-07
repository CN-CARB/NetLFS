local TOKEN_IS_VALID = NetLFS.Cache.Token_IsValid or false
local TOKEN_EXPIRE_TIME = NetLFS.Cache.Token_ExpireTime or 0
local TOKEN_REGISTERING

NetLFS.Cache.RequestQueue = NetLFS.Cache.RequestQueue or {}

local RequestQueue = NetLFS.Cache.RequestQueue

local next_check = (TOKEN_IS_VALID and CurTime() + 1) or math.huge

local function flushQueue()
    if not TOKEN_IS_VALID then return end

    -- Take the whole queue first so requests queued while flushing wait for the next refresh
    local pending = table.Copy(RequestQueue)

    table.Empty(RequestQueue)

    for _, request in ipairs(pending) do
        local success, err = pcall(request, NetLFS.Cache.Token_Server)

        if not success then
            RiceLib.Error("Queued request failed: " .. tostring(err), "Net LFS")
        end
    end
end

--- Runs request(token) now when the token is valid, otherwise queues it until the token is refreshed.
--- @param request fun(token: string)
function NetLFS.QueueRequest(request)
    if TOKEN_IS_VALID then
        request(NetLFS.Cache.Token_Server)

        return
    end

    table.insert(RequestQueue, request)
end

--- Marks the server token as invalid (e.g. after a 401); the refresh loop in Think fetches a new one.
--- Does nothing if the token was already replaced since the failed request was made.
--- @param failed_token string The token used by the request that got rejected
function NetLFS.InvalidateToken(failed_token, forced)
    if failed_token ~= NetLFS.Cache.Token_Server and not forced then return end
    if not TOKEN_IS_VALID and not forced then return end

    TOKEN_IS_VALID = false
    TOKEN_EXPIRE_TIME = 0
    TOKEN_REGISTERING = false

    NetLFS.Cache.Token_IsValid = false
    NetLFS.Cache.Token_ExpireTime = 0

    next_check = CurTime()
end

local function requireToken()
    if TOKEN_IS_VALID then return end
    if TOKEN_REGISTERING then return end

    local function resetRegistering()
        TOKEN_REGISTERING = false
        next_check = CurTime() + 1
    end
    
    http.Fetch(NetLFS.EndPoint .. "/register", function(body, size, headers, code)
        if not body then
            RiceLib.Error("Error fetching token from server, Empty body", "Net LFS")

            resetRegistering()

            return
        end

        local data = util.JSONToTable(body)

        local function responseIsValid(data)
            return data and data.server and data.client and data.expiration and code == 200
        end

        if not responseIsValid(data) then
            RiceLib.Error("Error fetching token from server, Invalid JSON or missing fields, Code: " .. code, "Net LFS")

            resetRegistering()

            return
        end

        local token_server = data.server
        local token_client = data.client

        TOKEN_EXPIRE_TIME = os.time() + data.expiration
        TOKEN_IS_VALID = true

        NetLFS.Cache.Token_Server = token_server
        NetLFS.Cache.Token_Client = token_client

        NetLFS.Cache.Token_IsValid = TOKEN_IS_VALID
        NetLFS.Cache.Token_ExpireTime = TOKEN_EXPIRE_TIME

        resetRegistering()

        RiceLib.Protobuf.Send("NetLFS.Token", {
            Token = token_client
        })

        RiceLib.Info("Successfully fetched token from server", "Net LFS")

        hook.Run("NetLFS_RefreshToken", token_server, token_client)

        flushQueue()
    end, function(error)
        RiceLib.Error("Error fetching token from server: " .. error, "Net LFS")

        resetRegistering()
    end)

    TOKEN_REGISTERING = true
end

hook.Add("NetLFS_RefreshEndPoint", "NetLFS_RefreshToken", function()
    NetLFS.InvalidateToken(_, true)
end)

hook.Add("RiceLibClientReady", "NetLFS_SendClientToken", function(client_player)
    RiceLib.Protobuf.Send("NetLFS.Token", {
        Token = NetLFS.Cache.Token_Client
    }, client_player)
end)

hook.Add("InitPostEntity", "RequireToken", requireToken)

hook.Add("Think", "NetLFS_CheckTokenValid", function()
    if next_check > CurTime() then return end
    next_check = CurTime() + 1

    if TOKEN_EXPIRE_TIME > 0 and os.time() > TOKEN_EXPIRE_TIME then
        TOKEN_IS_VALID = false

        next_check = math.huge
    end

    if not TOKEN_IS_VALID then
        requireToken()
    end
end)

concommand.Add("net_lfs_refresh_token", function(ply)
    if IsValid(ply) and not ply:IsSuperAdmin() then return end

    NetLFS.InvalidateToken(_, true)
end)
