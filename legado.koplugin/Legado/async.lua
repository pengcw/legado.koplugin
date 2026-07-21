-- =================================================================================
-- Async Task Lib by v0.1
-- =================================================================================
local UIManager = require("ui/uimanager")
local coroutine = require("coroutine")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local buffer = require("string.buffer")
local socket = require("socket") 

local  M = { cache = {}, channels = {} }

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

function Channel:new(name, max_workers, shared_cache, on_finish, start_paused)
    local obj = setmetatable({}, self)
    obj.name = name
    obj.max_workers = max_workers or 1
    obj.active_workers = 0
    obj.session = 0
    obj.queue = {}
    obj.cache = shared_cache
    obj.session_abort_hooks = {}
    obj.on_finish = on_finish
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
    local cache_key = opts.cache_key

    if cache_key and self.cache[cache_key] then
        UIManager:nextTick(function()
            safe_call("on_start (cache)", opts.on_start, 0)
            safe_call("callback (cache)", callback, true, self.cache[cache_key], 0)
        end)
        return
    end

    local task_node = {
        func = task_func,
        args = opts.args,
        args_generator = opts.args_generator,
        callback = callback,
        on_start = opts.on_start,
        cache_key = cache_key,
        session = self.session,
        max_retries = opts.max_retries or 0,
        current_retry = 0,
        timeout = opts.timeout or 180,
        returns_string = opts.returns_string,
        delay = opts.delay,
        run_in_main = opts.run_in_main
    }

    if opts.insert_at_head then
        table.insert(self.queue, 1, task_node)
    else
        table.insert(self.queue, task_node)
    end

    if self.active_workers < self.max_workers then
        self:_processNext()
    end
end

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

    if task.delay and type(task.delay) == "number" and task.delay > 0 then
        self.cooldown_until = socket.gettime() + task.delay
    end

    local actual_args = task.args
    if type(task.args_generator) == "function" then
        local gen_ok, gen_args = safe_call("args_generator", task.args_generator, task.current_retry)
        if gen_ok then actual_args = gen_args else actual_args = nil end
    end

    local execute_func
    if actual_args and type(actual_args) == "table" then
        execute_func = function() return task.func(unpack(actual_args)) end
    else
        execute_func = task.func
    end

    safe_call("on_start", task.on_start, task.current_retry)
    if self.active_workers == 1 then pcall(function() Device:enableCPUCores(2) end) end
    logger.dbg("Channel:_processNext - START", self.name)

    local start_time = os.time()
    local pid, parent_read_fd = nil, nil
    local poll_count = 0

    local function deliver_result(ok, r1, r2)
        if parent_read_fd then
            pcall(ffiUtil.readAllFromFD, parent_read_fd)
            parent_read_fd = nil
        end
        
        local completed, result = ok, r1

        if task.session == self.session then
            local success = (completed and result ~= nil and actual_args ~= nil)

            if not success and task.current_retry < task.max_retries then
                task.current_retry = task.current_retry + 1
                table.insert(self.queue, 1, task) 
            else
                if success and task.cache_key then self.cache[task.cache_key] = result end
                safe_call("callback", task.callback, success, result, task.current_retry)
            end
        end

        self.active_workers = self.active_workers - 1
        
        if #self.queue == 0 and self.active_workers == 0 then
            UIManager:scheduleIn(2.0, function()
                local is_busy = M:hasAnyTasks()
                if not is_busy then
                    logger.dbg("TaskFlow: All channels idle, smoothly downgrading CPU to 1 core.")
                    pcall(function() Device:enableCPUCores(1) end)
                end
            end)
            UIManager:nextTick(function()
                if #self.queue == 0 and self.active_workers == 0 then
                    safe_call("on_finish", self.on_finish, false)
                end
            end)
        else
            UIManager:nextTick(function() self:_processNext() end)
        end
    end

    if task.run_in_main then
        logger.dbg("Channel:_processNext - Bypass to MAIN thread")
        local job_ok, r1, r2 = safe_call("run_in_main", execute_func)
        UIManager:nextTick(function() deliver_result(job_ok, r1, r2) end)
        return 
    end

    pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd)
        local job_ok, r1, r2 = pcall(execute_func)
        local ret_tbl = { ok = job_ok, r1 = r1, r2 = r2 }
        
        local output_str = ""
        local enc_ok, str = pcall(buffer.encode, ret_tbl)
        if enc_ok and str then
            output_str = str
        else
            ret_tbl = { ok = false, r1 = "serialization_error", r2 = tostring(str)}
            output_str = buffer.encode(ret_tbl) or ""
        end
        ffiUtil.writeToFD(child_write_fd, output_str, true)
    end, true)

    if not pid then
        deliver_result(false, "start_failed")
        return
    end

    local function poll()
        poll_count = poll_count + 1
        
        if task.timeout and os.difftime(os.time(), start_time) >= task.timeout then
            ffiUtil.terminateSubProcess(pid)
            -- delay until process exits
            UIManager:scheduleIn(0.5, function() deliver_result(false, "timeout") end)
            return
        end
        local subprocess_done = ffiUtil.isSubProcessDone(pid)
        if subprocess_done then
            local ok, r1, r2 = false, nil, nil
            if parent_read_fd then
                local ret_str = ffiUtil.readAllFromFD(parent_read_fd) or ""
                if ret_str ~= "" then
                    local dec_ok, ret_tbl = pcall(buffer.decode, ret_str)
                    if dec_ok and type(ret_tbl) == "table" then
                        ok, r1, r2 = ret_tbl.ok, ret_tbl.r1, ret_tbl.r2
                    else
                        logger.warn(string.format("Channel:_processNext - malformed data (len: %d)", #ret_str))
                        ok, r1, r2 = false, "decode_error", nil
                    end
                else
                    ok, r1, r2 = false, "empty_pipe_error", nil
                end
                parent_read_fd = nil
            end
            logger.dbg("Channel:_processNext - background task completed")
            deliver_result(ok, r1, r2)
        else
            local next_delay = (poll_count <= 5) and 0.02 or 0.2
            UIManager:scheduleIn(next_delay, poll)
        end
    end
    poll()
end

function Channel:clearTasks()
    local had_tasks = (#self.queue > 0 or self.active_workers > 0)
    self.queue = {}
    self.session = self.session + 1
    self.cooldown_until = 0 
    
    local hooks = self.session_abort_hooks
    self.session_abort_hooks = {} 
    for _, hook in pairs(hooks) do safe_call("session_abort_hook", hook) end
    
    if had_tasks and self.on_finish then
        safe_call("on_finish (abort)", self.on_finish, true)
    end
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
    -- 必须显式传入 aggregate=true 才会聚合结果，否则丢弃释放内存
    local results_map = (aggregate == true) and {} or nil 
    local batch_id = tostring({}) 
    
    self.session_abort_hooks[batch_id] = function()
        if not is_aborted then
            is_aborted = true
            if on_batch_end then safe_call("end", on_batch_end, true, results_map) end
        end
    end

    for i, item in ipairs(items) do
        local wrap_start = on_start and function(retry) on_start(i, item, retry) end or nil
        local args_gen = get_task_args and function(retry) return get_task_args(item, retry) end or nil
        
        local wrap_end = function(success, result, retries_used)
            if is_aborted then return end 

            completed_count = completed_count + 1
            if results_map then results_map[i] = { success = success, result = result } end
            
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

        local item_cache_key = type(params.get_cache_key) == "function" and params.get_cache_key(item) or nil

        self:pushTask(task_func, wrap_end, {
            args = (not args_gen) and {item} or nil, 
            args_generator = args_gen,
            on_start = wrap_start,
            max_retries = params.max_retries,
            timeout = params.timeout,
            returns_string = params.returns_string,
            insert_at_head = params.insert_at_head,
            cache_key = item_cache_key,
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
    local tree_id = tostring({}) 

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
            cache_key = task.cache_key,
            insert_at_head = task.insert_at_head,
            delay = task.delay,
            run_in_main = task.run_in_main 
        })
    end

    for _, start_id in ipairs(ready_queue) do schedule_node(start_id) end
end

function M:createChannel(name, max_workers, on_finish, start_paused)
    if not self.channels[name] then
        self.channels[name] = Channel:new(name, max_workers, self.cache, on_finish, start_paused)
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

function M:clearCache() self.cache = {} end

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

function M.delay(seconds, func)
    local pending = true
    UIManager:scheduleIn(seconds, function()
        pending = false
        func()
    end)
    return function()
        if pending then
            pending = false
            UIManager:unschedule(func)
        end
    end
end

return M