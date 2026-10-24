local Backend = require("Legado/Backend")
local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local Probe = require("Legado.Helper.Probe")
local Store = require("Legado.Skeleton.BookStore")
local M = {}

local function get_active_reader_ui()
    local ReaderUI = require("apps/reader/readerui")
    return ReaderUI and ReaderUI.instance
end

function M:getTocEntry(toc, book_cache_id, chapter_idx)
    if not (H.is_tbl(toc) and H.is_str(book_cache_id) and H.is_num(chapter_idx)) then return nil end
    local chapters = Backend:getReadableChapters(book_cache_id)
    if not H.is_tbl(chapters) or #toc > #chapters then return nil end
    for ordinal, chapter in ipairs(chapters) do
        if chapter.chapters_index == chapter_idx then
            return toc[ordinal], ordinal
        end
    end
end

function M:resolveChapter(ui, book_cache_id, previous_toc_idx)
    if not (ui and ui.document and ui.toc and H.is_str(book_cache_id)) then return nil end
    if ui.document.isTocAlternativeToc and ui.document:isTocAlternativeToc() then return nil end
    local xpointer = ui.document:getXPointer()
    if not H.is_str(xpointer) and ui.rolling then
        xpointer = ui.rolling.xpointer
    end

    local toc_idx
    if H.is_str(xpointer) and ui.toc.fillToc and ui.toc.getAccurateTocIndexByXPointer then
        local ok, value = pcall(function()
            ui.toc:fillToc()
            return ui.toc:getAccurateTocIndexByXPointer(xpointer)
        end)
        if ok then toc_idx = value end
    end
    if not toc_idx and ui.toc.getTocIndexByPage then
        local page = ui.getCurrentPage and ui:getCurrentPage() or ui.document:getCurrentPage()
        local ok, value = pcall(ui.toc.getTocIndexByPage, ui.toc, page)
        if ok then toc_idx = value end
    end
    if not H.is_num(toc_idx) then return nil end
    if toc_idx == previous_toc_idx then return nil, toc_idx, true end
    local chapters = Backend:getReadableChapters(book_cache_id)
    if not H.is_tbl(chapters) or (H.is_tbl(ui.toc.toc) and #ui.toc.toc > #chapters) then
        return nil, toc_idx, false
    end
    return chapters[toc_idx], toc_idx, false
end

function M:refreshInPlace(ui, context)
    ui = ui or get_active_reader_ui()
    context = context or {}
    if not (ui and ui.document and ui.document._document) then
        return false, "no active credocument"
    end
    local doc = ui.document
    if doc.been_rendered ~= true then
        Probe.event("DOM", "跳过未渲染文档热重载", tostring(doc.file))
        return false, "document not rendered"
    end
    if not (ui.rolling and ui.rolling.onUpdatePos) then
        return false, "no active ReaderRolling"
    end

    local probe_context = Probe.context(context._warm_trace_id, context._warm_probe_span)
    local t_start = Probe.start("DOM", "原地热重载", doc.file, nil, probe_context)
    local stage_context = Probe.child_context(probe_context, t_start)
    local function cache_stale()
        if not doc.isCacheFileStale then return "unsupported" end
        local stale_ok, stale = pcall(doc.isCacheFileStale, doc)
        if not stale_ok then return "probe_error" end
        return stale
    end
    local old_pos = doc._document:getCurrentPos()
    local old_height = doc._document:getFullHeight()
    local old_page = doc._document:getCurrentPage()
    local old_percent = (old_pos and old_height and old_height > 0) and (old_pos / old_height) or nil
    local cur_chapter_xp
    do
        local cur_xp = doc._document:getXPointer()
        local frag_prefix = cur_xp and cur_xp:match("^(/body/DocFragment%[%d+%])")
        if frag_prefix then cur_chapter_xp = frag_prefix .. "/body/div/h2" end
    end

    if doc.setCallback then doc:setCallback(nil) end
    local stale_before = cache_stale()
    local uses_keep = context._keep_cache_path ~= nil
    doc._loaded = false

    local reloaded = false
    local partial = doc.isPartialRerenderingEnabled and doc:isPartialRerenderingEnabled()
    local ok, err = pcall(function()
        local t_load = Probe.start("DOM", "主进程加载 EPUB", doc.file,
            function()
                return string.format("(keep=%s stale_before=%s)",
                    tostring(uses_keep), tostring(stale_before))
            end, stage_context)
        if not doc._document:loadDocument(doc.file) then
            Probe.fail("DOM", "主进程加载 EPUB", doc.file, t_load, "loadDocument=false", stage_context)
            error("loadDocument failed")
        end
        doc._loaded = true
        local stale_after = cache_stale()
        Probe.done("DOM", "主进程加载 EPUB", doc.file, t_load,
            uses_keep and stale_after == false and "CACHE_HIT" or "200 OK",
            function() return string.format("stale_after=%s", tostring(stale_after)) end,
            nil, stage_context)

        if partial then doc:enablePartialRerendering(false) end
        local t_render = Probe.start("DOM", "主进程完整排版", doc.file, nil, stage_context)
        doc:render()
        Probe.done("DOM", "主进程完整排版", doc.file, t_render, "200 OK", nil, nil, stage_context)

        local t_reset = Probe.start("DOM", "重置调用缓存", doc.file, nil, stage_context)
        doc:resetCallCache()
        Probe.done("DOM", "重置调用缓存", doc.file, t_reset, "200 OK", nil, nil, stage_context)

        local t_update = Probe.start("DOM", "同步 ReaderRolling", doc.file, nil, stage_context)
        ui.rolling:onUpdatePos(true)
        Probe.done("DOM", "同步 ReaderRolling", doc.file, t_update, "200 OK", nil, nil, stage_context)
        reloaded = true

        local t_finalize = Probe.start("DOM", "恢复视口与底栏", doc.file, nil, stage_context)
        if old_percent and old_page and old_page > 1 and doc._document:getCurrentPage() <= 1 then
            local restored = false
            if cur_chapter_xp then
                local anchor_ok = pcall(ui.rolling.onGotoXPointer, ui.rolling, cur_chapter_xp)
                restored = anchor_ok and doc._document:getCurrentPage() > 1
            end
            if not restored then
                ui.rolling:onGotoPercent(old_percent * 100)
            end
        end
        doc._legado_epub_revision = (Store._epub_revision and Store._epub_revision[doc.file]) or 0
        if ui.view and ui.view.footer and ui.view.footer.onUpdateFooter then
            local footer_ok, footer_err = pcall(ui.view.footer.onUpdateFooter, ui.view.footer, ui.view.footer_visible)
            if not footer_ok then
                logger.warn("refreshInPlace: footer update failed: " .. tostring(footer_err))
            end
        end
        Probe.done("DOM", "恢复视口与底栏", doc.file, t_finalize, "200 OK", nil, nil, stage_context)
        Probe.done("DOM", "原地重载完成", function()
            return string.format("页数: %s, 高度: %s, keep: %s, stale: %s",
                tostring(doc:getPageCount()), tostring(doc.info.doc_height),
                tostring(uses_keep), tostring(stale_after))
        end, t_start, "200 OK", nil, nil, probe_context)
    end)
    if partial then
        local restored, restore_err = pcall(doc.enablePartialRerendering, doc, true)
        if not restored then
            logger.warn("refreshDocumentInPlace: restore partial rerendering failed: " .. tostring(restore_err))
        end
    end
    if not ok then
        Probe.fail("DOM", "原地重载失败", doc.file, t_start, tostring(err), probe_context)
    end
    return ok and reloaded, ok and nil or err
end

return M
