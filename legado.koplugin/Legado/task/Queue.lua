-- =================================================================================
-- Async Task Lib by v0.11
-- =================================================================================
local UIManager = require("ui/uimanager")
local coroutine = require("coroutine")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local buffer = require("string.buffer")
local socket = require("socket") 
local Device = require("device")

local M = { channels = {} }

local function safe_call(tag, func, ...)
    if type(func) ~= "function" then return true, nil end
    local ok, res, res2 = pcall(func, ...)
    if not ok then
        logger.err(string.format("[M Panic] %s: %s", tag, tostring(res)))
    end
    return ok, res, res2
end

local Channel = {}
Channel.__index = Channel

function Channel:new(name, max_workers, on_finish, start_paused)
    local obj = setmetatable({}, self)
    obj.name = name
    obj.max_workers = max_workers or 1
    obj.active_workers = 0
    obj.session = 0
    obj.queue = {}
    obj.running_tasks = {}
    obj._task_counter = 0
    obj.session_abort_hooks = {}
    obj.on_finish = on_finish
    obj.did_abort_current_drain = false
    obj.cooldown_until = 0                 
    obj._cooldown_timer_scheduled = false
    obj.is_paused = start_paused or false
    return obj
end

function Channel:hasTasks()
    local queued = #self.queue
    local active = self.active_workers
    if self.is_paused then return (active > 0), queued, active end
    local is_busy = (queued > 0 or active > 0)
    return is_busy, queued, active
end

function Channel:pushTask(task_func, callback, opts)
    opts = opts or {}

    self._task_counter = self._task_counter + 1
    local task_node = {
        id = self._task_counter,
        trace_id = opts.trace_id,
        status = "pending",
        pid = nil,
        start_time = nil,
        func = task_func,
        args = opts.args,
        args_generator = opts.args_generator,
        callback = callback,
        on_start = opts.on_start,
        session = self.session,
        max_retries = opts.max_retries or 0,
        current_retry = 0,
        timeout = opts.timeout or 180,
        returns_string = opts.returns_string,
        delay = opts.delay,
        run_in_main = opts.run_in_main
    }
    
    self.did_abort_current_drain = false

    if opts.insert_at_head then
        table.insert(self.queue, 1, task_node)
    else
        table.insert(self.queue, task_node)
    end

    if self.active_workers < self.max_workers then
        self:_processNext()
    end
end

-- NetworkMgr:isConnected() not Work in task
function Channel:_processNext()
    if #self.queue == 0 then return end
    if self.is_paused then return end
    local now = socket.gettime()
    
    if self.cooldown_until > now then
        if not self._cooldown_timer_scheduled then
            self._cooldown_timer_scheduled = true
            local wait_time = self.cooldown_until - now
            UIManager:scheduleIn(wait_time, function()
                self._cooldown_timer_scheduled = false
                self:_processNext() 
            end)
        end
        return 
    end

    self.active_workers = self.active_workers + 1
    local task = table.remove(self.queue, 1)

    self.running_tasks[task.id] = task
    task.status = "running"
    task.start_time = socket.gettime()

    if task.delay and type(task.delay) == "number" and task.delay > 0 then
        self.cooldown_until = socket.gettime() + task.delay
    end

    local actual_args = task.args
    if type(task.args_generator) == "function" then
        local gen_ok, gen_args = safe_call("args_generator", task.args_generator, task.current_retry)
        actual_args = (gen_ok and gen_args ~= nil) and gen_args or nil
        if not actual_args then
            logger.err("Channel: Args generation failed, aborting task", self.name)
            safe_call("callback", task.callback, false, "Arguments generation failed", task.current_retry)
            UIManager:nextTick(function() self:_processNext() end)
            return
        end
    end

     actual_args = actual_args or {} 
    local execute_func
    if actual_args and type(actual_args) == "table" then
        local unpack_func = table.unpack or unpack
        execute_func = function() return task.func(unpack_func(actual_args)) end
    else
        execute_func = task.func
    end

    if task.max_retries == 0 or task.args_generator then
        task.args = nil 
    end

    if task.on_start then
        safe_call("on_start", task.on_start, task.current_retry)
        task.on_start = nil 
    end
    if self.active_workers == 1 then M.requestHighCPU() end
    logger.dbg("Channel:_processNext - START", self.name)

    local function finish_callback(ok, r1, r2)
        logger.dbg("Channel:_processNext - END", self.name)
        self.running_tasks[task.id] = nil
        
        if task.delay and type(task.delay) == "number" and task.delay > 0 then
            self.cooldown_until = socket.gettime() + task.delay
        end
        
        if task.session == self.session then
            local success = false
            local final_result = nil
            local final_error = nil
            
            if not ok then
                 success = false
                final_error = tostring(r1)
            elseif r1 == false then
               success = false
                final_error = r2 or "Task soft-failed without error message"
            else
                success = (actual_args ~= nil) 
                final_result = r1
                if not success then final_error = "Arguments generation failed" end
            end

            if success then
                safe_call("callback", task.callback, true, final_result, task.current_retry)
            else
                if task.current_retry < task.max_retries then
                     task.current_retry = task.current_retry + 1
                     task.status = "pending"
                     task.pid = nil
                    table.insert(self.queue, 1, task)
                    logger.warn(string.format("Channel '%s': Task failed, retrying... (%d/%d)", self.name, task.current_retry, task.max_retries))
                else
                    logger.err("Channel: Task failure or returned nil:", self.name)
                    safe_call("callback", task.callback, false, final_error, task.current_retry)
                end
            end
        else
            logger.dbg("Channel: Dropped stale task for:", self.name)
        end

        self.active_workers = self.active_workers - 1
        if #self.queue == 0 and self.active_workers == 0 then
            M.releaseHighCPU()
            if not self.did_abort_current_drain then
                UIManager:nextTick(function()
                    if #self.queue == 0 and self.active_workers == 0 and not self.did_abort_current_drain then
                        logger.dbg("Channel: Naturally drained:", self.name)
                        safe_call("on_finish (drain)", self.on_finish, false)
                    end
                end)
            end
        else
            UIManager:nextTick(function() self:_processNext() end)
        end
    end

    if task.run_in_main then
        logger.dbg("Channel:_processNext - Bypass to MAIN thread")
        task.pid = "main"
        local job_ok, r1, r2 = safe_call("run_in_main", execute_func)
        UIManager:nextTick(function() finish_callback(job_ok, r1, r2) end)
        return 
    end

    local timeout = task.timeout or 1200
    local pid = M.spawnProcess(execute_func, finish_callback, timeout, task.returns_string)
    task.pid = pid
end

function Channel:clearTasks()
    local had_tasks = (#self.queue > 0 or self.active_workers > 0)
    self.queue = {}
    self.session = self.session + 1
    self.cooldown_until = 0 
    
    local hooks = self.session_abort_hooks
    self.session_abort_hooks = {} 
    for _, hook in pairs(hooks) do safe_call("session_abort_hook", hook) end
    
    self.did_abort_current_drain = true
    if had_tasks and self.on_finish then
        logger.warn("Channel: Forcefully aborted:", self.name)
        safe_call("on_finish (abort)", self.on_finish, true)
    end
    logger.dbg("Channel: Tasks cleared. New session for:", self.name)
end

function Channel:pause()
    if self.is_paused then return end
    self.is_paused = true
    logger.dbg("TaskFlow Channel Paused:", self.name)
end

function Channel:resume()
    if not self.is_paused then return end
    self.is_paused = false
    logger.dbg("TaskFlow Channel Resumed:", self.name)
    self:_processNext()
end

function Channel:executeBatch(params)
    params = params or {}
    local items = params.items or {}
    local task_func = params.task_func
    local get_task_args = params.get_task_args
    local on_start = params.on_start
    local on_progress = params.on_progress
    local on_item_end = params.on_item_end
    local on_batch_end = params.on_batch_end
    local aggregate = params.aggregate or false

    
    if not task_func then return end
    self:clearTasks()
    
    local total_count = #items
    if total_count == 0 then
        if on_batch_end then safe_call("end", on_batch_end, false, {}) end
        return
    end

    local completed_count = 0
    local is_aborted = false
    local results_map = (aggregate == true) and {} or nil 
    self.batch_counter = (self.batch_counter or 0) + 1
    local batch_id = "batch_" .. self.batch_counter 
    
    self.session_abort_hooks[batch_id] = function()
        if not is_aborted then
            is_aborted = true
            logger.warn(string.format("Channel '%s': Batch externally aborted!", self.name))
            if on_batch_end then safe_call("end", on_batch_end, true, results_map) end
        end
    end

    for i, item in ipairs(items) do
        local wrap_start = on_start and function(retry) on_start(i, item, retry) end or nil
        local args_gen = get_task_args and function(retry) return get_task_args(item, retry) end or nil
        
        local wrap_end = function(success, result, retries_used)
            if is_aborted then return end 

            completed_count = completed_count + 1
            if results_map then results_map[i] = { success = success, result = result, retries_used = retries_used } end
            
            local should_abort = false
            if on_item_end then
                -- if on_item_end crashes, return nil here, convert to false without blocking subsequent tasks
                local ok, req_abort = safe_call("on_item_end", on_item_end, i, item, success, result, retries_used)
                should_abort = (ok and req_abort == true)
            end

            if on_progress then safe_call("prog", on_progress, completed_count, total_count, i, item, success) end

            if should_abort or completed_count == total_count then
                is_aborted = true
                self.session_abort_hooks[batch_id] = nil
                
                if should_abort then self:clearTasks() end
                if on_batch_end then safe_call("end", on_batch_end, should_abort, results_map) end
            end
        end

        self:pushTask(task_func, wrap_end, {
            args = (not args_gen) and {item} or nil, 
            args_generator = args_gen,
            on_start = wrap_start,
            max_retries = params.max_retries,
            timeout = params.timeout,
            returns_string = params.returns_string,
            insert_at_head = params.insert_at_head,
            delay = params.delay,
            run_in_main = params.run_in_main
        })
    end
end

function Channel:executeTree(params)
    params = params or {}
    local tasks = params.tasks or {}
    local total_tasks = #tasks
    if total_tasks == 0 then
        if params.on_tree_end then safe_call("end", params.on_tree_end, false, {}) end
        return
    end

    self:clearTasks()
    local in_degree, adj_list, task_map, tree_results = {}, {}, {}, {}
    local completed_count = 0
    local is_aborted = false
    self.tree_counter = (self.tree_counter or 0) + 1
    local tree_id = "tree_" .. self.tree_counter 

    for _, task in ipairs(tasks) do
        task_map[task.id] = task
        in_degree[task.id] = 0
        adj_list[task.id] = {}
    end

    for _, task in ipairs(tasks) do
        local deps = task.depends_on or {}
        for _, dep_id in ipairs(deps) do
            in_degree[task.id] = in_degree[task.id] + 1
            table.insert(adj_list[dep_id], task.id)
        end
    end

    local ready_queue = {}
    for id, degree in pairs(in_degree) do
        if degree == 0 then table.insert(ready_queue, id) end
    end

    if #ready_queue == 0 and total_tasks > 0 then
        logger.err("Tree aborted! Cyclic dependencies.")
        if params.on_tree_end then safe_call("end", params.on_tree_end, false, {}) end
        return
    end

    self.session_abort_hooks[tree_id] = function()
        if not is_aborted then
            is_aborted = true
            logger.warn(string.format("Channel '%s': Tree externally aborted!", self.name))
            if params.on_tree_end then safe_call("end", params.on_tree_end, false, tree_results) end
        end
    end

    local function schedule_node(task_id)
        if is_aborted then return end
        local task = task_map[task_id]

        local args_gen = nil
        if type(task.get_task_args) == "function" then
            args_gen = function(retry) return task.get_task_args(tree_results, retry) end
        end

        local wrap_end = function(success, result)
            if is_aborted then return end
            if params.on_task_end then safe_call("task_end", params.on_task_end, task_id, success, result) end

            if not success then
                is_aborted = true
                self.session_abort_hooks[tree_id] = nil
                self:clearTasks()
                if params.on_tree_end then safe_call("end", params.on_tree_end, false, tree_results) end
                return
            end

            tree_results[task_id] = result
            completed_count = completed_count + 1

            if completed_count == total_tasks then
                is_aborted = true
                self.session_abort_hooks[tree_id] = nil
                if params.on_tree_end then safe_call("end", params.on_tree_end, true, tree_results) end
            else
                for _, dep_id in ipairs(adj_list[task_id]) do
                    in_degree[dep_id] = in_degree[dep_id] - 1
                    if in_degree[dep_id] == 0 then schedule_node(dep_id) end
                end
            end
        end

        self:pushTask(task.func, wrap_end, {
            args = (not args_gen) and task.args or nil,
            args_generator = args_gen,
            on_start = task.on_start,
            max_retries = task.max_retries,
            timeout = task.timeout,
            returns_string = task.returns_string,
            insert_at_head = task.insert_at_head,
            delay = task.delay,
            run_in_main = task.run_in_main 
        })
    end

    for _, start_id in ipairs(ready_queue) do schedule_node(start_id) end
end

function M:createChannel(name, max_workers, on_finish, start_paused)
    if not self.channels[name] then
        self.channels[name] = Channel:new(name, max_workers, on_finish, start_paused)
    end
    return self.channels[name]
end

function M:getChannel(name) return self.channels[name] or self:createChannel(name, 1) end

function M:destroyChannel(name)
    local ch = self.channels[name]
    if ch then 
        ch:clearTasks()
        self.channels[name] = nil 
    end
end

function M:destroyAll()
    for _, ch in pairs(self.channels) do if ch.name then self:destroyChannel(ch.name) end end
end

function Channel:getStatus()
    local pending = {}
    for _, t in ipairs(self.queue) do
        table.insert(pending, { id = t.id, trace_id = t.trace_id, retry = t.current_retry })
    end
    
    local running = {}
    for id, t in pairs(self.running_tasks) do
        table.insert(running, {
            id = id,
            trace_id = t.trace_id,
            pid = t.pid,
            retry = t.current_retry,
            is_orphaned = (t.session ~= self.session),
            elapsed = socket.gettime() - (t.start_time or socket.gettime())
        })
    end
    
    return {
        name = self.name,
        active_workers = self.active_workers,
        max_workers = self.max_workers,
        pending = pending,
        running = running,
        is_paused = self.is_paused
    }
end

function M:getEngineStatus()
    local report = {}
    for name, ch in pairs(self.channels) do
        report[name] = ch:getStatus()
    end
    return report
end

function M:hasAnyTasks()
    local total_queued = 0
    local total_active = 0
    for _, ch in pairs(self.channels) do
        if not ch.is_paused then total_queued = total_queued + #ch.queue end
        total_active = total_active + ch.active_workers
    end
    local is_busy = (total_queued > 0 or total_active > 0)
    return is_busy, total_queued, total_active
end

function M.requestHighCPU()
    pcall(function() Device:enableCPUCores(2) end)
end

function M.releaseHighCPU()
    if M._cpu_downgrade_timer_cancel then
        M._cpu_downgrade_timer_cancel()
        M._cpu_downgrade_timer_cancel = nil
    end
    M._cpu_downgrade_timer_cancel = M.delay(3.0, function()
        local is_busy = M:hasAnyTasks()
        if not is_busy and (M._active_processes or 0) <= 0 then
            pcall(function() Device:enableCPUCores(1) end)
        end
        M._cpu_downgrade_timer_cancel = nil
    end)
end

function M.spawnProcess(job, callback, timeout, returns_simple_string)
    M._active_processes = (M._active_processes or 0) + 1
    if M._active_processes == 1 then M.requestHighCPU() end

    local start_time = socket.gettime()
    local pid, parent_read_fd = nil, nil
    local poll_count = 0
    local check_interval_sec = 0.125

    local function deliver_result(ok, r1, r2)
        if parent_read_fd then
            pcall(ffiUtil.readAllFromFD, parent_read_fd)
            parent_read_fd = nil
        end
        
        M._active_processes = M._active_processes - 1
        if M._active_processes <= 0 then
            M._active_processes = 0
            M.releaseHighCPU()
        end

        if type(callback) == "function" then
            callback(ok, r1, r2)
        end
    end
    
    pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd)
        local job_ok, r1, r2 = pcall(job)
        local output_str = nil
        local need_pack = not returns_simple_string
        if returns_simple_string then
            if job_ok and type(r1) == "string" then
                output_str = "\x01" .. r1
                need_pack = false
            else
                need_pack = true 
                if not job_ok then
                    logger.warn("spawnProcess - execute_func crashed:", r1)
                else
                    logger.warn("spawnProcess - returned value from task_func is not a string")
                    r1 = "returned value from task_func is not a string"
                    job_ok = false
                end
            end
        end
        if need_pack then
            local ret_tbl = { ok = job_ok, r1 = r1, r2 = r2 }
            local enc_ok, str = pcall(buffer.encode, ret_tbl)
            if enc_ok and str then
                output_str = str
            else
                logger.warn("spawnProcess - serialization failed:", str or "unknown error")
                ret_tbl = { ok = false, r1 = "serialization_error", r2 = tostring(str) }
                output_str = buffer.encode(ret_tbl) or ""
            end
            if returns_simple_string then
                output_str = "\x02" .. output_str
            end 
        end
        ffiUtil.writeToFD(child_write_fd, output_str or "", true)
    end, true)

    if not pid then
        logger.warn("spawnProcess - background task failed to start")
        deliver_result(false, "start_failed")
        return nil
    end

    local function poll()
        poll_count = poll_count + 1
        
        local function safe_collect_and_clean(target_pid, fd_to_close, max_retries, retry_interval, debug_tag)
            local retry_count = 0
            local function cleaner_step()
                retry_count = retry_count + 1
                if ffiUtil.isSubProcessDone(target_pid) then
                   if fd_to_close then pcall(ffiUtil.readAllFromFD, fd_to_close) end
                    logger.dbg(string.format("spawnProcess - %s collected successfully.", debug_tag))
                elseif retry_count >= max_retries then
                    logger.warn(string.format("spawnProcess - %s failed to collect PID %d after %d retries. Forcibly terminating!", debug_tag, target_pid, max_retries))
                    ffiUtil.terminateSubProcess(target_pid)
                    UIManager:scheduleIn(1, function()
                        if ffiUtil.isSubProcessDone(target_pid) then
                            logger.warn("spawnProcess - cleaner_step max_retries, force killed and exited", target_pid)
                            if fd_to_close then pcall(ffiUtil.readAllFromFD, fd_to_close) end
                        end
                    end)
                else
                    if fd_to_close and ffiUtil.getNonBlockingReadSize(fd_to_close) ~= 0 then
                        pcall(ffiUtil.readAllFromFD, fd_to_close)
                        fd_to_close = nil 
                    end
                    UIManager:scheduleIn(retry_interval, cleaner_step)
                end
            end
            cleaner_step()
        end

        local duration_seconds = socket.gettime() - start_time
        if timeout and duration_seconds >= timeout then
            logger.warn("spawnProcess - timeout reached, killing subprocess", pid, duration_seconds)
            ffiUtil.terminateSubProcess(pid)
            safe_collect_and_clean(pid, parent_read_fd, 5, 3, "timed-out subprocess")
            parent_read_fd = nil
            deliver_result(false, "timeout")
            return
        end

        local subprocess_done = ffiUtil.isSubProcessDone(pid)
        local stuff_to_read = parent_read_fd and ffiUtil.getNonBlockingReadSize(parent_read_fd) ~= 0
        if subprocess_done or stuff_to_read then
            -- Subprocess is gone or nearly gone
            local ok, r1, r2 = false, nil, nil
            if parent_read_fd then
                local ret_str = ffiUtil.readAllFromFD(parent_read_fd) or ""
                parent_read_fd = nil
                if ret_str ~= "" or (ret_str == "" and returns_simple_string) then
                    if returns_simple_string then
                        local wire_flag = ret_str:sub(1, 1)
                        if wire_flag == "\x01" then
                            ok, r1, r2 = true, ret_str:sub(2), nil
                        elseif wire_flag == "\x02" then
                            local dec_ok, ret_tbl = pcall(buffer.decode, ret_str:sub(2))
                            if dec_ok and type(ret_tbl) == "table" then
                                ok, r1, r2 = ret_tbl.ok, ret_tbl.r1, ret_tbl.r2
                            else
                                logger.warn("spawnProcess - malformed serialized data")
                                ok, r1, r2 = false, "decode_error", nil
                            end
                        else
                            logger.warn("spawnProcess - malformed serialized data")
                            ok, r1, r2 = false, "decode_error", nil
                        end
                    else
                        local dec_ok, ret_tbl = pcall(buffer.decode, ret_str)
                        if dec_ok and type(ret_tbl) == "table" then
                            ok, r1, r2 = ret_tbl.ok, ret_tbl.r1, ret_tbl.r2
                        else
                            logger.warn("spawnProcess - malformed serialized data")
                            ok, r1, r2 = false, "decode_error", nil
                        end
                    end
                else
                    ok, r1, r2 = false, "empty_pipe_error", nil
                end
            end
            
            if not subprocess_done then
                safe_collect_and_clean(pid, parent_read_fd, 3, 1, "pre-read subprocess")
            end
            
            deliver_result(ok, r1, r2)
        else
            if check_interval_sec < 1 and poll_count % 10 == 0 then
                check_interval_sec = math.min(check_interval_sec * 2, 1)
            end
            UIManager:scheduleIn(check_interval_sec, poll)
        end
    end
    poll()
    return pid
end

function M.delay(seconds, func)
    local pending = true
    local wrapped_func = function()
        if pending then
            pending = false
            func()
        end
    end
    UIManager:scheduleIn(seconds, wrapped_func)
    return function()
        if pending then
            pending = false
            UIManager:unschedule(wrapped_func)
        end
    end
end

return M