local util = require("util")
local UIManager = require("ui/uimanager")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local LocalExtension = require("Legado.LocalExtension")
local PlgState = require("Legado/PlgState")
local TaskProg = require("Legado.task.Progress")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Probe = require("Legado.Helper.Probe")
local Error = require("Legado.Helper.Error")

local M = {}

function M.toggleSyncReading(settings)
    settings = H.is_tbl(settings) and settings or Backend:getSettings()
    local ok_msg = settings.sync_reading and "关闭" or "开启"
    settings.sync_reading = not settings.sync_reading or nil
    Backend:HandleResponse(Backend:saveSettings(settings), function()
        MessageBox:info(string.format("设置已%s", ok_msg))
    end, function(err_msg)
        MessageBox:error('设置失败:', err_msg)
    end)
    return settings
end

local function get_engine_version()
    local status = LocalExtension.status(true)
    return status.usable and tostring(status.version) or "不可用"
end

local function check_local_engine(menu_def)
    local Update = require("Legado/Update")
    Update:ensureEngineLibrary(function()
        MessageBox:notice("本地解析扩展可用，版本: v" .. get_engine_version())
        if menu_def and menu_def.updateItems then menu_def:updateItems() end
    end, function(err_msg)
        if err_msg == "已取消安装" then return end
        local message = Error.extract_message(err_msg or "未知错误")
        Probe.fail("Update", "安装解析扩展", "", nil, message)
        MessageBox:error(Error.format_failure("扩展安装失败，请重试", message))
    end)
end

function M.getItems()
    local function update_settings_menu(menu_def)
        if menu_def and menu_def.updateItems then menu_def:updateItems() end
    end

    local function choose_full_book_cache_dir(menu_def)
        local PathChooser = require("ui/widget/pathchooser")
        UIManager:show(PathChooser:new{
            title = "选择整本缓存保存目录",
            path = Backend:getFullBookCacheOutputDir(),
            select_directory = true,
            select_file = false,
            onConfirm = function(output_dir)
                if not (H.is_str(output_dir) and util.directoryExists(output_dir)) then
                    return MessageBox:error("选择的目录不可用")
                end
                local settings = Backend:getSettings()
                settings.full_book_cache_output_dir = output_dir
                Backend:HandleResponse(Backend:saveSettings(settings), function()
                    MessageBox:notice("整本缓存保存目录已设置为：" .. output_dir)
                    update_settings_menu(menu_def)
                end, function(err_msg)
                    MessageBox:error("设置失败：", tostring(err_msg))
                end)
            end,
        })
    end

    local function reset_full_book_cache_dir(menu_def)
        local settings = Backend:getSettings()
        if not settings.full_book_cache_output_dir then
            return MessageBox:notice("整本缓存保存目录已使用 KOReader Home")
        end
        settings.full_book_cache_output_dir = nil
        Backend:HandleResponse(Backend:saveSettings(settings), function()
            MessageBox:notice("整本缓存保存目录已恢复为 KOReader Home")
            update_settings_menu(menu_def)
        end, function(err_msg)
            MessageBox:error("设置失败：", tostring(err_msg))
        end)
    end

    local function full_book_cache_dir_item()
        return {
            text_func = function()
                local output_dir = Backend:getFullBookCacheOutputDir():gsub("/+$", "")
                local dir_name = output_dir:match("[^/]+$") or "/"
                return "整本缓存目录: " .. dir_name
            end,
            help_text = "整本打开模式的书籍文件保存在此目录；兼容模式下也可提前设置。",
            keep_menu_open = true,
            callback = function(menu_def)
                local dialog
                dialog = require("ui/widget/buttondialog"):new{
                    title = "整本缓存保存目录\n当前：" .. Backend:getFullBookCacheOutputDir(),
                    buttons = {
                        {
                            {
                                text = "重置",
                                callback = function()
                                    UIManager:close(dialog)
                                    reset_full_book_cache_dir(menu_def)
                                end,
                            },
                            {
                                text = "选择目录",
                                callback = function()
                                    UIManager:close(dialog)
                                    choose_full_book_cache_dir(menu_def)
                                end,
                            },
                        },
                        {
                            {
                                text = "取消",
                                callback = function() UIManager:close(dialog) end,
                            },
                        },
                    },
                }
                UIManager:show(dialog)
            end,
        }
    end

    local function local_extension_item()
        local sub_item_table = {
                {
                    text = "关于扩展",
                    keep_menu_open = true,
                    callback = function()
                        local ok, err_msg = LocalExtension.available()
                        if not ok then
                            return MessageBox:error("解析扩展不可用: " .. tostring(err_msg or "未知错误"))
                        end
                        MessageBox:info("专门为资源有限设备书源解析优化\n当前版本: v" .. get_engine_version())
                    end,
                }, {
                    text = "检查/修复扩展",
                    callback = function(menu_def)
                        check_local_engine(menu_def)
                    end,
                }, {
                    text = "书源设置",
                    enabled_func = function() return Backend:_isLocal() end,
                    callback = function()
                        require("Legado/BookSourceResults"):openLocalBookSourceSettings()
                    end,
                }, {
                    text = "替换规则",
                    callback = function()
                        LocalExtension.showReplaceRules()
                    end,
                }, {
                    text = "停用本地解析",
                    callback = function(menu_def)
                        MessageBox:confirm("停用本地解析并切换为云端模式？", function(confirmed)
                            if not confirmed then return end
                            local ok, err_msg = Backend:toggleLocalMode(false)
                            if not ok then
                                return MessageBox:error("停用本地解析失败: " .. tostring(err_msg or "未知错误"))
                            end
                            MessageBox:notice("已停用本地解析")
                            if menu_def and menu_def.updateItems then menu_def:updateItems() end
                        end, { ok_text = "停用", cancel_text = "取消" })
                    end,
                }, {
                    text = "清除扩展库",
                    callback = function(menu_def)
                        MessageBox:confirm("确定清除解析扩展库？\n清除后将恢复使用云端接口", function(confirmed)
                            if not confirmed then return end
                            if Backend:_isLocal() then
                                local ok, err_msg = Backend:toggleLocalMode(false)
                                if not ok then
                                    return MessageBox:error("停用本地解析失败: " .. tostring(err_msg or "未知错误"))
                                end
                            end
                            local ok, err_msg = LocalExtension.remove()
                            if not ok then
                                return MessageBox:error("卸载扩展库失败: " .. tostring(err_msg or "未知错误"))
                            end
                            MessageBox:notice("解析扩展库已卸载")
                            if menu_def and menu_def.updateItems then menu_def:updateItems() end
                        end, { ok_text = "卸载", cancel_text = "取消" })
                    end,
                },
        }
        if not Backend:_isLocal() then
            for index, item in ipairs(sub_item_table) do
                if item.text == "停用本地解析" then
                    table.remove(sub_item_table, index)
                    break
                end
            end
        end
        return { text = "本地解析", sub_item_table = sub_item_table }
    end

    local function reading_mode_item()
        local function save_reading_mode(chapter_mode, menu_def)
            local settings = Backend:getSettings()
            if (settings.chapter_mode ~= false) == chapter_mode then return end

            local function save()
                settings.chapter_mode = chapter_mode
                Backend:HandleResponse(Backend:saveSettings(settings), function()
                    PlgState:clearReadingRoute()
                    if chapter_mode then
                        MessageBox:notice("已切换为逐章加载（兼容）")
                    end
                    if menu_def and menu_def.updateItems then menu_def:updateItems() end
                end, function(err_msg)
                    MessageBox:error("设置失败：", tostring(err_msg))
                end)
            end

            if chapter_mode then
                save()
            else
                MessageBox:confirm(
                    "“整本打开”目前处于测试阶段，可能会遇到问题。若阅读异常，可切回“逐章加载（兼容）”。",
                    function(confirmed)
                        if confirmed then save() end
                    end,
                    { ok_text = "继续切换", cancel_text = "取消" }
                )
            end
        end

        return {
            text_func = function()
                local chapter_mode = Backend:getSettings().chapter_mode ~= false
                local mode_name = chapter_mode and "分章" or "整本"
                return "阅读方式:" .. mode_name
            end,
            _legado_reading_mode = true,
            help_text = "选择兼容性较好的逐章加载，或处于测试阶段的整本打开模式。",
            sub_item_table_func = function()
                local items = {
                    {
                        text = "分章阅读(兼容)",
                        help_text = "每章单独加载，兼容性较好；章节间可能有短暂停顿。",
                        checked_func = function()
                            return Backend:getSettings().chapter_mode ~= false
                        end,
                        callback = function(menu_def)
                            save_reading_mode(true, menu_def)
                        end,
                    }, {
                        text = "整本阅读",
                        help_text = "章节在同一本书中连续阅读；目前处于测试阶段，遇到问题可切回逐章加载（兼容）。",
                        checked_func = function()
                            return Backend:getSettings().chapter_mode == false
                        end,
                        callback = function(menu_def)
                            save_reading_mode(false, menu_def)
                        end,
                    },
                }
                local dir_item = full_book_cache_dir_item()
                dir_item._legado_full_book_cache_dir = true
                table.insert(items, dir_item)
                return items
            end,
        }
    end

    local auto_upload_progress_item = {
        text = "自动上传进度",
        help_text = "阅读时，自动上传阅读进度",
        checked_func = function()
            return Backend:getSettings().sync_reading == true
        end,
        callback = function()
            M.toggleSyncReading(Backend:getSettings())
        end,
    }
    local items = {
    {
        text = "服务设置",
        callback = function()
            require("Legado/WebConfigDialog"):openWebConfigManager()
        end,
    }, auto_upload_progress_item, {
        text = "书架显示封面",
        help_text = "开启后，书架将尝试加载并显示书籍封面",
        checked_func = function()
            return Backend:getSettings().show_cover == true
        end,
        callback = function(menu_def)
            local settings = Backend:getSettings()
            local new_state = not settings.show_cover

            local function save_and_notify()
                settings.show_cover = new_state
                local msg = new_state and "已开启封面显示" or "已关闭封面显示"
                Backend:HandleResponse(Backend:saveSettings(settings), function()
                    MessageBox:notice(msg)
                    if menu_def and menu_def.updateItems then menu_def:updateItems() end
                end, function(err_msg)
                    MessageBox:error("设置失败:", err_msg)
                end)
            end

            if new_state then
                local current_items = settings.items_per_page or G_reader_settings:readSetting("items_per_page") or 14
                if current_items > 8 then
                    MessageBox:confirm("开启封面建议每页 8 条（可自行调整最佳行数），是否自动调整？", function(is_ok)
                        if is_ok then
                            settings.items_per_page = 8
                        end
                        save_and_notify()
                    end)
                    return
                end
            end
            save_and_notify()
        end,
    }, {
        text_func = function()
            local settings = Backend:getSettings()
            local default_items = settings.show_cover and 8 or (G_reader_settings:readSetting("items_per_page") or 14)
            local current = settings.items_per_page or default_items
            return string.format("书架每页项数: %d", current)
        end,
        callback = function()
            local settings = Backend:getSettings()
            local default_items = settings.show_cover and 8 or (G_reader_settings:readSetting("items_per_page") or 14)
            local thread_spin = require("ui/widget/spinwidget"):new{
                value = settings.items_per_page or default_items,
                value_min = 4,
                value_max = 15,
                value_step = 1,
                value_hold_step = 3,
                ok_text = "确定",
                title_text = "书架每页项数",
                info_text = "设置书架每页显示书籍数量",
                default_value = default_items,
                default_text = tostring(default_items),
                callback = function(spin)
                    settings.items_per_page = spin.value
                    Backend:HandleResponse(Backend:saveSettings(settings), function()
                        MessageBox:notice(string.format("每页项数已设置为: %d", spin.value))
                    end, function(err_msg)
                        MessageBox:error("设置失败：", tostring(err_msg))
                    end)
                end,
            }
            UIManager:show(thread_spin)
        end,
    }, {
        text_func = function()
            return string.format("预载章数: %d", Backend:getSettings().preload_chapters or 4)
        end,
        callback = function()
            local settings = Backend:getSettings()
            local thread_spin = require("ui/widget/spinwidget"):new{
                value = settings.preload_chapters or 4,
                value_min = 0,
                value_max = 40,
                value_step = 1,
                value_hold_step = 5,
                ok_text = "确定",
                title_text = "预下载章节数",
                info_text = "阅读时, 向后预缓存正文",
                default_value = 4,
                default_text = "4",
                callback = function(spin)
                    settings.preload_chapters = spin.value
                    Backend:HandleResponse(Backend:saveSettings(settings), function()
                        MessageBox:notice(string.format("预缓存章节数已设置为: %d", spin.value))
                    end, function(err_msg)
                        MessageBox:error("设置失败：", tostring(err_msg))
                    end)
                end,
            }
            UIManager:show(thread_spin)
        end,
    }, {
        text_func = function()
            return string.format("下载并发数: %d", Backend:normalizeDownloadThreads(Backend:getSettings().download_threads))
        end,
        callback = function()
            local settings = Backend:getSettings()
            local thread_spin = require("ui/widget/spinwidget"):new{
                value = Backend:normalizeDownloadThreads(settings.download_threads),
                value_min = 1,
                value_max = 6,
                value_step = 1,
                value_hold_step = 2,
                ok_text = "确定",
                title_text = "同时下载进程数",
                info_text = "有的书源有限制\n（如正文异常，可尝试调为 1）",
                default_value = 2,
                default_text = "2",
                callback = function(spin)
                    settings.download_threads = Backend:normalizeDownloadThreads(spin.value)
                    Backend:HandleResponse(Backend:saveSettings(settings), function()
                        MessageBox:notice(string.format("同时下载数已设置为: %d", spin.value))
                    end, function(err_msg)
                        MessageBox:error("设置失败：", tostring(err_msg))
                    end)
                end,
            }
            UIManager:show(thread_spin)
        end,
    },
    }
    if not Backend:supportsProviderMethod("saveBookProgress") then
        for i, item in ipairs(items) do
            if item == auto_upload_progress_item then
                table.remove(items, i)
                break
            end
        end
    end
    local engine_status = LocalExtension.status(true)
    if engine_status.any_file and engine_status.usable then
        table.insert(items, 2, local_extension_item())
    end
    table.insert(items, reading_mode_item())
    table.insert(items, {
        text = "清理与维护",
        sub_item_table = {
            {
                text = "任务队列",
                keep_menu_open = true,
                callback = function()
                    require("Legado.task.QueueStatus"):show()
                end,
            },
            {
                text = "压缩数据库",
                keep_menu_open = true,
                callback = function()
                    local old_size = Backend:getDBFileSize()
                    local formatted_old = FS.formatFileSize(old_size)
                    MessageBox:confirm(
                        string.format("当前数据库大小为：%s\n\n是否确认压缩数据库？", formatted_old),
                        function(result)
                            if result then
                                TaskProg.loading("压缩中...", function()
                                    return Backend:vacuumDatabase()
                                end, function(state, response)
                                    if state == true then
                                        Backend:HandleResponse(response, function(data)
                                            local old_str = FS.formatFileSize(data.old_size)
                                            local new_str = FS.formatFileSize(data.new_size)
                                            MessageBox:info(string.format("数据库压缩完成！\n压缩前: %s\n压缩后: %s", old_str, new_str))
                                        end, function(err_msg)
                                            MessageBox:error("压缩失败：", tostring(err_msg))
                                        end)
                                    end
                                end)
                            end
                        end
                    )
                end,
            },
            {
                text = "清除认证状态",
                keep_menu_open = true,
                callback = function()
                    if Backend:clearAuthState() then
                        MessageBox:success("当前服务端的登录状态已清除！")
                    else
                        MessageBox:notice("当前服务端无需清理登录 Token")
                    end
                end,
            },
        },
    })
    return items
end

return M
