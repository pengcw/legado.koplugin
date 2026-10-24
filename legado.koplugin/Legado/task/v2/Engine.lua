local JSON = require("json")
local socket = require("socket")
local UIManager = require("ui/uimanager")
local TaskModule = require("Legado.task.v2.Task")
local ProcessStream = require("Legado.task.v2.ProcessStream")
local RateGate = require("Legado.task.v2.RateGate")
local Task = TaskModule.Task
local create_task_context = TaskModule.create_task_context

local Engines = {}

local copas_pump_running = false

local function ensure_copas_pump(copas)
    if copas_pump_running then return end
    copas_pump_running = true
    local function pump_copas()
        if copas.finished() then
            copas_pump_running = false
            return
        end
        copas.step(0)
        if not copas.finished() and UIManager and UIManager.scheduleIn then
            UIManager:scheduleIn(0.05, pump_copas)
        else
            copas_pump_running = false
        end
    end
    if UIManager and UIManager.nextTick then
        UIManager:nextTick(pump_copas)
    elseif UIManager and UIManager.scheduleIn then
        UIManager:scheduleIn(0, pump_copas)
    else
        copas_pump_running = false
    end
end

local CopasEngine = {}
CopasEngine.__index = CopasEngine

function CopasEngine.start(task)
    local ok_copas, copas = pcall(require, "Legado.vendor.copas")
    if not ok_copas or not copas then
        task:fail("copas_module_not_available")
        return nil
    end

    local paused = false
    local cancelled = false
    local cancel_reason = nil
    local timeout_fired = false

    local handle = {
        cancel = function(_, reason)
            if cancelled or task:is_done() then return end
            cancelled = true
            cancel_reason = reason or "user_cancelled"
            task.cancel_reason = cancel_reason
            task.state = Task.STATE.CANCELLING
        end,
        pause = function()
            paused = true
            return true
        end,
        resume = function()
            paused = false
            return true
        end,
        is_paused = function() return paused end,
        is_cancelled = function() return cancelled end,
    }
    task.engine_handle = handle
    task:transition(Task.STATE.RUNNING)
    copas.addthread(function()
        if task:is_done() then return end
        if cancelled then
            task:transition(Task.STATE.CANCELLED, nil, cancel_reason)
            return
        end

        local ctx = create_task_context(task, nil, copas)
        local timeout_timer
        if task.timeout and task.timeout > 0 and UIManager and UIManager.scheduleIn then
            timeout_timer = function()
                if not task:is_done() and not cancelled then
                    timeout_fired = true
                    handle:cancel("timeout")
                end
            end
            UIManager:scheduleIn(task.timeout, timeout_timer)
        end

        local job_rets = {}
        local ok, err_tb = xpcall(function()
            job_rets = { task.job(ctx) }
        end, function(e)
            if type(e) == "table" and not e.trace then
                e.trace = debug.traceback(tostring(e), 2)
            end
            return e
        end)

        if timeout_timer and UIManager and UIManager.unschedule then
            pcall(UIManager.unschedule, UIManager, timeout_timer)
        end

        if task:is_done() then return end

        if ok then
            local res = job_rets[1]
            local extra_err = job_rets[2]
            if cancelled then
                if timeout_fired then
                    task:transition(Task.STATE.TIMEOUT)
                else
                    task:transition(Task.STATE.CANCELLED, nil, cancel_reason)
                end
            elseif res == false and extra_err ~= nil then
                task:fail(extra_err)
            else
                task:transition(Task.STATE.COMPLETED, res)
            end
        else
            local res = err_tb
            local is_cancelled = (type(res) == "table" and res.type == "cancelled")
                or tostring(res):find('"type":"cancelled"')
                or tostring(res):find("type = \"cancelled\"")
                or cancelled

            if is_cancelled then
                if timeout_fired then
                    task:transition(Task.STATE.TIMEOUT)
                else
                    task:transition(Task.STATE.CANCELLED, nil, cancel_reason)
                end
            else
                task:fail(res)
            end
        end
    end)

    ensure_copas_pump(copas)

    return handle
end

local ProcessEngine = {}
ProcessEngine.__index = ProcessEngine

function ProcessEngine.start(task)
    task:transition(Task.STATE.RUNNING)

    local return_result = nil
    local handle
    local pending_rate_grants = {}

    local function send_rate_grant(request_id)
        local function send()
            if task:is_done() then return end
            if not handle then
                pending_rate_grants[#pending_rate_grants + 1] = request_id
                return
            end
            handle:send(JSON.encode({
                type = "control",
                action = "rate_grant",
                request_id = request_id,
            }))
        end
        if UIManager and UIManager.nextTick then
            UIManager:nextTick(send)
        else
            send()
        end
    end

    local stream_opts = {
        timeout = task.timeout,
        on_decode = function(line)
            local ok, data = pcall(JSON.decode, line)
            return ok and data or nil
        end,
        on_chunk = function(frame)
            if not (frame and type(frame) == "table") then return end
            if frame.type == "__progress__" then
                task:emit("progress", frame.ratio, frame.msg)
            elseif frame.type == "__return__" then
                return_result = frame.data
            elseif frame.type == "__v2_rate_acquire__" then
                local data = frame.data or {}
                RateGate:acquire(data.key, data.rate, data.request_id, function()
                    send_rate_grant(data.request_id)
                end, function()
                    return task:is_done() or task:is_cancelled()
                end)
            elseif frame.type == "chunk" then
                task:emit("chunk", frame.data)
            else
                task:emit(frame.type, frame.data)
            end
        end,
        on_finish = function(ok, err)
            RateGate:cancel_task(task.id)
            if task:is_done() then return end
            if ok then
                task:transition(Task.STATE.COMPLETED, return_result)
            else
                if err == "timeout" then
                    task:transition(Task.STATE.TIMEOUT)
                elseif err == "已取消" or (type(err) == "string" and err:find("cancel")) then
                    task:transition(Task.STATE.CANCELLED, nil, err)
                else
                    task:fail(err)
                end
            end
        end,
    }

    handle = ProcessStream.spawnProcessStream(function(...)
        local stream = select(3, ...)
        local copas = require("Legado.vendor.copas")
        copas.running = true
        local ctx = create_task_context(task, stream, copas)
        local return_value = nil
        local job_error = nil
        local job_finished = false

        copas.addthread(function()
            local deadline = (task.timeout and task.timeout > 0) and (socket.gettime() + task.timeout) or nil
            local sleep_interval = 0.1

            while not job_finished and not stream._closed do
                stream:poll_control()
                if stream:is_cancelled() then break end

                local now = socket.gettime()
                if deadline then
                    if now >= deadline then
                        stream:cancel("timeout")
                        break
                    elseif (deadline - now) < 1.0 then
                        sleep_interval = 0.03
                    end
                end

                copas.sleep(sleep_interval)
            end
        end)

        copas.addthread(function()
            local job_rets = {}
            local ok, err_tb = xpcall(function()
                job_rets = { task.job(ctx) }
            end, function(e)
                if type(e) == "table" and not e.trace then
                    e.trace = debug.traceback(tostring(e), 2)
                end
                return e
            end)

            job_finished = true

            if ok then
                local res = job_rets[1]
                local extra_err = job_rets[2]
                if res == false and extra_err ~= nil then
                    job_error = extra_err
                else
                    return_value = res
                end
            else
                local is_cancelled = (type(err_tb) == "table" and err_tb.type == "cancelled")
                    or (stream and stream.is_cancelled and stream:is_cancelled())
                if not is_cancelled then
                    job_error = err_tb
                end
            end
        end)

        while not job_finished do copas.step(0.02) end

        if job_error then error(job_error) end

        if return_value ~= nil then
            stream:write(JSON.encode({ type = "__return__", data = return_value }))
        end
    end, stream_opts)

    task.engine_handle = handle
    for _, request_id in ipairs(pending_rate_grants) do
        send_rate_grant(request_id)
    end
    pending_rate_grants = {}
    return handle
end

Engines.copas = CopasEngine
Engines.main = CopasEngine
Engines.process = ProcessEngine

function Engines.get(name)
    if name == nil or name == "main" or name == "copas" then
        return CopasEngine
    elseif name == "process" then
        return ProcessEngine
    end
    return nil, "unknown_engine:" .. tostring(name)
end

return Engines
