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
    local dialog
    local buttons = { {{
        text = "更换书籍封面",
        callback = function()
            local ui = FileManager.instance or ReaderUI.instance
            if file and ui and ui.bookinfo then
                UIManager:close(dialog)

                logger.info("更换封面: 快捷方式文件 =", file)

                -- 获取书籍缓存ID，优先从DocSettings读取，如果没有则从.lua配置文件读取
                local doc_settings = DocSettings:open(file)
                local book_cache_id = doc_settings:readSetting("book_cache_id")

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
                            local extensions = {'jpg', 'jpeg', 'png', 'webp', 'gif'}
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
        text = "更多设置",
        callback = function()
            UIManager:close(dialog)
            UIManager:nextTick(function()
                self:openMenu()
            end)
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
    }}, {{
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

local function switch_stream_mode(settings, callback)
    settings = H.is_tbl(settings) and settings or Backend:getSettings()
    MessageBox:confirm(string.format(
        "当前模式: %s \r\n \r\n缓存模式: 边看边下载。\n缺点：占空间。\n优点：预加载后相对流畅。\r\n \r\n流式：不下载到磁盘。\n缺点：对网络要求较高且画质缺少优化，需要下载任一章节后才能开启（建议服务端开启图片代理）。\n优点：不占空间。",
        (settings.stream_image_view and '[流式]' or '[缓存]')), function(result)
        if result then
            settings.stream_image_view = not settings.stream_image_view or nil
            Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                MessageBox:notice("设置成功")
                if H.is_func(callback) then callback() end
            end, function(err_msg)
                MessageBox:error('设置失败:', err_msg)
            end)
        end
    end, {
        ok_text = "切换",
        cancel_text = "取消"
    })
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
        text = string.format("%s 流式漫画模式  %s", Icons.FA_BOOK,
            (settings.stream_image_view and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            switch_stream_mode(settings)
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
        logger.err("loadAndRenderChapter  parameter error")
        return 
    end
    if chapter.cacheExt == 'cbz' and Backend:getSettings().stream_image_view == true then
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
    local chapter = self:readingChapter()
    if not (H.is_str(chapter_direction) and H.is_tbl(chapter)) then
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
    local ext_switch_stream_mode = switch_stream_mode

    local is_legado_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find('/cache/legado.cache/', 1, true) or false
    end
    local is_legado_browser_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:find("/Legado\u{200B}书目/", 1, true) or false
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

            local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
            -- document.is_new = nil ? at readerui
            local document_is_new = (document.is_new == true) or doc_settings:readSetting("doc_props") == nil
            if document_is_new then
                doc_settings:saveSetting("legado_doc_is_new", true)
            end

            if util.fileExists(book_defaults_path) then
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                if book_defaults and H.is_tbl(book_defaults.data) then
                    local summary = doc_settings.data.summary -- keep status
                    local book_defaults_data = util.tableDeepCopy(book_defaults.data)
                    for k, v in pairs(book_defaults_data) do
                        doc_settings.data[k] = v
                    end
                    doc_settings.data.doc_path = document.file
                    doc_settings.data.summary = doc_settings.data.summary or summary
                end
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
            local library_obj = library_ref:getInstance()
            local chapter_direction = library_obj:chapterDirection()
            local page_count = doc_settings:readSetting("doc_pages") or 99999
            -- koreader some cases is goto last_page
            local page_number = calculate_goto_page(chapter_direction, page_count)
            if H.is_num(page_number) then
                doc_settings.data.last_page = page_number
            end

        elseif is_legado_browser_path(document.file) and doc_settings.data then
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
                local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                local doc_settings_data = util.tableDeepCopy(self.ui.doc_settings.data)
                local is_updated

                for k, v in pairs(doc_settings_data) do
                    if persisted_settings_keys[k] and not H.deep_equal(book_defaults.data[k], v) then
                        book_defaults.data[k] = v
                        is_updated = true
                        -- logger.info("onSaveSettings save k v", k, v)
                    end
                end
                if is_updated == true then
                    book_defaults:flush()
                end
            end
        elseif is_legado_browser_path(nil, self.ui) and self.ui.doc_settings then
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
        if not (is_legado_browser_path(file) and file:find("\u{200B}.html", 1, true)) then
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
                help_text = "阅读时，自动上传阅读进度",
                checked_func = function() return settings.stream_image_view == true end,
                callback = function() 
                    local library_obj = library_ref:getInstance()
                    local reading_chapter = library_obj:readingChapter()
                    if reading_chapter.cacheExt ~= 'cbz'  then
                        return MessageBox:error("当前阅读不是漫画类型, 设置无效")
                    end
                    switch_stream_mode(settings, function()
                        library_obj:loadAndRenderChapter(reading_chapter)
                    end)
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
                            UIManager:nextChapter(function()
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
        book_lnk_name = util.getSafeFilename(book_lnk_name)
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
            -- 检查是否需要迁移旧版自定义封面到缓存目录
            local custom_cover = DocSettings:findCustomCoverFile(book_lnk_path)
            if custom_cover and util.fileExists(custom_cover) then
                local cover_cache_path = H.getCoverCacheFilePath(book_cache_id)
                local ext = custom_cover:match("%.([^.]+)$") or "jpg"
                local target_cover = string.format("%s.%s", cover_cache_path, ext:lower())

                -- 如果缓存目录中没有封面，迁移自定义封面
                local has_cached_cover = false
                local extensions = {'jpg', 'jpeg', 'png', 'webp', 'gif'}
                for _, check_ext in ipairs(extensions) do
                    local check_cover = string.format("%s.%s", cover_cache_path, check_ext)
                    if util.fileExists(check_cover) then
                        has_cached_cover = true
                        break
                    end
                end

                if not has_cached_cover then
                    -- 复制自定义封面到缓存目录
                    H.copyFileFromTo(custom_cover, target_cover)
                    logger.info("已迁移自定义封面到缓存目录:", target_cover)
                end
            end
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
                -- 下载封面到缓存目录（统一管理）
                local cover_path, cover_name = Backend:download_cover_img(book_cache_id, cover_url)
                if cover_path and util.fileExists(cover_path) then
                    -- 快捷方式直接使用缓存封面（通过软链接或直接引用）
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

        -- 构建信息文本，当字段为空时显示空
        local msginfo = [[
书名： <<%1>>
作者： %2
分类： %3
书源： %4
总章数：%5
总字数：%6
    ]]

        msginfo = T(msginfo,
            bookinfo.name or '',
            bookinfo.author or '',
            bookinfo.kind or '',
            bookinfo.originName or '',
            bookinfo.totalChapterNum or '',
            bookinfo.wordCount or '')

        -- 检查是否为漫画类型（通过章节的 cacheExt 判断）
        local is_comic = false
        local first_chapter = Backend:getChapterInfoCache(bookinfo.cache_id, 1)
        if first_chapter then
            local cache_chapter = Backend:getCacheChapterFilePath(first_chapter, true)
            if cache_chapter and cache_chapter.cacheFilePath and
               cache_chapter.cacheFilePath:match("%.cbz$") then
                is_comic = true
            end
        end

        MessageBox:confirm(msginfo, nil, {
            icon = "notice-info",
            no_ok_button = true,
            other_buttons_first = true,
            other_buttons = {{{
                text = "简介",
                callback = function()
                    local intro_text
                    if bookinfo.intro and bookinfo.intro ~= '' then
                        intro_text = string.format("《%s》\n\n%s", bookinfo.name or "未命名", bookinfo.intro)
                    else
                        intro_text = "暂无简介"
                    end
                    MessageBox:custom({
                        text = intro_text,
                        alignment = "left"
                    })
                end
            }}, {{
                text = (bookinfo.sortOrder > 0) and '置顶书籍' or '取消置顶',
                callback = function()
                    Backend:manuallyPinToTop(item.cache_id, bookinfo.sortOrder)
                    self:refreshItems(true)
                end
            }}, {{
                text = "快捷方式",
                callback = function()
                    UIManager:nextTick(function()
                        self.parent_ref:addBkShortcut(bookinfo, true)
                    end)
                    MessageBox:notice("已调用生成，请到 Home 目录查看")
                end
            }}, {{
                text = '换源',
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        require("Legado/BookSourceResults"):changeSourceDialog(bookinfo, function()
                            self:onRefreshLibrary()
                        end)
                    end)
                end
            }}, {{
                text = is_comic and '导出 CBZ' or '导出 EPUB',
                callback = function()
                    if is_comic then
                        self.parent_ref:exportBookToCbz(bookinfo)
                    else
                        self.parent_ref:exportBookToEpub(bookinfo)
                    end
                end
            }}, {{
                text = '删除',
                callback = function()
                    MessageBox:confirm(string.format(
                        "是否删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复",
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

                end
            }}}
        })

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
                originOrder = bookinfo.originOrder

            }, onReturnCallBack, function(chapter)
                    self:loadAndRenderChapter(chapter)
            end, true, visible)

    else
        logger.dbg("update book_toc widget ReturnCallback")
        self.book_toc:updateReturnCallback(onReturnCallBack)

        if visible == true then
            self.book_toc:refreshItems()
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

function LibraryView:exportBookToCbz(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        MessageBox:error("书籍信息错误")
        return
    end

    -- 获取章节列表
    local chapter_count = Backend:getChapterCount(bookinfo.cache_id)
    if not chapter_count or chapter_count == 0 then
        MessageBox:error("该书没有章节")
        return
    end

    -- 显示加载提示
    local loading_msg
    if chapter_count > 100 then
        loading_msg = MessageBox:showloadingMessage("正在统计已缓存章节...")
    end

    -- 异步统计已缓存章节数
    UIManager:nextTick(function()
        local cached_count = 0
        local book_cache_id = bookinfo.cache_id

        -- 统计已缓存的 CBZ 章节
        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if chapter and chapter.cacheFilePath then
                if util.fileExists(chapter.cacheFilePath) then
                    cached_count = cached_count + 1
                end
            end
        end

        if loading_msg then
            if loading_msg.close then
                loading_msg:close()
            else
                UIManager:close(loading_msg)
            end
        end

        -- 确认导出
        MessageBox:confirm(string.format(
            "是否导出 <<%s>> 为 CBZ 文件？\n\n作者：%s\n总章节数：%d\n已缓存章节：%d\n\n全部导出需要下载所有章节，可能需要一些时间",
            bookinfo.name or "未命名",
            bookinfo.author or "未知作者",
            chapter_count,
            cached_count
        ), function(result)
            if not result then
                return
            end

            -- 开始导出流程（下载缺失章节）
            self:startCbzExport(bookinfo, chapter_count, false)
        end, {
            ok_text = "全部导出",
            cancel_text = "取消",
            other_buttons = {{
                {
                    text = "仅已缓存",
                    callback = function()
                        if cached_count == 0 then
                            MessageBox:error("没有已缓存的章节")
                            return
                        end
                        -- 直接导出已缓存章节（不下载）
                        self:startCbzExport(bookinfo, chapter_count, true)
                    end
                },
            }}
        })
    end)
end

function LibraryView:startCbzExport(bookinfo, chapter_count, only_cached)
    local book_cache_id = bookinfo.cache_id

    -- 开始缓存章节
    local all_chapters = Backend:getAllChapters(book_cache_id)
    loading_msg:close()
    if not (H.is_tbl(all_chapters) and #all_chapters == chapter_count) then
        return MessageBox:error('获取全部章节信息失败')
    end
    Backend:preLoadingChapters(all_chapters, nil, cache_progress_callback)

    -- 统计已缓存的章节
    local cached_chapters = {}
    local missing_count = 0

    for i, chapter in ipairs(all_chapters) do
        local cache_chapter = Backend:getCacheChapterFilePath(chapter, true)
        local is_cached = cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath)

        if is_cached then
            table.insert(cached_chapters, {
                index = i - 1,
                chapter = chapter,
                cache_chapter = cache_chapter
            })
        else
            missing_count = missing_count + 1
        end
    end

    -- 如果只导出已缓存章节，跳过下载直接生成CBZ
    if only_cached then
        MessageBox:notice(string.format('跳过 %d 个未缓存章节，开始生成 CBZ', missing_count))
        UIManager:nextTick(function()
            self:generateCbzFile(bookinfo, chapter_count, true, cached_chapters)
        end)
        return
    end

    -- 如果所有章节都已缓存，直接生成CBZ
    if missing_count == 0 then
        MessageBox:notice('所有章节已缓存，开始生成 CBZ')
        UIManager:nextTick(function()
            self:generateCbzFile(bookinfo, chapter_count, false, cached_chapters)
        end)
        return
    end

    -- 步骤2: 缓存缺失的章节
    local dialog_title = string.format("缓存书籍 %d/%d 章", missing_count, chapter_count)
    local loading_msg = missing_count > 10 and
        MessageBox:progressBar(dialog_title, {title = "正在下载章节", max = missing_count}) or
        MessageBox:showloadingMessage(dialog_title, {progress_max = missing_count})

    if not (loading_msg and loading_msg.reportProgress and loading_msg.close) then
        return MessageBox:error("进度显示控件生成失败")
    end

    local cache_complete = false
    local cache_cancelled = false

    -- 缓存进度回调
    local cache_progress_callback = function(progress, err_msg)
        if progress == false or progress == true then
            loading_msg:close()
            cache_complete = true

            if progress == true and not cache_cancelled then
                -- 缓存完成，开始生成CBZ
                UIManager:nextTick(function()
                    self:generateCbzFile(bookinfo, chapter_count)
                end)
            elseif err_msg then
                MessageBox:error('缓存章节出错：', tostring(err_msg))
            elseif cache_cancelled then
                MessageBox:notice('已取消导出')
            end
        elseif H.is_num(progress) then
            loading_msg:reportProgress(progress)
        end
    end

    Backend:preLoadingChapters(all_chapters, nil, cache_progress_callback)

    -- 添加取消按钮
    if loading_msg.cancel then
        loading_msg:setCancelCallback(function()
            cache_cancelled = true
            if not cache_complete then
                loading_msg:close()
                MessageBox:notice('已取消缓存')
            end
        end)
    end
end

function LibraryView:generateCbzFile(bookinfo, chapter_count, only_cached, cached_chapters_param)
    local book_cache_id = bookinfo.cache_id

    if not H.is_str(book_cache_id) then
        MessageBox:error("书籍缓存ID错误")
        return
    end

    -- 准备章节数据
    local valid_chapters = cached_chapters_param or {}

    if not cached_chapters_param then
        -- 未传入缓存章节列表，需要重新收集
        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if chapter then
                local cache_chapter = Backend:getCacheChapterFilePath(chapter)
                if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
                    table.insert(valid_chapters, {
                        index = i,
                        chapter = chapter,
                        cache_chapter = cache_chapter
                    })
                end
            end
        end
    end

    local actual_chapter_count = #valid_chapters

    if actual_chapter_count == 0 then
        MessageBox:error("没有可导出的章节")
        return
    end

    -- 显示生成进度
    local export_msg = MessageBox:progressBar("正在生成 CBZ 文件", {
        title = "导出进度",
        max = actual_chapter_count
    })

    if not export_msg then
        export_msg = MessageBox:showloadingMessage("正在生成 CBZ 文件")
    end

    UIManager:nextTick(function()
        local success, result = pcall(function()
            -- 准备输出路径
            local export_settings = self:getEpubExportSettings()
            local filename = self:generateExportFilename(bookinfo, ".cbz")
            local output_dir = export_settings.output_path or H.getHomeDir()
            local output_path = H.joinPath(output_dir, filename)
            local cbz_path_tmp = output_path .. '.tmp'

            -- 如果文件已存在，先删除
            if util.fileExists(output_path) then
                pcall(function()
                    util.removeFile(output_path)
                end)
            end

            -- 如果临时文件已存在，先删除
            if util.fileExists(cbz_path_tmp) then
                pcall(function()
                    util.removeFile(cbz_path_tmp)
                end)
            end

            local function get_image_ext(filename)
                local extension = filename:match("%.(%w+)$")
                if extension then
                    local valid_extensions = {
                        jpg = true, jpeg = true, png = true, 
                        gif = true, webp = true, bmp = true
                    }
                    if valid_extensions[extension:lower()] then
                        return extension
                    end
                end
                return nil
            end

            -- 创建 CBZ 压缩包
            local cbz
            local cbz_lib
            -- 准备临时目录
            local tmp_base
            local main_temp_dir
            
            local use_archiver = true
                local ok, Archiver = pcall(require, "ffi/archiver")
                if ok and Archiver then
                    cbz_lib = "archiver"
                    cbz = Archiver.Writer:new{}
                    if not cbz:open(cbz_path_tmp, "epub") then
                        -- 不能用 error 会崩溃
                        MessageBox:error(string.format("无法创建 CBZ 文件: %s", tostring(cbz.err)))
                    end
                    cbz:setZipCompression("store")
                    cbz:addFileFromMemory("mimetype", "application/vnd.comicbook+zip", os.time())
                    cbz:setZipCompression("deflate")
                else
                    use_archiver = false
                end
            

            if not use_archiver then
                local ok, ZipWriter = pcall(require, "ffi/zipwriter")
                if ok and ZipWriter then
                    cbz_lib = "zipwriter"
                    cbz = ZipWriter:new{}
                    if not cbz:open(cbz_path_tmp) then
                        -- 不能用 error 会崩溃
                        MessageBox:error("无法创建 CBZ 文件")
                    end

                    -- 解压的临时目录
                    tmp_base = H.joinPath(H.getTempDirectory(), ".tmp.sdr")
                    H.checkAndCreateFolder(tmp_base)
                    local run_stamp = tostring(os.time()) .. "_" .. tostring(math.floor(math.random() * 100000))
                    main_temp_dir = H.joinPath(tmp_base, "cbz_temp_" .. run_stamp)
                    H.checkAndCreateFolder(main_temp_dir)

                    cbz:add("mimetype", "application/vnd.comicbook+zip", true)
                else
                    -- 不能用 error 会崩溃
                    MessageBox:error("无法加载任何压缩库")
                end
            end

            -- 合并所有章节的图片到一个 CBZ
            local current_progress = 0
            local image_index = 1
            local total_pages = 0

            for _, valid_chapter in ipairs(valid_chapters) do
                local chapter = valid_chapter.chapter
                local cache_chapter = valid_chapter.cache_chapter

                -- 如果是 CBZ 文件，需要解压并提取图片
                if cache_chapter.cacheFilePath and cache_chapter.cacheFilePath:match("%.cbz$") then
                    -- 根据已有库选择使用处理方式
                   if cbz_lib == "archiver" then
                            local chapter_cbz
                            chapter_cbz = Archiver.Reader:new()
                            chapter_cbz:open(cache_chapter.cacheFilePath) 
                                -- archiver使用iterate()迭代，extractToMemory()提取内容
                                for entry in chapter_cbz:iterate() do
                                    
                                    local ext = get_image_ext(entry.path)
                                    if entry.mode == "file" and ext then
                                        
                                        local img_data = chapter_cbz:extractToMemory(entry.path)
                                        if img_data then
                                            local new_name = string.format("%04d.%s", image_index, ext)
                                            -- archiver
                                            cbz:addFileFromMemory(new_name, img_data, os.time())
                                            
                                            image_index = image_index + 1
                                            total_pages = total_pages + 1
                                        end
                                    end
                                end
                           
                            chapter_cbz:close()
                        else
                             -- 兼容旧版本处理压缩文件
                             -- 为每个章节创建独立的临时目录
                            local chapter_temp_dir = H.joinPath(main_temp_dir, "chapter_" .. current_progress)
                            logger.info(chapter_temp_dir)
                            H.checkAndCreateFolder(chapter_temp_dir)
                            
                            -- 解压 CBZ 到临时目录
                            local cache_path_escaped = cache_chapter.cacheFilePath:gsub("'", "'\\''")
                            local target_escaped = chapter_temp_dir:gsub("'", "'\\''")
                            local unzip_cmd = string.format("unzip -qqo '%s' -d '%s'", 
                                cache_path_escaped, target_escaped)
                            local result = os.execute(unzip_cmd)
                            
                            if result == 0 then
                                -- 遍历临时目录中的图片文件，按文件名排序
                                local image_files = {}
                                
                                -- 先收集所有图片文件
                                util.findFiles(chapter_temp_dir, function(path, fname, attr)
                                    if get_image_ext(fname) then
                                        table.insert(image_files, {
                                            path = path,
                                            name = fname
                                        })
                                    end
                                end, false)
                                
                                -- 按文件名排序
                                table.sort(image_files, function(a, b)
                                    local num_a = tonumber(a.name:match("^(%d+)")) or 0
                                    local num_b = tonumber(b.name:match("^(%d+)")) or 0
                                    logger.info("测试测试:num_a", num_a, num_b)
                                    return num_a < num_b
                                end)
                                
                                -- 将图片添加到 CBZ
                                for _, file in ipairs(image_files) do
                                    local file_path = H.joinPath(chapter_temp_dir, file.path)
                                    -- 读取图片文件
                                    local img_data = util.readFromFile(file_path, "rb")
                                    if img_data then
                                            local ext = get_image_ext(file.name) or "jpg"
                                            local new_name = string.format("%04d.%s", image_index, ext:lower())
                                            
                                            -- 使用 zipwriter 添加图片（启用压缩）
                                            cbz:add(new_name, img_data, false) -- false = 使用压缩

                                            --logger.info("添加图片:", new_name, "来自:", file)
                                            image_index = image_index + 1
                                            total_pages = total_pages + 1
                                    end
                                end
                                -- 清理本章节的临时目录
                                if util.directoryExists(chapter_temp_dir) then
                                    ffiUtil.purgeDir(chapter_temp_dir)
                                    util.removePath(chapter_temp_dir)
                                end
                           else
                                logger.warn("解压失败:", cache_path_escaped)
                                if util.directoryExists(chapter_temp_dir) then
                                    ffiUtil.purgeDir(chapter_temp_dir)
                                    util.removePath(chapter_temp_dir)
                                end
                            end
                        end
                end

                current_progress = current_progress + 1
                if export_msg.reportProgress then
                    export_msg:reportProgress(current_progress)
                end
            end

            -- 生成 ComicInfo.xml 元数据
            local comic_info = string.format([[<?xml version="1.0" encoding="utf-8"?>
<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Title>%s</Title>
  <Series>%s</Series>
  <Writer>%s</Writer>
  <Publisher>Legado</Publisher>
  <Genre>%s</Genre>
  <PageCount>%d</PageCount>
  <Summary>%s</Summary>
  <LanguageISO>zh</LanguageISO>
  <Manga>Yes</Manga>
</ComicInfo>]],
                H.escapeXml(bookinfo.name or "未命名"),
                H.escapeXml(bookinfo.name or "未命名"),
                H.escapeXml(bookinfo.author or "未知作者"),
                H.escapeXml(bookinfo.kind or "漫画"),
                total_pages,
                H.escapeXml(bookinfo.intro or "")
            )

            -- 添加 ComicInfo.xml 到 CBZ
            if cbz_lib == "zipwriter" then
                cbz:add("ComicInfo.xml", comic_info, true)
            else
                cbz:addFileFromMemory("ComicInfo.xml", comic_info, os.time())
            end

            -- 关闭并保存 CBZ
            if cbz and cbz.close then
                cbz:close()
            end

            -- 重命名临时文件
            if util.fileExists(output_path) then
                util.removeFile(output_path)
            end

            if cbz_lib == "zipwriter" and util.directoryExists(tmp_base) then
                -- 清理所有的临时目录
                ffiUtil.purgeDir(tmp_base)
                util.removePath(tmp_base)
            end
            
            os.rename(cbz_path_tmp, output_path)

            return {
                success = true,
                path = output_path
            }
        end)

        -- 关闭进度对话框
        if export_msg then
            if export_msg.close then
                export_msg:close()
            else
                UIManager:close(export_msg)
            end
        end

        -- 显示结果
        if success and result then
            if result.success then
                local filename = result.path and result.path:match("([^/\\]+)$") or "未知"
                local output_dir = result.path and result.path:match("(.+)[/\\]") or H.getHomeDir()
                MessageBox:confirm(
                    string.format("CBZ 导出成功！\n\n文件：%s\n位置：%s", filename, output_dir),
                    function(open_file)
                        if open_file and result.path then
                            UIManager:close(self.book_menu)
                            UIManager:scheduleIn(0.1, function()
                                require("apps/reader/readerui"):showReader(result.path)
                            end)
                        end
                    end,
                    {
                        ok_text = "打开",
                        cancel_text = "完成"
                    }
                )
            else
                MessageBox:confirm(
                    "CBZ 导出失败：" .. (result.error or "未知错误"),
                    function(retry)
                        if retry then
                            self:exportBookToCbz(bookinfo)
                        end
                    end,
                    {
                        ok_text = "重试",
                        cancel_text = "完成"
                    }
                )
            end
        else
            MessageBox:confirm(
                "CBZ 导出失败：" .. tostring(result),
                function(retry)
                    if retry then
                        self:exportBookToCbz(bookinfo)
                    end
                end,
                {
                    ok_text = "重试",
                    cancel_text = "完成"
                }
            )
        end
    end)
end

function LibraryView:exportBookToEpub(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        MessageBox:error("书籍信息错误")
        return
    end

    -- 获取章节列表
    local chapter_count = Backend:getChapterCount(bookinfo.cache_id)
    if not chapter_count or chapter_count == 0 then
        MessageBox:error("该书没有章节")
        return
    end

    -- 显示加载提示（统计章节可能需要时间）
    local loading_msg
    if chapter_count > 100 then
        loading_msg = MessageBox:showloadingMessage("正在统计已缓存章节...")
    end

    -- 异步统计已缓存章节数
    UIManager:nextTick(function()
        local cached_count = 0

        -- 优化：批量检查，减少数据库查询
        local book_cache_id = bookinfo.cache_id
        local book_cache_path = H.getBookCachePath(book_cache_id)

        -- 只需要遍历检查文件是否存在，不需要每次都查数据库
        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if chapter and chapter.cacheFilePath then
                -- 如果数据库已标记有缓存路径，快速检查文件是否存在
                if util.fileExists(chapter.cacheFilePath) then
                    cached_count = cached_count + 1
                end
            end
        end

        if loading_msg then
            if loading_msg.close then
                loading_msg:close()
            else
                UIManager:close(loading_msg)
            end
        end

        -- 确认导出
        MessageBox:confirm(string.format(
            "是否导出 <<%s>> 为 EPUB 文件？\n\n作者：%s\n总章节数：%d\n已缓存章节：%d\n\n全部导出需要下载所有章节，可能需要一些时间",
            bookinfo.name or "未命名",
            bookinfo.author or "未知作者",
            chapter_count,
            cached_count
        ), function(result)
            if not result then
                return
            end

            -- 开始导出流程（下载缺失章节）
            self:startEpubExport(bookinfo, chapter_count, false)
        end, {
            ok_text = "全部导出",
            cancel_text = "取消",
            other_buttons = {{
                {
                    text = "仅已缓存",
                    callback = function()
                        if cached_count == 0 then
                            MessageBox:error("没有已缓存的章节")
                            return
                        end
                        -- 直接导出已缓存章节（不下载）
                        self:startEpubExport(bookinfo, chapter_count, true)
                    end
                },
                {
                    text = "设置",
                    callback = function()
                        self:showEpubExportSettings()
                    end
                }
            }}
        })
    end)
end

function LibraryView:startEpubExport(bookinfo, chapter_count, only_cached)
    local book_cache_id = bookinfo.cache_id

    -- 步骤1: 生成全书章节列表，检查缓存是否存在
    local all_chapters = {}
    local missing_count = 0
    local cached_chapters = {}  -- 保存已缓存章节信息

    for i = 0, chapter_count - 1 do
        local chapter = Backend:getChapterInfoCache(book_cache_id, i)
        if chapter then
            -- 检查缓存文件是否实际存在（不依赖数据库标志）
            local cache_chapter = Backend:getCacheChapterFilePath(chapter, true)
            local is_cached = cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath)

            if not is_cached then
                -- 添加到待下载列表
                chapter.call_event = 'next'
                table.insert(all_chapters, chapter)
                missing_count = missing_count + 1
            else
                -- 保存已缓存章节信息
                table.insert(cached_chapters, {
                    index = i,
                    chapter = chapter,
                    cache_chapter = cache_chapter
                })
            end
        end
    end

    -- 如果只导出已缓存章节，跳过下载直接生成EPUB
    if only_cached then
        MessageBox:notice(string.format('跳过 %d 个未缓存章节，开始生成 EPUB', missing_count))
        UIManager:nextTick(function()
            self:generateEpubFile(bookinfo, chapter_count, true, cached_chapters)
        end)
        return
    end

    -- 如果所有章节都已缓存，直接生成EPUB
    if missing_count == 0 then
        MessageBox:notice('所有章节已缓存，开始生成 EPUB')
        UIManager:nextTick(function()
            self:generateEpubFile(bookinfo, chapter_count, false, cached_chapters)
        end)
        return
    end

    -- 步骤2: 缓存缺失的章节
    local dialog_title = string.format("缓存书籍 %d/%d 章", missing_count, chapter_count)
    local loading_msg = missing_count > 10 and
        MessageBox:progressBar(dialog_title, {title = "正在下载章节", max = missing_count}) or
        MessageBox:showloadingMessage(dialog_title, {progress_max = missing_count})

    if not (loading_msg and loading_msg.reportProgress and loading_msg.close) then
        return MessageBox:error("进度显示控件生成失败")
    end

    local cache_cancelled = false
    local cache_complete = false

    -- 缓存进度回调
    local cache_progress_callback = function(progress, err_msg)
        if progress == false or progress == true then
            loading_msg:close()
            cache_complete = true

            if progress == true and not cache_cancelled then
                -- 缓存完成，开始生成EPUB
                UIManager:nextTick(function()
                    self:generateEpubFile(bookinfo, chapter_count)
                end)
            elseif err_msg then
                MessageBox:error('缓存章节出错：', tostring(err_msg))
            elseif cache_cancelled then
                MessageBox:notice('已取消导出')
            end
        end
        if H.is_num(progress) then
            loading_msg:reportProgress(progress)
        end
    end

    -- 使用章节列表直接调用 preLoadingChapters
    -- 第一个参数支持传入待下载章节列表
    Backend:preLoadingChapters(all_chapters, nil, cache_progress_callback)

    -- 添加取消按钮（如果支持进度条）
    if loading_msg.cancel then
        loading_msg:setCancelCallback(function()
            cache_cancelled = true
            if not cache_complete then
                loading_msg:close()
                MessageBox:notice('已取消缓存')
            end
        end)
    end
end

function LibraryView:generateEpubFile(bookinfo, chapter_count, only_cached, cached_chapters_param)
    local book_cache_id = bookinfo.cache_id

    if not H.is_str(book_cache_id) then
        MessageBox:error("书籍缓存ID错误")
        return
    end

    -- 准备章节数据（如果传入了缓存章节列表，直接使用；否则重新收集）
    local valid_chapters = cached_chapters_param or {}

    if not cached_chapters_param then
        -- 未传入缓存章节列表，需要重新收集
        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if chapter then
                local cache_chapter = Backend:getCacheChapterFilePath(chapter)
                if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
                    table.insert(valid_chapters, {
                        index = i,
                        chapter = chapter,
                        cache_chapter = cache_chapter
                    })
                end
            end
        end
    end

    local actual_chapter_count = #valid_chapters

    if actual_chapter_count == 0 then
        MessageBox:error("没有可导出的章节")
        return
    end

    -- 显示生成进度
    local export_msg = MessageBox:progressBar("正在生成 EPUB 文件", {
        title = "导出进度",
        max = actual_chapter_count + 2  -- 实际章节数 + 封面 + 打包
    })

    if not export_msg then
        export_msg = MessageBox:showloadingMessage("正在生成 EPUB 文件")
    end

    UIManager:nextTick(function()
        local success, result = pcall(function()
            local current_progress = 0

            -- 准备章节数据
            local chapters = {}
            for _, valid_chapter in ipairs(valid_chapters) do
                local chapter = valid_chapter.chapter
                local cache_chapter = valid_chapter.cache_chapter

                -- 读取章节内容
                local content = ""
                if cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
                    local file_ext = cache_chapter.cacheFilePath:match("%.([^.]+)$")
                    if file_ext == "txt" then
                        local f = io.open(cache_chapter.cacheFilePath, "r")
                        if f then
                            content = f:read("*all")
                            f:close()
                            -- 将文本段落转换为HTML段落
                            content = content:gsub("([^\n]+)", "<p>%1</p>")
                        end
                    elseif file_ext == "html" or file_ext == "xhtml" then
                        local f = io.open(cache_chapter.cacheFilePath, "r")
                        if f then
                            local html_content = f:read("*all")
                            f:close()

                            -- 提取 body 中的内容，避免重复的 HTML 结构
                            local body_content = html_content:match("<body[^>]*>(.-)</body>")
                            if body_content then
                                -- 移除可能重复的标题
                                content = body_content:gsub("<h2[^>]*>.-</h2>", "", 1)
                            else
                                -- 如果没有 body 标签，尝试提取 div 内容
                                local div_content = html_content:match("<div[^>]*>(.-)</div>")
                                content = div_content or html_content
                            end
                        end
                    end
                end

                table.insert(chapters, {
                    title = chapter.title or string.format("第%d章", valid_chapter.index + 1),
                    content = content
                })

                current_progress = current_progress + 1
                if export_msg.reportProgress then
                    export_msg:reportProgress(current_progress)
                end
            end

            -- 准备输出路径
            local export_settings = self:getEpubExportSettings()
            local filename = self:generateExportFilename(bookinfo, ".epub")
            local output_dir = export_settings.output_path or H.getHomeDir()
            local output_path = H.joinPath(output_dir, filename)

            -- 如果文件已存在，先删除
            if util.fileExists(output_path) then
                pcall(function()
                    util.removeFile(output_path)
                end)
            end

            -- 获取封面（统一使用缓存目录）
            local cover_path = nil
            local cover_source = "无"

            -- 检查缓存目录中的封面
            local cover_cache_path = H.getCoverCacheFilePath(book_cache_id)
            local extensions = {'jpg', 'jpeg', 'png', 'webp', 'gif'}
            for _, ext in ipairs(extensions) do
                local cached_cover = string.format("%s.%s", cover_cache_path, ext)
                if util.fileExists(cached_cover) then
                    cover_path = cached_cover
                    cover_source = "缓存目录"
                    logger.info("EPUB导出: 使用缓存封面 -", cached_cover)
                    break
                end
            end

            -- 如果缓存中没有封面，检查是否有旧版自定义封面需要迁移
            if not cover_path then
                logger.info("EPUB导出: 缓存目录无封面，检查旧版自定义封面")
                local DocSettings = require("docsettings")
                local home_dir = H.getHomeDir()
                local book_lnk_name = string.format("%s-%s\u{200B}.html",
                    bookinfo.name or "未命名图书",
                    bookinfo.author or "未知作者")
                book_lnk_name = util.getSafeFilename(book_lnk_name)

                if book_lnk_name then
                    local book_lnk_path = H.joinPath(home_dir, book_lnk_name)
                    logger.info("EPUB导出: 检查快捷方式 -", book_lnk_path)
                    if util.fileExists(book_lnk_path) then
                        local custom_cover = DocSettings:findCustomCoverFile(book_lnk_path)
                        logger.info("EPUB导出: 自定义封面路径 -", custom_cover or "无")
                        if custom_cover and util.fileExists(custom_cover) then
                            -- 迁移旧版自定义封面到缓存目录
                            local ext = custom_cover:match("%.([^.]+)$") or "jpg"
                            local target_cover = string.format("%s.%s", cover_cache_path, ext:lower())
                            logger.info("EPUB导出: 迁移自定义封面", custom_cover, "->", target_cover)
                            H.copyFileFromTo(custom_cover, target_cover)
                            cover_path = target_cover
                            cover_source = "旧版自定义封面(已迁移)"
                            logger.info("EPUB导出: 封面迁移成功")
                        else
                            logger.info("EPUB导出: 未找到有效的自定义封面文件")
                        end
                    else
                        logger.info("EPUB导出: 快捷方式文件不存在")
                    end
                end
            end

            -- 如果还是没有封面，则下载
            if not cover_path and bookinfo.coverUrl then
                logger.info("EPUB导出: 从网络下载封面 -", bookinfo.coverUrl)
                cover_path, _ = Backend:download_cover_img(book_cache_id, bookinfo.coverUrl)
                if cover_path then
                    cover_source = "网络下载"
                    logger.info("EPUB导出: 封面下载成功 -", cover_path)
                else
                    logger.warn("EPUB导出: 封面下载失败")
                end
            elseif not cover_path then
                logger.warn("EPUB导出: 无封面URL，跳过封面")
            end

            logger.info("EPUB导出: 最终封面来源 -", cover_source, "| 路径 -", cover_path or "无")

            -- 准备自定义 CSS
            local custom_css = nil
            local use_custom_css = false
            if export_settings.use_custom_css and export_settings.custom_css_path then
                if util.fileExists(export_settings.custom_css_path) then
                    local f = io.open(export_settings.custom_css_path, "r")
                    if f then
                        custom_css = f:read("*all")
                        use_custom_css = true
                        f:close()
                    end
                end
            end

            -- 如果使用自定义 CSS，移除章节中的首字下沉相关代码
            if use_custom_css then
                for _, chapter in ipairs(chapters) do
                    if chapter.content then
                        -- 移除首字下沉的 span 标签和内联样式
                        chapter.content = chapter.content:gsub('<p%s+style="text%-indent:%s*0em;"><span%s+class="duokan%-dropcaps%-two">(.)</span>', '<p>%1')
                    end
                end
            end

            current_progress = current_progress + 1
            if export_msg.reportProgress then
                export_msg:reportProgress(current_progress)
            end

            -- 创建导出器
            local EpubHelper = require("Legado/EpubHelper")
            local exporter = EpubHelper.EpubExporter:new():init({
                title = bookinfo.name or "未命名图书",
                author = bookinfo.author or "未知作者",
                description = bookinfo.intro,
                cover_path = cover_path,
                custom_css = custom_css,
                chapters = chapters,
                output_path = output_path,
                book_cache_id = book_cache_id
            })

            -- 构建EPUB
            local build_result = exporter:build()

            current_progress = current_progress + 1
            if export_msg.reportProgress then
                export_msg:reportProgress(current_progress)
            end

            return build_result
        end)

        if export_msg.close then
            export_msg:close()
        end

        if success and result then
            if result.success then
                local filename = result.path and result.path:match("([^/\\]+)$") or "未知"
                local output_dir = result.path and result.path:match("(.+)[/\\]") or H.getHomeDir()
                MessageBox:confirm(
                    string.format("EPUB 导出成功！\n\n文件：%s\n位置：%s", filename, output_dir),
                    function(open_file)
                        if open_file and result.path then
                            -- 打开文件
                            UIManager:close(self.book_menu)
                            UIManager:scheduleIn(0.1, function()
                                require("apps/reader/readerui"):showReader(result.path)
                            end)
                        end
                    end,
                    {
                        ok_text = "打开",
                        cancel_text = "完成"
                    }
                )
            else
                MessageBox:confirm(
                    "EPUB 导出失败：" .. (result.error or "未知错误"),
                    function(retry)
                        if retry then
                            -- 重试导出
                            self:exportBookToEpub(bookinfo)
                        end
                    end,
                    {
                        ok_text = "重试",
                        cancel_text = "完成"
                    }
                )
            end
        else
            MessageBox:confirm(
                "EPUB 导出失败：" .. tostring(result),
                function(retry)
                    if retry then
                        -- 重试导出
                        self:exportBookToEpub(bookinfo)
                    end
                end,
                {
                    ok_text = "重试",
                    cancel_text = "完成"
                }
            )
        end
    end)
end

-- 获取导出设置
function LibraryView:getEpubExportSettings()
    local settings = Backend:getSettings()
    return {
        output_path = settings.epub_output_path,
        custom_css_path = settings.epub_custom_css_path,
        use_custom_css = settings.epub_use_custom_css,
        filename_template = settings.export_filename_template or "{书名}",
        epub_extension = settings.export_epub_extension or ".epub"
    }
end

-- 保存导出设置
function LibraryView:saveEpubExportSettings(export_settings)
    local settings = Backend:getSettings()
    settings.epub_output_path = export_settings.output_path
    settings.epub_custom_css_path = export_settings.custom_css_path
    settings.epub_use_custom_css = export_settings.use_custom_css
    settings.export_filename_template = export_settings.filename_template
    settings.export_epub_extension = export_settings.epub_extension
    return Backend:saveSettings(settings)
end

-- 生成导出文件名
function LibraryView:generateExportFilename(bookinfo, extension)
    local export_settings = self:getEpubExportSettings()
    local template = export_settings.filename_template or "{书名}"

    -- 如果是 EPUB，使用自定义扩展名
    local file_ext = extension
    if extension == ".epub" then
        file_ext = export_settings.epub_extension or ".epub"
    end

    -- 获取当前日期
    local date = os.date("%Y%m%d")

    -- 替换变量
    local filename = template
    filename = filename:gsub("{书名}", bookinfo.name or "未命名")
    filename = filename:gsub("{作者}", bookinfo.author or "未知作者")
    filename = filename:gsub("{导出日期}", date)

    -- 安全化文件名
    filename = util.getSafeFilename(filename)

    return filename .. file_ext
end

-- 显示导出设置菜单
function LibraryView:showEpubExportSettings()
    local export_settings = self:getEpubExportSettings()
    local dialog

    local function getOutputPathText()
        if export_settings.output_path then
            return export_settings.output_path
        else
            return H.getHomeDir()
        end
    end

    local function getCSSStatusText()
        if export_settings.use_custom_css and export_settings.custom_css_path then
            return Icons.UNICODE_STAR
        else
            return Icons.UNICODE_STAR_OUTLINE
        end
    end

    local function getFilenameTemplateText()
        return export_settings.filename_template or "{书名}"
    end

    local function getEpubExtensionText()
        return export_settings.epub_extension or ".epub"
    end

    local buttons = {{{
        text = string.format("%s 自定义输出路径", Icons.FA_FOLDER),
        callback = function()
            UIManager:close(dialog)
            local PathChooser = require("ui/widget/pathchooser")
            local path_chooser = PathChooser:new{
                title = "选择 EPUB 输出目录",
                path = getOutputPathText(),
                select_directory = true,
                onConfirm = function(output_dir)
                    export_settings.output_path = output_dir
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        MessageBox:notice("输出路径已设置为：" .. output_dir)
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end
            }
            UIManager:show(path_chooser)
        end,
    }}, {{
        text = string.format("%s 文件名模板: %s", Icons.FA_FILE, getFilenameTemplateText()),
        callback = function()
            UIManager:close(dialog)

            -- 显示变量说明对话框
            local help_text = [[
支持的变量：

{书名} - 书籍名称
{作者} - 作者名称
{导出日期} - 导出日期 (YYYYMMDD)

示例：
{书名} → 三体
{书名}-{作者} → 三体-刘慈欣
{作者}-{书名}-{导出日期} → 刘慈欣-三体-20251003

注意：文件名中的特殊字符会被自动处理
]]

            MessageBox:confirm(help_text, function(confirmed)
                if confirmed then
                    -- 显示输入对话框
                    local InputDialog = require("ui/widget/inputdialog")
                    local input_dialog
                    input_dialog = InputDialog:new{
                        title = "设置文件名模板",
                        input = export_settings.filename_template or "{书名}",
                        input_hint = "支持变量: {书名} {作者} {导出日期}",
                        buttons = {{
                            {
                                text = "取消",
                                callback = function()
                                    UIManager:close(input_dialog)
                                end,
                            },
                            {
                                text = "确定",
                                is_enter_default = true,
                                callback = function()
                                    local template = input_dialog:getInputText()
                                    export_settings.filename_template = template
                                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                                        MessageBox:notice("文件名模板已设置为：" .. template)
                                    end, function(err)
                                        MessageBox:error("设置失败：" .. tostring(err))
                                    end)
                                    UIManager:close(input_dialog)
                                end,
                            },
                        }},
                    }
                    UIManager:show(input_dialog)
                    input_dialog:onShowKeyboard()
                end
            end, {
                ok_text = "开始设置",
                cancel_text = "返回"
            })
        end,
    }}, {{
        text = string.format("%s EPUB 扩展名: %s", Icons.FA_FILE_ALT, getEpubExtensionText()),
        callback = function()
            UIManager:close(dialog)
            local ext_dialog
            local ext_buttons = {{{
                text = ".epub (标准)",
                callback = function()
                    UIManager:close(ext_dialog)
                    export_settings.epub_extension = ".epub"
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        MessageBox:notice("EPUB 扩展名已设置为：.epub")
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end,
            }}, {{
                text = ".kepub.epub (Kobo)",
                callback = function()
                    UIManager:close(ext_dialog)
                    export_settings.epub_extension = ".kepub.epub"
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        MessageBox:notice("EPUB 扩展名已设置为：.kepub.epub")
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end,
            }}}
            ext_dialog = require("ui/widget/buttondialog"):new{
                title = "选择 EPUB 扩展名",
                title_align = "center",
                buttons = ext_buttons,
            }
            UIManager:show(ext_dialog)
        end,
    }}, {{
        text = string.format("%s 自定义 CSS 样式  %s", Icons.FA_PAINT_BRUSH, getCSSStatusText()),
        callback = function()
            UIManager:close(dialog)
            local css_dialog
            local css_buttons = {{{
                text = "选择 CSS 文件",
                callback = function()
                    UIManager:close(css_dialog)
                    local PathChooser = require("ui/widget/pathchooser")
                    local path_chooser = PathChooser:new{
                        title = "选择 CSS 文件",
                        path = H.getHomeDir(),
                        select_directory = false,
                        select_file = true,
                        file_filter = function(filename)
                            return filename:match("%.css$")
                        end,
                        onConfirm = function(css_file)
                            export_settings.custom_css_path = css_file
                            export_settings.use_custom_css = true
                            Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                                MessageBox:notice("CSS 文件已设置：" .. css_file)
                            end, function(err)
                                MessageBox:error("设置失败：" .. tostring(err))
                            end)
                        end
                    }
                    UIManager:show(path_chooser)
                end,
            }}, {{
                text = "移除自定义 CSS",
                enabled = export_settings.custom_css_path ~= nil,
                callback = function()
                    UIManager:close(css_dialog)
                    export_settings.custom_css_path = nil
                    export_settings.use_custom_css = false
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        MessageBox:notice("已移除自定义 CSS，将使用默认样式")
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end,
            }}}

            css_dialog = require("ui/widget/buttondialog"):new{
                title = "CSS 样式设置",
                title_align = "center",
                buttons = css_buttons,
            }
            UIManager:show(css_dialog)
        end,
    }}, {{
        text = "重置为默认设置",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("确定要重置所有导出设置为默认值吗？", function(result)
                if result then
                    export_settings.output_path = nil
                    export_settings.custom_css_path = nil
                    export_settings.use_custom_css = false
                    export_settings.filename_template = "{书名}"
                    export_settings.epub_extension = ".epub"
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        MessageBox:notice("已重置为默认设置")
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end
            end, {
                ok_text = "重置",
                cancel_text = "取消"
            })
        end,
    }}}

    dialog = require("ui/widget/buttondialog"):new{
        title = "EPUB 导出设置",
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return LibraryView