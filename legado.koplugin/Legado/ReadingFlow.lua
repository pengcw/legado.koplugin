local logger = require("logger")
local util = require("util")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local DocSettings = require("docsettings")
local Backend = require("Legado/Backend")
local Store = require("Legado.Skeleton.BookStore")
local Reader = require("Legado.Skeleton.Reader")
local SkeletonBook = require("Legado.Skeleton.Book")
local H = require("Legado/Helper")
local PlgState = require("Legado/PlgState")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")
local ReaderUI = require("apps/reader/readerui")

local ReadingFlow = {}

local function skeleton_supported()
    return Store:isSupported()
end

local function can_use_skeleton()
    local settings = Backend:getSettings()
    return skeleton_supported() and settings ~= nil and settings.chapter_mode == false
end

function ReadingFlow:isFullBookMode(item, options)
    if options and options.mode == "full_book" then return skeleton_supported() end
    if options and options.mode == "chapter_mode" then return false end
    if H.is_tbl(item) and (item.is_virtual_epub == true
            or (item.cacheFilePath and item.cacheFilePath:match("%.epub$"))) then
        return true
    end
    if not H.is_tbl(item) then return false end
    local book_cache_id = item.cache_id or item.book_cache_id
    if book_cache_id then
        local override = Backend:bookReaderRoute(book_cache_id)
        if override == "comic" then return false end
        if override == "reader" then return can_use_skeleton() end
        local container = PlgState:readingRoute(book_cache_id)
        if container then return container == "skeleton" end
    end
    return Backend:bookContentType(book_cache_id or item) == "reader" and can_use_skeleton()
end

ReadingFlow.isSkeletonEnabled = ReadingFlow.isFullBookMode

function ReadingFlow:resolveRoute(bookinfo, chapter, options)
    options = options or {}
    local book_cache_id = chapter.book_cache_id
    if options.mode == "full_book" then
        return skeleton_supported() and "skeleton" or "legacy", "explicit"
    end
    if options.mode == "chapter_mode" then return "legacy", "explicit" end
    if chapter.is_virtual_epub == true or (chapter.cacheFilePath and chapter.cacheFilePath:match("%.epub$")) then
        return "skeleton", "document"
    end
    local container, session_source = PlgState:readingRoute(book_cache_id)
    if container then return container, session_source or "session" end

    local route = Backend:bookReaderRoute(book_cache_id)
    local source = "user_override"
    if route == "auto" then
        route = Backend:bookContentType(bookinfo)
        source = route == "unknown" and "default" or "declared"
    end
    if route == "comic" then
        local extras = Backend:getBookExtras(book_cache_id)
        local stream_enabled = not (H.is_tbl(extras.data) and extras.data.stream_image_view == false)
        return stream_enabled and "stream" or "legacy", source
    end
    if route == "reader" and can_use_skeleton() then return "skeleton", source end
    return "legacy", source
end

function ReadingFlow:openBook(chapter, options)
    options = options or {}
    local on_error = options.on_error or function(msg) MessageBox:error(msg) end
    if not (H.is_tbl(chapter) and chapter.book_cache_id) then
        return on_error("章节数据无效")
    end

    local bookinfo = Backend:getBookInfoCache(chapter.book_cache_id)
    if not H.is_tbl(bookinfo) then return on_error("书籍数据无效") end
    local open_generation = SkeletonBook:beginOpenIntent()
    local container, source = self:resolveRoute(bookinfo, chapter, options)
    if container == "skeleton" then
        local cached = Backend:getCacheChapterFilePath(chapter, true)
        local path = cached and cached.cacheFilePath
        if H.is_str(path) and path:lower():match("%.cbz$") and util.fileExists(path) then
            container, source = "legacy", "chapter_fallback"
        end
    end
    PlgState:readingRoute(chapter.book_cache_id, container, source)
    PlgState:readingMode(container == "skeleton" and "full_book" or "chapter_mode")

    if container == "skeleton" then
        return SkeletonBook:openBook(bookinfo, chapter, options, open_generation)
    end
    if container == "stream" then
        local parent_view = options.parent_view
        if parent_view and H.is_func(parent_view.openStreamImageView) then
            return parent_view:openStreamImageView(chapter, options)
        end
        PlgState:readingRoute(chapter.book_cache_id, "legacy", "capability_fallback")
    end
    return self:_openLegacyBook(bookinfo, chapter, options)
end

function ReadingFlow:_openLegacyBook(_, chapter, options)
    local parent_view = options.parent_view
    local on_error = options.on_error or function(msg) MessageBox:error(msg) end

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)
    if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
        if parent_view and parent_view.showReaderUI then
            parent_view:showReaderUI(cache_chapter)
        end
        return
    end

    if not NetworkMgr:isConnected() then
        return on_error("本章尚未缓存，请连接网络后重试")
    end

    Backend:closeDbManager()
    return TaskProg.loading("正在下载正文 ", function()
        return Backend:downloadChapter(chapter)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if H.is_tbl(data) and data.kind == "cbz" then
                    local pending = data
                    local cbz_writer = require("Legado.task.QueueCbz"):new()
                    local total_imgs = #pending.img_sources
                    local progress_bar = (total_imgs > 2) and TaskProg.showBar("正在下载章节图片...", { title = "漫画章节下载", max = total_imgs }) or TaskProg.showSpinner("正在下载章节图片")
                    cbz_writer:from_urls_async({
                        output = pending.filePath,
                        images = pending.img_sources,
                        opts = {
                            max_workers = Backend:normalizeDownloadThreads(Backend.settings_data.data.download_threads),
                            comic_info = { name = pending.chapter.title or "" }
                        },
                        on_progress = function(completed)
                            if progress_bar and progress_bar.reportProgress then progress_bar:reportProgress(completed) end
                        end,
                        on_finish = function(_, result)
                            if progress_bar then progress_bar:close() end
                            if result and result.success then
                                pending.chapter.cacheFilePath = pending.filePath
                                UIManager:nextTick(function()
                                    if parent_view and parent_view.showReaderUI then
                                        parent_view:showReaderUI(pending.chapter)
                                    end
                                end)
                            else
                                on_error("章节打包失败")
                            end
                        end,
                    })
                    return
                end

                if not (H.is_tbl(data) and H.is_str(data.cacheFilePath)) then
                    return on_error("下载失败")
                end

                if parent_view and parent_view.showReaderUI then
                    parent_view:showReaderUI(data)
                end
            end, function(err_msg)
                on_error(err_msg or "下载章节失败")
            end)
        else
            on_error(tostring(response or "下载正文失败"))
        end
    end)
end

function ReadingFlow:refreshCurrentChapter(options)
    options = options or {}
    local on_success = options.on_success or function() MessageBox:notice("本章刷新成功") end
    local on_error = options.on_error or function(err_msg) MessageBox:error("刷新失败: " .. tostring(err_msg)) end

    local reading_chapter = PlgState:readingChapter()

    local is_skeleton = PlgState:isFullBookMode()
    local reader_ui = is_skeleton and ReaderUI and ReaderUI.instance
    local reader_doc = reader_ui and reader_ui.document

    if reader_doc then
        local book_cache_id = reading_chapter and reading_chapter.book_cache_id
        if not book_cache_id and reader_doc.file then
            local ds = DocSettings:open(reader_doc.file)
            book_cache_id = ds and ds:readSetting("book_cache_id")
        end
        if book_cache_id then
            local resolved = Reader:resolveChapter(reader_ui, book_cache_id)
            if resolved then
                reading_chapter = resolved
                PlgState:readingChapter(resolved)
            end
        end
    end

    if not (H.is_tbl(reading_chapter) and reading_chapter.book_cache_id and reading_chapter.chapters_index) then
        return on_error("未获取到当前章节信息")
    end

    if not NetworkMgr:isConnected() then
        return on_error("操作失败, 请检查网络")
    end

    local book_cache_id = reading_chapter.book_cache_id
    local ch_idx = reading_chapter.chapters_index
    local bookinfo = Backend:getBookInfoCache(book_cache_id)

    Backend:clearChapterCache(book_cache_id, ch_idx)
    reading_chapter.isDownLoaded = false
    reading_chapter.cacheFilePath = nil
    if bookinfo then
        reading_chapter.name = bookinfo.name or reading_chapter.name
        reading_chapter.bookUrl = bookinfo.bookUrl or reading_chapter.bookUrl
        reading_chapter.origin = bookinfo.origin or reading_chapter.origin
        reading_chapter.author = bookinfo.author or reading_chapter.author
    end

    Backend:closeDbManager()
    return TaskProg.loading("正在重新下载本章 ", function()
        pcall(function() Backend:refreshBookContent(reading_chapter) end)
        return Backend:downloadChapter(reading_chapter)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not (H.is_tbl(data) and H.is_str(data.cacheFilePath)) then
                    return on_error("下载章节正文为空")
                end

                if is_skeleton and bookinfo then
                    local raw = util.readFromFile(data.cacheFilePath)
                    if not raw or raw == "" then
                        return on_error("下载章节正文为空")
                    end
                    local synced, sync_err, changed = Store:syncChapter(book_cache_id, ch_idx, raw, bookinfo.name)
                    if not synced then return on_error(sync_err or "EPUB 注入失败") end

                    if reader_doc then
                        local current_ui = ReaderUI and ReaderUI.instance
                        local current = PlgState:readingChapter()
                        if current_ui ~= reader_ui or current_ui.document ~= reader_doc
                                or not current or current.book_cache_id ~= book_cache_id
                                or not PlgState:isFullBookMode() then
                            return
                        end
                        local revision = (Store._epub_revision and Store._epub_revision[reader_doc.file]) or 0
                        if changed ~= false or reader_doc._legado_epub_revision ~= revision then
                            local refreshed, refresh_err = Reader:refreshInPlace(current_ui)
                            if not refreshed then return on_error(refresh_err or "阅读器重载失败") end
                        end
                    end
                    on_success()
                else
                    local LibraryView = require("Legado/LibraryView")
                    local library_obj = LibraryView:getInstance()
                    if library_obj then
                        library_obj:showReaderUI(data)
                    end
                    on_success()
                end
            end, function(err_msg)
                on_error(err_msg)
            end)
        else
            on_error(response or "下载正文失败")
        end
    end)
end

return ReadingFlow
