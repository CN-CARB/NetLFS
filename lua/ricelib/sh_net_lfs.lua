--[[
    Net LFS
    Copyright (C) 2026 Rice

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
]]

--- @class NetLFS
--- @field BaseURL string
--- @field APIRevision string
--- @field EndPoint string
NetLFS = NetLFS or {}

NetLFS.Cache = NetLFS.Cache or {}

RiceLib.Config.DefineNameSpace("net_lfs", {
    DisplayName = "Net LFS"
})

local CONFIG_BASE_URL = RiceLib.Config.Define("net_lfs", "net_lfs_baseurl", {
    DisplayName = "Net LFS Base URL",
    Category = "Core",

    Type = "String",
    Default = "https://gm-express.anon-nanning.party",

    Shared = true
})

local CONFIG_REVISION = RiceLib.Config.Define("net_lfs", "net_lfs_revision", {
    DisplayName = "Net LFS API Revision",
    Category = "Core",

    Type = "String",
    Default = "v1",

    Shared = true
})

NetLFS.BaseURL = CONFIG_BASE_URL:GetValue()
NetLFS.APIRevision = CONFIG_REVISION:GetValue()
NetLFS.EndPoint = NetLFS.BaseURL .. "/" .. NetLFS.APIRevision

function CONFIG_BASE_URL:OnValueChanged(value)
    NetLFS.BaseURL = value
    NetLFS.EndPoint = NetLFS.BaseURL .. "/" .. NetLFS.APIRevision

    hook.Run("NetLFS_RefreshEndPoint", NetLFS.EndPoint)
end

function CONFIG_REVISION:OnValueChanged(value)
    NetLFS.APIRevision = value
    NetLFS.EndPoint = NetLFS.BaseURL .. "/" .. NetLFS.APIRevision

    hook.Run("NetLFS_RefreshEndPoint", NetLFS.EndPoint)
end

RiceLib.IncludeDir("net_lfs")
