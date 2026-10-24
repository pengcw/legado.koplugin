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
    obj.engine = opts.engine or "copas"
    obj.channel = opts.channel or "default"
    obj.priority = opts.priority or 0
    obj.timeout = opts.timeout or nil
    local retry = opts.retry
    local retry_opts = type(retry) == "table" and retry or nil
    obj.retry = {
        max = tonumber(retry_opts and retry_opts.max or retry) or 0,
        current = 0,
        delay = tonumber(retry_opts and retry_opts.delay) or 1.0,
        backoff = tonumber(retry_opts and retry_opts.backoff) or 1.5,
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
    obj.children_group = nil
    obj.parent_task = nil
    obj._finalized = false
    obj._slot_owned = false
    obj._slot_released = false
    obj._attempt_error = nil
    return obj
end

function Task:on(event, callback)
    if not event or type(callback) ~= "function" then return self end
    if event == "done" and self:is_done() then
        pcall(callback, self.state == Task.STATE.COMPLETED, self.result or self.error, self.state, self)
        return self
    end
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
    return self.engine_handle and self.engine_handle.is_paused and self.engine_handle:is_paused() or false
end

function Task:get_result()
    return self.result, self.error
end

function Task:get_children_group()
    if not self.children_group then
        local TaskGroup = require("Legado.task.v2.TaskGroup")
        self.children_group = TaskGroup:new(self)
    end
    return self.children_group
end

function Task:add_child(task)
    return self:get_children_group():add(task)
end

function Task:cancel(reason)
    if self:is_done() or self.state == Task.STATE.CANCELLING then return false end
    self.cancel_reason = reason or "user_cancelled"

    if self.state == Task.STATE.PENDING then
        if self.children_group then
            self.children_group:cancel(self.cancel_reason)
        end
        self:transition(Task.STATE.CANCELLED, nil, self.cancel_reason)
    else
        self:transition(Task.STATE.CANCELLING)
        if self.children_group then
            self.children_group:cancel(self.cancel_reason)
        end
        if self.engine_handle and self.engine_handle.cancel then
            self.engine_handle:cancel(self.cancel_reason)
        end
    end
    return true
end

function Task:fail(err)
    if self.retry.current < self.retry.max then
        self.retry.current = self.retry.current + 1
        self._attempt_error = err
        self:emit("attempt_error", err, self.retry.current, self.retry.max, self)
        return false
    end
    self:transition(Task.STATE.FAILED, nil, err)
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
    if self._finalized and new_state ~= Task.STATE.PENDING then return end
    if new_state == Task.STATE.CANCELLED and self.state == Task.STATE.RUNNING then
        self.state = Task.STATE.CANCELLING
        return
    end
    local prev_state = self.state
    self.state = new_state

    if new_state == Task.STATE.RUNNING then
        self.started_at = socket.gettime()
        self:emit("start", self)
    elseif new_state == Task.STATE.COMPLETED then
        self._finalized = true
        self.finished_at = socket.gettime()
        self.result = result
        self:emit("finish", result, self)
        self:emit("done", true, result, new_state, self)
    elseif new_state == Task.STATE.FAILED then
        self._finalized = true
        self.finished_at = socket.gettime()
        local raw_err = err or result
        local clean_err = type(raw_err) == "table" and (raw_err[1] or raw_err.reason or raw_err.message or raw_err.error or raw_err.errorMsg or raw_err.err or raw_err.msg or tostring(raw_err)) or raw_err
        self.error = clean_err
        self:emit("error", clean_err, self)
        self:emit("done", false, clean_err, new_state, self)
    elseif new_state == Task.STATE.CANCELLED then
        self._finalized = true
        self.finished_at = socket.gettime()
        local raw_reason = err or result or self.cancel_reason or "user_cancelled"
        local clean_reason = type(raw_reason) == "table" and (raw_reason.reason or raw_reason[1] or raw_reason.message or raw_reason.msg or tostring(raw_reason)) or raw_reason
        self.error = { type = "cancelled", reason = clean_reason }
        self:emit("cancel", clean_reason, self)
        self:emit("done", false, clean_reason, new_state, self)
    elseif new_state == Task.STATE.TIMEOUT then
        self._finalized = true
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

    function ctx.progress(ratio, msg)
        if stream then
            stream:write(JSON.encode({ type = "__progress__", ratio = ratio, msg = msg }))
        else
            task:emit("progress", ratio, msg)
        end
    end
    ctx.report_progress = ctx.progress

    local rate_request_seq = 0
    function ctx.acquire_rate_limit(key, rate)
        if not stream or not stream.take_rate_grant then return true end
        rate_request_seq = rate_request_seq + 1
        local request_id = string.format("%s:%d", tostring(task.id), rate_request_seq)
        ctx.throw_if_cancelled()
        ctx.wait_if_paused()
        local sent, send_err = stream:write(JSON.encode({
            type = "__v2_rate_acquire__",
            data = {
                request_id = request_id,
                key = key,
                rate = rate,
            },
        }))
        if not sent then error(send_err or "rate_acquire_send_failed") end

        while true do
            ctx.throw_if_cancelled()
            if stream:take_rate_grant(request_id) then
                ctx.throw_if_cancelled()
                ctx.wait_if_paused()
                return true
            end
            if copas_mod then
                copas_mod.sleep(0.02)
            else
                socket.sleep(0.02)
            end
        end
    end

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

    function ctx.is_cancelled()
        if stream and stream.is_cancelled then
            return stream:is_cancelled()
        end
        return task:is_cancelled()
    end
    ctx.cancelled = ctx.is_cancelled

    function ctx.throw_if_cancelled()
        if stream and stream.throw_if_cancelled then
            stream:throw_if_cancelled()
        elseif ctx.is_cancelled() then
            error({ type = "cancelled", reason = task.cancel_reason or "user_cancelled" })
        end
    end

    function ctx.is_paused()
        if stream and stream.is_paused then
            return stream:is_paused()
        end
        local handle = task.engine_handle
        return handle and handle.is_paused and handle:is_paused() or false
    end
    ctx.paused = ctx.is_paused

    function ctx.wait_if_paused()
        if stream and stream.wait_if_paused then
            stream:wait_if_paused()
            return
        end
        while ctx.is_paused() do
            ctx.throw_if_cancelled()
            if copas_mod then
                copas_mod.sleep(0.05)
            else
                socket.sleep(0.05)
            end
        end
    end

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

            for _ = 1, concurrency do
                local handle = copas_mod.addthread(function()
                    while true do
                        ctx.throw_if_cancelled()
                        ctx.wait_if_paused()
                        cur_idx = cur_idx + 1
                        local idx = cur_idx
                        if idx > total then break end
                        local ok, res = pcall(worker_fn, items[idx], idx)
                        results[idx] = ok and res or nil
                    end
                    finished_count = finished_count + 1
                end)

                if not stream then
                    task:get_children_group():add_handle({
                        cancel = function() copas_mod.removethread(handle) end,
                    })
                end
            end
            while finished_count < concurrency do
                ctx.throw_if_cancelled()
                copas_mod.sleep(0.01)
            end
            return results
        end

        function ctx.async(fn, ...)
            local args = { ... }
            local future = future_mod.addthread(function()
                return fn(unpack(args))
            end)

            return future
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
            if type(futures_map) ~= "table" or next(futures_map) == nil then
                return nil, "race_empty"
            end
            local pending = 0
            for _ in pairs(futures_map) do pending = pending + 1 end
            local failures = {}
            while pending > 0 do
                if ctx.is_cancelled() then return nil, "cancelled" end
                for k, f in pairs(futures_map) do
                    local status, res = f:try()
                    if status == true then
                        for other_k, other_f in pairs(futures_map) do
                            if other_k ~= k then other_f:cancel() end
                        end
                        return k, res
                    elseif status ~= future_mod.PENDING then
                        if failures[k] == nil then
                            failures[k] = res
                            pending = pending - 1
                        end
                    end
                end
                if pending > 0 then copas_mod.sleep(0.01) end
            end
            return nil, failures
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
