local logger = require("logger")

local M = {}

--- 提取错误信息（支持字符串、LuaSocket/Copas table 错误形如 {[1]="...", message="..."}，并自动剥离 traceback 与行号）
M.extract_message = function(err)
    if err == nil then return "unknown error" end
    local raw_str = nil
    if type(err) == "string" then
        raw_str = err
    elseif type(err) == "table" then
        local val = err[1] or err.reason or err.message or err.error or err.errorMsg or err.err or err.msg or "unknown table error"
        if type(val) == "table" then
            return M.extract_message(val)
        end
        raw_str = tostring(val)
    else
        raw_str = tostring(err)
    end

    local clean = raw_str:match("^(.-)%s*[%->\n\r]+%s*stack traceback:") or raw_str:match("^(.-)\r?\n") or raw_str
    while clean:match("^.-:%d+:%s*(.+)$") do
        clean = clean:match("^.-:%d+:%s*(.+)$")
    end
    clean = clean:match("^%s*(.-)%s*$")
    return (clean and clean ~= "") and clean or raw_str
end

M.pcall = function(f, ...)
    if type(f) ~= "function" then
        return false, "safe_pcall: first argument must be a function"
    end
    local function err_handler(err)
        local raw_msg = M.extract_message(err)
        local err_msg = tostring(raw_msg or "unknown error")
        if logger and type(logger.err) == "function" and
            G_reader_settings and G_reader_settings:isTrue("debug") then
            local trace = debug.traceback(err_msg, 2)
            logger.err("safe_call: ", trace)
        end
        local first_line = err_msg:match("^(.-)\n%s*stack traceback:") or err_msg:match("^(.-)\r?\n") or err_msg
        local clean_msg = first_line:match("^.-:%d+:%s*(.+)$") or first_line
        return clean_msg:match("^%s*(.-)%s*$")
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
