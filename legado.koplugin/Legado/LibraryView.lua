local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Device = require("device")

local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Icons = require("Legado.res.icons")
local Backend = require("Legado/Backend")
local Reader = require("Legado.Skeleton.Reader")
local SkeletonBook = require("Legado.Skeleton.Book")
local LocalExtension = require("Legado.LocalExtension")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local Probe = require("Legado.Helper.Probe")
local Error = require("Legado.Helper.Error")

local PlgState = require("Legado/PlgState")

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
    LibraryView.instance = self
end

function LibraryView:fetchAndShow()
    self:getInstance()
    local widget = self:getMenuWidget()
    if widget then
        widget:show_view()
        widget:refreshItems()
    end
    return self
end

function LibraryView:isDisableBrowserMode()
    local settings = Backend:getSettings()
    if settings and settings.chapter_mode ~= false then
        return settings.disable_browser == true
    end
    return false
end

function LibraryView:addBkShortcut(bookinfo, always_add)
    if not always_add and self:isDisableBrowserMode() then
        return nil, "当前设置已禁用本地书库入口"
    end
    local browser = self:getBrowserWidget()
    if not browser then
        return nil, "本地书库服务未就绪"
    end
    local ok, epub_path, err_msg = pcall(function()
        return browser:addBookShortcut(bookinfo)
    end)
    if not ok then
        logger.warn("addBkShortcut failed:", tostring(epub_path))
        return nil, tostring(epub_path)
    end
    return epub_path, err_msg
end

function LibraryView:onRefreshLibrary()
    if self.book_shelf then
        self.book_shelf:onRefreshLibrary()
    end
end

function LibraryView:refreshLocalModeView()
    if not self.book_shelf then return end
    self.book_shelf:refreshItems(true)
end

function LibraryView:enableLocalMode()
    local function activate_local_mode()
        local shelf_id = Backend:getCurrentBookShelfId()

        local local_sources = {}
        if Backend.dbManager and type(Backend.dbManager.getEnabledBookSources) == "function" then
            local_sources = Backend.dbManager:getEnabledBookSources(shelf_id) or {}
        end

        if #local_sources > 0 then
            local books = Backend:getBookShelfCache()
            if not books or #books == 0 then
                return MessageBox:notice("书架为空，请先同步")
            end
            pcall(function() Backend:BookSourcesAndRulesAsync(true) end)
            Backend:applyLocalModeState(true)
            self:refreshLocalModeView()
            MessageBox:notice("已启用本地接管解析")
            return
        end

        Backend:closeDbManager()
        TaskProg.loading({
            text = "首次启用正在准备本地书源...",
            dismissable = true,
            runnable = function()
                local ok, err_msg, synced = Backend:syncLocalModeData(shelf_id)
                if not ok then return false, err_msg end
                return { synced = synced == true, message = err_msg }
            end,
            callback = function(ok, result)
                if ok ~= true then
                    return MessageBox:error("本地接管解析失败", tostring(result or "书源同步失败"))
                end

                local synced = H.is_tbl(result) and result.synced == true
                if not synced then
                    local check_sources = {}
                    if Backend.dbManager and type(Backend.dbManager.getEnabledBookSources) == "function" then
                        check_sources = Backend.dbManager:getEnabledBookSources(shelf_id) or {}
                    end
                    if #check_sources == 0 then
                        return MessageBox:error("本地接管解析失败", "同步书源失败且本地无离线书源")
                    end
                end

                local books = Backend:getBookShelfCache()
                if not books or #books == 0 then
                    return MessageBox:notice("书架为空，请先同步")
                end

                Backend:applyLocalModeState(true)
                self:refreshLocalModeView()
                MessageBox:notice(synced and "已启用本地接管解析" or "已启用本地接管解析（使用离线书源）")
            end,
        })
    end

    if LocalExtension.available() then
        return MessageBox:confirm(
            "开启后可脱离服务端使用，兼容大部分书源。是否启用？",
            function(confirmed)
                if confirmed then activate_local_mode() end
            end,
            { ok_text = "启用", cancel_text = "取消" }
        )
    end

    local Update = require("Legado/Update")
    return Update:ensureEngineLibrary(
        activate_local_mode,
        function(err_msg)
            if err_msg == "已取消安装" then return end
            local message = Error.extract_message(err_msg or "未知错误")
            Probe.fail("Update", "启用本地解析", "", nil, message)
            MessageBox:error(Error.format_failure("扩展安装失败，请重试", message))
        end,
        false,
        {
            confirm_text = "开启后可脱离服务端, 目前处于测试阶段，兼容大部分书源。下载扩展后将自动启用，是否安装？",
        }
    )
end

function LibraryView:disableLocalMode()
    local ok, err_msg = Backend:toggleLocalMode(false)
    if not ok then
        return MessageBox:error("停用本地解析失败", tostring(err_msg or "请稍后重试"))
    end
    self:refreshLocalModeView()
    MessageBox:notice("已停用本地解析")
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

function LibraryView:openMenu(dimen)
    local dialog
    self:getInstance()
    local unified_align = dimen and "left" or "center"
    local local_mode = Backend:_isLocal()
    local buttons = {{}}
    if Backend:canUseBookDiscovery() then
        table.insert(buttons, {{
            text = Icons.FA_SEARCH .. " 搜书与发现",
            callback = function()
                UIManager:close(dialog)
                self:openSearchBooksDialog()
            end,
            align = unified_align,
        }})
    end
    table.insert(buttons, {{
        text = Icons.FA_GLOBE .. " 切换服务",
        callback = function()
            UIManager:close(dialog)
            require("Legado/WebConfigDialog"):openWebConfigManager(function()
                self:invalidateBookShelf()
                self:fetchAndShow()
                self:onRefreshLibrary()
            end)
        end,
        align = unified_align,
    }})

    if local_mode or PlgState.LOCAL_MODE_ENTRY_ENABLED then
        table.insert(buttons, {{
            text = local_mode and Icons.FA_CLOUD .. " 停用本地解析"
                or Icons.FA_DOWNLOAD .. " 启用本地解析",
            callback = function()
                UIManager:close(dialog)
                if local_mode then
                    self:disableLocalMode()
                else
                    self:enableLocalMode()
                end
            end,
            align = unified_align,
        }})
    end

    if not local_mode then
        table.insert(buttons, {{
            text = Icons.FA_REFRESH .. " 拉取远端排序",
            callback = function()
                UIManager:close(dialog)
                MessageBox:confirm("即将同步远端书架，按最后阅读时间排序。此操作将覆盖本地书架排序（手动置顶的书籍不受影响)\n是否继续？", function(result)
                    if result then
                        TaskProg.loading("同步中...", function()
                            return Backend:syncAndResortBooks()
                        end, function(state, response)
                            if state == true then
                                Backend:HandleResponse(response, function()
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
        }})
    end

    if not Device:isTouchDevice() then
        table.insert(buttons, #buttons, {{
            text = Icons.FA_REFRESH .. ' ' .. (local_mode and " 刷新书架" or " 同步书架"),
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

function LibraryView:openStreamImageView(chapter)
    MessageBox:notice("漫画免缓存已开启")
    self:afterCloseReaderUi(function()
        self.stream_view = require("Legado/StreamImageView"):fetchAndShow({
            chapter = chapter,
            on_return_callback = function()
                local bookinfo = Backend:getBookInfoCache(chapter.book_cache_id)
                self:showBookTocDialog(bookinfo)
            end,
            on_fallback_callback = function()
                PlgState:clearReadingRoute(chapter.book_cache_id)
                self:loadAndRenderChapter(chapter, { mode = "chapter_mode" })
            end,
        })
    end)
    return self.stream_view
end

function LibraryView:loadAndRenderChapter(chapter, options)
    if not (H.is_tbl(chapter) and chapter.book_cache_id) then
        logger.err("loadAndRenderChapter: chapter parameter is invalid")
        return
    end

    local ReadingFlow = require("Legado.ReadingFlow")
    options = options or {}
    options.parent_view = self
    options.on_error = options.on_error or function(err_msg)
        MessageBox:error(err_msg or "开书失败")
    end
    return ReadingFlow:openBook(chapter, options)
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

function LibraryView:navigateAfterReaderOpen(opts)
    opts = opts or {}
    local ui = self.ui or ReaderUI.instance
    if not (ui and ui.document) then return false end
    local doc_settings = opts.doc_settings or ui.doc_settings
    local chapter = opts.chapter

    if chapter and Env.is_legado_skeleton_book(ui.document.file) then
        local cur_resolved = Reader:resolveChapter(ui, chapter.book_cache_id)
        if cur_resolved and cur_resolved.chapters_index == chapter.chapters_index then
            Probe.eventf("Nav", "跳过同章跳转", nil, "第%d章 (book_id: %s)",
                chapter.chapters_index + 1, tostring(chapter.book_cache_id))
            return true
        end
        local toc = ui.document:getToc()
        local target = Reader:getTocEntry(toc, chapter.book_cache_id, chapter.chapters_index)
        if not target then
            logger.warn("virtual EPUB TOC entry not found for chapter", chapter.chapters_index)
            return false
        end
        Probe.eventf("Nav", "执行章节跳转", nil,
            "第%d章 (xpointer: %s, page: %s)", chapter.chapters_index + 1,
            tostring(target.xpointer or "-"), tostring(target.page or "-"))
        if target.xpointer then
            if ui.rolling and ui.rolling._wrapped_gotoXPointer then
                ui.rolling:_wrapped_gotoXPointer(target.xpointer, target.xpointer)
            else
                ui:handleEvent(Event:new("GotoXPointer", target.xpointer, target.xpointer))
            end
        elseif target.page then
            if ui.paging and ui.paging._wrapped_gotoPage then
                ui.paging:_wrapped_gotoPage(target.page)
            else
                ui:handleEvent(Event:new("GotoPage", target.page))
            end
        end
        return true
    end

    local chapter_direction = opts.chapter_direction or PlgState:chapterDirection()
    if not chapter_direction then return false end
    if not Env.is_legado_chapter_cache(nil, ui) then return false end

    local document_is_new = ui.document.is_new == true or (doc_settings and doc_settings:readSetting("legado_doc_is_new") == true)

    if document_is_new then
        if doc_settings then doc_settings:delSetting("legado_doc_is_new") end
        if chapter_direction == "next" then return true end
    end

    local current_page = ui:getCurrentPage()
    local is_paging = true

    if not H.is_num(current_page) or current_page == 0 then
        if ui.paging or (ui.document.info and ui.document.info.has_pages) then
            current_page = ui.view.state.page
        else
            is_paging = false
            local xp = ui.document:getXPointer()
            current_page = ui.document:getPageFromXPointer(tostring(xp))
        end
    end

    local page_count = ui.document:getPageCount()
    if not (H.is_num(page_count) and page_count > 0) and doc_settings then
        page_count = doc_settings:readSetting("doc_pages")
    end

    local target_page
    if chapter_direction == "next" then
        target_page = 1
    elseif chapter_direction == "prev" and page_count then
        target_page = page_count
    end

    if not H.is_num(target_page) then return false end

    if target_page == tonumber(current_page) then return true end
    if ui.link then ui.link:addCurrentLocationToStack() end

    if is_paging then
        if ui.paging and ui.paging._wrapped_gotoPage then
            ui.paging:_wrapped_gotoPage(target_page)
        else
            ui:handleEvent(Event:new("GotoPage", target_page))
        end
    else
        local page_xpointer = ui.document:getPageXPointer(target_page)
        if not page_xpointer then return false end
        if ui.rolling and ui.rolling._wrapped_gotoXPointer then
            ui.rolling:_wrapped_gotoXPointer(page_xpointer, page_xpointer)
        else
            ui:handleEvent(Event:new("GotoXPointer", page_xpointer, page_xpointer))
        end
    end
    return true
end

function LibraryView:showReaderUI(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then return end
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    if Env.is_legado_skeleton_book(book_path) then
        return SkeletonBook:openExisting(chapter, {
            parent_view = self,
            navigate = function(opts) return self:navigateAfterReaderOpen(opts) end,
        })
    end
    PlgState:readingChapter(chapter)
    local is_skeleton = false

    local toc_obj = self:getBookTocWidget()
    if toc_obj and UIManager:isWidgetShown(toc_obj) then UIManager:close(toc_obj) end
    local triggered = false
    local function navigate_to_target_chapter()
        if triggered then return end
        triggered = true
        local chapter_direction = PlgState:chapterDirection()
        PlgState:afterReadUiOpenCallback(false)
        self:navigateAfterReaderOpen({
            chapter = chapter,
            chapter_direction = chapter_direction,
        })
    end

    local safe_navigate = function(...)
        local cb = PlgState:afterReadUiOpenCallback()
        if cb then return cb(...) end
    end

    local ui = ReaderUI.instance
    if ui then
        if ui.document and ui.document.file == book_path then
            UIManager:nextTick(navigate_to_target_chapter)
            return
        end
        PlgState:afterReadUiOpenCallback(navigate_to_target_chapter)
        ui:switchDocument(book_path, true, safe_navigate)
    else
        PlgState:afterReadUiOpenCallback(navigate_to_target_chapter)
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        local show_reader = is_skeleton and ReaderUI._legado_wrapped or ReaderUI.showReader
        show_reader = show_reader or ReaderUI.showReader
        show_reader(ReaderUI, book_path, nil, true, nil, safe_navigate)
    end
end

function LibraryView:openLastReadChapter(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return false end

    local book_cache_id = bookinfo.cache_id
    local last_read_chapter_index = Backend:getLastReadChapter(book_cache_id)
    if H.is_num(last_read_chapter_index) then
        if last_read_chapter_index < 0 then last_read_chapter_index = 0 end
        local chapter = Backend:getChapterInfoCache(book_cache_id, last_read_chapter_index)

        if H.is_tbl(chapter) and chapter.isVolume == true then
            chapter = Backend:findNextChapter({
                book_cache_id = book_cache_id,
                chapters_index = chapter.chapters_index,
                call_event = "next",
            }) or Backend:findNextChapter({
                book_cache_id = book_cache_id,
                chapters_index = chapter.chapters_index,
                call_event = "prev",
            })
        end

        if H.is_tbl(chapter) and H.is_num(chapter.chapters_index) then
            chapter.call_event = "next"
            self:loadAndRenderChapter(chapter, { resume_position = true })
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

function LibraryView:getBrowserHomeDir()
    return Backend:getFullBookCacheOutputDir()
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
    return require("Legado/BookLinks")(self)
end

function LibraryView:getMenuWidget()
    return require("Legado/BookShelf")(self)
end

function LibraryView:invalidateBookShelf()
    if self.book_shelf then
        self.book_shelf:onClose()
        self.book_shelf = nil
    end
end

function LibraryView:getBookTocWidget()
    return self.book_toc
end

function LibraryView:refreshBookTocWidget(bookinfo, onReturnCallBack, visible)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return self.book_toc end

    local book_cache_id = bookinfo.cache_id
    local toc_obj = self.book_toc
    local toc_bookinfo = {
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
        variable = bookinfo.variable,
    }

    if not (H.is_tbl(toc_obj) and H.is_tbl(toc_obj.bookinfo) and toc_obj.bookinfo.cache_id == book_cache_id) then
        self.book_toc = require("Legado/ChapterListing"):fetchAndShow(toc_bookinfo, onReturnCallBack, function(chapter)
            self:loadAndRenderChapter(chapter)
        end, true, visible)
    else
        self.book_toc.bookinfo = toc_bookinfo
        self.book_toc.expanded_nodes = nil
        self.book_toc:updateReturnCallback(onReturnCallBack)
        if visible == true then
            self.book_toc:refreshItems(nil, true)
            UIManager:show(self.book_toc)
        end
    end
    return self.book_toc
end

function LibraryView:showBookTocDialog(bookinfo, onReturnCallBack)
    PlgState:chapterDirection("nil")
    return self:refreshBookTocWidget(bookinfo, onReturnCallBack, true)
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
