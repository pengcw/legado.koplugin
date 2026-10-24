local ffi = require("ffi")
local M = {}
M.__index = M
local active_lease

function M.new(handlers, options)
    assert(type(handlers) == "table", "host handlers must be a table")
    local copy = {}
    for operation, handler in pairs(handlers) do
        assert(type(operation) == "string" and operation:match("^[%w_.%-]+$")
            and #operation <= 128 and type(handler) == "function", "invalid host handler")
        copy[operation] = handler
    end
    local limit = options and options.max_response_bytes or 65536
    assert(type(limit) == "number" and limit % 1 == 0 and limit >= 1
        and limit <= 8 * 1024 * 1024, "invalid host response limit")
    return setmetatable({ handlers = copy, max_response_bytes = limit }, M)
end

function M:call(operation, arguments, context)
    local handler = self.handlers[operation]
    if not handler then
        return nil, { kind = "unsupported", message = "host capability is not available: " .. operation }
    end
    return handler(arguments, context)
end

function M.is_active()
    return active_lease ~= nil
end

function M:with_binding(library, json, context, run, ...)
    if active_lease then return false, "host callbacks cannot re-enter Reader" end
    local callback = ffi.cast("reader_host_call", function(_, operation_ptr, args_ptr, output, capacity)
        local ok, encoded = pcall(function()
            local operation = ffi.string(operation_ptr)
            local arguments = json.decode(ffi.string(args_ptr))
            local data, err = self:call(operation, arguments, context)
            if err ~= nil then
                if type(err) ~= "table" then err = { kind = "operation_failed", message = tostring(err) } end
                return json.encode({ ok = false, error = {
                    kind = tostring(err.kind or "operation_failed"),
                    message = tostring(err.message or "host capability failed"),
                } })
            end
            return '{"ok":true,"data":' .. (data == nil and "null" or json.encode(data)) .. '}'
        end)
        if not ok then
            encoded = '{"ok":false,"error":{"kind":"host_failure","message":"host capability failed"}}'
        end
        if #encoded > tonumber(capacity) then return -2 end
        ffi.copy(output, encoded, #encoded)
        return #encoded
    end)
    local descriptor = ffi.new("ReaderHostServices", {
        abi_version = 1, call = callback, user_data = nil,
        max_response_bytes = self.max_response_bytes,
    })
    local bound, status = pcall(library.reader_set_host_services, descriptor)
    if not bound or status ~= 0 then
        callback:free()
        return false, "host service registration failed: " .. tostring(status)
    end
    active_lease = { callback = callback, descriptor = descriptor, library = library }
    local ok, result = pcall(run, ...)
    local cleared, clear_status = pcall(library.reader_set_host_services, nil)
    if not cleared or clear_status ~= 0 then
        return false, "host service cleanup failed: " .. tostring(clear_status)
    end
    active_lease = nil
    callback:free()
    return ok, result
end

if jit then jit.off(M.with_binding, true) end
return M
