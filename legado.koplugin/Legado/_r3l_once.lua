local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local socket_url = require("socket.url")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")

return function()
    local settings_data = LuaSettings:open(Env.getUserSettingsPath())
    local settings = settings_data.data
    local is_changed = false

    -- <1.0.9 清空配置
    if settings.setting_url or settings_data.data.legado_server then
        settings = {}
        is_changed = true
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
         is_changed = true
    end
    -- 1.1.1 去除 server_address_md5 并更改 bookShelfId 规则
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
            local BookInfoDB = require("Legado/BookInfoDB")
            local dbManager = BookInfoDB:new({
                dbPath = Env.getTempDirectory() .. "/bookinfo.db"
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
        is_changed = true
        logger.info("Database bookShelfId upgrade completed")
    end

    -- 1.1.2 
    if H.is_str(settings.chapter_sorting_mode) or settings.stream_image_view then
        settings.chapter_sorting_mode = nil
        settings.stream_image_view = nil
        is_changed = true
    end

    if is_changed == true then
        settings_data.data = settings
        settings_data:flush()
    end
    
    -- > 1.1.4
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

    -- > 1.1.5: Clean up obsolete task.pid.lua & legacy task_pid DB table
    local old_task_pid = Env.getTempDirectory() .. '/task.pid.lua'
    if util.fileExists(old_task_pid) then
        util.removeFile(old_task_pid)
    end
    pcall(function()
        local Backend = require("Legado/Backend")
        if Backend and Backend.dbManager then
            Backend.dbManager:execute("DROP TABLE IF EXISTS task_pid;")
        end
    end)

    -- > 1.1.6: Migrate legacy book cache dirs (strip the '.sdr' suffix)
    pcall(function()
        local tmp_dir = Env.getTempDirectory()
        local ok, iter, dir_obj = pcall(lfs.dir, tmp_dir)
        if not ok then return end
        local migrated_any = false
        for entry in iter, dir_obj do
            -- only top-level dirs; skip hidden dirs (e.g. '.tmp.sdr' used by export)
            if entry ~= "." and entry ~= ".."
                    and entry:sub(1, 1) ~= "."
                    and entry:sub(-4) == ".sdr"
                    and lfs.attributes(FS.joinPath(tmp_dir, entry), "mode") == "directory" then
                local old_path = FS.joinPath(tmp_dir, entry)
                local new_path = FS.joinPath(tmp_dir, entry:sub(1, -5))
                if util.directoryExists(new_path) then
                    util.removePath(old_path)
                else
                    FS.moveFile(old_path, new_path)
                end
                migrated_any = true
                logger.info(string.format("Migrated book cache dir '%s' -> '%s'", old_path, new_path))
            end
        end
        if migrated_any then
            -- sync cacheFilePath in bookinfo.db with the new ('.sdr'-free) dir names
            local Backend = require("Legado/Backend")
            if Backend and Backend.dbManager then
                Backend.dbManager:execute(
                    "UPDATE chapters SET cacheFilePath = REPLACE(cacheFilePath, '.sdr/', '/') WHERE cacheFilePath LIKE '%.sdr/%';")
                logger.info("Synced legacy cacheFilePath entries in bookinfo.db")
            end
        end
    end)

    return true
end
