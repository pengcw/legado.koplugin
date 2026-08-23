local ffi = require("ffi")
local logger = require("logger")
local socket = require("socket")
local MessageQueue = require("ui/message/messagequeue")

require("ffi/zeromq_h")

local zmq, czmq
pcall(function() zmq = ffi.loadlib("zmq", "5") end)
pcall(function() czmq = ffi.loadlib("czmq", "4") end)

-- 安卓被裁减, 无导出函数
pcall(ffi.cdef, [[
int zmq_setsockopt(void *, int, const void *, size_t);
zmsg_t *zmsg_recv(void *);
bool zpoller_terminated(zpoller_t *);
]])

local zsock_ptr_t = ffi.typeof("zsock_t *[1]")
local zpoller_ptr_t = ffi.typeof("zpoller_t *[1]")
local zmsg_ptr_t = ffi.typeof("zmsg_t *[1]")
local zframe_ptr_t = ffi.typeof("zframe_t *[1]")

local ZMQ_ROUTER = 6
local ZMQ_DEALER = 5
local ZMQ_IDENTITY = 5
local ZMQ_LINGER = 17

local M = MessageQueue:extend{
    endpoint = nil,
    is_server = false,
    identity = nil,
    socket = nil,
    poller = nil,
    receiveCallback = nil,
    started = false,
    stopped = false,
    clients = nil,
    last_purge_time = 0,
}

local function is_null(ptr)
    return ptr == nil or ptr == ffi.NULL
end

function M.is_available()
    return czmq ~= nil and zmq ~= nil
end

-- 安卓其实 zmq_setsockopt 这个也没有
local function set_socket_linger(sock, linger_ms)
    if not (sock and czmq and zmq) then return end
    pcall(function()
        local raw = czmq.zsock_resolve(sock)
        if raw ~= nil then
            local val = ffi.new("int[1]", linger_ms or 0)
            zmq.zmq_setsockopt(raw, ZMQ_LINGER, val, ffi.sizeof("int"))
        end
    end)
end

local function set_socket_identity(sock, identity)
    if not (sock and identity and czmq and zmq) then return end
    pcall(function()
        local raw = czmq.zsock_resolve(sock)
        if raw ~= nil then
            zmq.zmq_setsockopt(raw, ZMQ_IDENTITY, identity, #identity)
        end
    end)
end

local function safe_destroy_poller(poller)
    if poller and czmq then
        pcall(function() czmq.zpoller_destroy(zpoller_ptr_t(poller)) end)
    end
end

local function safe_destroy_socket(sock)
    if sock and czmq then
        set_socket_linger(sock, 0)
        pcall(function() czmq.zsock_destroy(zsock_ptr_t(sock)) end)
    end
end

function M:start()
    if self.started then return true end
    if not self.endpoint then
        error("[IpcMessage] endpoint missing")
    end
    if not self.is_available() then
        error("[IpcMessage] czmq/zmq unavailable")
    end

    local socket_type = self.is_server and ZMQ_ROUTER or ZMQ_DEALER
    self.socket = czmq.zsock_new(socket_type)
    if is_null(self.socket)then
        error("[IpcMessage] create socket failed")
    end
    set_socket_linger(self.socket, 250)

    if not self.is_server then
        if not self.identity then
            local now_ms = math.floor(socket.gettime() * 1000)
            self.identity = string.format("client_%d_%d", now_ms, math.random(1000, 9999))
        end
        set_socket_identity(self.socket, self.identity)
    else
        self.clients = {}
    end

    local is_ipc = self.endpoint:sub(1, 6) == "ipc://"
    local ipc_path = is_ipc and self.endpoint:sub(7) or nil
    local is_abstract = ipc_path and ipc_path:sub(1, 1) == "@"

    if self.is_server and ipc_path and not is_abstract then
        pcall(os.remove, ipc_path)
    end

    local rc
    if self.is_server then
        rc = czmq.zsock_bind(self.socket, self.endpoint)
        if rc > 0 and (self.endpoint:find(":%*$") or self.endpoint:find(":0$")) then
            local prefix = self.endpoint:match("^(.-://.-:)") or "tcp://127.0.0.1:"
            self.endpoint = prefix .. rc
            self.port = rc
        end
    else
        rc = czmq.zsock_connect(self.socket, self.endpoint)
    end
    if rc < 0 then
        self:stop()
        error("[IpcMessage] connect/bind failed " .. self.endpoint)
    end

    self.poller = czmq.zpoller_new(self.socket, nil)
    if is_null(self.poller) then
        self:stop()
        error("[IpcMessage] poller create failed")
    end

    self.started = true
    self.stopped = false
    return true
end

function M:stop()
    local poller = self.poller
    self.poller = nil
    safe_destroy_poller(poller)

    local sock = self.socket
    self.socket = nil
    safe_destroy_socket(sock)

    if self.is_server and self.endpoint and self.endpoint:sub(1, 6) == "ipc://" then
        local ipc_path = self.endpoint:sub(7)
        if ipc_path and ipc_path:sub(1, 1) ~= "@" then
            pcall(os.remove, ipc_path)
        end
    end

    self.started = false
    self.stopped = true
end

function M:send(data, target_id)
    if is_null(self.socket) then return false, "closed" end
    data = tostring(data or "")
    local msg = czmq.zmsg_new()
    if not msg then return false, "alloc_failed" end

    if self.is_server then
        if not target_id then
            czmq.zmsg_destroy(zmsg_ptr_t(msg))
            return false, "target_required"
        end
        target_id = tostring(target_id)
        czmq.zmsg_addmem(msg, target_id, #target_id)
    end

    czmq.zmsg_addmem(msg, data, #data)
    local rc = czmq.zmsg_send(zmsg_ptr_t(msg), self.socket)
    if rc ~= 0 then return false, "send_failed" end
    return true
end

function M:wait(timeout_ms)
    if is_null(self.socket) or is_null(self.poller) then return end
    local which = czmq.zpoller_wait(self.poller, timeout_ms or 0)
    if which == nil then
        local is_term = false
        pcall(function()
            if czmq.zpoller_terminated(self.poller) then is_term = true end
        end)
        if is_term then self:stop() end
    end
    return which
end

local zmsg_recv_fn = nil
local zframe_more_fn = nil
if czmq then
    pcall(function() zmsg_recv_fn = czmq.zmsg_recv end)
    pcall(function() zframe_more_fn = czmq.zframe_more end) -- 新增
end

local function frame_to_string(frame)
    if frame == nil then return nil end
    local size = czmq.zframe_size(frame)
    if size == nil then return nil end
    if size == 0 then return "" end
    local data = czmq.zframe_data(frame)
    if data == nil then return nil end
    return ffi.string(data, size)
end

local function destroy_frame(frame)
    if frame ~= nil then
        pcall(function()
            czmq.zframe_destroy(zframe_ptr_t(frame))
        end)
    end
end

function M:recv()
    if is_null(self.socket) or czmq == nil then return nil end
    local id = nil
    local body = nil
    -- 优先使用 zmsg_recv
    if zmsg_recv_fn then
        local msg = zmsg_recv_fn(self.socket)
        if msg == nil then return nil end
        if self.is_server then
            local id_frame = czmq.zmsg_pop(msg)
            if id_frame ~= nil then
                id = frame_to_string(id_frame)
                destroy_frame(id_frame)
            end
        end

        local body_frame = czmq.zmsg_pop(msg)
        if body_frame ~= nil then
            body = frame_to_string(body_frame)
            destroy_frame(body_frame)
        end
        czmq.zmsg_destroy(zmsg_ptr_t(msg))
    -- fallback：逐帧接收
    else
        if self.is_server then
            local id_frame = czmq.zframe_recv(self.socket)
            if id_frame == nil then return nil end
            id = frame_to_string(id_frame)
            destroy_frame(id_frame)
        end
        local body_frame = czmq.zframe_recv(self.socket)
        if body_frame == nil then return nil end
        body = frame_to_string(body_frame)
        destroy_frame(body_frame)
    end
    if body == nil then return nil end
    if id ~= nil and self.clients then
        self.clients[id] = socket.gettime()
    end
    return body, id
end

function M:waitEvent(timeout, max_events)
    if is_null(self.socket) or is_null(self.poller) then return end
    if self.is_server and self.clients then
        local now = socket.gettime()
        if now - (self.last_purge_time or 0) > 60 then
            self:purgeClients(300)
            self.last_purge_time = now
        end
    end

    local to = timeout or 0
    local limit = max_events or 256
    local events = 0
    while events < limit do
        if is_null(self.socket) or is_null(self.poller) then break end
        local which = self:wait(events == 0 and to or 0)
        if which == nil then break end
        local body, id = self:recv()
        if body ~= nil and self.receiveCallback then
            local ok, err = pcall(self.receiveCallback, { id = id, data = body })
            if not ok and logger and logger.err then
                logger.err("[IpcMessage] receiveCallback error: " .. tostring(err))
            end
        end
        if is_null(self.socket) or is_null(self.poller) then break end
        events = events + 1
    end
end

function M:getClients()
    local res = {}
    if self.clients then
        for id, time in pairs(self.clients) do
            res[id] = time
        end
    end
    return res
end

function M:purgeClients(timeout_sec)
    if not self.is_server or not self.clients then return end
    local now = socket.gettime()
    for id, last_time in pairs(self.clients) do
        if (now - last_time) > (timeout_sec or 300) then
            self.clients[id] = nil
        end
    end
end

M.czmq = czmq
M.zmq = zmq

return M
