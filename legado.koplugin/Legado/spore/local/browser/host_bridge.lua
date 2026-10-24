local JSON = require("json")
local socket = require("socket")
local M = {}

function M.worker(writer, stream, options)
    local timeout = options and options.timeout or 120
    assert(type(timeout) == "number" and timeout > 0 and timeout < math.huge)
    local sequence = 0
    local client = {}
    function client:call(operation, arguments)
        sequence = sequence + 1
        local id = sequence
        local deadline = socket.gettime() + timeout
        stream:throw_if_cancelled()
        local sent = writer(JSON.encode({type = "host_request", id = id, operation = operation, arguments = arguments}))
        if sent == false then return nil, {kind = "closed", message = "host transport closed"} end
        while true do
            stream:throw_if_cancelled()
            local remaining = deadline - socket.gettime()
            if remaining <= 0 then
                return nil, {kind = "timeout", message = "host request timed out"}
            end
            local frame, receive_error = stream:receive(nil, math.min(0.05, remaining))
            if frame then
                local ok, reply = pcall(JSON.decode, frame)
                if not ok or type(reply) ~= "table" or reply.type ~= "host_reply" then
                    return nil, {kind = "protocol_error", message = "invalid host reply"}
                end
                if type(reply.id) ~= "number" or reply.id % 1 ~= 0 or reply.id > id then
                    return nil, {kind = "protocol_error", message = "invalid host reply id"}
                end
                if reply.id == id then
                    if reply.operation ~= operation or type(reply.ok) ~= "boolean" then
                        return nil, {kind = "protocol_error", message = "mismatched host reply"}
                    end
                    if reply.ok then return reply.data end
                    return nil, type(reply.error) == "table" and reply.error
                        or {kind = "host_failure", message = "host request failed"}
                end
            elseif receive_error == "closed" or receive_error == "no_transport" then
                return nil, {kind = "closed", message = "host transport closed"}
            end
        end
    end
    return client
end

function M.parent(send, handlers)
    local closed, last_id, pending = false, 0, nil
    local router = {}
    local function discard()
        local previous = pending
        pending = nil
        if previous and previous.cleanup then pcall(previous.cleanup) end
    end
    function router:close()
        if closed then return end
        closed = true
        discard()
    end
    function router:dispatch(message)
        if type(message) ~= "table" or message.type ~= "host_request" then return false end
        if closed then return true end
        local id, operation = message.id, message.operation
        if type(id) ~= "number" or id % 1 ~= 0 or id <= last_id
            or type(operation) ~= "string" then return true end
        discard()
        last_id = id
        local entry = {}
        pending = entry
        local function reply(data, err)
            if closed or pending ~= entry then return false end
            pending = nil
            return send(JSON.encode({type = "host_reply", id = id, operation = operation,
                ok = err == nil, data = data, error = err}))
        end
        local handler = handlers[operation]
        if not handler then
            reply(nil, {kind = "unsupported", message = "host operation is not available"})
            return true
        end
        local ok, cleanup = pcall(handler, message.arguments, reply)
        if not ok then
            reply(nil, {kind = "host_failure", message = "host handler failed"})
        elseif type(cleanup) == "function" then
            if pending == entry then entry.cleanup = cleanup
            elseif closed then pcall(cleanup) end
        end
        return true
    end
    return router
end

return M
