local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local socket_url = require("socket.url")
local LuaSettings = require("luasettings")
local md5 = require("ffi/sha2").md5

return function()
    local settings_data = LuaSettings:open(H.getUserSettingsPath())
    local settings = settings_data.data

    -- <1.0.9 清空配置
    if settings.setting_url or settings_data.data.legado_server then
        settings_data.data = {}
        settings_data:flush()
    end
    -- 1.0.9
    if not H.is_tbl(settings.web_configs) and H.is_str(settings.server_address) then
        -- 转换当前配置到 web_configs
        settings.web_configs = {}
        local default_conf_name = "默认配置"
        settings.web_configs[default_conf_name] = {
            url = settings.server_address,
            type = settings.server_type,
            desc = "从旧版本自动迁移",
            user = settings.reader3_un or "",
            pwd = settings.reader3_pwd or "",
        }
         settings.current_conf_name = default_conf_name
         settings_data:flush()
    end
    -- 1.1.1 去除 server_address_md5 并更改 bookShelfId 规则
    if H.is_tbl(settings.web_configs) and H.is_str(settings.server_address_md5) then
        local web_configs = settings.web_configs
        local updates_to_perform = {}
        for config_name, config in pairs(web_configs) do
            if H.is_tbl(config) and H.is_str(config.url) and H.is_str(config_name) then
                local parsed_url = socket_url.parse(config.url)
                if H.is_tbl(parsed_url) and H.is_str(parsed_url.host) then
                    local old_id = tostring(md5(parsed_url.host))
                    local new_id = tostring(md5(config_name))
                    if old_id ~= new_id then
                        updates_to_perform[old_id] = new_id
                    end
                end
            end
        end
        if next(updates_to_perform) ~= nil then
            local BookInfoDB = require("Legado/BookInfoDB")
            local dbManager = BookInfoDB:new({
                dbPath = H.getTempDirectory() .. "/bookinfo.db"
            })
            dbManager:transaction(function()
                for old_id, new_id in pairs(updates_to_perform) do
                    dbManager:dynamicUpdate('books', {
                        bookShelfId = new_id
                    }, {
                        bookShelfId = old_id
                    })
                end
            end)()
            dbManager:closeDB()
        end

        if settings.server_address_md5 then
            settings.server_address_md5 = nil
        end
        settings_data:flush()
        logger.info("Database bookShelfId upgrade completed")
    end

    return true
end
