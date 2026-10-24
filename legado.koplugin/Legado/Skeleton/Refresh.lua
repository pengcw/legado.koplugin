local Backend = require("Legado/Backend")
local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local Probe = require("Legado.Helper.Probe")
local UIManager = require("ui/uimanager")
local TaskQueueV2 = require("Legado.task.v2")
local lfs = require("libs/libkoreader-lfs")
local PlgState = require("Legado/PlgState")
local RefreshGate = require("Legado.Helper.RefreshGate")
local InplaceCacheWarmer = require("Legado.InplaceCacheWarmer")
local Store = require("Legado.Skeleton.BookStore")
local Reader = require("Legado.Skeleton.Reader")
local M = {}

local function get_active_reader_ui()
    local ReaderUI = require("apps/reader/readerui")
    return ReaderUI and ReaderUI.instance
end

local function preload_keep_ledger()
    return Env.getTempDirectory() .. "/inplace_cache_keep.list"
end

function M:_getPreloadRefreshGate()
    if self._preload_refresh_gate then return self._preload_refresh_gate end

    self._preload_refresh_gate = RefreshGate:new{
        idle_seconds = 5,
        max_wait_seconds = 15,
        prepare = function(priority, context, on_ready)
            self:_preparePreloadRefresh(priority, context, on_ready)
        end,
        is_valid = function(context)
            local current = PlgState:readingChapter()
            local reason
            if context.book_cache_id and (not current or current.book_cache_id ~= context.book_cache_id) then
                reason = "reading_book_changed"
            else
                local ui = get_active_reader_ui()
                if not (ui and ui.document and ui.document.file) then
                    reason = "reader_closed"
                elseif context._warm_revision and
                        ((Store._epub_revision and Store._epub_revision[ui.document.file]) or 0)
                            ~= context._warm_revision then
                    reason = "epub_revision_changed"
                elseif (context._reader_doc and ui.document ~= context._reader_doc)
                        or (context.epub_path and ui.document.file ~= context.epub_path) then
                    reason = "reader_document_changed"
                end
            end
            if reason then Probe.event("Refresh", "校验失败", reason); return false end
            self:updatePriority()
            return true
        end,
        can_refresh = function()
            local top = UIManager:getTopmostVisibleWidget() or {}
            local ui = get_active_reader_ui()
            local selecting = ui and ui.highlight
                and (ui.highlight.hold_pos or ui.highlight.select_mode)
            return top.name == "ReaderUI" and not selecting
                and ui and ui.document and ui.document.been_rendered == true
                and ui.document._loaded ~= false
                and ui.postReaderReadyCallback == nil
                and ui.rolling and (ui.rolling.batched_update_count or 0) <= 0
        end,
        on_refresh = function(context)
            local ui = context._warm_revision ~= nil and get_active_reader_ui()
            if ui and ui.document
                    and ui.document._legado_epub_revision == context._warm_revision then
                if context.on_refreshed then pcall(context.on_refreshed) end
                return
            end
            local ok = Reader:refreshInPlace(nil, context)
            if ok and context._keep_cache_path then
                if self._active_preload_keep and self._active_preload_keep ~= context._keep_cache_path then
                    os.remove(self._active_preload_keep)
                end
                self._active_preload_keep = context._keep_cache_path
                self._pending_preload_keep = nil
                self._pending_preload_doc = nil
                self._pending_preload_revision = nil
            end
            if ok and context.on_refreshed then
                pcall(context.on_refreshed)
            end
        end,
    }
    return self._preload_refresh_gate
end

function M:_cleanupStalePreloadCaches(cache_dir)
    if self._preload_keep_ledger_checked then return end
    self._preload_keep_ledger_checked = true
    local ledger = preload_keep_ledger()
    local f = io.open(ledger, "r")
    if not f then return end
    for path in f:lines() do
        if path:sub(1, #cache_dir + 1) == cache_dir .. "/"
                and path:match("%.cr3%.keep$") then
            os.remove(path)
        end
    end
    f:close()
    os.remove(ledger)
end

function M:_clearPreloadRefreshScheduler()
    if self._preload_refresh_gate then
        self._preload_refresh_gate:cancel()
    end
    if self._preload_cache_warmer then
        self._preload_cache_warmer:cancel()
    end
    if self._skeleton_loading_info and self._skeleton_loading_info.warm_context then
        self:hideLoading()
    end
    if self._pending_preload_keep then
        os.remove(self._pending_preload_keep)
        self._pending_preload_keep = nil
        self._pending_preload_doc = nil
        self._pending_preload_revision = nil
    end
    if self._active_preload_keep then
        os.remove(self._active_preload_keep)
        self._active_preload_keep = nil
    end
    if self._preload_keep_ledger_checked then os.remove(preload_keep_ledger()) end
end

function M:cancelForDocument(document)
    if not document then return end
    local gate = self._preload_refresh_gate
    local job = self._preload_cache_warmer and self._preload_cache_warmer.job
    if (gate and gate.context and gate.context._reader_doc == document)
            or (job and job.request.doc == document) then
        self:_clearPreloadRefreshScheduler()
    end
end

function M:updatePriority()
    local gate = self._preload_refresh_gate
    local context = gate and gate.context
    local current = PlgState:readingChapter()
    if gate and gate.priority == "urgent" and context and current
            and current.book_cache_id == context.book_cache_id
            and context._waiting_chapter ~= nil
            and current.chapters_index ~= context._waiting_chapter then
        gate.priority = "idle"
        if context._preload_close_loading then context._preload_close_loading() end
    end
end

function M:request(priority, context)
    context = context or {}
    local ui = get_active_reader_ui()
    local doc = ui and ui.document
    local revision = doc and Store._epub_revision and Store._epub_revision[doc.file] or 0
    if doc then
        context.epub_path = doc.file
        context._reader_doc = doc
        context._warm_revision = revision
    end
    local gate = self:_getPreloadRefreshGate()
    self:updatePriority()
    local current = PlgState:readingChapter()
    context._waiting_chapter = priority == "urgent" and current and current.chapters_index
        or (gate.context and gate.context._waiting_chapter)
    if not gate.is_valid(context) then return end
    if doc and doc._legado_epub_revision == revision then
        Probe.event("Refresh", "跳过已加载版本", function()
            return string.format("revision=%s priority=%s", tostring(revision), tostring(priority))
        end)
        if gate.context and gate.context.epub_path == doc.file
                and gate.context._warm_revision == revision then
            gate:cancel()
            if self._preload_cache_warmer then self._preload_cache_warmer:cancel() end
        end
        local current = PlgState:readingChapter()
        if priority == "urgent" and current and current.book_cache_id == context.book_cache_id then
            self:hideLoading(current)
        end
        if context.on_refreshed then pcall(context.on_refreshed) end
        return
    end
    gate:request(priority, context)
end

function M:_preparePreloadRefresh(priority, context, on_ready)
    local ui = get_active_reader_ui()
    local doc = ui and ui.document
    local revision = doc and Store._epub_revision and Store._epub_revision[doc.file] or 0
    local chapter = PlgState:readingChapter()
    local loading
    if priority == "urgent" and chapter and chapter.book_cache_id == context.book_cache_id then
        loading = self:showLoading(chapter, context)
    end
    local function close_loading()
        if loading and self._skeleton_loading_info == loading and loading.warm_context == context then
            self:hideLoading(chapter)
        end
    end
    local function prepared()
        close_loading()
        on_ready()
    end
    context._preload_close_loading = close_loading
    context._preload_on_ready = prepared
    if doc and doc._legado_epub_revision == revision then
        prepared()
        return
    end
    if doc and doc.getCacheFilePath then
        local cache = doc:getCacheFilePath()
        local cache_dir = cache and cache:match("^(.*)/[^/]+$")
        if cache_dir then self:_cleanupStalePreloadCaches(cache_dir) end
    end
    if self._pending_preload_keep then
        if doc == self._pending_preload_doc and revision == self._pending_preload_revision then
            context._keep_cache_path = self._pending_preload_keep
            context._warm_revision = revision
            context.epub_path = doc.file
            prepared()
            return
        end
        os.remove(self._pending_preload_keep)
        self._pending_preload_keep = nil
        self._pending_preload_doc = nil
        self._pending_preload_revision = nil
    end
    if not (Backend.settings_data and Backend.settings_data.data
            and Backend.settings_data.data.inplace_cache_warm ~= false
            and doc and doc.been_rendered and doc._document
            and ui.rolling and doc.file and doc.file:lower():match("%.epub$")) then
        prepared()
        return
    end
    if not self._preload_cache_warmer then
        self._preload_cache_warmer = InplaceCacheWarmer:new(function(request, cache_path)
            request.context._preload_close_loading()
            local probe_context = Probe.context(
                request.context and request.context._warm_trace_id,
                request.context and request.context._warm_probe_span)
            local target = string.format("revision=%s priority=%s",
                tostring(request.revision), tostring(request.priority))
            local active = get_active_reader_ui()
            if not (active and active.document == request.doc
                    and Store._epub_revision
                    and Store._epub_revision[request.doc.file] == request.revision) then
                Probe.event("Warm", "丢弃预热缓存", target .. " reason=reader_or_revision_changed", probe_context)
                request.context._preload_on_ready()
                return
            end
            local t_handoff = Probe.start("Warm", "接管预热缓存", target, nil, probe_context)
            local old_cache = request.doc:getCacheFilePath()
            local live_cache_dir = old_cache and old_cache:match("^(.*)/[^/]+$")
            local warm_cache_name = cache_path and cache_path:match("([^/]+%.cr3)$")
            local handoff_ok = false
            local handoff_reason = "cache_input_invalid"
            if live_cache_dir and warm_cache_name
                    and lfs.attributes(cache_path, "mode") == "file" then
                local keep_path = FS.joinPath(live_cache_dir, warm_cache_name) .. ".keep"
                local ledger = io.open(preload_keep_ledger(), "a")
                if ledger then
                    local recorded = ledger:write(keep_path, "\n")
                    ledger:close()
                    if recorded then
                        handoff_ok = os.rename(cache_path, keep_path) and true or false
                        handoff_reason = handoff_ok and nil or "rename_failed"
                    else
                        handoff_reason = "ledger_write_failed"
                    end
                    if handoff_ok then
                        request.context._keep_cache_path = keep_path
                        self._pending_preload_keep = keep_path
                        self._pending_preload_doc = request.doc
                        self._pending_preload_revision = request.revision
                        request.context._warm_revision = request.revision
                        request.context.epub_path = request.doc.file
                    end
                else
                    handoff_reason = "ledger_open_failed"
                end
            end
            if handoff_ok then
                Probe.done("Warm", "接管预热缓存", target, t_handoff, "KEEP_READY", nil, nil, probe_context)
            else
                Probe.fail("Warm", "接管预热缓存", target, t_handoff, handoff_reason, probe_context)
            end
            request.context._preload_on_ready()
        end)
    end
    self._preload_cache_warmer:request(doc, revision, priority, context)
end

function M:showLoading(chapter, warm_context)
    if not PlgState:isFullBookMode() then return end
    if not chapter or chapter.isVolume then return end
    local book_cache_id = chapter.book_cache_id
    local ch_idx = chapter.chapters_index
    if not (book_cache_id and ch_idx ~= nil) then return end

    local info = self._skeleton_loading_info
    if info and info.book_cache_id == book_cache_id and info.chapters_index == ch_idx then
        if not warm_context then return info end
        if info.timer_cancel then info.timer_cancel(); info.timer_cancel = nil end
    else
        self:hideLoading()
        info = { book_cache_id = book_cache_id, chapters_index = ch_idx, created_at = os.time() }
        self._skeleton_loading_info = info
    end
    info.warm_context = warm_context

    local function show()
        local TaskProg = require("Legado.task.Progress")
        local msg = chapter.title or chapter.name or string.format("第%d章", ch_idx + 1)
        local ok, spinner = pcall(TaskProg.showSpinner, msg, {
            dismissable = true,
            update_interval = 0.8,
            dismiss_callback = function()
                if self._skeleton_loading_info == info then self:hideLoading(chapter) end
            end,
        })
        if ok then info.spinner = spinner end
        if warm_context and info.spinner then info.spinner:unschedule() end
    end

    if warm_context then
        if info.spinner then
            info.spinner:unschedule()
        else
            info.timer_cancel = TaskQueueV2.delay(0.3, function()
                if self._skeleton_loading_info ~= info or info.warm_context ~= warm_context then return end
                info.timer_cancel = nil
                local current = PlgState:readingChapter()
                local top = UIManager:getTopmostVisibleWidget() or {}
                if current and current.book_cache_id == book_cache_id
                        and current.chapters_index == ch_idx and top.name == "ReaderUI" then
                    show()
                end
            end)
        end
    else
        show()
        info.timer_cancel = TaskQueueV2.delay(20, function()
            if self._skeleton_loading_info == info and not info.warm_context then
                logger.warn("SkeletonChapterLoading: timeout reached for chapter", ch_idx)
                self:hideLoading(chapter, "加载超时，请检查网络或书源")
            end
        end)
    end
    return info
end

function M:hideLoading(chapter, error_msg)
    local info = self._skeleton_loading_info
    if chapter and info
            and (info.book_cache_id ~= chapter.book_cache_id
                or info.chapters_index ~= chapter.chapters_index) then
        return
    end

    if info then
        if info.timer_cancel then
            pcall(info.timer_cancel)
            info.timer_cancel = nil
        end

        self._skeleton_loading_info = nil
        if info.spinner and type(info.spinner.close) == "function" then
            pcall(info.spinner.close)
        end
    end

    if error_msg and error_msg ~= "" then
        Backend:_show_notice(error_msg)
    end
end

function M:cleanup()
    self:hideLoading()
    self:_clearPreloadRefreshScheduler()
end

return M
