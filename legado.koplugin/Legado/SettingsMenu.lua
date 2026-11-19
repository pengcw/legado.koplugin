-- Legado settings menu, built on demand.
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
    local ok, status = pcall(LocalExtension.status, true)
    if not ok then
        return MessageBox:error("检查扩展状态失败：" .. Error.extract_message(status))
    end
    if status.usable then
        return MessageBox:notice("扩展已可正常使用。")
    end

    local confirm_text
    if not status.any_file then
        confirm_text = "未找到扩展文件（Legado/spore/local/），是否现在安装？"
    elseif not status.loadable then
        confirm_text = "扩展无法加载，是否下载并修复？"
    elseif status.abi_ok == false then
        confirm_text = "扩展接口异常，是否下载并修复？"
    else
        confirm_text = "扩展与当前插件不兼容，是否更新？"
    end

    MessageBox:confirm(confirm_text, function(confirmed)
        if not confirmed then return end
        local Update = require("Legado/Update")
        Update:ensureEngineLibrary(function()
            MessageBox:notice("扩展已修复，版本：v" .. get_engine_version())
            if menu_def and menu_def.updateItems then menu_def:updateItems() end
        end, function(err_msg)
            if err_msg == "已取消安装" then return end
            local message = Error.extract_message(err_msg or "未知错误")
            Probe.fail("Update", "安装解析扩展", "", nil, message)
            MessageBox:error(Error.format_failure("扩展修复失败", message))
        end, true)
    end, { ok_text = "修复", cancel_text = "取消" })
end

function M.editCustomStyle()
    local editor = require("pluginloader"):getPluginInstance("texteditor")
    if not editor then
        return MessageBox:info("请先启用“文本编辑器”：\n顶部菜单 → 插件管理 → 文本编辑器。")
    end
    local EpubHelper = require("Legado/EpubHelper")
    local path = EpubHelper.getUserCssPath()
    if not util.fileExists(path) then
        local ok, err = EpubHelper.refreshStyles()
        if not ok or not util.fileExists(path) then
            return MessageBox:error("自定义样式文件创建失败：" .. tostring(err or path))
        end
    end
    local ui = editor.ui
    local document = ui and ui.document
    editor:openFile(path, function()
        if not (document and ui.document == document and ui.styletweak) then return end
        local Env = require("Legado.Helper.Env")
        if Env.is_legado_chapter_cache(nil, ui) or Env.is_legado_skeleton_book(nil, ui) then
            ui.styletweak:updateCssText(true)
        end
    end)
end

function M.getItems()
    local function update_settings_menu(menu_def)
        if menu_def and menu_def.updateItems then menu_def:updateItems() end
    end

    local function local_extension_item()
        local sub_item_table = {
                {
                    text = "关于扩展",
                    keep_menu_open = true,
                    callback = function()
                        local ok, status = pcall(LocalExtension.status, true)
                        if not ok then
                            return MessageBox:error("检查扩展状态失败：" .. Error.extract_message(status))
                        end
                        if status.usable then
                            return MessageBox:info("专门为资源有限设备书源解析优化\n当前版本：v" .. tostring(status.version))
                        end
                        if not status.any_file then
                            return MessageBox:error("未找到扩展文件（Legado/spore/local/），请修复。")
                        elseif not status.loadable then
                            return MessageBox:error("扩展无法加载，请修复。")
                        elseif status.abi_ok == false then
                            return MessageBox:error("扩展接口异常，请修复。")
                        end
                        return MessageBox:error("扩展与当前插件不兼容，请修复。")
                    end,
                }, {
                    text = "检查/修复扩展",
                    keep_menu_open = true,
                    callback = function(menu_def)
                        check_local_engine(menu_def)
                    end,
                }, {
                    text = "书源设置",
                    callback = function()
                        require("Legado/BookSourceResults"):openLocalBookSourceSettings()
                    end,
                }, {
                    text = "替换净化",
                    callback = function()
                        LocalExtension.showReplaceRules()
                    end,
                }, {
                    text = "自定义样式",
                    help_text = "保存不会自动启用样式。\n阅读时进入：样式微调 → 用户样式微调 → Legado 自定义。\n点击用于本书；长按后选择用于所有书籍，可全局启用。",
                    callback = M.editCustomStyle,
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
                    keep_menu_open = true,
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
                        MessageBox:notice("已切换为分章阅读")
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
                    "整本阅读会边看边注入章节，提供与本地书籍一致的整体阅读体验，集中记录阅读历史与统计笔记，无需预先下载全书。此功能测试阶段，遇到问题可切回分章阅读。",
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
            help_text = "选择分章阅读，或在同一本书中按需注入章节的整本阅读。",
            sub_item_table_func = function()
                local items = {
                    {
                        text = "分章阅读",
                        checked_func = function()
                            return Backend:getSettings().chapter_mode ~= false
                        end,
                        callback = function(menu_def)
                            save_reading_mode(true, menu_def)
                        end,
                    }, {
                        text = "整本阅读",
                        help_text = "边看边将章节注入同一本书，无需预先下载全书，提供与本地书籍一致的整体阅读体验，让阅读历史、阅读统计等信息集中记录。",
                        checked_func = function()
                            return Backend:getSettings().chapter_mode == false
                        end,
                        callback = function(menu_def)
                            save_reading_mode(false, menu_def)
                        end,
                    },
                }
                return items
            end,
        }
    end

    local virtual_bookshelf_item = {
        text = "目录书架",
        sub_item_table = {
            {
                text = "启用",
                checked_func = function()
                    return Backend:getSettings().virtual_bookshelf_enabled == true
                end,
                callback = function(menu_def)
                    local settings = Backend:getSettings()
                    local enabled = settings.virtual_bookshelf_enabled ~= true
                    local function save_enabled(map_cached)
                        local dir = settings.virtual_bookshelf_dir
                        if enabled and not (H.is_str(dir) and dir ~= "" and util.directoryExists(dir)) then
                            return MessageBox:info("请先设置有效的目标目录")
                        end
                        local updated = util.tableDeepCopy(settings)
                        updated.virtual_bookshelf_enabled = enabled
                        Backend:HandleResponse(Backend:saveSettings(updated), function()
                            update_settings_menu(menu_def)
                            if not map_cached then return end
                            UIManager:nextTick(function()
                                local result, err = require("Legado/BookEntry").mapCachedBooks(Backend)
                                if not result then return MessageBox:error(err) end
                                MessageBox:info(string.format("映射完成：成功 %d 本，跳过 %d 本，失败 %d 本", result.mapped, result.skipped, result.failed))
                            end)
                        end, function(err)
                            MessageBox:error("设置失败：", tostring(err))
                        end)
                    end
                    if not enabled then return save_enabled() end
                    local map_cached
                    local ConfirmBox = require("ui/widget/confirmbox")
                    local dialog = ConfirmBox:new{
                        text = "将云端书籍映射到本地目录，方便快捷打开，也可用于 Bookshelf 的分类书架。"
                            .. (ConfirmBox.addWidget and "" or "\n开启时将映射当前书架中已缓存的书籍。"),
                        ok_text = "开启",
                        cancel_text = "取消",
                        ok_callback = function()
                            save_enabled(map_cached == nil or map_cached.checked)
                        end,
                    }
                    if dialog.addWidget then
                        map_cached = require("ui/widget/checkbutton"):new{
                            text = "映射更新当前书架已缓存书籍",
                            checked = false,
                            parent = dialog,
                        }
                        dialog:addWidget(map_cached)
                    end
                    UIManager:show(dialog)
                end,
            }, {
                text_func = function()
                    local dir = Backend:getSettings().virtual_bookshelf_dir
                    if not (H.is_str(dir) and dir ~= "") then return "目标目录：未设置" end
                    local name = require("ffi/util").basename(dir)
                    return "目标目录：" .. (name ~= "" and name or "/")
                end,
                hold_callback = function()
                    local dir = Backend:getSettings().virtual_bookshelf_dir
                    MessageBox:info("目标目录：" .. (H.is_str(dir) and dir ~= "" and dir or "未设置"))
                end,
                callback = function(menu_def)
                    local dir = Backend:getSettings().virtual_bookshelf_dir
                    local has_dir = H.is_str(dir) and dir ~= ""
                    local dialog
                    dialog = require("ui/widget/buttondialog"):new{
                        title = "目标目录：" .. (has_dir and dir or "未设置")
                            .. "\n清空后将关闭目录书架，已有文件不受影响。",
                        buttons = {
                            {{
                                text = "选择目录",
                                callback = function()
                                    UIManager:close(dialog)
                                    local PathChooser = require("ui/widget/pathchooser")
                                    UIManager:show(PathChooser:new{
                                        title = "选择目标目录",
                                        path = has_dir and dir or require("Legado.Helper.Env").getHomeDir(),
                                        select_directory = true,
                                        select_file = false,
                                        onConfirm = function(dir)
                                            if not (H.is_str(dir) and dir ~= "" and util.directoryExists(dir)) then
                                                return MessageBox:error("选择的目录不可用")
                                            end
                                            local settings = util.tableDeepCopy(Backend:getSettings())
                                            local old_dir = settings.virtual_bookshelf_dir
                                            settings.virtual_bookshelf_dir = dir
                                            Backend:HandleResponse(Backend:saveSettings(settings), function()
                                                update_settings_menu(menu_def)
                                                local message = "目标目录已设置为：" .. dir
                                                if H.is_str(old_dir) and old_dir ~= "" and old_dir ~= dir then
                                                    message = message .. "\n请按需手动清理原目录中的旧文件：" .. old_dir
                                                end
                                                MessageBox:notice(message)
                                            end, function(err)
                                                MessageBox:error("设置失败：", tostring(err))
                                            end)
                                        end,
                                    })
                                end,
                            }},
                            {{
                                text = "清空设置",
                                enabled = has_dir,
                                callback = function()
                                    local settings = util.tableDeepCopy(Backend:getSettings())
                                    settings.virtual_bookshelf_dir = ""
                                    settings.virtual_bookshelf_enabled = false
                                    Backend:HandleResponse(Backend:saveSettings(settings), function()
                                        UIManager:close(dialog)
                                        update_settings_menu(menu_def)
                                        MessageBox:notice("目标目录已清空，目录书架已关闭；已有文件不受影响")
                                    end, function(err)
                                        MessageBox:error("设置失败：", tostring(err))
                                    end)
                                end,
                            }},
                            {{
                                text = "取消",
                                callback = function() UIManager:close(dialog) end,
                            }},
                        },
                    }
                    UIManager:show(dialog)
                end,
            }, {
                text = "刷新目录",
                help_text = "补建或更新当前书架已缓存书籍的快捷入口，不下载正文或删除旧文件。",
                enabled_func = function()
                    local settings = Backend:getSettings()
                    local dir = settings.virtual_bookshelf_dir
                    return settings.virtual_bookshelf_enabled == true
                        and H.is_str(dir) and dir ~= "" and util.directoryExists(dir)
                end,
                callback = function()
                    UIManager:nextTick(function()
                        local result, err = require("Legado/BookEntry").mapCachedBooks(Backend)
                        if not result then return MessageBox:error(err) end
                        MessageBox:info(string.format("刷新完成：成功 %d 本，跳过 %d 本，失败 %d 本", result.mapped, result.skipped, result.failed))
                    end)
                end,
            },
        },
    }
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
    }, virtual_bookshelf_item, {
        text = "界面设置",
        sub_item_table = {
            {
                text = "书架封面",
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
                                if is_ok then settings.items_per_page = 8 end
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
                    return string.format("书架每页项数：%d", current)
                end,
                keep_menu_open = true,
                callback = function(menu_def)
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
                                update_settings_menu(menu_def)
                            end, function(err_msg)
                                MessageBox:error("设置失败：", tostring(err_msg))
                            end)
                        end,
                    }
                    UIManager:show(thread_spin)
                end,
            }, {
                text_func = function()
                    local ratio = require("Legado/ChapterListing").getWidthRatio()
                    return string.format("阅读目录宽度：%.2f", ratio)
                end,
                help_text = "设置阅读时目录宽度比例",
                keep_menu_open = true,
                callback = function(menu_def)
                    local ratio = require("Legado/ChapterListing").getWidthRatio()
                    UIManager:show(require("ui/widget/spinwidget"):new{
                        -- 使用整数百分比，避免小数步进产生浮点累积误差。
                        value = math.floor(ratio * 50 + 0.5) * 2,
                        value_min = 40,
                        value_max = 100,
                        value_step = 2,
                        value_hold_step = 10,
                        ok_text = "确定",
                        title_text = "侧边栏目录宽度比（%）",
                        info_text = "宽度可选40～100, 仅作用于阅读时侧边目录.\n(点击中间数字可直接输入)",
                        callback = function(spin)
                            local settings = util.tableDeepCopy(Backend:getSettings())
                            settings.toc_width_ratio = spin.value / 100
                            Backend:HandleResponse(Backend:saveSettings(settings), function()
                                update_settings_menu(menu_def)
                                MessageBox:notice(string.format("已设置为：%.2f", settings.toc_width_ratio))
                            end, function(err)
                                MessageBox:error("设置失败：", tostring(err))
                            end)
                        end,
                        extra_text = "恢复默认",
                        extra_callback = function()
                            local settings = util.tableDeepCopy(Backend:getSettings())
                            settings.toc_width_ratio = nil
                            Backend:HandleResponse(Backend:saveSettings(settings), function()
                                update_settings_menu(menu_def)
                                MessageBox:notice("已恢复默认")
                            end, function(err)
                                MessageBox:error("设置失败：", tostring(err))
                            end)
                        end,
                    })
                end,
            },
        },
    }, {
        text = "阅读设置",
        sub_item_table = {
            auto_upload_progress_item, {
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
            }, reading_mode_item(),
        },
    },
    }
    local reading_items = items[#items].sub_item_table
    if not Backend:supportsProviderMethod("saveBookProgress") then
        for i, item in ipairs(reading_items) do
            if item == auto_upload_progress_item then
                table.remove(reading_items, i)
                break
            end
        end
    end
    local engine_status = LocalExtension.status(true)
    if engine_status.any_file and engine_status.usable then
        table.insert(items, 2, local_extension_item())
    end
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
