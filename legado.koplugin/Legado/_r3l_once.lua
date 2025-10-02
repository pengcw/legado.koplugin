local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Backend = require("Legado/Backend")

return function()
    local settings_data = Backend:getLuaConfig(H.getUserSettingsPath())
    -- 兼容历史版本 <1.0.9
    if settings_data.data.setting_url then
        settings_data.data.setting_url = nil
        settings_data.data.servers_history = nil
    end
    -- 兼容历史版本 <1.038
    if settings_data.data.legado_server then
        settings_data.data.legado_server = nil
    end
    -- <1.049
    if not settings_data.data.server_address and H.is_str(settings_data.data.legado_server) then
        settings_data.data.server_address = settings_data.data.legado_server
        if string.find(string.lower(settings_data.data.server_address), "/reader3$") then
            settings_data.data.server_type = 2
        else
            settings_data.data.server_type = 1
        end
        settings_data.data.legado_server = nil
        settings_data:flush()
    end
    return true
end