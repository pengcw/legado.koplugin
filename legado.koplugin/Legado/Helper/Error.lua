local logger = require("logger")

local M = {}

M.pcall = function(f, ...)
    if type(f) ~= "function" then
        return false, "safe_pcall: first argument must be a function"
    end
    local function err_handler(err)
        local err_msg = tostring(err or "unknown error")
        if logger and type(logger.err) == "function" and 
            G_reader_settings and G_reader_settings:isTrue("debug") then
            local trace = debug.traceback(err, 2)
            logger.err("safe_call: ", trace)
        end
        return string.match(err_msg, ":%d+: (.*)$") or err_msg
    end
    return xpcall(f, err_handler, ...)
end

M.map_error_message = function(err_msg)
    if type(err_msg) ~= "string" then 
        return "网络请求失败"
    end
    local lower_err = err_msg:lower()
    local err_map = {
        ["wantread"] = "连接超时，请稍后重试", 
        ["connection refused"] = "连接被拒绝，请检查服务地址",
        ["no route to host"] = "无法连接到网络",
        ["network is unreachable"] = "网络不可用，请检查网络连接",
        ["timeout not expected"] = "网络连接不稳定，请重试",
        ["host not found"] = "域名解析失败",
        ["ssl handshake failed"] = "安全连接失败",
        ["timeout"] = "请求超时",
        ["closed"] = "连接已关闭",
        ["eof"] = "连接意外终止",
    }
    return err_map[lower_err] or ("网络请求失败，请检查：" .. err_msg)
end

return M
