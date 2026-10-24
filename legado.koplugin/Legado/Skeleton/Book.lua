local Backend = require("Legado/Backend")
local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local Probe = require("Legado.Helper.Probe")
local Store = require("Legado.Skeleton.BookStore")
local Reader = require("Legado.Skeleton.Reader")
local Refresh = require("Legado.Skeleton.Refresh")
local PlgState = require("Legado/PlgState")
local DocSettings = require("docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local M = { _open_generation = 0 }
local ReaderUI
local function init_reader()
    ReaderUI = require("apps/reader/readerui")
end

function M:beginOpenIntent()
    self._open_generation = (self._open_generation or 0) + 1
    PlgState:afterReadUiOpenCallback(false)
    return self._open_generation
end

function M:ensureEpubAsync(bookinfo, target_chapter_idx, custom_output_path, on_done, on_error)
    on_done = on_done or function() end
    on_error = on_error or function() end
    local TaskProg = require("Legado.task.Progress")
    TaskProg.loading("正在打开书籍…", function()
        return Store:ensureEpub(bookinfo, target_chapter_idx, custom_output_path)
    end, function(ok, epub_path)
        if ok and H.is_str(epub_path) and util.fileExists(epub_path) then
            on_done(epub_path)
        else
            on_error(ok and "快捷 EPUB 未生成" or tostring(epub_path or "构建失败"))
        end
    end)
end

function M:openBook(bookinfo, chapter, options, open_generation)
    init_reader()
    options = options or {}
    open_generation = open_generation or self:beginOpenIntent()
    local opening_ui = ReaderUI.instance
    local opening_document = opening_ui and opening_ui.document
    local function is_current_open_intent()
        return self._open_generation == open_generation
    end
    local function is_open_origin_current()
        if not is_current_open_intent() then return false end
        local current_ui = ReaderUI.instance
        if opening_ui == nil then return current_ui == nil end
        return current_ui == opening_ui and current_ui.document == opening_document
    end
    local parent_view = options.parent_view
    local on_error = options.on_error or function(msg) require("Legado/MessageBox"):error(msg) end
    local book_cache_id = bookinfo.cache_id or chapter.book_cache_id
    local resume_position = options.resume_position == true

    local function on_epub_ready(epub_path)
        if not is_open_origin_current() then
            Probe.event("Nav", "丢弃过期开书", tostring(book_cache_id))
            return
        end
        local active_same_book = ReaderUI.instance and ReaderUI.instance.document
            and ReaderUI.instance.document.file == epub_path
        local saved_settings = DocSettings:open(epub_path)
        local saved_xpointer = saved_settings and saved_settings:readSetting("last_xpointer")
        local should_resume = resume_position and (active_same_book or H.is_str(saved_xpointer))

        local function sync_cached_chapter()
            local cache_chapter = Backend:getCacheChapterFilePath(chapter)
            if cache_chapter and cache_chapter.cacheFilePath
                    and not cache_chapter.cacheFilePath:lower():match("%.cbz$")
                    and util.fileExists(cache_chapter.cacheFilePath) then
                local raw = util.readFromFile(cache_chapter.cacheFilePath)
                if raw and raw ~= "" and not Store:isPlaceholder(raw) then
                    local ok_sync, _, changed = Store:syncChapter(
                        book_cache_id, chapter.chapters_index, raw, bookinfo.name)
                    return ok_sync and changed ~= false
                end
            else
                chapter.cacheFilePath = nil
            end
            return false
        end
        if not active_same_book then sync_cached_chapter() end
        local opening_revision = (Store._epub_revision and Store._epub_revision[epub_path]) or 0

        chapter.is_virtual_epub = true
        if not chapter.name and bookinfo.name then chapter.name = bookinfo.name end
        if not chapter.bookUrl and bookinfo.bookUrl then chapter.bookUrl = bookinfo.bookUrl end
        if not chapter.author and bookinfo.author then chapter.author = bookinfo.author end
        PlgState:readingChapter(chapter)
        PlgState:currentSelectedBook({ cache_id = book_cache_id })

        if not ReaderUI then
            return on_error("ReaderUI 未就绪")
        end

        local function prepare_chapter(active_chapter)
            active_chapter.is_virtual_epub = true
            if not active_chapter.name and bookinfo.name then active_chapter.name = bookinfo.name end
            if not active_chapter.bookUrl and bookinfo.bookUrl then active_chapter.bookUrl = bookinfo.bookUrl end
            if not active_chapter.author and bookinfo.author then active_chapter.author = bookinfo.author end
            return active_chapter
        end

        local triggered = false
        local function navigate_and_trigger()
            if triggered or not is_current_open_intent() then return end
            triggered = true
            PlgState:afterReadUiOpenCallback(false)

            local ui = ReaderUI.instance
            if not (ui and ui.document and ui.document.file == epub_path) then return end
            if not active_same_book then
                ui.document._legado_epub_revision = opening_revision
            end
            ui._legado_navigation_pending = true
            local current_reading = PlgState:readingChapter()
            local cur_resolved = Reader:resolveChapter(ui, book_cache_id)
            local already_at_target = false
            if cur_resolved and cur_resolved.chapters_index == chapter.chapters_index
                    and (chapter.chapters_index ~= 0 or (current_reading and current_reading.chapters_index == 0)) then
                already_at_target = true
            end

            local keep_restored_position = should_resume or already_at_target
            if keep_restored_position and not active_same_book and saved_xpointer
                and ui.document.isXPointerInDocument and not already_at_target then
                keep_restored_position = ui.document:isXPointerInDocument(saved_xpointer)
            end

            local target_found = keep_restored_position
            if already_at_target then
                Probe.eventf("Nav", "跳过同章跳转", nil, "第%d章 (book_id: %s)",
                    chapter.chapters_index + 1, tostring(book_cache_id))
            elseif not keep_restored_position then
                local toc = ui.document:getToc()
                local target = Reader:getTocEntry(toc, book_cache_id, chapter.chapters_index)
                if target then
                    target_found = true
                    Probe.eventf("Nav", "执行章节跳转", nil,
                        "第%d章 (xpointer: %s, page: %s)", chapter.chapters_index + 1,
                        tostring(target.xpointer or "-"), tostring(target.page or "-"))
                    if target.xpointer then
                        ui:handleEvent(Event:new("GotoXPointer", target.xpointer, target.xpointer))
                    elseif target.page then
                        ui:handleEvent(Event:new("GotoPage", target.page))
                    end
                else
                    logger.warn("virtual EPUB TOC entry not found for chapter", chapter.chapters_index)
                end
            else
                Probe.eventf("Nav", "保留恢复视口", nil,
                    "第%d章 (should_resume=true)", chapter.chapters_index + 1)
            end

            UIManager:nextTick(function()
                if not is_current_open_intent() then return end
                if not (ReaderUI.instance == ui and ui.document and ui.document.file == epub_path) then return end
                local resolved = Reader:resolveChapter(ui, book_cache_id)
                ui._legado_navigation_pending = nil
                if resolved then
                    prepare_chapter(resolved)
                    PlgState:readingChapter(resolved)
                end
                if keep_restored_position and resolved then
                    Backend:after_reader_chapter_show(resolved)
                elseif target_found and resolved and resolved.chapters_index == chapter.chapters_index then
                    Backend:after_reader_chapter_show(resolved)
                else
                    logger.warn("virtual EPUB chapter navigation verification failed", chapter.chapters_index,
                        resolved and resolved.chapters_index or "nil")
                end
            end)
        end

        if parent_view and parent_view.getBookTocWidget then
            local toc_obj = parent_view:getBookTocWidget()
            if toc_obj and UIManager:isWidgetShown(toc_obj) then
                UIManager:close(toc_obj)
            end
        end

        local safe_navigate = function(...)
            if not is_current_open_intent() then return end
            local cb = PlgState:afterReadUiOpenCallback()
            if cb then return cb(...) end
        end

        if ReaderUI.instance then
            if ReaderUI.instance.document and ReaderUI.instance.document.file == epub_path then
                local ui = ReaderUI.instance
                UIManager:nextTick(navigate_and_trigger)
                UIManager:tickAfterNext(function()
                    if not is_current_open_intent() then return end
                    if ReaderUI.instance ~= ui or not ui.document or ui.document.file ~= epub_path then return end
                    local current = Reader:resolveChapter(ui, book_cache_id)
                    if not current or current.chapters_index ~= chapter.chapters_index then return end
                    local injected_now = sync_cached_chapter()
                    local revision = (Store._epub_revision and Store._epub_revision[epub_path]) or 0
                    if injected_now or ui.document._legado_epub_revision ~= revision then
                        Reader:refreshInPlace(ui)
                    end
                end)
                return
            end
            PlgState:afterReadUiOpenCallback(navigate_and_trigger)
            ReaderUI.instance:switchDocument(epub_path, true, safe_navigate)
        else
            PlgState:afterReadUiOpenCallback(navigate_and_trigger)
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            local show_reader = ReaderUI._legado_wrapped or ReaderUI.showReader
            show_reader(ReaderUI, epub_path, nil, true, nil, safe_navigate)
        end
    end

    local active = ReaderUI.instance
    local expected_path = Store:getPath(book_cache_id,
        string.format("%s-%s", bookinfo.name or bookinfo.title or "未知书名", bookinfo.author or "未知作者"))
    if H.is_str(expected_path) and active and active.document and active.document.been_rendered == true
            and active.document.file == expected_path
            and Store:isUsable(expected_path, book_cache_id) then
        return on_epub_ready(expected_path)
    end
    return self:ensureEpubAsync(bookinfo, chapter.chapters_index, nil, on_epub_ready, function(err)
        if not is_open_origin_current() then return end
        return on_error("构建骨架 EPUB 失败：" .. tostring(err))
    end)
end

function M:openExisting(chapter, options)
    init_reader()
    local open_generation = self:beginOpenIntent()
    local function is_current_open_intent()
        return self._open_generation == open_generation
    end
    local parent_view = options.parent_view
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then return end
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return require("Legado/MessageBox"):error(book_path, "不存在")
    end
    PlgState:readingChapter(chapter)
    local is_skeleton = Env.is_legado_skeleton_book(book_path)

    local toc_obj = parent_view:getBookTocWidget()
    if toc_obj and UIManager:isWidgetShown(toc_obj) then UIManager:close(toc_obj) end
    local triggered = false
    local function navigate_to_target_chapter()
        if triggered or not is_current_open_intent() then return end
        triggered = true
        local chapter_direction = PlgState:chapterDirection()
        PlgState:afterReadUiOpenCallback(false)
        options.navigate({
            chapter = chapter,
            chapter_direction = chapter_direction,
        })
    end

    local safe_navigate = function(...)
        if not is_current_open_intent() then return end
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

function M:syncNewChapters(book_cache_id, book_name)
    return Store:syncNewChapters(book_cache_id, book_name, function(path)
        init_reader()
        local ui = ReaderUI and ReaderUI.instance
        if ui and ui.document and ui.document.file == path then Reader:refreshInPlace(ui) end
    end)
end

function M:preloadCallbacks()
    return {
        inject_one = function(...) return Store:syncChapter(...) end,
        inject_many = function(...) return Store:syncChapters(...) end,
        request_refresh = function(...) return Refresh:request(...) end,
        show_chapter_loading = function(...) return Refresh:showLoading(...) end,
        hide_chapter_loading = function(...) return Refresh:hideLoading(...) end,
        sync_new_chapters = function(...) return self:syncNewChapters(...) end,
        cleanup = function() return Refresh:_clearPreloadRefreshScheduler() end,
    }
end

function M:onPageUpdate(ui, pageno, last_virtual_toc_idx)
    if not Env.is_legado_skeleton_book(nil, ui) then return last_virtual_toc_idx end
    if not pageno or not ui or not ui.toc then return last_virtual_toc_idx end
    if ui.postReaderReadyCallback ~= nil or ui._legado_navigation_pending then return last_virtual_toc_idx end

    local current_reading = PlgState:readingChapter()
    local book_cache_id = current_reading and current_reading.book_cache_id
    if not book_cache_id and ui.document and ui.document.file then
        local ds = DocSettings:open(ui.document.file)
        book_cache_id = ds and ds:readSetting("book_cache_id")
    end
    if not H.is_str(book_cache_id) then return last_virtual_toc_idx end

    local new_chapter, toc_idx, unchanged = Reader:resolveChapter(
        ui, book_cache_id, last_virtual_toc_idx)
    if unchanged then return last_virtual_toc_idx end
    if not (new_chapter and H.is_num(toc_idx)) then
        logger.warn("virtual EPUB chapter cannot be resolved", tostring(toc_idx))
        return last_virtual_toc_idx
    end
    last_virtual_toc_idx = toc_idx
    if current_reading
            and current_reading.chapters_index == new_chapter.chapters_index
            and new_chapter.chapters_index ~= 0 then
        return last_virtual_toc_idx
    end

    Probe.done("Page", "跨章翻页", string.format("第%s章 -> 第%d章 (页码: %s)",
        tostring((current_reading and current_reading.chapters_index or 0) + 1),
        new_chapter.chapters_index + 1, tostring(pageno)))
    PlgState:readingChapter(new_chapter)
    Refresh:updatePriority()
    UIManager:nextTick(function()
        Backend:after_reader_chapter_show(new_chapter)
    end)
    return last_virtual_toc_idx
end

return M
