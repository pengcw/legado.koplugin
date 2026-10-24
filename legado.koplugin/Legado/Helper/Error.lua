local logger = require("logger")

local M = {}

local function strip_lua_locations(message)
    local clean = message

    local previous
    repeat
        previous = clean
        clean = clean:gsub("^%s*[%w_%.%-%/\\@]+%.lua:%d+:%s*", "")
        clean = clean:gsub("^%s*%[string .-%]:%d+:%s*", "")
        clean = clean:gsub("([%s%(])[%w_%.%-%/\\@]+%.lua:%d+:%s*", "%1")
        clean = clean:gsub("([%s%(])%[string .-%]:%d+:%s*", "%1")
        clean = clean:gsub("(：)%s*[%w_%.%-%/\\@]+%.lua:%d+:%s*", "%1")
        clean = clean:gsub("(：)%s*%[string .-%]:%d+:%s*", "%1")
    until clean == previous

    return clean
end

M.extract_message = function(err)
    if err == nil then return "unknown error" end
    local raw_str
    if type(err) == "string" then
        raw_str = err
    elseif type(err) == "table" then
        local val = err[1] or err.message or err.errorMsg or err.error or err.reason or err.err or err.msg or "unknown table error"
        if type(val) == "table" then
            return M.extract_message(val)
        end
        raw_str = tostring(val)
    else
        raw_str = tostring(err)
    end

    raw_str = raw_str:gsub("\r\n", "\n"):gsub("\r", "\n")
    local trace_pos = raw_str:find("\n%s*stack traceback:")
    local clean = trace_pos and raw_str:sub(1, trace_pos - 1) or raw_str
    clean = clean:match("^(.-)\n") or clean
    clean = strip_lua_locations(clean)
    clean = clean:match("^%s*(.-)%s*$")
    return (clean and clean ~= "") and clean or raw_str
end

M.format_failure = function(message, err)
    if err == nil then return message end
    local detail = M.extract_message(err)
    local chars = require("util").splitToChars(detail)
    if #chars > 40 then
        detail = table.concat(chars, "", 1, 40) .. "…"
    end
    return message .. "：" .. detail
end

M.pcall = function(f, ...)
    if type(f) ~= "function" then
        return false, "safe_pcall: first argument must be a function"
    end
    local function err_handler(err)
        if logger and type(logger.err) == "function" and
            G_reader_settings and G_reader_settings:isTrue("debug") then
            logger.err("safe_call: ", debug.traceback(tostring(err), 2))
        end
        return M.extract_message(err)
    end
    return xpcall(f, err_handler, ...)
end

M.map_message = function(err_msg)
    err_msg = M.extract_message(err_msg)
    local lower_err = tostring(err_msg):lower()
    local err_map = {
        ["wantread"] = "连接超时，请稍后重试",
        ["connection refused"] = "连接被拒绝，请检查服务地址",
        ["no route to host"] = "无法连接到服务",
        ["network is unreachable"] = "网络不可用，请检查网络连接",
        ["timeout not expected"] = "网络连接不稳定，请重试",
        ["host not found"] = "域名解析失败",
        ["ssl handshake failed"] = "安全连接失败",
        ["timeout"] = "请求超时",
        ["closed"] = "连接已关闭",
        ["eof"] = "连接意外终止",
    }
    return err_map[lower_err] or ("网络请求失败，请检查：" .. tostring(err_msg))
end

return M
