local JSON = require("json")
local socket = require("socket")
local logger = require("logger")

local Task = {}
Task.__index = Task

Task.STATE = {
    PENDING   = "pending",
    RUNNING   = "running",
    COMPLETED = "completed",
    FAILED    = "failed",
    CANCELLING= "cancelling",
    CANCELLED = "cancelled",
    TIMEOUT   = "timeout",
}

local function new_task_id()
    return string.format("task_%d_%d", math.floor(socket.gettime() * 1000), math.random(1000, 9999))
end

function Task:new(job, opts)
    opts = opts or {}
    local obj = setmetatable({}, self)
    obj.id = opts.id or new_task_id()
    obj.job = job
    obj.engine = opts.engine or "copas" -- "copas" | "process"
    obj.channel = opts.channel or "default"
    obj.priority = opts.priority or 0
    obj.timeout = opts.timeout or nil
    obj.retry = {
        max = opts.retry and (opts.retry.max or opts.retry) or 0,
        current = 0,
        delay = opts.retry and opts.retry.delay or 1.0,
        backoff = opts.retry and opts.retry.backoff or 1.5,
    }
    obj.state = Task.STATE.PENDING
    obj.result = nil
    obj.error = nil
    obj.created_at = socket.gettime()
    obj.started_at = nil
    obj.finished_at = nil
    obj.cancel_reason = nil
    obj.listeners = {}
    obj.engine_handle = nil
    return obj
end

function Task:on(event, callback)
    if not event or type(callback) ~= "function" then return self end
    self.listeners[event] = self.listeners[event] or {}
    table.insert(self.listeners[event], callback)
    return self
end

function Task:emit(event, ...)
    local list = self.listeners[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then
            logger.err(string.format("[Task %s] 事件回调 %s 异常: %s", self.id, event, tostring(err)))
        end
    end
end

function Task:get_state()
    return self.state
end

function Task:is_pending()
    return self.state == Task.STATE.PENDING
end

function Task:is_running()
    return self.state == Task.STATE.RUNNING
end

function Task:is_done()
    return self.state == Task.STATE.COMPLETED
        or self.state == Task.STATE.FAILED
        or self.state == Task.STATE.CANCELLED
        or self.state == Task.STATE.TIMEOUT
end

function Task:is_cancelled()
    return self.state == Task.STATE.CANCELLED or self.state == Task.STATE.CANCELLING
end

function Task:is_paused()
    return self.state == Task.STATE.PAUSED
end

function Task:get_result()
    return self.result, self.error
end

function Task:cancel(reason)
    if self:is_done() then return false end
    self.cancel_reason = reason or "user_cancelled"
    self:transition(Task.STATE.CANCELLED, nil, self.cancel_reason)
    if self.engine_handle and self.engine_handle.cancel then
        self.engine_handle:cancel(self.cancel_reason)
    end
    return true
end

function Task:pause()
    if self.engine_handle and self.engine_handle.pause then
        return self.engine_handle:pause()
    end
    return false
end

function Task:resume()
    if self.engine_handle and self.engine_handle.resume then
        return self.engine_handle:resume()
    end
    return false
end

function Task:send(action_or_data, maybe_data)
    if self:is_done() then return false, "task_done" end
    if not self.engine_handle then return false, "not_running" end
    local payload
    if maybe_data ~= nil then
        payload = { action = tostring(action_or_data), data = maybe_data }
    elseif type(action_or_data) == "table" then
        payload = action_or_data
    else
        payload = { action = "message", data = action_or_data }
    end
    local msg = JSON.encode(payload)
    if self.engine_handle.send_line then
        return self.engine_handle:send_line(msg)
    elseif self.engine_handle.send then
        return self.engine_handle:send(msg)
    end
    return false, "unsupported"
end

function Task:send_command(cmd)
    return self:send(cmd)
end

function Task:transition(new_state, result, err)
    if self:is_done() and new_state ~= Task.STATE.PENDING then return end
    local prev_state = self.state
    self.state = new_state

    if new_state == Task.STATE.RUNNING then
        self.started_at = socket.gettime()
        self:emit("start", self)
    elseif new_state == Task.STATE.COMPLETED then
        self.finished_at = socket.gettime()
        self.result = result
        self:emit("finish", result, self)
        self:emit("done", true, result, new_state, self)
    elseif new_state == Task.STATE.FAILED then
        self.finished_at = socket.gettime()
        local raw_err = err or result
        local clean_err = type(raw_err) == "table" and (raw_err[1] or raw_err.reason or raw_err.message or raw_err.error or raw_err.errorMsg or raw_err.err or raw_err.msg or tostring(raw_err)) or raw_err
        self.error = clean_err
        self:emit("error", clean_err, self)
        self:emit("done", false, clean_err, new_state, self)
    elseif new_state == Task.STATE.CANCELLED then
        self.finished_at = socket.gettime()
        local raw_reason = err or result or self.cancel_reason or "user_cancelled"
        local clean_reason = type(raw_reason) == "table" and (raw_reason.reason or raw_reason[1] or raw_reason.message or raw_reason.msg or tostring(raw_reason)) or raw_reason
        self.error = { type = "cancelled", reason = clean_reason }
        self:emit("cancel", clean_reason, self)
        self:emit("done", false, clean_reason, new_state, self)
    elseif new_state == Task.STATE.TIMEOUT then
        self.finished_at = socket.gettime()
        local clean_msg = "task_execution_timeout"
        self.error = { type = "timeout", message = clean_msg }
        self:emit("timeout", clean_msg, self)
        self:emit("done", false, clean_msg, new_state, self)
    end

    self:emit("state_change", new_state, prev_state, self)
end

local function create_task_context(task, stream, copas_mod)
    local ctx = {}
    local future_mod = copas_mod and require("Legado.vendor.copas.future")
    local lock_mod = copas_mod and require("Legado.vendor.copas.lock")
    local sema_mod = copas_mod and require("Legado.vendor.copas.semaphore")

    -- 进度汇报 (0.0 ~ 1.0)
    function ctx.progress(ratio, msg)
        if stream then
            stream:write(JSON.encode({ type = "__progress__", ratio = ratio, msg = msg }))
        else
            task:emit("progress", ratio, msg)
        end
    end
    ctx.report_progress = ctx.progress

    -- 增量事件推流
    function ctx.emit(data_or_type, maybe_data)
        local payload
        if maybe_data ~= nil then
            payload = { type = tostring(data_or_type), data = maybe_data }
        else
            payload = { type = "chunk", data = data_or_type }
        end
        if stream then
            stream:write(JSON.encode(payload))
        else
            if payload.type == "chunk" then
                task:emit("chunk", payload.data)
            else
                task:emit(payload.type, payload.data)
            end
        end
    end

    -- 智能休眠 (可被即时中断唤醒与协程调度)
    function ctx.sleep(sec)
        if copas_mod then
            local deadline = socket.gettime() + (sec or 0)
            while socket.gettime() < deadline do
                ctx.throw_if_cancelled()
                ctx.wait_if_paused()
                local remain = deadline - socket.gettime()
                if remain <= 0 then break end
                copas_mod.sleep(math.min(remain, 0.05))
            end
        elseif stream and stream.sleep then
            return stream:sleep(sec)
        else
            socket.sleep(sec or 0)
        end
    end

    -- 检查是否已被取消
    function ctx.is_cancelled()
        if stream and stream.is_cancelled then
            return stream:is_cancelled()
        end
        return task:is_cancelled()
    end
    ctx.cancelled = ctx.is_cancelled

    -- 校验取消并抛出结构化 Cancelled 异常
    function ctx.throw_if_cancelled()
        if stream and stream.throw_if_cancelled then
            stream:throw_if_cancelled()
        elseif ctx.is_cancelled() then
            error({ type = "cancelled", reason = task.cancel_reason or "user_cancelled" })
        end
    end

    -- 暂停与等待恢复
    function ctx.is_paused()
        if stream and stream.is_paused then
            return stream:is_paused()
        end
        return false
    end
    ctx.paused = ctx.is_paused

    function ctx.wait_if_paused()
        if stream and stream.wait_if_paused then
            stream:wait_if_paused()
        end
    end

    -- 双向交互会话：命令接收与路由
    function ctx.receive(to)
        if stream and stream.receive then
            local line = stream:receive("*l", to)
            if not line then return nil end
            local ok, data = pcall(JSON.decode, line)
            return ok and data or line
        end
        return nil
    end
    ctx.receive_command = ctx.receive

    function ctx.on_command(handlers)
        if not copas_mod then return end
        copas_mod.addthread(function()
            while not ctx.is_cancelled() and not (stream and stream._closed) do
                local cmd = ctx.receive(0.1)
                if cmd then
                    if type(handlers) == "function" then
                        pcall(handlers, cmd, ctx)
                    elseif type(handlers) == "table" and type(cmd) == "table" and cmd.action then
                        local h = handlers[cmd.action]
                        if type(h) == "function" then
                            pcall(h, cmd.data or cmd, ctx)
                        end
                    end
                end
                copas_mod.sleep(0.02)
            end
        end)
    end

    -- Copas 专属并发原语扩展
    if copas_mod then
        function ctx.map(items, arg2, arg3)
            if not items or #items == 0 then return {} end
            local worker_fn, concurrency
            if type(arg2) == "function" then
                worker_fn = arg2
                concurrency = tonumber(arg3) or 4
            else
                concurrency = tonumber(arg2) or 4
                worker_fn = arg3
            end
            concurrency = math.max(1, math.min(concurrency, #items))
            local cur_idx = 0
            local total = #items
            local finished_count = 0
            local results = {}

            for w = 1, concurrency do
                copas_mod.addthread(function()
                    while true do
                        cur_idx = cur_idx + 1
                        local idx = cur_idx
                        if idx > total then break end
                        local ok, res = pcall(worker_fn, items[idx], idx)
                        results[idx] = ok and res or nil
                    end
                    finished_count = finished_count + 1
                end)
            end
            while finished_count < concurrency do copas_mod.sleep(0.01) end
            return results
        end

        function ctx.async(fn, ...)
            local args = { ... }
            return future_mod.addthread(function()
                return fn(unpack(args))
            end)
        end

        function ctx.all(futures_map)
            local results = {}
            for k, f in pairs(futures_map) do
                local ok, res = f:get()
                results[k] = ok and res or nil
            end
            return results
        end

        function ctx.race(futures_map)
            local winner_k, winner_res
            while not winner_k do
                for k, f in pairs(futures_map) do
                    local status, res = f:try()
                    if status == true then
                        winner_k = k
                        winner_res = res
                        break
                    end
                end
                if not winner_k then copas_mod.sleep(0.01) end
            end
            for k, f in pairs(futures_map) do
                if k ~= winner_k then f:cancel() end
            end
            return winner_k, winner_res
        end

        function ctx.semaphore(max, start, timeout)
            local sema = sema_mod.new(max, start or max, timeout)
            local wrapper = {}
            function wrapper:acquire(fn)
                local ok_t, err_t = sema:take(1)
                if not ok_t then error("acquire semaphore failed: " .. tostring(err_t)) end
                local status, res = pcall(fn)
                sema:give(1)
                if not status then error(res) end
                return res
            end
            function wrapper:take(count, to) return sema:take(count or 1, to) end
            function wrapper:give(count) return sema:give(count or 1) end
            return wrapper
        end

        function ctx.new_lock(timeout) return lock_mod.new(timeout) end
        function ctx.with_lock(l, fn)
            local ok_l, err_l = l:get()
            if not ok_l then error("acquire lock failed: " .. tostring(err_l)) end
            local status, res = pcall(fn)
            l:release()
            if not status then error(res) end
            return res
        end
    end
    return ctx
end
return {
    Task = Task,
    create_task_context = create_task_context,
}
