-- Legado/ReadingFlow.lua
local logger = require("logger")
local util = require("util")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local DocSettings = require("docsettings")
local Backend = require("Legado/Backend")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")
local PlgState = require("Legado/PlgState")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")

local function get_reader_ui()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return require("apps/reader/readerui")
end

local ReadingFlow = {}

-- 入口判定
function ReadingFlow:isFullBookMode(item, options)
    -- 漫画类型强制走独立分章 CBZ / 流式流程
    if H.is_tbl(item) then
        if item.kind == "cbz" or item.cacheExt == "cbz" or (item.img_sources and #item.img_sources > 0) then
            return false
        end
        -- 传入的实体本身已是 EPUB 文件或已标记为 virtual_epub
        if item.is_virtual_epub == true or (item.cacheFilePath and item.cacheFilePath:match("%.epub$")) then
            return true
        end
    end

    -- 入口 2, 调用方显式指定 mode
    if options and options.mode == "full_book" then
        return true
    elseif options and options.mode == "chapter_mode" then
        return false
    end

    -- 环境检测：若无 Zip 压缩库支持，强制降级为传统分章模式
    local SkeletonEpub = require("Legado.Helper.SkeletonEpub")
    if not SkeletonEpub.isSupported() then
        return false
    end

    -- 全局配置：若用户手动开启了“分章模式”
    local settings = Backend:getSettings()
    if settings and settings.chapter_mode == true then
        return false
    end

    return true
end

-- 向后兼容别名
ReadingFlow.isSkeletonEnabled = ReadingFlow.isFullBookMode

--- 统一开书与切章入口
function ReadingFlow:openBook(chapter, options)
    options = options or {}
    local parent_view = options.parent_view
    local on_error = options.on_error or function(msg) MessageBox:error(msg) end

    if not (H.is_tbl(chapter) and chapter.book_cache_id) then
        return on_error("章节数据无效")
    end

    local book_cache_id = chapter.book_cache_id
    local bookinfo = Backend:getBookInfoCache(book_cache_id)
    local is_full_book = self:isFullBookMode(chapter, options) and H.is_tbl(bookinfo)

    if is_full_book then
        PlgState:readingMode("full_book")
        return self:_openSkeletonBook(bookinfo, chapter, options)
    else
        PlgState:readingMode("chapter_mode")
        return self:_openLegacyBook(bookinfo, chapter, options)
    end
end

--- 骨架 EPUB 开书调度
function ReadingFlow:_openSkeletonBook(bookinfo, chapter, options)
    local parent_view = options.parent_view
    local on_error = options.on_error or function(msg) MessageBox:error(msg) end
    local book_cache_id = bookinfo.cache_id or chapter.book_cache_id

    -- 确保骨架 EPUB 存在
    local epub_path = Backend:ensureVirtualBookEpub(bookinfo, chapter.chapters_index)
    if not (epub_path and util.fileExists(epub_path)) then
        return on_error("构建骨架 EPUB 失败")
    end

    -- 检查当前章是否有本地物理缓存，有则直接注入
    local SkeletonEpub = require("Legado.Helper.SkeletonEpub")
    local cache_chapter = Backend:getCacheChapterFilePath(chapter)
    if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
        local raw = util.readFromFile(cache_chapter.cacheFilePath)
        if raw and raw ~= "" and not SkeletonEpub.isPlaceholderHtml(raw) then
            Backend:syncChapterToVirtualBook(book_cache_id, chapter.chapters_index, raw, bookinfo.name)
        end
    else
        chapter.cacheFilePath = nil
    end

    chapter.is_virtual_epub = true
    if not chapter.name and bookinfo.name then chapter.name = bookinfo.name end
    if not chapter.bookUrl and bookinfo.bookUrl then chapter.bookUrl = bookinfo.bookUrl end
    if not chapter.author and bookinfo.author then chapter.author = bookinfo.author end
    PlgState:readingChapter(chapter)
    PlgState:currentSelectedBook({ cache_id = book_cache_id })

    local ReaderUI = get_reader_ui()
    if not ReaderUI then
        return on_error("ReaderUI 未就绪")
    end

    -- 定位到目标章节并主动触发阅读状态与自愈预读
    local function navigate_and_trigger()
        if ReaderUI.instance and ReaderUI.instance.document then
            local toc = ReaderUI.instance.document:getToc()
            local target_idx = (chapter.chapters_index or 0) + 1
            if toc and toc[target_idx] then
                if toc[target_idx].xpointer then
                    ReaderUI.instance:handleEvent(Event:new("GotoXPointer", toc[target_idx].xpointer, toc[target_idx].xpointer))
                elseif toc[target_idx].page then
                    ReaderUI.instance:handleEvent(Event:new("GotoPage", toc[target_idx].page))
                end
            end
        end
        Backend:after_reader_chapter_show(chapter)
    end

    -- 关闭目录对话框（若显示）
    if parent_view and parent_view.getBookTocWidget then
        local toc_obj = parent_view:getBookTocWidget()
        if toc_obj and UIManager:isWidgetShown(toc_obj) then
            UIManager:close(toc_obj)
        end
    end

    -- 驱动 ReaderUI 展示或原地重载
    if ReaderUI.instance then
        if ReaderUI.instance.document and ReaderUI.instance.document.file == epub_path then
            Backend:refreshDocumentInPlace(ReaderUI.instance)
            UIManager:nextTick(navigate_and_trigger)
            return
        end
        ReaderUI.instance:switchDocument(epub_path, true)
        UIManager:nextTick(navigate_and_trigger)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(epub_path, nil, true)
        UIManager:nextTick(navigate_and_trigger)
    end
end

--- 传统单章模式开书调度
function ReadingFlow:_openLegacyBook(bookinfo, chapter, options)
    local parent_view = options.parent_view
    local on_error = options.on_error or function(msg) MessageBox:error(msg) end

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)
    if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
        if parent_view and parent_view.showReaderUI then
            parent_view:showReaderUI(cache_chapter)
        end
        return
    end

    -- 尚未缓存，下载并打开
    Backend:closeDbManager()
    return TaskProg.loading("正在下载正文 ", function()
        return Backend:downloadChapter(chapter)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                -- 漫画 CBZ 处理
                if H.is_tbl(data) and data.kind == "cbz" then
                    local pending = data
                    local cbz_writer = require("Legado.task.QueueCbz"):new()
                    local total_imgs = #pending.img_sources
                    local progress_bar = (total_imgs > 2) and TaskProg.showBar("正在下载章节图片...", { title = "漫画章节下载", max = total_imgs }) or TaskProg.showSpinner("正在下载章节图片")
                    cbz_writer:from_urls_async({
                        output = pending.filePath,
                        images = pending.img_sources,
                        opts = {
                            max_workers = tonumber(Backend.settings_data.data.download_threads) or 4,
                            comic_info = { name = pending.chapter.title or "" }
                        },
                        on_progress = function(completed)
                            if progress_bar and progress_bar.reportProgress then progress_bar:reportProgress(completed) end
                        end,
                        on_finish = function(aborted, result)
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

--- 强制刷新当前阅读章节,两种模式
function ReadingFlow:refreshCurrentChapter(options)
    options = options or {}
    local on_success = options.on_success or function() MessageBox:notice("本章刷新成功") end
    local on_error = options.on_error or function(err_msg) MessageBox:error("刷新失败: " .. tostring(err_msg)) end

    local reading_chapter = PlgState:readingChapter()
    local ReaderUI = get_reader_ui()

    --  尝试从 ReaderUI 活跃文档精确定位当前章节（骨架 EPUB 翻页动态校准）
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        local doc = ReaderUI.instance.document
        local toc = doc.getToc and doc:getToc()
        if toc and #toc > 0 then
            local pageno = (ReaderUI.instance.getCurrentPage and ReaderUI.instance:getCurrentPage()) or (doc.getCurrentPage and doc:getCurrentPage()) or (ReaderUI.instance.view and ReaderUI.instance.view.state and ReaderUI.instance.view.state.page) or 1
            local curr_ch_idx = nil
            for i = #toc, 1, -1 do
                if toc[i].page and pageno >= toc[i].page then
                    curr_ch_idx = i - 1 -- 0-based
                    break
                end
            end
            if curr_ch_idx then
                local book_cache_id = reading_chapter and reading_chapter.book_cache_id
                if not book_cache_id and doc.file then
                    local ds = DocSettings:open(doc.file)
                    book_cache_id = ds:readSetting("book_cache_id")
                end
                if book_cache_id then
                    local fresh_info = Backend:getChapterInfoCache(book_cache_id, curr_ch_idx)
                    if fresh_info then
                        reading_chapter = fresh_info
                        PlgState:readingChapter(reading_chapter)
                    end
                end
            end
        end
    end

    if not (H.is_tbl(reading_chapter) and reading_chapter.book_cache_id and reading_chapter.chapters_index) then
        return on_error("未获取到当前章节信息")
    end

    local book_cache_id = reading_chapter.book_cache_id
    local ch_idx = reading_chapter.chapters_index
    local bookinfo = Backend:getBookInfoCache(book_cache_id)

    -- 清理本地单章物理缓存
    Backend:clearChapterCache(book_cache_id, ch_idx)
    reading_chapter.isDownLoaded = false
    reading_chapter.cacheFilePath = nil
    if bookinfo then
        if not reading_chapter.name and bookinfo.name then reading_chapter.name = bookinfo.name end
        if not reading_chapter.bookUrl and bookinfo.bookUrl then reading_chapter.bookUrl = bookinfo.bookUrl end
        if not reading_chapter.author and bookinfo.author then reading_chapter.author = bookinfo.author end
    end

    -- 重新向源站发起刷新与下载请求
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

                local is_skeleton = ReadingFlow:isSkeletonEnabled(reading_chapter)
                if is_skeleton and bookinfo then
                    local raw = util.readFromFile(data.cacheFilePath)
                    if raw and raw ~= "" then
                        Backend:syncChapterToVirtualBook(book_cache_id, ch_idx, raw, bookinfo.name)
                    end
                    if ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
                        Backend:refreshDocumentInPlace(ReaderUI.instance)
                    end
                    on_success()
                else
                    -- 传统单章缓存模式
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
