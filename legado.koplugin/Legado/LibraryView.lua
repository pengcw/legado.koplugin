local BD = require("ui/bidi")
local Font = require("ui/font")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Menu = require("ui/widget/menu")
local Device = require("device")
local T = ffiUtil.template
local _ = require("gettext")

local ChapterListing = require("Legado/ChapterListing")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local LibraryView = {
    disk_available = nil,
    -- record the current reading items
    _selected_book = nil,
    book_toc = nil,
    _ui_refresh_time = os.time(),
    _displayed_chapter = nil,
    _readerui_is_showing = nil,
    _chapter_direction = nil,
    -- menu mode
    book_menu = nil,
    stream_view = nil,
    -- file browser mode
    book_browser = nil,
    book_browser_homedir = nil,
    shared_meta_data = nil,
    shared_meta_data_directory = nil,
}

function LibraryView:init()
    if LibraryView.instance then
        return
    end
    self.book_browser_homedir = self:getBrowserHomeDir(true)
    self:backupDbWithPreCheck()
    LibraryView.instance = self
end

function LibraryView:backupDbWithPreCheck()
    local temp_dir = H.getTempDirectory()
    local last_backup_db = H.joinPath(temp_dir, "bookinfo.db.bak")
    local bookinfo_db_path = H.joinPath(temp_dir, "bookinfo.db")

    if not util.fileExists(bookinfo_db_path) then
        logger.warn("legado plugin: source database file does not exist - " .. bookinfo_db_path)
        return false
    end

    local setting_data = Backend:getSettings()
    local last_backup_time = setting_data.last_backup_time or 0
    local has_backup = util.fileExists(last_backup_db)
    local needs_backup = not has_backup or (os.time() - last_backup_time > 86400)

    if not needs_backup then
        return true
    end

    local status, err = pcall(function()
        Backend:getBookShelfCache()
    end)
    if not status then
        logger.err("legado plugin: database pre-check failed - " .. tostring(err))
        return false
    end

    if has_backup then
        util.removeFile(last_backup_db)
    end
    H.copyFileFromTo(bookinfo_db_path, last_backup_db)
    logger.info("legado plugin: backup successful")
    setting_data.last_backup_time = os.time()
    Backend:saveSettings(setting_data)
end

function LibraryView:fetchAndShow()
    local is_first = not LibraryView.instance
    local library_obj = LibraryView.instance or self:getInstance()
    local use_browser = not self:isDisableBrowserMode() and is_first and self:browserViewHasLnk()
    local widget = use_browser and self:getBrowserWidget() or self:getMenuWidget()
    if widget then
        widget:show_view()
        widget:refreshItems()
    end
    return self
end

function LibraryView:isDisableBrowserMode()
    local settings = Backend:getSettings()
    return settings and settings.disable_browser == true
end
function LibraryView:browserViewHasLnk()
    local browser_homedir = self:getBrowserHomeDir(true)
    return browser_homedir and util.directoryExists(browser_homedir) and not util.isEmptyDir(browser_homedir)
end

function LibraryView:addBkShortcut(bookinfo, always_add)
    if not always_add and self:isDisableBrowserMode() then
        return
    end
    local browser = self:getBrowserWidget()
    if browser then
        browser:addBookShortcut(bookinfo)
    end
end

function LibraryView:onRefreshLibrary()
    if self.book_menu then
        self.book_menu:onRefreshLibrary()
    end
end

function LibraryView:clearMenuItems()
    if self.book_menu then
        self.book_menu.item_table = self.book_menu:generateEmptyViewItemTable()
        self.book_menu.multilines_show_more_text = true
        self.book_menu.items_per_page = 1
        self.book_menu:updateItems()
    end
end

function LibraryView:closeMenu()
    if self.book_menu then
        self.book_menu:onClose()
    end
end

function LibraryView:openBrowserMenu(file)
    self:getInstance()
    self:getBrowserWidget()

    local book_cache_id
    local ui = FileManager.instance or ReaderUI.instance
    if file and ui and ui.bookinfo then
        -- 获取书籍缓存ID，优先从DocSettings读取，如果没有则从.lua配置文件读取
        local doc_settings = DocSettings:open(file)
        book_cache_id = doc_settings:readSetting("book_cache_id")

        if not book_cache_id then
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_config then
                book_cache_id = lnk_config:readSetting("book_cache_id")
                -- 同步到DocSettings以便下次直接读取
                if book_cache_id then
                    doc_settings:saveSetting("book_cache_id", book_cache_id):flush()
                end
            end
        end
    else
        return MessageBox:error("获取书籍信息出错")
    end

    local dialog
    local buttons = { {{
        text = "更多设置",
        callback = function()
            UIManager:close(dialog)
            UIManager:nextTick(function()
                self:openMenu()
            end)
        end
    }},{{
        text = "更换书籍封面",
        callback = function()
            if book_cache_id then
                UIManager:close(dialog)

                logger.info("更换封面: 获取到的 book_cache_id =", book_cache_id or "无")

                local custom_book_cover = DocSettings:findCustomCoverFile(file)
                if custom_book_cover and util.fileExists(custom_book_cover) then
                    logger.info("更换封面: 删除旧的自定义封面 -", custom_book_cover)
                    util.removeFile(custom_book_cover)
                end

                local DocumentRegistry = require("document/documentregistry")
                local PathChooser = require("ui/widget/pathchooser")
                local path_chooser = PathChooser:new{
                    select_directory = false,
                    path = H.getHomeDir(),
                    file_filter = function(filename)
                        return DocumentRegistry:isImageFile(filename)
                    end,
                    onConfirm = function(image_file)
                        -- 更新快捷方式封面
                        if DocSettings:flushCustomCover(file, image_file) then
                            self.book_browser:emitMetadataChanged(file)
                        end

                        -- 同时更新缓存目录的封面
                        logger.info("更换封面: book_cache_id =", book_cache_id)
                        logger.info("更换封面: image_file =", image_file)
                        if book_cache_id then
                            local cover_cache_path = H.getCoverCacheFilePath(book_cache_id)
                            local ext = image_file:match("%.([^.]+)$") or "jpg"
                            local target_cover = string.format("%s.%s", cover_cache_path, ext:lower())

                            logger.info("更换封面: 目标路径 =", target_cover)

                            -- 删除旧的缓存封面
                            local extensions = {'jpg', 'jpeg', 'png', 'webp','bmp', 'tiff'}
                            for _, old_ext in ipairs(extensions) do
                                local old_cover = string.format("%s.%s", cover_cache_path, old_ext)
                                if util.fileExists(old_cover) and old_cover ~= target_cover then
                                    logger.info("更换封面: 删除旧封面 -", old_cover)
                                    util.removeFile(old_cover)
                                end
                            end

                            -- 复制新封面到缓存目录
                            local success = H.copyFileFromTo(image_file, target_cover)
                            logger.info("更换封面: 复制结果 =", success)
                            if util.fileExists(target_cover) then
                                logger.info("更换封面: 成功 - 新封面已保存到缓存目录")
                            else
                                logger.warn("更换封面: 失败 - 新封面未能保存到缓存目录")
                            end
                        else
                            logger.warn("更换封面: 无 book_cache_id，无法更新缓存目录")
                        end
                    end
                }
                UIManager:show(path_chooser)
            else
                MessageBox:notice("操作失败: 仅能在文件浏览器下操作")
            end
        end
    }, {
        text = "显示书籍详情",
        callback = function()
            if book_cache_id then
                local bookinfo = Backend:getBookInfoCache(book_cache_id)
                if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
                    MessageBox:error('书籍不存在于当前激活书架或已被删除')
                    return
                end
                UIManager:close(dialog)
                UIManager:nextTick(function()
                    UIManager:show(require("Legado/BookDetailsDialog"):new{
                        bookinfo = bookinfo,
                        has_reload_btn = true,
                    })
                end)
            end
        end
    }}, {{
        text = "清空书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("是否清除所有书籍快捷方式?", function(result)
                if result then
                    local browser_homedir = self:getBrowserHomeDir(true)
                    if self:deleteFile(browser_homedir) then
                        MessageBox:notice("已清除")
                    end
                end
            end, {
                ok_text = "清除",
                cancel_text = "取消"
            })
        end
    }, {
        text = "修复书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            self.book_browser:verifyBooksMetadata()
        end
    }},}

    dialog = require("ui/widget/buttondialog"):new{
        title = "Legado 设置",
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons,
    }

    UIManager:show(dialog)
end

local function switch_sync_reading(settings)
    settings = H.is_tbl(settings) and settings or Backend:getSettings()
    local ok_msg = settings.sync_reading and "关闭" or "开启"
    settings.sync_reading = not settings.sync_reading or nil
    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
        MessageBox:notice(string.format("设置已%s", ok_msg))
    end, function(err_msg)
        MessageBox:error('设置失败:', err_msg)
    end)
    return settings
end

function LibraryView:openMenu(dimen)
    local dialog
    self:getInstance()
    local unified_align = dimen and "left" or "center"
    local settings = Backend:getSettings()
    local buttons = {{},{{
        text = Icons.FA_GLOBE .. " Legado WEB地址",
        callback = function()
            UIManager:close(dialog)
            require("Legado/WebConfigDialog"):openWebConfigManager(function()
                self:clearMenuItems()
                self:onRefreshLibrary()
            end)
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s 自动上传进度  %s", Icons.FA_CLOUD,
            (settings.sync_reading and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            switch_sync_reading(settings)
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s 自动生成快捷方式  %s", Icons.FA_FOLDER,
            (settings.disable_browser and Icons.UNICODE_STAR_OUTLINE or Icons.UNICODE_STAR)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "自动生成快捷方式：%s \r\n \r\n 打开书籍目录时自动在文件浏览器 Home 目录中生成对应书籍快捷方式，支持封面显示, 关闭后可在书架菜单手动生成",
                (settings.disable_browser and '[关闭]' or '[开启]')), function(result)
                if result then
                    local ok_msg = "设置已开启"
                    if not settings.disable_browser then
                        ok_msg = "设置已关闭，请手动删除目录"
                    end
                    settings.disable_browser = not settings.disable_browser or nil
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice(ok_msg)
                    end, function(err_msg)
                        MessageBox:error('设置失败:', err_msg)
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end,
        align = unified_align,
    }}, {{
        text = Icons.FA_REFRESH .. " 拉取远端排序",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("即将同步远端书架，按最后阅读时间排序。此操作将覆盖本地书架排序（手动置顶的书籍不受影响)\n是否继续？", function(result)
                if result then
                    MessageBox:loading("同步中...", function()
                        return Backend:syncAndResortBooks()
                    end, function(state, response)
                        if state == true then
                            Backend:HandleResponse(response, function(data)
                                MessageBox:notice("同步并排序成功")
                                if self.book_menu then
                                    self.book_menu:refreshItems(true)
                                end
                            end, function(err_msg)
                                MessageBox:error('操作失败: ', tostring(err_msg))
                            end)
                        else
                            MessageBox:error('操作失败', '未知错误')
                        end
                    end)
                end
            end, {
                ok_text = "确定",
                cancel_text = "取消"
            })
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s 下载线程数: %d", Icons.FA_DOWNLOAD, settings.download_threads or 1),
        callback = function()
            UIManager:close(dialog)
            local SpinWidget = require("ui/widget/spinwidget")
            local thread_spin = SpinWidget:new{
                value = settings.download_threads or 1,
                value_min = 1,
                value_max = 16,
                value_step = 1,
                value_hold_step = 2,
                ok_text = "确定",
                title_text = "设置下载线程数",
                info_text = "建议根据网络状况选择 4–8 线程\n（如下载异常，可尝试调为 1）",
                callback = function(spin)
                    local threads = spin.value
                    settings.download_threads = threads
                    Backend:HandleResponse(Backend:saveSettings(settings), function()
                        MessageBox:notice(string.format("下载线程数已设置为: %d", threads))
                    end, function(err_msg)
                        MessageBox:error('设置失败：', tostring(err_msg))
                    end)
                end
            }
            UIManager:show(thread_spin)
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s Clear all caches", Icons.FA_TRASH),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(
                "是否清空本地书架所有已缓存章节与阅读记录？\r\n（刷新会重新下载）",
                function(result)
                    if result then
                        Backend:closeDbManager()
                        MessageBox:loading("清除中", function()
                            return Backend:cleanAllBookCaches()
                        end, function(state, response)
                            if state == true then
                                Backend:HandleResponse(response, function(data)
                                    settings.servers_history = {}
                                    Backend:saveSettings(settings)
                                    MessageBox:notice("已清除")
                                    self:closeMenu()
                                end, function(err_msg)
                                    MessageBox:error('操作失败：', tostring(err_msg))
                                end)
                            end
                        end)
                    end
                end, {
                    ok_text = "清空",
                    cancel_text = "取消"
                })
        end,
        align = unified_align,
    }}, {{
        text = Icons.FA_QUESTION_CIRCLE .. ' ' .. "关于/更新",
        callback = function()
            UIManager:close(dialog)
            local about_txt = [[
-- 清风不识字，何故乱翻书 --

简介：
一个在 KOReader 中阅读 Legado 书库的插件，适配阅读 3.0，支持手机 APP 和服务器版本。初衷是 Kindle 的浏览器体验不佳，目的是部分替代受限设备的浏览器，实现流畅的网文阅读，提升老设备体验。

操作：
列表支持下拉或 Home 键刷新，右键列表菜单 / Menu 键左上角菜单，阅读界面下拉菜单有返回选项，书架和目录可绑定手势使用。

章节页面图标说明:
%1 可下载  %2 已阅读  %3 阅读进度

帮助改进：
请到 Github：pengcw/legado.koplugin 反馈 issues

版本: ver_%4]]
            local legado_update = require("Legado.Update")
            local curren_version = legado_update:getCurrentPluginVersion() or ""
            about_txt = T(about_txt, Icons.FA_DOWNLOAD, Icons.FA_CHECK_CIRCLE, Icons.FA_THUMB_TACK, curren_version)
            MessageBox:custom({
                text = about_txt,
                alignment = "left"
            })

            UIManager:nextTick(function()
                Backend:checkOta(true)
            end)
        end,
        align = unified_align,
    }}}

    if not Device:isTouchDevice() then
        table.insert(buttons, #buttons, {{
            text = Icons.FA_REFRESH .. ' ' .. " 同步书架",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshLibrary()
            end,
            align = unified_align,
        }})
    end

    if not self.disk_available then
        local cache_dir = H.getTempDirectory()
        local disk_use = util.diskUsage(cache_dir)
        if disk_use and disk_use.available then
            self.disk_available = disk_use.available / 1073741824
        end
    end

    dialog = require("ui/widget/buttondialog"):new{
        title = string.format(Icons.FA_DATABASE .. " Free: %.1f G", self.disk_available or -1),
        title_align = unified_align,
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons,
        shrink_unneeded_width = dimen and true,
        anchor = dimen and function()
            return dimen
        end or nil,
    }

    UIManager:show(dialog)
end

function LibraryView:openSearchBooksDialog(def_search_input)
    require("Legado/BookSourceResults"):searchBookDialog(function()
        self:onRefreshLibrary()
    end, def_search_input)
end

-- exit readerUI,  closing the at readerUI、FileManager the same time app will exit
-- readerUI -> ReturnLegadoChapterListing event -> show ChapterListing -> close ->show LibraryView ->close -> ? 
function LibraryView:openLegadoFolder(path, focused_file, selected_files, done_callback)
    UIManager:nextTick(function()
        if ReaderUI and ReaderUI.instance then
            ReaderUI.instance:onClose()
            self:readerUiVisible(false)
        end
        if FileManager.instance then
            FileManager.instance:reinit(path, focused_file, selected_files)
        else
            FileManager:showFiles(path, focused_file, selected_files)
        end
        if FileManager.instance and path then
            FileManager.instance:updateTitleBarPath(path)
        end
        if H.is_func(done_callback) then
            done_callback()
        end
    end)
end

function LibraryView:afterCloseReaderUi(callback)
    self:openLegadoFolder(nil, nil, nil, callback)
end

function LibraryView:loadAndRenderChapter(chapter)
    if not (H.is_tbl(chapter) and chapter.book_cache_id) then 
        logger.err("loadAndRenderChapter: chapter parameter is invalid")
        return 
    end
    if chapter.cacheExt == 'cbz' then
        local book_cache_id = chapter.book_cache_id
        local extras_settings = Backend:getBookExtras(book_cache_id)
        if H.is_tbl(extras_settings.data) and extras_settings.data.stream_image_view == true then
            MessageBox:notice("流式漫画开启")
            if not NetworkMgr:isConnected() then
                MessageBox:error("需要网络连接")
                return
            end
             self:afterCloseReaderUi(function()
                local ex_chapter = chapter
                self.stream_view = require("Legado/StreamImageView"):fetchAndShow({
                    chapter = ex_chapter,
                    on_return_callback = function()
                        local bookinfo = Backend:getBookInfoCache(ex_chapter.book_cache_id)
                        --self:openLastReadChapter(bookinfo)
                        self:showBookTocDialog(bookinfo)
                    end,
                })   
            end)
            return 
        end
    end

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)

    if (H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath)) then
        self:showReaderUI(cache_chapter)
    else
        Backend:closeDbManager()
        return MessageBox:loading("正在下载正文", function()
            return Backend:downloadChapter(chapter)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    if not H.is_tbl(data) or not H.is_str(data.cacheFilePath) then
                        MessageBox:error('下载失败')
                        return
                    end
                    self:showReaderUI(data)
                end, function(err_msg)
                    MessageBox:notice("请检查并刷新书架")
                    MessageBox:error(err_msg or '错误')
                end)
            end

        end)
    end
end

function LibraryView:ReaderUIEventCallback(chapter_direction)
    if not H.is_str(chapter_direction) then
        logger.err("ReaderUIEventCallback: chapter_direction parameter is invalid")
        return
    end

    local chapter = self:readingChapter()
    if not (H.is_tbl(chapter) and chapter.book_cache_id) then
        logger.err("ReaderUIEventCallback: current reading chapter is invalid")
        return
    end

    self:chapterDirection(chapter_direction)
    chapter.call_event = chapter_direction

    local nextChapter = Backend:findNextChapter({
        chapters_index = chapter.chapters_index,
        call_event = chapter.call_event,
        book_cache_id = chapter.book_cache_id,
        totalChapterNum = chapter.totalChapterNum
    })
 
    if H.is_tbl(nextChapter) then
        nextChapter.call_event = chapter.call_event
        self:loadAndRenderChapter(nextChapter)
    else
        local book_cache_id = self:getReadingBookId()
        if book_cache_id then
            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            self:afterCloseReaderUi(function()
                self:showBookTocDialog(bookinfo)
            end)
        end
    end
end

function LibraryView:showReaderUI(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then
        return
    end
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    self:readingChapter(chapter)

    local toc_obj = self:getBookTocWidget()
    if toc_obj and UIManager:isWidgetShown(toc_obj) then
        UIManager:close(toc_obj)
    end
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(book_path, true)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(book_path, nil, true)
    end
    UIManager:nextTick(function()
        Backend:after_reader_chapter_show(chapter)
    end)
end

function LibraryView:openLastReadChapter(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        logger.err("openLastReadChapter parameter error")
        return false
    end

    local book_cache_id = bookinfo.cache_id
    local last_read_chapter_index = Backend:getLastReadChapter(book_cache_id)
    -- default 0
    if H.is_num(last_read_chapter_index) then

        if last_read_chapter_index < 0 then
            last_read_chapter_index = 0
        end

        local chapter = Backend:getChapterInfoCache(book_cache_id, last_read_chapter_index)
        if H.is_tbl(chapter) and chapter.chapters_index then
            -- jump to the reading position
            chapter.call_event = "next"
            self:loadAndRenderChapter(chapter)
        else
            -- chapter does not exist, request refresh
            self:showBookTocDialog(bookinfo)
            MessageBox:notice('请同步刷新目录数据')
        end
        
        return true
    end 
end

function LibraryView:getSharedMetaData(dir)
    if H.is_str(self.shared_meta_data_directory) and self.shared_meta_data_directory == dir and 
            H.is_tbl(self.shared_meta_data) then
        return self.shared_meta_data
    end
    self.shared_meta_data = Backend:sharedChapterMetadata(dir)
    self.shared_meta_data_directory = dir
    return self.shared_meta_data
end

function LibraryView:initializeRegisterEvent(parent_ref)
    local DocSettings = require("docsettings")
    local FileManager = require("apps/filemanager/filemanager")
    local util = require("util")
    local logger = require("logger")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local ChapterListing = require("Legado/ChapterListing")
    local Backend = require("Legado/Backend")
    local H = require("Legado/Helper")

    local library_ref = self
    local ext_switch_sync_reading = switch_sync_reading

    local is_legado_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find('/cache/legado.cache/', 1, true) or false
    end
    local is_legado_browser_book = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == "string"
                and file_path:find("/Legado\u{200B}书目/", 1, true)
                and file_path:find("\u{200B}.html", 1, true)
    end

    function parent_ref:onShowLegadoLibraryView()
        -- FileManager menu only
        if not (self.ui and self.ui.document) then
            self:openLibraryView()
        end
        return true
    end

    function parent_ref:_loadBookFromManager(file, undoFileOpen)

        local loading_msg = MessageBox:info("前往最近阅读章节...", 3)

        -- prioritize using custom matedata book_cache_id
        local doc_settings = DocSettings:open(file)
        local book_cache_id = doc_settings:readSetting("book_cache_id")

        if not book_cache_id then
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_config then
                book_cache_id = lnk_config:readSetting("book_cache_id")
            end
        end

        -- unrecognized file
        if not H.is_str(book_cache_id) then
            UIManager:close(loading_msg)
            return undoFileOpen and undoFileOpen(file)
        end

        local library_obj = library_ref:getInstance()

        if not library_obj then
            logger.warn("oadLastReadChapter LibraryView instance not loaded")
            UIManager:close(loading_msg)
            MessageBox:error("加载书架失败")
            return
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            UIManager:close(loading_msg)
            -- no sync
            self:onShowLegadoLibraryView()
            MessageBox:notice("书籍不存在于当前激活书架或已被删除")
            return
        end

        local onReturnCallBack = function()
            -- local dir = library_obj:getBrowserHomeDir()
            -- Sometimes LibraryView instance may not start
            -- library_ref:openLegadoFolder(dir)
        end

        library_obj:refreshBookTocWidget(bookinfo, onReturnCallBack)
        library_obj:currentSelectedBook({cache_id = book_cache_id})

        library_obj:openLastReadChapter(bookinfo)
        UIManager:close(loading_msg)
        return true
    end

    function parent_ref:onShowLegadoToc(book_cache_id)
        local library_obj = library_ref:getInstance()

        if not library_obj then
            logger.warn("ShowLegadoToc LibraryView instance not loaded")
            return true
        end
        if not book_cache_id then
            book_cache_id = library_obj:getReadingBookId()
        end
        if not book_cache_id then
            logger.warn("ShowLegadoToc book_cache_id not obtained")
            return true
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            MessageBox:error('书籍不存在于当前激活书架或已被删除')
            return
        end

        library_obj:showBookTocDialog(bookinfo)
        return true
    end

    local calculate_goto_page = function(chapter_direction, page_count)
        if chapter_direction == "next" then
            return 1
        elseif page_count and chapter_direction == "prev" then
            return page_count
        end
    end
    function parent_ref:onDocSettingsLoad(doc_settings, document)
        if not (doc_settings and doc_settings.data and document) then
            return
        end
        if is_legado_path(document.file) then

            local directory, file_name = util.splitFilePathName(document.file)
            local _, extension = util.splitFileNameSuffix(file_name or "")
            if not (directory and file_name and directory ~= "" and file_name ~= "") then
                return
            end

            -- document.is_new = nil ? at readerui
            local document_is_new = (document.is_new == true) or doc_settings:readSetting("doc_props") == nil
            if document_is_new then
                doc_settings:saveSetting("legado_doc_is_new", true)
            end

            local library_obj = library_ref:getInstance()
            local shared_meta_data = library_obj:getSharedMetaData(directory)

            if H.is_tbl(shared_meta_data) and H.is_tbl(shared_meta_data.data) then
                local summary = doc_settings.data.summary -- keep status
                local book_defaults_data = util.tableDeepCopy(shared_meta_data.data)
                for k, v in pairs(book_defaults_data) do
                    doc_settings.data[k] = v
                end
                doc_settings.data.doc_path = document.file
                doc_settings.data.summary = doc_settings.data.summary or summary
            end
            

            if extension == 'txt' then
                doc_settings.data.txt_preformatted = 0
                doc_settings.data.style_tweaks = doc_settings.data.style_tweaks or {}
                doc_settings.data.style_tweaks.paragraph_whitespace_half = true
                doc_settings.data.style_tweaks.paragraphs_indent = true
                doc_settings.data.css = "./data/fb2.css"
            end

            -- statistics.koplugin
            if document then
                document.is_pic = true
            end
            -- Does it affect the future ？
            --[=[
                    if document_is_new then  
                        local bookinfo = library_ref.instance.book_toc.bookinfo
                        doc_settings.data.doc_props = doc_settings.data.doc_props or {}
                        doc_settings.data.doc_props.title = bookinfo.name or "N/A"
                        doc_settings.data.doc_props.authors = bookinfo.author or "N/A"
                    end
                ]=]

            -- current_page == nil
            -- self.ui.document:getPageCount() unreliable, sometimes equal to 0
            local chapter_direction = library_obj:chapterDirection()
            local page_count = doc_settings:readSetting("doc_pages") or 99999
            -- koreader some cases is goto last_page
            local page_number = calculate_goto_page(chapter_direction, page_count)
            if H.is_num(page_number) then
                doc_settings.data.last_page = page_number
            end

        elseif is_legado_browser_book(document.file) and doc_settings.data then
            doc_settings.data.provider = "legado"
        end
    end
    -- or UIManager:flushSettings() --onFlushSettings
    function parent_ref:onSaveSettings()
        if not (self.ui and self.ui.doc_settings) then
            return
        end
        local filepath = self.ui.document and self.ui.document.file or self.ui.doc_settings:readSetting("doc_path")
        if is_legado_path(filepath) then

            local directory, file_name = util.splitFilePathName(filepath)
            if not is_legado_path(directory) then
                return
            end
            -- logger.dbg("Legado: Saving reader settings...")
            if self.ui.doc_settings and type(self.ui.doc_settings.data) == 'table' then
                local persisted_settings_keys = require("Legado/BookMetaData")
                local library_obj = library_ref:getInstance()
                local shared_meta_data = library_obj:getSharedMetaData(directory)
               
                if H.is_tbl(shared_meta_data) and H.is_tbl(shared_meta_data.data) then
                    local is_updated
                    local doc_settings_data = util.tableDeepCopy(self.ui.doc_settings.data)
                    for k, v in pairs(doc_settings_data) do
                        if persisted_settings_keys[k] and not H.deep_equal(shared_meta_data.data[k], v) then
                            shared_meta_data.data[k] = v
                            is_updated = true
                            -- logger.info("onSaveSettings save k v", k, v)
                        end
                    end
                    if is_updated == true and H.is_func(shared_meta_data.flush) then
                        shared_meta_data:flush()
                    end
                end
            end
        elseif is_legado_browser_book(nil, self.ui) and self.ui.doc_settings then
            self.ui.doc_settings.data.provider = "legado"
        end
    end

    -- .cbz call twice ?
    function parent_ref:onReaderReady(doc_settings)
        -- logger.dbg("document.is_pic",self.ui.document.is_pic)
        -- logger.dbg(doc_settings.data.summary.status)
        if not (doc_settings and doc_settings.data and self.ui) then
            return
        end

        local library_obj = library_ref:getInstance()
        if not is_legado_path(nil, self.ui) then
            if library_obj then library_obj:readerUiVisible(false) end
            return
        elseif self.ui.link and self.ui.document then
            if library_obj then library_obj:readerUiVisible(true) end
            local chapter_direction = library_obj:chapterDirection()
            if not chapter_direction then
                return
            end

            local document_is_new =
                (self.ui.document.is_new == true) or doc_settings:readSetting("legado_doc_is_new") == true
            doc_settings:delSetting("legado_doc_is_new")
            if document_is_new and chapter_direction == "next" then
                return
            end

            local function make_pages_continuous(chapter_event)
                local current_page = self.ui:getCurrentPage()
                if not current_page or current_page == 0 then
                    -- fallback to another method if current_page is unavailable
                    -- self.ui.document.info.has_pages == self.ui.paging
                    if self.ui.paging or (self.ui.document.info and self.ui.document.info.has_pages) then
                        current_page = self.view.state.page
                    else
                        current_page = self.ui.document:getXPointer()
                        current_page = self.ui.document:getPageFromXPointer(current_page)
                    end
                end

                local page_count = self.ui.document:getPageCount()
                if not (H.is_num(page_count) and page_count > 0) then
                    page_count = doc_settings:readSetting("doc_pages")
                end

                local page_number = calculate_goto_page(chapter_event, page_count)

                if H.is_num(page_number) and current_page ~= page_number then
                    self.ui.link:addCurrentLocationToStack()
                    self.ui:handleEvent(Event:new("GotoPage", page_number))
                end
            end
            make_pages_continuous(chapter_direction)
        end
    end

    function parent_ref:onCloseDocument()
        if is_legado_path(nil, self.ui) then
            local library_obj = library_ref:getInstance()
            if library_obj then library_obj:readerUiVisible(false) end
            if not self.patches_ok then
                require("readhistory"):removeItemByPath(self.document.file)
            end
        end
    end

    function parent_ref:onShowLegadoSearch()
        local def_search_input
        if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
            local doc_props = self.ui.doc_settings.data.doc_props
            def_search_input = doc_props.authors or doc_props.title
        end

        require("Legado/BookSourceResults"):searchBookDialog(function()
            self:openLibraryView()
        end, def_search_input)

        return true
    end

    function parent_ref:onEndOfBook()
        if is_legado_path(nil, self.ui) then
            local library_obj = library_ref:getInstance()
            if library_obj then
                local chapter_direction = "next"
                library_obj:ReaderUIEventCallback(chapter_direction)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onStartOfBook()
        if is_legado_path(nil, self.ui) then
            local library_obj = library_ref:getInstance()
            if library_obj then
                local chapter_direction = "prev"
                library_obj:ReaderUIEventCallback(chapter_direction)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onShowLegadoBrowserOption(file)
        -- logger.info("Received ShowLegadoBrowserOption event", file)
        local library_obj = library_ref:getInstance()
        if FileManager.instance and library_obj then
            library_obj:openBrowserMenu(file)
        end
    end

    function parent_ref:onSuspend()
        Backend:closeDbManager()
    end

    table.insert(parent_ref.ui, 3, parent_ref)

    function parent_ref:openFile(file)
        if not H.is_str(file) then
            return
        end
        local function open_regular_file(file)
            local ReaderUI = require("apps/reader/readerui")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(file, nil, true)
        end
        if not is_legado_browser_book(file) then
            open_regular_file(file)
            return
        end
        local ok, err = pcall(function() 
            self:_loadBookFromManager(file, open_regular_file)
        end)
        if not ok then
            logger.err("fail to open file:", err)
        end
        return true
    end

    function parent_ref:initializeFromReaderUI(document, menu_items)
        if not (document and menu_items and is_legado_path(document.file)) then 
            return 
        end

        if not self.patches_ok then
            menu_items.go_back_to_legado = {
                text = "返回 Legado...",
                sorting_hint = "main",
                help_text = "点击返回 Legado 书籍目录",
                callback = function()
                    self.ui:handleEvent(Event:new("ShowLegadoToc"))
                end
            }
        end

        local settings = Backend:getSettings()

        menu_items.Legado_reader_ui_menu = {
            text = "Legado 书目",
            sorting_hint = "search",
            sub_item_table = {{
                text = "流式漫画模式",
                keep_menu_open = true,
                help_text = "在线获取内容",
                checked_func = function()
                    local library_obj = library_ref:getInstance()
                    local book_cache_id = library_obj:getReadingBookId()
                    if book_cache_id then
                        local extras_settings = Backend:getBookExtras(book_cache_id)
                        return H.is_tbl(extras_settings.data) and extras_settings.data.stream_image_view == true
                    end
                    return false
                end,
                callback = function() 
                    local library_obj = library_ref:getInstance()
                    local reading_chapter = library_obj:readingChapter()
                    local toc_obj = library_obj:getBookTocWidget()
                    if reading_chapter and toc_obj then
                        local stream_mode_item = toc_obj:getStreamModeItem(nil, function()
                            library_obj:loadAndRenderChapter(reading_chapter)
                        end)
                        if H.is_tbl(stream_mode_item) and H.is_tbl(stream_mode_item[1]) and H.is_func(stream_mode_item[1].callback) then
                            stream_mode_item[1].callback()
                        else
                            return MessageBox:error("当前阅读不是漫画类型, 设置无效")
                        end
                    end
                end,
            }, {
                text = "强制刷新本章",
                separator = true,
                callback = function()
                    local library_obj = library_ref:getInstance()
                    local reading_chapter = library_obj:readingChapter()
                    if reading_chapter then
                        reading_chapter.isDownLoaded = true
                        Backend:HandleResponse(Backend:ChangeChapterCache(reading_chapter), function(data)
                            MessageBox:notice("刷新成功")
                            UIManager:nextTick(function()
                                library_obj:loadAndRenderChapter(reading_chapter)
                            end)
                        end, function(err_msg)
                            MessageBox:error('操作失败:', tostring(err_msg))
                        end)
                    else
                        MessageBox:error("操作失败: 没有获取到当前章节")
                    end
                end,
            }, {
                text = "自动上传阅读进度",
                keep_menu_open = true,
                help_text = "阅读时，自动上传阅读进度",
                checked_func = function() return settings.sync_reading == true end,
                callback = function() ext_switch_sync_reading(settings) end,
            }, {
                text = "立即上传阅读进度",
                callback = function()
                    local library_obj = library_ref:getInstance()
                    local reading_chapter = library_obj:readingChapter()
                    if reading_chapter then
                        local toc_obj = library_obj:getBookTocWidget()
                        if toc_obj then
                            toc_obj:syncProgressShow(reading_chapter)
                        end
                    else
                        MessageBox:error("上传进度失败: 没有获取到当前章节")
                    end
                end,
            }},
        }
    end
end

local function init_book_browser(parent)
    if parent.book_browser then
        return parent.book_browser
    end

    local book_browser = {
        parent = parent
    }

    function book_browser:show_view(focused_file, selected_files)
        local homedir = self.parent:getBrowserHomeDir()
        if not homedir then
            return
        end
        local current_dir = self.parent:getBrowserCurrentDir()
        if current_dir and current_dir == homedir then
            if not self.parent.book_menu then
                self.parent.book_menu = self.parent:getMenuWidget()
            end
            self.parent.book_menu:show_view()
            self.parent.book_menu:refreshItems(true)
            return
        end
        self.parent:openLegadoFolder(homedir, focused_file, selected_files)
    end

    function book_browser:goHome()
        if FileManager.instance then
            FileManager.instance:goHome()
        end
    end

    function book_browser:refreshItems()
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end

    function book_browser:deleteFile(file, is_file)
        self.parent:deleteFile(file, is_file)
    end
    function book_browser:verifyBooksMetadata()
        -- possible cover name change
        local browser_homedir = self.parent:getBrowserHomeDir()
        if not util.directoryExists(browser_homedir) then
            return
        end

        local function is_valid_book_file(fullpath, name)
            return util.fileExists(fullpath) and H.is_str(name) and name:find("\u{200B}.html", 1, true)
        end

        local function get_book_id(fullpath)
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, fullpath)
            if ok and H.is_tbl(lnk_config) and lnk_config.readSetting then
                return lnk_config:readSetting("book_cache_id")
            end
            local doc_settings = DocSettings:open(fullpath)
            return doc_settings:readSetting("book_cache_id")
        end

        util.findFiles(browser_homedir, function(fullpath, name)
            if not is_valid_book_file(fullpath, name) then
                goto continue
            end

            local book_cache_id = get_book_id(fullpath)
            if not book_cache_id then
                self:deleteFile(fullpath, true)
                goto continue
            end

            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                goto continue
            end

            self:refreshBookMetadata(nil, fullpath, bookinfo)
            ::continue::
        end, true)
    end

    function book_browser:wirteLnk(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("book_browser.wirteLnk: parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local book_name = bookinfo.name
        local book_author = bookinfo.author or "未知作者"

        local book_lnk_name = string.format("%s-%s\u{200B}.html", book_name, book_author)
        book_lnk_name = H.getSafeFilename(book_lnk_name)
        if not book_lnk_name then
            logger.err("book_browser.wirteLnk: getSafeFilename error")
            return
        end
        local book_lnk_path = H.joinPath(home_dir, book_lnk_name)
        if book_lnk_path and util.fileExists(book_lnk_path) then
            return book_lnk_path, book_lnk_name
        end

        local book_lnk_config = Backend:getLuaConfig(book_lnk_path)
        book_lnk_config:saveSetting("book_cache_id", book_cache_id):flush()

        return book_lnk_path, book_lnk_name
    end

    function book_browser:getCustomMateData(filepath)
        local custom_metadata_file = DocSettings:findCustomMetadataFile(filepath)
        return custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
    end

    function book_browser:addBookShortcut(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id and bookinfo.coverUrl) then
            logger.err("addBookShortcut: parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local book_lnk_path, book_lnk_name = self:wirteLnk(bookinfo)
        if not (book_lnk_path and util.fileExists(book_lnk_path)) then
            logger.err("addBookShortcut: failed to create lnk")
            return
        end

        if not self:getCustomMateData(book_lnk_path) then
            self:refreshBookMetadata(book_lnk_name, book_lnk_path, bookinfo)
        else
            self:bind_provider(book_lnk_path)
        end

        if DocSettings:findCustomCoverFile(book_lnk_path) then
            return
        end

        if not NetworkMgr:isConnected() then
            return
        end
        local book_cache_id = bookinfo.cache_id
        local cover_url = bookinfo.coverUrl
        if cover_url then
            Backend:runTaskWithRetry(function()
                if DocSettings:findCustomCoverFile(book_lnk_path) then
                    self:emitMetadataChanged(book_lnk_path)
                    return true
                end
            end, 12000, 2000)
            Backend:launchProcess(function()
                return Backend:download_cover_img(book_cache_id, cover_url)
            end, function(status, cover_path, cover_name)
                if status == true and cover_path and util.fileExists(cover_path) then
                    DocSettings:flushCustomCover(book_lnk_path, cover_path)
                end
            end)
        end
    end

    function book_browser:emitMetadataChanged(path)
        --[[
        local prop_updated = {
            filepath = file,
            doc_props = book_props,
            metadata_key_updated = prop_updated,
            metadata_value_old = prop_value_old,
        }
        ]]
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end

    function book_browser:bind_provider(file)
        local doc_settings = DocSettings:open(file)
        local provider = doc_settings:readSetting("provider")
        if provider ~= "legado" then
            doc_settings:saveSetting("provider", "legado"):flush()
        end
        return doc_settings
    end

    function book_browser:refreshBookMetadata(lnk_name, lnk_path, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_tbl(bookinfo) and bookinfo.cache_id and
            bookinfo.name) then
            logger.err("browser.refreshBookMetadata parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            doc_settings:saveSetting("custom_props", {
                authors = bookinfo.author,
                title = bookinfo.name,
                description = bookinfo.intro
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("doc_props", {
                pages = 1
            }):flushCustomMetadata(lnk_path)
        end

        self:emitMetadataChanged(lnk_path)
    end

    parent.book_browser = book_browser
    return book_browser
end

local function init_book_menu(parent)
    if parent.book_menu then
        return parent.book_menu
    end
    local book_menu = Menu:new{
        name = "library_view",
        -- is_enable_shortcut = false,
        title = "书架",
        with_context_menu = true,
        align_baselines = true,
        covers_fullscreen = true, -- hint for UIManager:_repaint()
        is_borderless = true,
        title_bar_left_icon = "appbar.menu",
        title_bar_fm_style = true,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        close_callback = function()
            Backend:closeDbManager()
        end,
        show_search_item = nil,
        refresh_menu_key = nil,
        parent_ref = parent,
    }

    if Device:hasKeys() then
        book_menu.refresh_menu_key = "Home"
        if Device:hasKeyboard() then
            book_menu.refresh_menu_key = "F5"
        end
        book_menu.key_events.RefreshLibrary = { { book_menu.refresh_menu_key } }
    end
    if Device:hasDPad() then
        book_menu.key_events.FocusRight = {{ "Right" }}
        book_menu.key_events.Right = nil
    end

    function book_menu:onLeftButtonTap()
        local dimen
        if self.title_bar and self.title_bar.left_button and self.title_bar.left_button.image then
            dimen = self.title_bar.left_button.image.dimen
        end
        parent:openMenu(dimen)
    end
    function book_menu:onFocusRight()
        local focused_widget = Menu.getFocusItem(self)
        if focused_widget then

            local point = focused_widget.dimen:copy()
            point.x = point.x + point.w
            point.y = point.y + point.h / 2
            point.w = 0
            point.h = 0
            UIManager:sendEvent(Event:new("Gesture", {
                ges = "tap",
                pos = point
            }))
            return true
        end
    end
    function book_menu:onSwipe(arg, ges_ev)
        local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
        if direction == "south" then
            if NetworkMgr:isConnected() then
                UIManager:nextTick(function()
                    self:onRefreshLibrary()
                end)
            else
                MessageBox:notice("刷新失败，请检查网络")
            end
            return
        end
        Menu.onSwipe(self, arg, ges_ev)
    end

    function book_menu:refreshItems(no_recalculate_dimen)
        local books_cache_data = Backend:getBookShelfCache()
        if H.is_tbl(books_cache_data) and #books_cache_data > 0 then
            self.item_table = self:generateItemTableFromMangas(books_cache_data)
            self.multilines_show_more_text = false
            self.items_per_page = nil
        else
            self.item_table = self:generateEmptyViewItemTable()
            self.multilines_show_more_text = true
            self.items_per_page = 1
        end
        self:updateItems(nil, no_recalculate_dimen)
    end

    function book_menu:onPrimaryMenuChoice(item)
        if not item.cache_id then
            require("Legado/BookSourceResults"):searchBookDialog(function()
                self:onRefreshLibrary()
            end)
            return
        end
        
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        self.parent_ref:currentSelectedBook(item)

        if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
            return MessageBox:error("书籍信息查询出错")
        end

        local onReturnCallBack = function()
            self:show_view()
            self:refreshItems(true)
        end

        local update_toc_visibility = function()
            self.parent_ref:refreshBookTocWidget(bookinfo, onReturnCallBack, true)
        end
        
        update_toc_visibility()
        self:onClose()
        
        UIManager:nextTick(function()
            Backend:autoPinToTop(bookinfo.cache_id, bookinfo.sortOrder)
            self.parent_ref:addBkShortcut(bookinfo)
        end)
    end

    function book_menu:onRefreshLibrary()
            Backend:closeDbManager()
            MessageBox:loading("Refreshing Library", function()
                return Backend:refreshLibraryCache(parent._ui_refresh_time)
            end, function(state, response)
                if state == true then
                    Backend:HandleResponse(response, function(data)
                        MessageBox:notice('同步成功')
                        self.show_search_item = true
                        self:refreshItems()
                        self.parent_ref._ui_refresh_time = os.time()
                    end, function(err_msg)
                        MessageBox:notice(tostring(err_msg) or '同步失败')
                    end)
                end
            end)
    end

    function book_menu:onMenuHold(item)
        if not item.cache_id then
            self.parent_ref:openSearchBooksDialog()
            return
        end
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return end

        local pin_top_text = (H.is_num(bookinfo.sortOrder) and bookinfo.sortOrder > 0) and '置顶' or '取消置顶'
        local BookDetailsDialog = require("Legado/BookDetailsDialog")
        local dialog = BookDetailsDialog:new{
            bookinfo = bookinfo,
            has_reload_btn = true,
            callbacks = {
                [pin_top_text] = function()
                    Backend:manuallyPinToTop(item.cache_id, bookinfo.sortOrder)
                    self:refreshItems(true)
                end,
                ["快捷方式"] = function()
                    UIManager:nextTick(function()
                        self.parent_ref:addBkShortcut(bookinfo, true)
                    end)
                    MessageBox:notice("已调用生成，请到 Home 目录查看")
                end,
                ["删除"] = function()
                    MessageBox:confirm(string.format(
                        "是否从书架删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复",
                        bookinfo.name), function(result)
                        if result then
                            Backend:closeDbManager()
                            MessageBox:loading("删除中...", function()
                                Backend:deleteBook(bookinfo)
                                return Backend:refreshLibraryCache()
                            end, function(state, response)
                                if state == true then
                                    Backend:HandleResponse(response, function(data)
                                        MessageBox:notice("删除成功")
                                        self:refreshItems(true)
                                    end, function(err_msg)
                                        MessageBox:error('删除失败：', err_msg)
                                    end)
                                end
                            end)
                        end
                    end, {
                        ok_text = "删除",
                        cancel_text = "取消"
                    })
                end,
            }
        }
        UIManager:show(dialog)
    end

    function book_menu:onMenuSelect(entry, pos)
        if entry.select_enabled == false then
            return true
        end
        local selected_context_menu = pos ~= nil and pos.x > 0.8
        if selected_context_menu then
            self:onMenuHold(entry, pos)
        else
            self:onPrimaryMenuChoice(entry, pos)
        end
        return true
    end

    function book_menu:generateEmptyViewItemTable()
        local hint = (self.refresh_menu_key and not Device:isTouchDevice())
            and string.format("press the %s button", self.refresh_menu_key)
            or "swiping down"
        return {{
            text = string.format("No books found. Try %s to refresh.", hint),
            dim = true,
            select_enabled = false,
        }}
    end

    function book_menu:generateItemTableFromMangas(books)
        local item_table = {}
        if self.show_search_item == true then
            item_table[1] = {
                text = string.format('%s Search...', Icons.FA_MAGNIFYING_GLASS),
                mandatory = "[Go]"
            }
            self.show_search_item = nil
        end

        for _, bookinfo in ipairs(books) do

            local show_book_title = ("%s (%s)[%s]"):format(bookinfo.name or "未命名书籍",
                bookinfo.author or "未知作者", bookinfo.originName)

            table.insert(item_table, {
                cache_id = bookinfo.cache_id,
                text = show_book_title,
                mandatory = Icons.FA_ELLIPSIS_VERTICAL
            })
        end

        return item_table
    end

    function book_menu:show_view()
        UIManager:show(self)
    end

    parent.book_menu = book_menu
    return book_menu
end

function LibraryView:getBrowserHomeDir(skip_check)
    local home_dir = H.getHomeDir()
    if not H.is_str(home_dir) then
        logger.err("LibraryView.getBrowserHomeDir: home_dir is nil")
        return nil
    end
    local browser_dir_name = "Legado\u{200B}书目"
    local expected_path = H.joinPath(home_dir, browser_dir_name)
    -- nil or home_dir changed
    if not H.is_str(self.book_browser_homedir) or self.book_browser_homedir ~= expected_path then
        -- 特殊情况：设置以 browser_dir_name 为主目录
        local clean_home_dir = home_dir:gsub("/+$", "")
        local last_folder = clean_home_dir:match("([^/]+)$")
        if last_folder and last_folder == browser_dir_name then
            self.book_browser_homedir = home_dir
        else
            self.book_browser_homedir = expected_path
        end
    end

    if not skip_check then
        local success, err = pcall(H.checkAndCreateFolder, self.book_browser_homedir)
        if not (success and util.directoryExists(self.book_browser_homedir)) then
            logger.err("LibraryView.getBrowserHomeDir: failed to create directory - " ..
                           tostring(err or "unknown error"))
            return nil
        end
    end
    return self.book_browser_homedir
end

function LibraryView:deleteFile(file, is_file)
    local exists = is_file and util.fileExists(file) or util.directoryExists(file)
    if not exists then
        return false
    end

    if FileManager.instance and FileManager.instance.goHome then
        pcall(function()
            FileManager.instance:goHome()
        end)
        FileManager.instance:deleteFile(file, is_file)
        pcall(function()
            FileManager.instance:onRefresh()
        end)
        return true
    end
    if is_file then
        return util.removeFile(file)
    else
        return pcall(ffiUtil.purgeDir, file)
    end
end

function LibraryView:getBrowserCurrentDir()
    local file_manager = FileManager.instance
    if file_manager and file_manager.file_chooser then
        return file_manager.file_chooser.path
    end
    local readerui = ReaderUI.instance
    if readerui then
        return readerui:getLastDirFile()
    end
end

function LibraryView:getInstance()
    if not LibraryView.instance then
        self:init()
        if not LibraryView.instance then
            logger.err("LibraryView init not loaded")
        end
    end
    return self
end

function LibraryView:getBrowserWidget()
    return init_book_browser(self)
end

function LibraryView:getMenuWidget()
    return init_book_menu(self)
end

function LibraryView:getBookTocWidget()
    return self.book_toc
end

function LibraryView:refreshBookTocWidget(bookinfo, onReturnCallBack, visible)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        logger.err("refreshBookTocWidget parameter error")
        return self.book_toc
    end

    local book_cache_id = bookinfo.cache_id

    local toc_obj = self.book_toc
    if not (H.is_tbl(toc_obj) and H.is_tbl(toc_obj.bookinfo) and 
            toc_obj.bookinfo.cache_id == book_cache_id) then
            logger.dbg("add new book_toc widget")

            self.book_toc = ChapterListing:fetchAndShow({
                cache_id = bookinfo.cache_id,
                bookUrl = bookinfo.bookUrl,
                durChapterIndex = bookinfo.durChapterIndex,
                name = bookinfo.name,
                author = bookinfo.author,
                cacheExt = bookinfo.cacheExt,
                origin = bookinfo.origin,
                originName = bookinfo.originName,
                originOrder = bookinfo.originOrder,
                coverUrl = bookinfo.coverUrl,

            }, onReturnCallBack, function(chapter)
                    self:loadAndRenderChapter(chapter)
            end, true, visible)

    else
        logger.dbg("update book_toc widget ReturnCallback")
        self.book_toc:updateReturnCallback(onReturnCallBack)

        if visible == true then
            self.book_toc:refreshItems(nil, true)
            UIManager:show(self.book_toc)
        end
    end

    return self.book_toc
end

function LibraryView:showBookTocDialog(bookinfo)
    -- Simple display should not cause changes onReturnCallBack
    return self:refreshBookTocWidget(bookinfo, nil, true)
end

function LibraryView:chapterDirection(direction)
    self._chapter_direction = self._chapter_direction or "next"
    if direction == "prev" or direction == "next" then
        self._chapter_direction = direction
    end
    return self._chapter_direction
end

function LibraryView:getReadingBookId()
    local book_cache_id
    local current_reading_chapter = self:readingChapter()
    local toc_obj = self:getBookTocWidget()
    local current_selected_book = self:currentSelectedBook()

    if current_reading_chapter and current_reading_chapter.book_cache_id then
        book_cache_id = current_reading_chapter.book_cache_id
    elseif toc_obj and H.is_tbl(toc_obj.bookinfo) and toc_obj.bookinfo.cache_id then
        book_cache_id = toc_obj.bookinfo.cache_id
    elseif current_selected_book then
        book_cache_id = current_selected_book.cache_id
    end
    return book_cache_id
end

function LibraryView:readingChapter(chapter)
    if H.is_tbl(chapter) and chapter.book_cache_id then
        self._displayed_chapter = chapter
        return self._displayed_chapter
    else
        local current = self._displayed_chapter
        if H.is_tbl(current) and current.book_cache_id then
            return current
        end
    end
end

function LibraryView:readerUiVisible(is_showing)
    if H.is_boolean(is_showing) then
        self._readerui_is_showing = is_showing
    end
    return self._readerui_is_showing
end

function LibraryView:currentSelectedBook(book)
    if H.is_tbl(book) and book.cache_id then
        self._selected_book = book
    end
    return self._selected_book
end

return LibraryView
