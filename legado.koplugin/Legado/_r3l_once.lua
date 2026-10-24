local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local socket_url = require("socket.url")
local LuaSettings = require("luasettings")

local function upgrade_database(dbManager)
    if dbManager and dbManager._migrateDB then
        return dbManager:_migrateDB()
    end
end

return function()
    local Backend = require("Legado/Backend")
    local dbManager = assert(Backend.dbManager, "BookInfoDB is not initialized")

    local settings_data = LuaSettings:open(Env.getUserSettingsPath())
    local settings = settings_data.data
    local is_changed = false

    if settings.setting_url or settings_data.data.legado_server then
        settings = {}
        is_changed = true
    end
    if not H.is_tbl(settings.web_configs) and H.is_str(settings.server_address) then
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
         is_changed = true
    end
    if H.is_tbl(settings.web_configs) and H.is_str(settings.server_address_md5) then
        local web_configs = settings.web_configs
        local updates_to_perform = {}
        for config_name, config in pairs(web_configs) do
            if H.is_tbl(config) and H.is_str(config.url) and H.is_str(config_name) then
                local parsed_url = socket_url.parse(config.url)
                if H.is_tbl(parsed_url) and H.is_str(parsed_url.host) then
                    local old_id = tostring(H.md5(parsed_url.host))
                    local new_id = tostring(H.md5(config_name))
                    if old_id ~= new_id then
                        updates_to_perform[old_id] = new_id
                    end
                end
            end
        end
        if next(updates_to_perform) ~= nil then
            dbManager:transaction(function()
                for old_id, new_id in pairs(updates_to_perform) do
                    dbManager:dynamicUpdate('books', {
                        bookShelfId = new_id
                    }, {
                        bookShelfId = old_id
                    })
                end
            end)()
        end

        if settings.server_address_md5 then
            settings.server_address_md5 = nil
        end
        is_changed = true
        logger.info("Database bookShelfId upgrade completed")
    end

    if H.is_str(settings.chapter_sorting_mode) or settings.stream_image_view then
        settings.chapter_sorting_mode = nil
        settings.stream_image_view = nil
        is_changed = true
    end

    if is_changed == true then
        settings_data.data = settings
        settings_data:flush()
    end

    local patches_dir = FS.joinPath(Env.getKoreaderDirectory(), 'patches')
    local patches_file_path = FS.joinPath(patches_dir, '2-legado_plugin_func.lua')
    local source_patches = FS.joinPath(Env.getPluginDirectory(), 'patches/2-legado_plugin_func.lua')
    local disabled_patches = patches_file_path .. '.disabled'
    for _, file in ipairs({source_patches, patches_file_path, disabled_patches}) do
        if util.fileExists(file) then
            util.removeFile(file)
        end
    end
    local plugin_dir = Env.getPluginDirectory()
    local plg_patches_dir = FS.joinPath(plugin_dir, 'patches')
    if util.directoryExists(plg_patches_dir) then
        local ffiUtil = require("ffi/util")
        ffiUtil.purgeDir(plg_patches_dir)
        util.removePath(plg_patches_dir)
    end

    local old_task_pid = Env.getTempDirectory() .. '/task.pid.lua'
    if util.fileExists(old_task_pid) then
        util.removeFile(old_task_pid)
    end
    dbManager:execute("DROP TABLE IF EXISTS task_pid;")
    dbManager:execute("DROP TABLE IF EXISTS replace_rules;")
    if dbManager:getDB():rowexec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sync_records';") then
        dbManager:execute("DELETE FROM sync_records WHERE resourceType = 'replace_rules';")
    end

    local legacy_book_dir = FS.joinPath(Env.getHomeDir(), "Legado\u{200B}书目")
    if util.directoryExists(legacy_book_dir) then
        local ffiUtil = require("ffi/util")
        ffiUtil.purgeDir(legacy_book_dir)
        util.removePath(legacy_book_dir)
    end

    local cache_dir = Env.getTempDirectory()
    for _, css_path in ipairs({
        FS.joinPath(cache_dir, "legado.css"),
        FS.joinPath(cache_dir, "resources/legado.css"),
    }) do
        if util.fileExists(css_path)
            and not util.removeFile(css_path)
            and util.fileExists(css_path) then
            error("failed to remove stale shared stylesheet: " .. css_path)
        end
    end

    local shared_css = require("Legado/EpubHelper").addCssRes()
    assert(util.fileExists(shared_css), "failed to restore shared stylesheet: " .. shared_css)

    upgrade_database(dbManager)
    return true
end
