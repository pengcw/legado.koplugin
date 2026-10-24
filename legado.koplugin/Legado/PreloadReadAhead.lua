local util = require("util")

local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Probe = require("Legado.Helper.Probe")
local TaskQueueV2 = require("Legado.task.v2")
local RateGate = require("Legado.task.v2.RateGate")

local M = {}
M.__index = M

local function format_chapter_desc(chapter)
    if not chapter then return "未知章节" end
    local index = chapter.chapters_index or chapter.index or "?"
    local title = chapter.title or chapter.name or ""
    if title ~= "" then
        return string.format("第%s章: %s", tostring(index), tostring(title))
    end
    return string.format("第%s章", tostring(index))
end

function M:new(host, state)
    return setmetatable({
        host = host,
        state = state,
        _epub_dirty_book_id = nil,
        _epub_dirty_indexes = {},
    }, self)
end

function M:_markEpubDirty(book_cache_id, chapter_indexes)
    if self._epub_dirty_book_id ~= book_cache_id then
        self._epub_dirty_book_id = book_cache_id
        self._epub_dirty_indexes = {}
    end
    for chapter_index in pairs(chapter_indexes or {}) do
        self._epub_dirty_indexes[chapter_index] = true
    end
end

function M:_clearEpubDirty(book_cache_id)
    if self._epub_dirty_book_id ~= book_cache_id then return end
    self._epub_dirty_book_id = nil
    self._epub_dirty_indexes = {}
end

function M:_isEpubDirtyChapter(chapter)
    return chapter
        and self._epub_dirty_book_id == chapter.book_cache_id
        and self._epub_dirty_indexes[chapter.chapters_index] == true
end

function M:_requestEpubRefresh(priority, book_cache_id, on_refreshed)
    self.host.request_refresh(priority, {
        book_cache_id = book_cache_id,
        on_refreshed = function()
            self:_clearEpubDirty(book_cache_id)
            if on_refreshed then on_refreshed() end
        end,
    })
end

function M:_getActiveTask(chapter)
    local task = self.state._preload_task
    if not task or (type(task.is_done) == "function" and task:is_done()) then return nil end
    if task._book_cache_id ~= nil and task._book_cache_id ~= chapter.book_cache_id then return nil end
    return task
end

function M:_isChapterPending(task, chapter_index)
    if not task or chapter_index == nil then return false end
    local pending = task._pending_chapter_indexes
    if H.is_tbl(pending) then return pending[chapter_index] == true end

    if task._start_idx ~= nil and task._end_idx ~= nil then
        return chapter_index >= task._start_idx and chapter_index <= task._end_idx
    end
    return task._target_idx == chapter_index
end

function M:_getReadableAheadIndexes(chapter, target)
    target = math.max(0, math.floor(tonumber(target) or 0))
    if target == 0 then return {} end

    if type(self.host.get_readable_ahead_indexes) == "function" then
        local indexes = self.host.get_readable_ahead_indexes(chapter, target)
        if H.is_tbl(indexes) then return indexes end
    end

    local current_index = tonumber(chapter and chapter.chapters_index)
    if not current_index then return {} end
    local indexes = {}
    for i = 1, target do
        indexes[i] = current_index + i
    end
    return indexes
end

function M:_countInflightAhead(chapter, cached_ahead, readable_ahead)
    local task = self:_getActiveTask(chapter)
    local start_pos = math.max(0, cached_ahead) + 1
    local first_missing_index = readable_ahead[start_pos]
    if not task or not first_missing_index then return 0, task, first_missing_index end

    local inflight = 0
    for i = start_pos, #readable_ahead do
        if not self:_isChapterPending(task, readable_ahead[i]) then break end
        inflight = inflight + 1
    end
    return inflight, task, first_missing_index
end

function M:getWindowBudget(chapter, target)
    target = math.max(0, math.floor(tonumber(target) or 0))
    local readable_ahead = self:_getReadableAheadIndexes(chapter, target)
    local effective_target = math.min(target, #readable_ahead)
    local cached_ahead = math.min(effective_target, math.max(0, tonumber(self.host.get_cached_ahead(chapter)) or 0))
    local inflight_ahead, task, first_missing_index = self:_countInflightAhead(chapter, cached_ahead, readable_ahead)
    return {
        target = effective_target,
        cached_ahead = cached_ahead,
        inflight_ahead = inflight_ahead,
        need = math.max(0, effective_target - cached_ahead - inflight_ahead),
        first_missing_index = first_missing_index,
        current_missing = self.host.get_usable_cache_path(chapter) == nil,
        task = task,
    }
end

function M:cancelTimer(chapter, reason)
    if not self.state._preload_timer_cancel then return end
    self.state._preload_timer_cancel()
    self.state._preload_timer_cancel = nil
    if reason then
        Probe.retry("Preload", "防抖重置 (快速切章)", format_chapter_desc(chapter), nil, reason)
    end
end

function M:ensure(chapter, allow_debounce)
    if not self.host.is_connected() or (chapter and chapter.isVolume) then
        if self.host.hide_chapter_loading then
            self.host.hide_chapter_loading(chapter)
        end
        return
    end

    if self:_isEpubDirtyChapter(chapter) then
        Probe.eventf("Preload", "当前章命中待刷新正文", nil, "book_id=%s idx=%s",
            tostring(chapter.book_cache_id), tostring(chapter.chapters_index))
        if self.host.hide_chapter_loading then
            self.host.hide_chapter_loading(chapter)
        end
        self:_requestEpubRefresh("urgent", chapter.book_cache_id)
    end

    local settings = self.host.get_settings()
    local target = tonumber(settings.preload_chapters) or 4
    if chapter.cacheExt == "cbz" then target = 1 end
    local budget = self:getWindowBudget(chapter, target)
    local task = budget.task
    local task_context = task and task._probe_context or nil
    local current_index = tonumber(chapter.chapters_index)
    local current_pending = task and self:_isChapterPending(task, current_index)
    local first_missing_index = budget.first_missing_index
    local future_covered = task and first_missing_index
        and self:_isChapterPending(task, first_missing_index)

    if budget.current_missing then
        self:cancelTimer(chapter, "当前章补救优先")
        if self.host.show_chapter_loading then
            self.host.show_chapter_loading(chapter)
        end
        if current_pending then
            Probe.eventf("Preload", "复用当前章补救任务", task_context,
                "book_id=%s idx=%s", tostring(chapter.book_cache_id), tostring(current_index))
            return
        end
        Probe.eventf("Preload", "当前章立即补救", nil,
            "book_id=%s idx=%s future_need=%d",
            tostring(chapter.book_cache_id), tostring(current_index), budget.need)
        self:start(chapter, budget.need)
        return
    end

    if not self:_isEpubDirtyChapter(chapter) and self.host.hide_chapter_loading then
        self.host.hide_chapter_loading(chapter)
    end

    if budget.need == 0 then
        self:cancelTimer(chapter)
        return
    end

    if future_covered then
        self:cancelTimer(chapter)
        Probe.eventf("Preload", "复用在途任务", task_context,
            "book_id=%s first_missing=%s need=%d",
            tostring(chapter.book_cache_id), tostring(first_missing_index), budget.need)
        Probe.done("Preload", "顺读复用在途任务", format_chapter_desc(chapter), nil, nil, nil, nil, task_context)
        return
    end

    if allow_debounce == false then
        self:cancelTimer(chapter)
        self:start(chapter, budget.need)
        return
    end

    self:cancelTimer(chapter, "取消前次未触发预读")
    Probe.eventf("Preload", "创建预读防抖", nil,
        "book_id=%s idx=%s target=%d cached=%d inflight=%d need=%d",
        tostring(chapter.book_cache_id), tostring(chapter.chapters_index),
        budget.target, budget.cached_ahead, budget.inflight_ahead, budget.need)
    Probe.start("Preload", "预读排队防抖 (1.5s)", format_chapter_desc(chapter), function()
        return string.format("(目标: %d章, 已缓存: %d, 在途: %d, 缺口: %d)",
            budget.target, budget.cached_ahead, budget.inflight_ahead, budget.need)
    end)
    self.state._preload_timer_cancel = TaskQueueV2.delay(1.5, function()
        self.state._preload_timer_cancel = nil
        self:ensure(chapter, false)
    end)
end

function M:buildPlan(chapter, future_need)
    future_need = math.max(0, math.floor(tonumber(future_need) or 0))
    local tasks = {}

    if not chapter.isVolume and self.host.get_usable_cache_path(chapter) == nil and chapter and chapter.chapters_index ~= nil then
        table.insert(tasks, chapter)
    end

    if future_need > 0 then
        local next_tasks = self.host.find_missing_chapters(chapter, future_need) or {}
        for _, task in ipairs(next_tasks) do
            if task.chapters_index ~= chapter.chapters_index then
                table.insert(tasks, task)
            end
        end
    end

    local first_index = tasks[1] and tasks[1].chapters_index
    local last_index = tasks[#tasks] and tasks[#tasks].chapters_index
    return {
        tasks = tasks,
        start_idx = first_index and math.min(first_index, last_index or first_index),
        end_idx = last_index and math.max(first_index or last_index, last_index),
    }
end

function M:start(chapter, future_need)
    local batch_id = string.format("preload:%s:%d:%d", tostring(chapter.book_cache_id), os.time(), math.random(100, 999))
    local probe_context = Probe.context(batch_id)
    local plan = self:buildPlan(chapter, future_need)
    local tasks = plan.tasks
    Probe.eventf("Preload", "计划生成", probe_context,
        "book_id=%s current=%s future_need=%s tasks=%d range=%s-%s",
        tostring(chapter.book_cache_id), tostring(chapter.chapters_index), tostring(future_need), #tasks,
        tostring(plan.start_idx or "-"), tostring(plan.end_idx or "-"))
    if #tasks == 0 then
        Probe.done("Preload", "全部已缓存跳过", format_chapter_desc(chapter), nil, "CACHE_HIT", nil, nil, probe_context)
        return
    end

    local book_info = self.host.get_book_info(chapter.book_cache_id)
    local rate_key = book_info and book_info.origin or chapter.origin
    local concurrent_rate = book_info and book_info.concurrentRate

    self.state:cancelPreload("new_preload_started")
    local settings = self.host.get_settings()
    local configured_processes = self.host.normalize_download_threads(settings.download_threads)
    local process_count = math.min(configured_processes, 2, #tasks)
    local chapter_timeout = self.host.is_comic(chapter.book_cache_id) and 120 or 20
    local limit, interval_ms = RateGate.parse(concurrent_rate)
    if type(rate_key) == "string" and rate_key ~= "" and limit then
        local wait_windows = math.ceil(process_count / limit)
        chapter_timeout = chapter_timeout + math.ceil(wait_windows * interval_ms / 1000)
    end
    local lock_ttl = math.max(180, chapter_timeout * math.ceil(#tasks / process_count) + 60)
    pcall(self.host.set_task_lock, tasks, true, lock_ttl, batch_id)
    local t_batch_start = Probe.start("Preload", "启动V2预读批次", format_chapter_desc(chapter), function()
        return string.format("共%d章 (processes=%d, timeout=%ds, mode=process)",
            #tasks, process_count, chapter_timeout)
    end, probe_context)

    local success_count = 0
    local stats = (Probe.is_enabled("Preload", "fail")
        or Probe.is_enabled("Chapter", "done")) and {
        scheduled = #tasks,
        completed = 0,
        failed = 0,
        cancelled_batches = 0,
        bytes = 0,
        inject_count = 0,
        inject_failed = 0,
        inject_bytes = 0,
        refresh_count = 0,
    } or nil
    local function metric_inc(name, value)
        if stats then
            stats[name] = (stats[name] or 0) + (value or 1)
        end
    end
    local function metric_summary()
        if not stats then return nil end
        return string.format(
            "计划:%d 完成:%d 失败:%d 取消批次:%d 下载:%s 注入:%d/%d(%s) 刷新:%d",
            stats.scheduled, stats.completed, stats.failed, stats.cancelled_batches,
            Probe.format_bytes(stats.bytes), stats.inject_count, stats.inject_failed,
            Probe.format_bytes(stats.inject_bytes), stats.refresh_count
        )
    end

    local batch_group
    batch_group = TaskQueueV2.batch(tasks, function(download_chapter, index, ctx)
        local t_chapter_start = H.timestamp()
        Probe.eventf("Preload", "进程领取章节", probe_context,
            "idx=%s", tostring(download_chapter.chapters_index))
        local ok, downloaded = pcall(function()
            return self.host.download_chapter(download_chapter, {
                auto_pack_cbz = true,
                check_running = function() return ctx.is_cancelled() end,
                acquire_request = function()
                    if not RateGate.parse(concurrent_rate) then return true end
                    return ctx.acquire_rate_limit(rate_key, concurrent_rate)
                end,
            })
        end)
        if ctx.is_cancelled() then
            return false, "cancelled"
        end
        if ok and downloaded and downloaded.cacheFilePath then
            return {
                chapter = download_chapter,
                cacheFilePath = downloaded.cacheFilePath,
                size = FS.getFileSize(downloaded.cacheFilePath),
                t_start = t_chapter_start,
                progress = string.format("完成 %d/%d", index, #tasks),
            }
        end
        return false, tostring(downloaded)
    end, {
        engine = "process",
        concurrency = process_count,
        timeout = chapter_timeout,
        on_item = function(index, success, result)
            local task = batch_group.task
            if task:is_cancelled() then return end
            if success and result then
                task:emit("chapter_done", result)
            else
                task:emit("chapter_failed", {
                    chapter = tasks[index],
                    t_start = H.timestamp(),
                    err = tostring(result),
                })
            end
        end,
    })
    local task = batch_group.task
    Probe.eventf("Preload", "启动章节进程", probe_context,
        "workers=%d tasks=%d engine=process_batch", process_count, #tasks)

    task._target_idx = tasks[1] and tasks[1].chapters_index
    task._concurrency = process_count
    task._book_cache_id = chapter.book_cache_id
    task._start_idx = plan.start_idx
    task._end_idx = plan.end_idx
    task._probe_context = probe_context
    task._pending_chapter_indexes = {}
    for _, pending_chapter in ipairs(tasks) do
        task._pending_chapter_indexes[pending_chapter.chapters_index] = true
    end
    self.state._preload_task = task

    local pending_updates = {}
    local book_cache_id = tasks[1] and tasks[1].book_cache_id
    local book_name = tasks[1] and tasks[1].name

    local function flush_pending_updates(reason)
        if next(pending_updates) == nil then return false end

        local batch_map = {}
        local pending_count = 0
        local inject_bytes = 0
        for chapter_index, raw in pairs(pending_updates) do
            batch_map[chapter_index] = raw
            pending_count = pending_count + 1
            inject_bytes = inject_bytes + #(raw or "")
        end
        Probe.eventf("Preload", "提交注入批次", probe_context,
            "reason=%s chapters=%d bytes=%s",
            tostring(reason), pending_count, Probe.format_bytes(inject_bytes))
        local inject_ok = false
        pcall(function()
            inject_ok = self.host.inject_many(book_cache_id, batch_map, book_name) and true or false
        end)
        if inject_ok then
            for chapter_index, raw in pairs(batch_map) do
                if pending_updates[chapter_index] == raw then
                    pending_updates[chapter_index] = nil
                end
            end
            self:_markEpubDirty(book_cache_id, batch_map)
            metric_inc("inject_count")
            metric_inc("inject_bytes", inject_bytes)

            local current_reading = self.host.reading_chapter()
            local priority = current_reading
                and current_reading.book_cache_id == book_cache_id
                and batch_map[current_reading.chapters_index] ~= nil
                and "urgent" or "idle"
            self:_requestEpubRefresh(priority, book_cache_id, function()
                metric_inc("refresh_count")
            end)
            Probe.eventf("Preload", "注入批次成功", probe_context,
                "chapters=%d bytes=%s refresh=%s",
                pending_count, Probe.format_bytes(inject_bytes), priority)
        else
            metric_inc("inject_failed")
            Probe.eventf("Preload", "注入批次失败，保留待注入正文", probe_context,
                "chapters=%d", pending_count)
        end
        return inject_ok
    end

    task:on("chapter_done", function(data)
        if task:is_cancelled() then return end
        success_count = success_count + 1
        task._pending_chapter_indexes[data.chapter.chapters_index] = nil
        metric_inc("completed")
        metric_inc("bytes", data.size or 0)
        pcall(self.host.commit_cache_path, data.chapter, data.cacheFilePath)
        pcall(self.host.set_task_lock, data.chapter, false, nil, batch_id)
        if data.cacheFilePath and util.fileExists(data.cacheFilePath)
                and not data.cacheFilePath:lower():match("%.cbz$") then
            local raw = util.readFromFile(data.cacheFilePath)
            if raw and raw ~= "" then
                local current_reading = self.host.reading_chapter()
                if current_reading and current_reading.book_cache_id == data.chapter.book_cache_id
                        and current_reading.chapters_index == data.chapter.chapters_index then
                    local inject_ok = false
                    pcall(function()
                        inject_ok = self.host.inject_one(data.chapter.book_cache_id, data.chapter.chapters_index, raw, data.chapter.name) and true or false
                    end)
                    if inject_ok then
                        self:_markEpubDirty(data.chapter.book_cache_id, {
                            [data.chapter.chapters_index] = true,
                        })
                        metric_inc("inject_count")
                        metric_inc("inject_bytes", #raw)
                        self:_requestEpubRefresh("urgent", data.chapter.book_cache_id, function()
                            metric_inc("refresh_count")
                        end)
                        Probe.eventf("Preload", "当前章快速注入成功", probe_context,
                            "idx=%s bytes=%s", tostring(data.chapter.chapters_index), Probe.format_bytes(#raw))
                    else
                        metric_inc("inject_failed")
                        Probe.eventf("Preload", "当前章快速注入失败，不触发无效刷新", probe_context,
                            "idx=%s", tostring(data.chapter.chapters_index))
                        if self.host.hide_chapter_loading then
                            self.host.hide_chapter_loading(data.chapter, "正文写入书籍失败")
                        end
                    end
                else
                    pending_updates[data.chapter.chapters_index] = raw
                    local pending_count = 0
                    for _ in pairs(pending_updates) do pending_count = pending_count + 1 end
                    Probe.eventf("Preload", "章节进入注入缓冲", probe_context,
                        "idx=%s pending=%d", tostring(data.chapter.chapters_index), pending_count)
                    if pending_count >= 3 then
                        flush_pending_updates("batch_threshold_3")
                    end
                end
            else
                local current_reading = self.host.reading_chapter()
                if current_reading and current_reading.book_cache_id == data.chapter.book_cache_id
                        and current_reading.chapters_index == data.chapter.chapters_index then
                    if self.host.hide_chapter_loading then
                        self.host.hide_chapter_loading(data.chapter, "章节正文为空")
                    end
                end
            end
        else
            local current_reading = self.host.reading_chapter()
            if current_reading and current_reading.book_cache_id == data.chapter.book_cache_id
                    and current_reading.chapters_index == data.chapter.chapters_index then
                if self.host.hide_chapter_loading then
                    self.host.hide_chapter_loading(data.chapter, "章节缓存文件缺失")
                end
            end
        end
        Probe.done("Chapter", "章节入库", format_chapter_desc(data.chapter), data.t_start,
            "200 OK", function() return Probe.format_bytes(data.size) end, data.progress, probe_context)
    end)

    task:on("chapter_failed", function(data)
        if data.chapter and data.chapter.chapters_index ~= nil then
            task._pending_chapter_indexes[data.chapter.chapters_index] = nil
        end
        metric_inc("failed")
        pcall(self.host.set_task_lock, data.chapter, false, nil, batch_id)
        local current_reading = self.host.reading_chapter()
        local is_current = current_reading and data.chapter
            and current_reading.book_cache_id == data.chapter.book_cache_id
            and current_reading.chapters_index == data.chapter.chapters_index
        local reason = tostring(data.err or ""):find("源站返回正文内容为空") and "源站正文为空" or "下载失败"
        if is_current then
            local message = string.format("《%s》%s，请尝试换源或刷新", tostring(data.chapter.title or "当前章节"), reason)
            Probe.done("Chapter", "提示正文异常", format_chapter_desc(data.chapter), data.t_start, "NOTICE_POPUP", message, nil, probe_context)
            if self.host.hide_chapter_loading then
                self.host.hide_chapter_loading(data.chapter, message)
            else
                self.host.show_notice(message)
            end
        else
            Probe.done("Chapter", "后台失败静默", format_chapter_desc(data.chapter), data.t_start, "SILENT_SKIP", string.format("当前在读: %s", tostring(current_reading and current_reading.chapters_index or "-")), nil, probe_context)
        end
    end)

    local cleaned = false
    local function cleanup()
        if cleaned then return end
        cleaned = true
        if self.state._preload_task == task then
            self.state._preload_task = nil
        end
        pcall(self.host.set_task_lock, tasks, false, nil, batch_id)
        task._pending_chapter_indexes = nil
    end

    task:on("done", cleanup)

    task:on("finish", function()
        cleanup()
        flush_pending_updates("batch_finish")
        if success_count > 0 then
            Probe.done("Preload", "预读批处理完成", format_chapter_desc(chapter),
                t_batch_start, "SUCCESS", metric_summary, nil, probe_context)
        else
            Probe.fail("Preload", "预读批处理未下载任何章节", format_chapter_desc(chapter),
                t_batch_start, metric_summary, probe_context)
        end
        local current = self.host.reading_chapter()
        if current and current.book_cache_id == chapter.book_cache_id then
            self:ensure(current, true)
        end
    end)

    local function metric_reason(reason)
        if not stats then return tostring(reason) end
        return tostring(reason) .. " | " .. metric_summary()
    end
    local function hide_current_loading()
        local current = self.host.reading_chapter()
        if current and current.book_cache_id == chapter.book_cache_id
                and not self:_isEpubDirtyChapter(current) and self.host.hide_chapter_loading then
            self.host.hide_chapter_loading(current)
        end
    end

    task:on("error", function(err)
        cleanup()
        flush_pending_updates("batch_error")
        Probe.fail("Preload", "预读批处理失败", format_chapter_desc(chapter), t_batch_start, metric_reason(err), probe_context)
        hide_current_loading()
    end)
    task:on("cancel", function(reason)
        cleanup()
        if reason ~= "change_book_source" and reason ~= "backend_exit_clean" then
            flush_pending_updates("batch_cancel")
        end
        metric_inc("cancelled_batches")
        Probe.retry("Preload", "预读批处理取消", format_chapter_desc(chapter), t_batch_start, metric_reason(reason or "cancelled"), probe_context)
        hide_current_loading()
    end)
end

return M
