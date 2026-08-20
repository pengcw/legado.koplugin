local UIManager = require("ui/uimanager")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local socket = require("socket")
local Device = require("device")
local IpcMQ

local M = {}

local active_processes = 0
local cpu_downgrade_timer_cancel = nil

local function delay(seconds, func)
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

local function requestHighCPU()
    pcall(function() Device:enableCPUCores(2) end)
end

local function releaseHighCPU()
    if cpu_downgrade_timer_cancel then
        cpu_downgrade_timer_cancel()
        cpu_downgrade_timer_cancel = nil
    end
    cpu_downgrade_timer_cancel = delay(3.0, function()
        if active_processes <= 0 then
            pcall(function() Device:enableCPUCores(1) end)
        end
        cpu_downgrade_timer_cancel = nil
    end)
end

local function generate_ipc_endpoint()
    local ffi = require("ffi")
    local is_android = Device and Device.isAndroid and Device:isAndroid()
    if ffi.os == "Linux" and not is_android then
        local name = string.format("legado_task_%d_%d", math.floor(socket.gettime() * 1000), math.random(1000, 9999))
        return "ipc://@" .. name
    end
    return "tcp://127.0.0.1:*"
end

function M.spawnProcessStream(job, opts)
    opts = opts or {}
    local on_chunk = opts.on_chunk
    local on_decode = opts.on_decode or function(s) return s end
    local on_finish = opts.on_finish
    local timeout = opts.timeout
    local raw_chunks = opts.raw_chunks == true
    -- 正常结束握手：子进程发 __end__ 标记后等待 ACK，父进程据此确认全部帧已按序送达
    local stream_ended = false

    local ERR_PREFIX = "\x00ERR:"

    local finished = false
    local zmq_registered = false
    local mq = nil

    local function finish(ok, err)
        if finished then return end
        finished = true

        if mq then
            if zmq_registered and UIManager.removeZMQ then
                pcall(UIManager.removeZMQ, UIManager, mq)
                zmq_registered = false
            end
            pcall(function() mq:stop() end)
            mq = nil
        end

        active_processes = math.max(0, (active_processes or 1) - 1)
        if active_processes == 0 then
            releaseHighCPU()
        end
        if type(on_finish) == "function" then
            pcall(on_finish, ok, err)
        end
    end

    active_processes = (active_processes or 0) + 1
    if active_processes == 1 then
        requestHighCPU()
    end

    local start_time = socket.gettime()
    local pid

    local client_identity = string.format("task_%d_%d", math.floor(socket.gettime() * 1000), math.random(1000, 9999))

    local function on_incoming_data(incoming)
        if finished or not incoming then return end
        local chunk = ""
        if type(incoming) == "table" then
            if incoming.id then
                client_identity = incoming.id
            end
            if incoming.data ~= nil then
                chunk = tostring(incoming.data)
            elseif #incoming > 0 then
                chunk = table.concat(incoming)
            end
        else
            chunk = tostring(incoming)
        end
        if #chunk == 0 then return end

        if chunk:sub(1, #ERR_PREFIX) == ERR_PREFIX then
            finish(false, chunk:sub(#ERR_PREFIX + 1))
            return false
        end

        -- 流结束标记：ZMQ 保序，此前所有帧必已收到；回 ACK 让子进程安全关闭
        -- （字符串层拦截，不受 on_decode 过滤影响）
        if chunk:find('"__end__"', 1, true) or chunk == "__end__" then
            stream_ended = true
            if mq and client_identity then
                pcall(function() mq:send("__ack__", client_identity) end)
            end
            return true
        end

        if raw_chunks then
            if type(on_chunk) == "function" then
                pcall(on_chunk, chunk)
            end
        else
            local okd, frame = pcall(on_decode, chunk)
            if not okd then
                logger.warn(string.format("[spawnProcessStream] on_decode 失败: %s (head: %s)",
                    tostring(frame), chunk:sub(1, 80)))
            elseif frame ~= nil then
                if type(on_chunk) == "function" then
                    local okc, cerr = pcall(on_chunk, frame)
                    if not okc then
                        logger.err(string.format("[spawnProcessStream] on_chunk 回调异常: %s", tostring(cerr)))
                    end
                end
            end
        end
        return true
    end

    if not IpcMQ then IpcMQ = require("Legado.task.v2.IpcMessage") end
    local endpoint = generate_ipc_endpoint()

    mq = IpcMQ:new{
        endpoint = endpoint,
        is_server = true,
        receiveCallback = on_incoming_data,
    }
    local ok_start, serr = pcall(function() mq:start() end)
    if not ok_start then
        logger.err("[spawnProcessStream] IpcMessage start failed: " .. tostring(serr))
        finish(false, "zmq_bind_failed")
        return setmetatable({
            pid = nil,
            send = function() return false end,
            send_line = function() return false end,
            pause = function() return false end,
            resume = function() return false end,
            cancel = function() end,
            is_done = function() return true end,
        }, { __call = function(t) t:cancel() end })
    end

    local bound_endpoint = mq.endpoint or endpoint

    pid = ffiUtil.runInSubProcess(function(_pid)
        local JSON = require("json")
        if not IpcMQ then IpcMQ = require("Legado.task.v2.IpcMessage") end
        local child_mq = IpcMQ:new{
            endpoint = bound_endpoint,
            is_server = false,
            identity = client_identity,
        }
        child_mq:start()

        local stream = {
            _closed = false,
            _cancelled = false,
            _cancel_reason = nil,
            _paused = false,
            _incoming_buffer = {},
            send = function(self, data)
                if self._closed then return false, "closed" end
                return child_mq:send(tostring(data))
            end,
            write = function(self, data)
                return self:send(data)
            end,
            poll_control = function(self)
                if self._closed then return end
                if not child_mq then return end
                while child_mq:wait(0) ~= nil do
                    local data = child_mq:recv()
                    if data ~= nil then
                        local ok_j, control_msg = pcall(JSON.decode, data)
                        if ok_j and type(control_msg) == "table" and control_msg.type == "control" then
                            if control_msg.action == "cancel" then
                                self._cancelled = true
                                self._cancel_reason = control_msg.reason or "user_cancelled"
                            elseif control_msg.action == "pause" then
                                self._paused = true
                            elseif control_msg.action == "resume" then
                                self._paused = false
                            end
                        elseif data == "CANCEL" or data == "CANCEL\n" then
                            self._cancelled = true
                            self._cancel_reason = "user_cancelled"
                        elseif data == "PAUSE" or data == "PAUSE\n" then
                            self._paused = true
                        elseif data == "RESUME" or data == "RESUME\n" then
                            self._paused = false
                        else
                            self._incoming_buffer = self._incoming_buffer or {}
                            table.insert(self._incoming_buffer, data)
                        end
                    else
                        break
                    end
                end
            end,
            is_cancelled = function(self)
                self:poll_control()
                return self._cancelled
            end,
            throw_if_cancelled = function(self)
                if self:is_cancelled() then
                    error({ type = "cancelled", reason = self._cancel_reason or "user_cancelled" })
                end
            end,
            is_paused = function(self)
                self:poll_control()
                return self._paused
            end,
            wait_if_paused = function(self)
                while self:is_paused() do
                    self:throw_if_cancelled()
                    if child_mq then
                        child_mq:wait(50)
                    else
                        socket.sleep(0.05)
                    end
                end
            end,
            sleep = function(self, sec)
                if not sec or sec <= 0 then return true end
                local deadline = socket.gettime() + sec

                while socket.gettime() < deadline do
                    self:poll_control()
                    if self._cancelled then
                        self:throw_if_cancelled()
                    end
                    local remain = deadline - socket.gettime()
                    if remain <= 0 then break end
                    local wait_ms = math.min(math.floor(remain * 1000), 50)

                    if child_mq then
                        child_mq:wait(wait_ms)
                    else
                        socket.sleep(wait_ms / 1000)
                    end
                end
                return true
            end,
            receive = function(self, pattern, to)
                if self._closed then return nil, "closed" end
                self:poll_control()
                if self._incoming_buffer and #self._incoming_buffer > 0 then
                    return table.remove(self._incoming_buffer, 1)
                end
                if child_mq then
                    local wait_time = (to and to > 0) and math.floor(to * 1000) or -1
                    local ev = child_mq:wait(wait_time)
                    if ev ~= nil then
                        self:poll_control()
                        if self._incoming_buffer and #self._incoming_buffer > 0 then
                            return table.remove(self._incoming_buffer, 1)
                        end
                    end
                    return nil, "timeout"
                end
                return nil, "no_transport"
            end,
            read = function(self, pattern, to)
                return self:receive(pattern, to)
            end,
            close = function(self)
                if not self._closed then
                    self._closed = true
                    if child_mq then
                        socket.sleep(0.02)
                        pcall(function() child_mq:stop() end)
                    end
                end
            end,
        }

        local function writer_fn(frame)
            local ok_w, werr = stream:send(frame)
            if not ok_w then
                error("write to stream failed: " .. tostring(werr))
            end
        end

        local function reader_fn(pattern, to)
            return stream:receive(pattern, to)
        end

        local raw_err = nil
        local job_ok, jerr = xpcall(function()
            return job(writer_fn, reader_fn, stream)
        end, function(e)
            raw_err = e
            -- 保留原始错误对象：避免 traceback 字符串污染业务错误消息（如"没有更多了"）
            if type(e) == "table" and not e.trace then
                e.trace = debug.traceback(tostring(e), 2)
            end
            return e
        end)

        if not job_ok then
            local is_cancelled_err = (type(raw_err) == "table" and raw_err.type == "cancelled")
                or (type(jerr) == "table" and jerr.type == "cancelled")
                or tostring(jerr):find('"type":"cancelled"')
                or tostring(jerr):find("type = \"cancelled\"")
                or (stream and stream.is_cancelled and stream:is_cancelled())

            if not is_cancelled_err then
                local raw_msg = jerr
                if type(raw_msg) == "table" then
                    raw_msg = raw_msg.message or raw_msg.errorMsg or raw_msg.error or raw_msg.msg or raw_msg.reason or raw_msg[1] or tostring(raw_msg)
                end
                local err_msg = tostring(raw_msg):gsub("\r", ""):gsub("\n", " -> ")
                pcall(function() stream:send(ERR_PREFIX .. err_msg) end)
            end
        else
            -- 正常结束：先发 __end__ 标记并等待父进程 ACK，保证所有帧送达后再关闭连接
            local ok_end = pcall(function()
                stream:write(JSON.encode({ type = "__end__" }))
            end)
            if ok_end then
                local ack = nil
                local deadline = socket.gettime() + 3
                while socket.gettime() < deadline do
                    if stream and stream.is_cancelled and stream:is_cancelled() then break end
                    ack = reader_fn("*l", 0.2)
                    if ack then break end
                end
                if ack == nil then
                    -- ACK 超时（如父进程已取消/关闭）：短暂休眠让 linger 继续 flush
                    socket.sleep(0.1)
                end
            end
        end

        stream:close()
        -- 绕过 runInSubProcess 里 os.exit(0) 的 C atexit 清理死锁：
        -- fork 后 czmq/LuaSocket 继承的锁在 exit() 清理阶段无法获取，导致子进程不退出。
        -- POSIX _exit 直接 exit_group，不运行 atexit，不触发任何库清理。
        pcall(function()
            local ffi = require("ffi")
            pcall(ffi.cdef, "void _exit(int status);")
            if ffi.C and ffi.C._exit then
                io.flush()
                ffi.C._exit(0)
            end
        end)
        -- fallback：若 _exit 不可用，退回原退出路径
        return
    end, false)

    if not pid then
        finish(false, "start_failed")
        return setmetatable({
            pid = nil,
            send = function() return false end,
            send_line = function() return false end,
            pause = function() return false end,
            resume = function() return false end,
            cancel = function() end,
            is_done = function() return true end,
        }, { __call = function(t) t:cancel() end })
    end

    if mq and UIManager.insertZMQ then
        pcall(function()
            UIManager:insertZMQ(mq)
            zmq_registered = true
        end)
    end

    local cancel_grace_deadline = nil

    local function poll()
        if finished then return end

        local now = socket.gettime()
        if cancel_grace_deadline and now >= cancel_grace_deadline then
            if pid then pcall(ffiUtil.terminateSubProcess, pid) end
            finish(false, "已取消")
            return
        end

        if timeout and now - start_time >= timeout then
            if pid then pcall(ffiUtil.terminateSubProcess, pid) end
            finish(false, "timeout")
            return
        end

        if mq and mq.waitEvent then
            pcall(function() mq:waitEvent() end)
        end

        local sub_done = ffiUtil.isSubProcessDone(pid)
        if sub_done then
            if mq and mq.waitEvent then
                pcall(function() mq:waitEvent(50) end)
            end
            if not finished then
                if cancel_grace_deadline then
                    finish(false, "已取消")
                else
                    finish(true)
                end
            end
            return
        end

        UIManager:scheduleIn(0.125, poll)
    end
    UIManager:scheduleIn(0.125, poll)

    local handle = setmetatable({
        pid = pid,
        send = function(self, data)
            if finished or not mq then return false, "closed" end
            local ok_s, serr = pcall(function()
                return mq:send(tostring(data), client_identity)
            end)
            return ok_s, serr
        end,
        send_line = function(self, line)
            return self:send(line)
        end,
        pause = function(self)
            return self:send("{\"type\":\"control\",\"action\":\"pause\"}")
        end,
        resume = function(self)
            return self:send("{\"type\":\"control\",\"action\":\"resume\"}")
        end,
        cancel = function(self, reason)
            if not finished and not cancel_grace_deadline then
                local reason_str = reason or "user_cancelled"
                self:send(string.format("{\"type\":\"control\",\"action\":\"cancel\",\"reason\":\"%s\"}", reason_str))
                cancel_grace_deadline = socket.gettime() + 1.5
            end
        end,
        is_done = function(self)
            return finished
        end,
    }, {
        __call = function(t, reason)
            t:cancel(reason)
        end
    })

    return handle
end

return M
