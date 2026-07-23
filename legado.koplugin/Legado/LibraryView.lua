local Font = require("ui/font")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")

local ChapterListing = require("Legado/ChapterListing")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local PlgState = require("Legado/PlgState")
local init_book_links = require("Legado/BookLinks")
local init_book_shelf = require("Legado/BookShelf")

local LibraryView = {
    book_toc = nil,
    book_shelf = nil,
    stream_view = nil,
    book_links = nil,
}

function LibraryView:init()
    if LibraryView.instance then
        return
    end
    self:getBrowserHomeDir(true)
    Backend:backupDbWithPreCheck()
    LibraryView.instance = self
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
    if self.book_shelf then
        self.book_shelf:onRefreshLibrary()
    end
end

function LibraryView:clearMenuItems()
    if self.book_shelf then
        self.book_shelf.item_table = self.book_shelf:generateEmptyViewItemTable()
        self.book_shelf.multilines_show_more_text = true
        self.book_shelf.items_per_page = 1
        self.book_shelf:updateItems()
    end
end

function LibraryView:closeMenu()
    if self.book_shelf then
        self.book_shelf:onClose()
    end
end

function LibraryView:openBrowserMenu(file)
    self:getInstance()
    self:getBrowserWidget()

    local book_cache_id
    local ui = FileManager.instance or ReaderUI.instance
    if file and ui and ui.bookinfo then
        local doc_settings = DocSettings:open(file)
        book_cache_id = doc_settings:readSetting("book_cache_id")

        if not book_cache_id then
            local ok, lnk_conf = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_conf then
                book_cache_id = lnk_conf:readSetting("book_cache_id")
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
        text = "更多设置 >>",
        callback = function()
            UIManager:close(dialog)
            UIManager:nextTick(function() self:openMenu() end)
        end
    }, {
        text = "书籍详情 >>",
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
                        lnk_file = file,
                    })
                end)
            end
        end
    }}, {{
        text = "清空云端书籍链接",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("是否清除所有云端书籍链接?", function(result)
                if result then
                    local browser_homedir = self:getBrowserHomeDir(true)
                    if self:deleteFile(browser_homedir) then
                        MessageBox:notice("已清除")
                    end
                end
            end, { ok_text = "清除", cancel_text = "取消" })
        end
    }, {
        text = "修复云端书籍链接",
        callback = function()
            UIManager:close(dialog)
            self.book_links:verifyBooksMetadata()
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

function LibraryView:openMenu(dimen)
    local dialog
    self:getInstance()
    local unified_align = dimen and "left" or "center"
    local buttons = {{},{{
        text = Icons.FA_SEARCH .. " 添加书籍",
        callback = function()
            UIManager:close(dialog)
            self:openSearchBooksDialog()
        end,
        align = unified_align,
    }}, {{
        text = Icons.FA_GLOBE .. " 切换书架",
        callback = function()
            UIManager:close(dialog)
            require("Legado/WebConfigDialog"):openWebConfigManager(function()
                self:clearMenuItems()
                self:onRefreshLibrary()
            end)
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
                                if self.book_shelf then
                                    self.book_shelf:refreshItems(true)
                                end
                            end, function(err_msg)
                                MessageBox:error('操作失败: ', tostring(err_msg))
                            end)
                        else
                            MessageBox:error('操作失败', '未知错误')
                        end
                    end)
                end
            end, { ok_text = "确定", cancel_text = "取消" })
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

    dialog = require("ui/widget/buttondialog"):new{
        title = "书架操作",
        title_align = unified_align,
        buttons = buttons,
        shrink_unneeded_width = dimen and true,
        anchor = dimen and function() return dimen end or nil,
    }
    UIManager:show(dialog)
end

function LibraryView:openSearchBooksDialog(def_search_input)
    require("Legado/BookSourceResults"):searchBookDialog(function()
        self:onRefreshLibrary()
    end, def_search_input)
end

function LibraryView:openLegadoFolder(path, focused_file, selected_files, done_callback)
    UIManager:nextTick(function()
        if ReaderUI and ReaderUI.instance then
            ReaderUI.instance:onClose()
            PlgState:readerUiVisible(false)
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

function LibraryView:ReaderUIEventCallback(chapter_direction, ui)
    if not H.is_str(chapter_direction) then return end

    local fullpath = ui and ui.document and ui.document.file
    local chapter = PlgState:readingChapter()
    
    if not (H.is_tbl(chapter) and chapter.book_cache_id) and fullpath then
        local doc_settings = DocSettings:open(fullpath)
        if doc_settings.data and doc_settings.data.doc_props then
            local chapters_index = doc_settings.data.doc_props.chapters_index
            local book_cache_id = doc_settings.data.doc_props.book_cache_id
            if book_cache_id and H.is_num(chapters_index) then
                chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
                if H.is_tbl(chapter) and chapter.book_cache_id then
                    PlgState:readingChapter(chapter)
                end
            end
        end
    end

    if not (H.is_tbl(chapter) and chapter.book_cache_id) then return end

    PlgState:chapterDirection(chapter_direction)
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
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then return end
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    PlgState:readingChapter(chapter)

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
end

function LibraryView:openLastReadChapter(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return false end

    local book_cache_id = bookinfo.cache_id
    local last_read_chapter_index = Backend:getLastReadChapter(book_cache_id)
    if H.is_num(last_read_chapter_index) then
        if last_read_chapter_index < 0 then last_read_chapter_index = 0 end
        local chapter = Backend:getChapterInfoCache(book_cache_id, last_read_chapter_index)
        if H.is_tbl(chapter) and chapter.chapters_index then
            chapter.call_event = "next"
            self:loadAndRenderChapter(chapter)
        else
            self:showBookTocDialog(bookinfo)
            MessageBox:notice('请同步刷新目录数据')
        end
        return true
    end 
end

function LibraryView:getSharedMetaData(dir)
    local cached_meta = PlgState:sharedMetaData(dir)
    if cached_meta then return cached_meta end
    
    local new_meta = Backend:sharedChapterMetadata(dir)
    PlgState:sharedMetaData(dir, new_meta)
    return new_meta
end

function LibraryView:getBrowserHomeDir(skip_check)
    local home_dir = H.getHomeDir()
    if not H.is_str(home_dir) then return nil end
    
    local browser_dir_name = "Legado\u{200B}书目"
    local expected_path = H.joinPath(home_dir, browser_dir_name)
    
    if not H.is_str(PlgState.book_links_homedir) or PlgState.book_links_homedir ~= expected_path then
        local clean_home_dir = home_dir:gsub("/+$", "")
        local last_folder = clean_home_dir:match("([^/]+)$")
        if last_folder and last_folder == browser_dir_name then
            PlgState.book_links_homedir = home_dir
        else
            PlgState.book_links_homedir = expected_path
        end
    end

    if not skip_check then
        local success, err = pcall(H.checkAndCreateFolder, PlgState.book_links_homedir)
        if not (success and util.directoryExists(PlgState.book_links_homedir)) then
            return nil
        end
    end
    return PlgState.book_links_homedir
end

function LibraryView:deleteFile(file, is_file)
    local exists = is_file and util.fileExists(file) or util.directoryExists(file)
    if not exists then return false end

    if FileManager.instance and FileManager.instance.goHome then
        pcall(function() FileManager.instance:goHome() end)
        FileManager.instance:deleteFile(file, is_file)
        pcall(function() FileManager.instance:onRefresh() end)
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
    end
    return self
end

function LibraryView:getBrowserWidget()
    return init_book_links(self)
end

function LibraryView:getMenuWidget()
    return init_book_shelf(self)
end

function LibraryView:getBookTocWidget()
    return self.book_toc
end

function LibraryView:refreshBookTocWidget(bookinfo, onReturnCallBack, visible)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return self.book_toc end

    local book_cache_id = bookinfo.cache_id
    local toc_obj = self.book_toc
    
    if not (H.is_tbl(toc_obj) and H.is_tbl(toc_obj.bookinfo) and toc_obj.bookinfo.cache_id == book_cache_id) then
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
        self.book_toc:updateReturnCallback(onReturnCallBack)
        if visible == true then
            self.book_toc:refreshItems(nil, true)
            UIManager:show(self.book_toc)
        end
    end
    return self.book_toc
end

function LibraryView:showBookTocDialog(bookinfo)
    PlgState:chapterDirection("nil")
    return self:refreshBookTocWidget(bookinfo, nil, true)
end

function LibraryView:getReadingBookId()
    local book_cache_id
    local current_reading_chapter = PlgState:readingChapter()
    local toc_obj = self:getBookTocWidget()
    local current_selected_book = PlgState:currentSelectedBook()

    if current_reading_chapter and current_reading_chapter.book_cache_id then
        book_cache_id = current_reading_chapter.book_cache_id
    elseif toc_obj and H.is_tbl(toc_obj.bookinfo) and toc_obj.bookinfo.cache_id then
        book_cache_id = toc_obj.bookinfo.cache_id
    elseif current_selected_book then
        book_cache_id = current_selected_book.cache_id
    end
    return book_cache_id
end

return LibraryView