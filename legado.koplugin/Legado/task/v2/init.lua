local socket = require("socket")
local logger = require("logger")
local TaskModule = require("Legado.task.v2.Task")
local Task = TaskModule.Task
local Engines = require("Legado.task.v2.Engine")

local TaskQueue = {}
TaskQueue.__index = TaskQueue

local Channel = {}
Channel.__index = Channel

function Channel:new(name, opts)
    opts = opts or {}
    local obj = setmetatable({}, self)
    obj.name = name or "default"
    obj.max_workers = math.max(1, tonumber(opts.max_workers) or 4)
    obj.active_workers = 0
    obj.paused = false
    obj.queue = {} -- 优先级队列
    obj.tasks = {} -- task_id -> Task
    obj.retry = {
        max = opts.retry and (opts.retry.max or opts.retry) or 0,
        delay = opts.retry and opts.retry.delay or 1.0,
        backoff = opts.retry and opts.retry.backoff or 1.5,
    }
    obj.rate_limit_delay = opts.delay or 0
    obj.last_dispatch_time = 0
    return obj
end

function Channel:submit(job, opts)
    opts = opts or {}
    opts.channel = self.name
    opts.retry = opts.retry or self.retry

    local task = Task:new(job, opts)
    self.tasks[task.id] = task

    task:on("finish", function()
        self.active_workers = math.max(0, self.active_workers - 1)
        self:schedule()
    end)

    task:on("error", function(err)
        self.active_workers = math.max(0, self.active_workers - 1)
        if task.retry and task.retry.current < task.retry.max then
            task.retry.current = task.retry.current + 1
            local delay = task.retry.delay * (task.retry.backoff ^ (task.retry.current - 1))
            task:emit("retry", task.retry.current, task.retry.max, delay, err)
            task.state = Task.STATE.PENDING

            local UIManager = require("ui/uimanager")
            if delay > 0 and UIManager and UIManager.scheduleIn then
                UIManager:scheduleIn(delay, function()
                    self:enqueue(task)
                end)
            else
                self:enqueue(task)
            end
        else
            task:emit("final_error", err)
            self:schedule()
        end
    end)

    task:on("cancel", function()
        self.active_workers = math.max(0, self.active_workers - 1)
        self:schedule()
    end)

    task:on("timeout", function()
        self.active_workers = math.max(0, self.active_workers - 1)
        self:schedule()
    end)

    self:enqueue(task)
    return task
end

function Channel:enqueue(task)
    -- 降序插入队列 ,priority 越大越靠前)
    local inserted = false
    for i, t in ipairs(self.queue) do
        if (task.priority or 0) > (t.priority or 0) then
            table.insert(self.queue, i, task)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(self.queue, task)
    end
    self:schedule()
end

function Channel:schedule()
    if self.paused then return end
    while self.active_workers < self.max_workers and #self.queue > 0 do
        local now = socket.gettime()
        if self.rate_limit_delay > 0 and (now - self.last_dispatch_time) < self.rate_limit_delay then
            local remain = self.rate_limit_delay - (now - self.last_dispatch_time)
            local UIManager = require("ui/uimanager")
            if UIManager and UIManager.scheduleIn then
                UIManager:scheduleIn(remain, function() self:schedule() end)
            end
            break
        end

        local task = table.remove(self.queue, 1)
        if task and not task:is_done() then
            self.active_workers = self.active_workers + 1
            self.last_dispatch_time = socket.gettime()
            local engine = Engines.get(task.engine)
            engine.start(task)
        end
    end
end

function Channel:pause()
    self.paused = true
    for _, task in pairs(self.tasks) do
        if task:is_running() then task:pause() end
    end
end

function Channel:resume()
    self.paused = false
    for _, task in pairs(self.tasks) do
        if task:is_running() then task:resume() end
    end
    self:schedule()
end

function Channel:clear()
    local tasks_to_cancel = self.queue
    self.queue = {}
    for _, task in ipairs(tasks_to_cancel) do
        task:cancel("channel_cleared")
    end
end

function Channel:get_status()
    return {
        name = self.name,
        active_workers = self.active_workers,
        max_workers = self.max_workers,
        queued_tasks = #self.queue,
        paused = self.paused,
    }
end

local channels = {}

function TaskQueue.channel(name, opts)
    name = name or "default"
    if not channels[name] then
        channels[name] = Channel:new(name, opts)
    end
    return channels[name]
end

function TaskQueue.submit(job, opts)
    opts = opts or {}
    local ch_name = opts.channel or "default"
    local ch = TaskQueue.channel(ch_name, opts)
    return ch:submit(job, opts)
end

function TaskQueue.spawn(job, opts)
    opts = opts or {}
    opts.engine = "process"
    local ch_name = opts.channel or ("spawn_" .. string.format("%d_%d", math.floor(socket.gettime() * 1000), math.random(1000, 9999)))
    local ch = TaskQueue.channel(ch_name, { max_workers = 1 })
    return ch:submit(job, opts)
end

--- 单次执行任务 (类似 Promise / async-await)
-- @param callback: function(ok, result_or_err)
function TaskQueue.run(job, callback, opts)
    opts = opts or {}
    local task = TaskQueue.submit(job, opts)
    if type(callback) == "function" then
        task:on("finish", function(result)
            callback(true, result)
        end)
        task:on("error", function(err)
            callback(false, err)
        end)
        task:on("cancel", function(err)
            callback(false, err)
        end)
        task:on("timeout", function(err)
            callback(false, err)
        end)
    end
    return task
end

function TaskQueue.stream(job, opts)
    opts = opts or {}
    local task = TaskQueue.submit(job, opts)
    if opts.on_chunk then task:on("chunk", opts.on_chunk) end
    if opts.on_progress then task:on("progress", opts.on_progress) end
    if opts.on_finish then
        task:on("finish", function(res) opts.on_finish(true, res) end)
        task:on("error", function(err) opts.on_finish(false, err) end)
        task:on("cancel", function(err) opts.on_finish(false, err) end)
        task:on("timeout", function(err) opts.on_finish(false, err) end)
    end
    return task
end

--- 双向交互长会话 (支持重入与动态命令路由)
function TaskQueue.session(job, opts)
    opts = opts or {}
    opts.engine = opts.engine or "process"
    local task = TaskQueue.submit(job, opts)
    if opts.on_chunk then task:on("chunk", opts.on_chunk) end
    if opts.on_message then task:on("chunk", opts.on_message) end
    if opts.on_finish then
        task:on("finish", function(res) opts.on_finish(true, res) end)
        task:on("error", function(err) opts.on_finish(false, err) end)
        task:on("cancel", function(err) opts.on_finish(false, err) end)
    end
    return task
end

local function _batchInProcess(items, worker_fn, opts)
    opts = opts or {}
    local total = items and #items or 0
    local results = {}
    local has_errors = false

    if total == 0 then
        if opts.on_finish then opts.on_finish(true, results) end
        return {
            tasks = {},
            cancel = function() end,
        }
    end

    local concurrency = math.max(1, tonumber(opts.concurrency) or 4)
    local finished_reported = false
    local function finish_batch(ok, res_or_err)
        if finished_reported then return end
        finished_reported = true
        if opts.on_finish then
            pcall(opts.on_finish, ok, res_or_err)
        end
    end

    local spawn_task = TaskQueue.spawn(function(ctx)
        local cur_idx = 0
        local total_items = #items
        local finished_count = 0
        local workers_done = 0
        local copas = require("Legado.vendor.copas")
        local actual_concurrency = math.max(1, math.min(concurrency, total_items))
        local batch_results = {}
        local child_has_errors = false

        for w = 1, actual_concurrency do
            copas.addthread(function()
                while true do
                    if ctx.is_cancelled and ctx:is_cancelled() then break end
                    cur_idx = cur_idx + 1
                    local idx = cur_idx
                    if idx > total_items then break end

                    local item = items[idx]
                    local item_success = false
                    local item_res = nil

                    local ok, ret_val, extra_err = pcall(function()
                        return worker_fn(item, idx, ctx)
                    end)

                    if ok then
                        if ret_val == false and extra_err ~= nil then
                            item_success = false
                            item_res = extra_err
                            child_has_errors = true
                        else
                            item_success = true
                            item_res = ret_val
                        end
                    else
                        item_success = false
                        item_res = tostring(ret_val)
                        child_has_errors = true
                    end

                    if item_success then
                        batch_results[idx] = item_res
                    else
                        batch_results[idx] = nil
                    end

                    ctx.emit("__batch_item__", {
                        idx = idx,
                        success = item_success,
                        res = item_res,
                    })

                    finished_count = finished_count + 1
                    ctx.progress(finished_count / total_items, string.format("%d/%d", finished_count, total_items))
                end
                workers_done = workers_done + 1
            end)
        end

        while workers_done < actual_concurrency do
            if ctx.is_cancelled and ctx:is_cancelled() then break end
            copas.sleep(0.01)
        end

        if ctx.throw_if_cancelled then
            ctx:throw_if_cancelled()
        end

        return {
            has_errors = child_has_errors,
            results = batch_results,
        }
    end, {
        timeout = opts.timeout,
        priority = opts.priority,
    })

    spawn_task:on("__batch_item__", function(data)
        if data and type(data) == "table" then
            local idx = data.idx
            local success = data.success
            local res = data.res
            if success then
                results[idx] = res
            else
                has_errors = true
                results[idx] = nil
            end
            if opts.on_item then
                pcall(opts.on_item, idx, success, res)
            end
        end
    end)

    spawn_task:on("progress", function(ratio, msg)
        if opts.on_progress then
            local done = math.floor(ratio * total + 0.5)
            pcall(opts.on_progress, ratio, done, total)
        end
    end)

    spawn_task:on("finish", function(res)
        if type(res) == "table" and res.results ~= nil then
            finish_batch(not res.has_errors, res.results)
        else
            finish_batch(not has_errors, results)
        end
    end)

    spawn_task:on("error", function(err)
        finish_batch(false, err)
    end)

    spawn_task:on("cancel", function(reason)
        finish_batch(false, reason or "cancelled")
    end)

    spawn_task:on("timeout", function()
        finish_batch(false, "timeout")
    end)

    return {
        task = spawn_task,
        tasks = { spawn_task },
        cancel = function(reason)
            spawn_task:cancel(reason or "batch_cancelled")
        end,
    }
end

TaskQueue._batchInProcess = _batchInProcess

--- 批处理任务组
-- @param items: 任务数据数组
-- @param worker_fn: function(item, idx, ctx)
-- @param opts: { engine="copas"|"process"|"main", concurrency=4, on_item=fn, on_progress=fn, on_finish=fn, timeout=num }
--              engine="copas" (默认): 单独一个子进程，内部由协程池并发扇出
--              engine="process": 纯多子进程队列 (每个 item 独立子进程，受 concurrency 限制)
--              engine="main": 主进程协程队列 (在主线程内由 Copas 协程调度)
function TaskQueue.batch(items, worker_fn, opts)
    opts = opts or {}
    local engine = opts.engine or "copas"
    if engine == "copas" or engine == "subprocess" then
        return _batchInProcess(items, worker_fn, opts)
    end

    local total = items and #items or 0
    local results = {}
    local finished_count = 0
    local has_errors = false

    if total == 0 then
        if opts.on_finish then opts.on_finish(true, results) end
        return {
            tasks = {},
            cancel = function() end,
        }
    end

    local ch_name = "batch_" .. string.format("%d_%d", math.floor(socket.gettime() * 1000), math.random(100, 999))
    local ch = TaskQueue.channel(ch_name, {
        max_workers = opts.concurrency or 4,
        retry = opts.retry,
    })
    local batch_tasks = {}

    local function check_batch_finish()
        if finished_count == total then
            if opts.on_finish then
                opts.on_finish(not has_errors, results)
            end
            channels[ch_name] = nil
        end
    end

    local task_engine = (engine == "process") and "process" or "main"

    for idx, item in ipairs(items) do
        local task = ch:submit(function(ctx)
            return worker_fn(item, idx, ctx)
        end, {
            engine = task_engine,
            priority = opts.priority or 0,
            retry = opts.retry,
        })

        local is_finalized = false
        local function finalize(success, res_or_err)
            if is_finalized then return end
            is_finalized = true
            finished_count = finished_count + 1
            if success then
                results[idx] = res_or_err
            else
                has_errors = true
                results[idx] = nil
            end
            if opts.on_item then pcall(opts.on_item, idx, success, res_or_err) end
            if opts.on_progress then pcall(opts.on_progress, finished_count / total, finished_count, total) end
            check_batch_finish()
        end

        task:on("finish", function(res)
            finalize(true, res)
        end)

        task:on("final_error", function(err)
            finalize(false, err)
        end)

        task:on("error", function(err)
            if not (task.retry and (task.retry.max or 0) > 0 and task.retry.current <= task.retry.max) then
                finalize(false, err)
            end
        end)

        task:on("cancel", function(reason)
            finalize(false, reason or "cancelled")
        end)

        task:on("timeout", function()
            finalize(false, "timeout")
        end)

        table.insert(batch_tasks, task)
    end

    return {
        tasks = batch_tasks,
        cancel = function()
            ch:clear()
            for _, t in ipairs(batch_tasks) do t:cancel("batch_cancelled") end
            channels[ch_name] = nil
        end,
    }
end

function TaskQueue.destroyChannel(name)
    if channels[name] then
        channels[name]:clear()
        channels[name] = nil
    end
end

function TaskQueue.destroyAll()
    for name, ch in pairs(channels) do
        ch:clear()
    end
    channels = {}
end

function TaskQueue.hasAnyTasks()
    local total_queued = 0
    local total_active = 0
    for _, ch in pairs(channels) do
        total_queued = total_queued + #ch.queue
        total_active = total_active + ch.active_workers
    end
    local is_busy = (total_queued > 0 or total_active > 0)
    return is_busy, total_queued, total_active
end

function TaskQueue.getEngineStatus()
    local status = {}
    for name, ch in pairs(channels) do
        status[name] = ch:get_status()
    end
    return status
end

function TaskQueue.delay(seconds, callback)
    local UIManager = require("ui/uimanager")
    local cancelled = false
    local fn = function()
        if not cancelled and type(callback) == "function" then
            callback()
        end
    end
    if UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(seconds, fn)
    end
    return function()
        cancelled = true
        if UIManager and UIManager.unschedule then
            UIManager:unschedule(fn)
        end
    end
end

TaskQueue.Task = Task
TaskQueue.Channel = Channel
TaskQueue.Engines = Engines

return TaskQueue
