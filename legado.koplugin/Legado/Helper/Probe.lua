local ok_logger, logger = pcall(require, "logger")
if not ok_logger or not logger or type(logger) ~= "table" then
    logger = {
        info = function(msg) print(msg) end,
        dbg = function(msg) print(msg) end,
        warn = function(msg) print(msg) end,
        err = function(msg) print(msg) end,
    }
end
local socket = require("socket")

local Probe = {
    ENABLED = false,
    LOG_LEVEL = "info",
}

local function init_copas_thread_tracking(copas)
    if not copas or copas._active_threads then return end
    copas._active_threads = setmetatable({}, { __mode = "k" })
    local raw_addnamed = copas.addnamedthread
    copas.addnamedthread = function(name, handler, ...)
        return raw_addnamed(name, function(...)
            local co = coroutine.running()
            if co then copas._active_threads[co] = true end
            return handler(...)
        end, ...)
    end
end

-- 模块加载时预先增强 copas 单例（若环境具备 copas）
local ok_copas_init, copas_mod_init = pcall(require, "Legado.vendor.copas")
if ok_copas_init and copas_mod_init then
    init_copas_thread_tracking(copas_mod_init)
end

function Probe.is_copas()
    local co = coroutine.running()
    if not co then return false end

    local ok_copas, copas = pcall(require, "Legado.vendor.copas")
    if ok_copas and copas then
        init_copas_thread_tracking(copas)
        if copas.running then return true end
        if copas._active_threads and copas._active_threads[co] then
            return true
        end
    end

    return false
end

function Probe.get_mode_tag()
    return Probe.is_copas() and "ASYNC" or "SYNC"
end

function Probe.format_bytes(bytes)
    if not bytes or bytes <= 0 then return "0B" end
    if bytes < 1024 then return bytes .. "B" end
    if bytes < 1024 * 1024 then return string.format("%.1fKB", bytes / 1024) end
    return string.format("%.2fMB", bytes / (1024 * 1024))
end

function Probe.format_summary(data)
    if not data then return "nil" end
    if type(data) == "table" then
        if #data > 0 then
            return string.format("%d items", #data)
        elseif data.list and type(data.list) == "table" and #data.list > 0 then
            return string.format("%d items", #data.list)
        else
            local count = 0
            for _ in pairs(data) do count = count + 1 end
            return count > 0 and (count .. " fields") or "0 items"
        end
    elseif type(data) == "string" then
        return Probe.format_bytes(#data)
    else
        return tostring(data)
    end
end

function Probe.start(category, action, url, timeout_info)
    if not Probe.ENABLED then return socket.gettime() end
    local t_start = socket.gettime()
    local mode_tag = Probe.get_mode_tag()
    local to_str = timeout_info and (" " .. timeout_info) or ""
    logger[Probe.LOG_LEVEL](string.format("[%sProbe] ▶ [START] [%s] %s %s%s",
        category or "Net", mode_tag, action or "REQ", tostring(url or ""), to_str))
    return t_start
end

function Probe.done(category, action, url, t_start, status_code, size_or_summary, ext)
    if not Probe.ENABLED then return end
    local elapsed_ms = t_start and math.floor((socket.gettime() - t_start) * 1000 + 0.5) or 0
    local mode_tag = Probe.get_mode_tag()
    local ext_tag = (ext and ext ~= "" and ext ~= "-") and (string.format("[%s] ", ext)) or ""
    logger[Probe.LOG_LEVEL](string.format("[%sProbe] ✔ [DONE: %s] [%dms] [%s] %s[%s] %s %s",
        category or "Net", tostring(status_code or "200 OK"), elapsed_ms, tostring(size_or_summary or "-"), ext_tag, mode_tag, action or "REQ", tostring(url or "")))
end

function Probe.fail(category, action, url, t_start, reason)
    if not Probe.ENABLED then return end
    local elapsed_ms = t_start and math.floor((socket.gettime() - t_start) * 1000 + 0.5) or 0
    local mode_tag = Probe.get_mode_tag()
    logger[Probe.LOG_LEVEL](string.format("[%sProbe] ✘ [FAIL: %s] [%dms] [%s] %s %s",
        category or "Net", tostring(reason or "未知错误"), elapsed_ms, mode_tag, action or "REQ", tostring(url or "")))
end

function Probe.retry(category, action, url, t_start, reason)
    if not Probe.ENABLED then return end
    local elapsed_ms = t_start and math.floor((socket.gettime() - t_start) * 1000 + 0.5) or 0
    local mode_tag = Probe.get_mode_tag()
    logger[Probe.LOG_LEVEL](string.format("[%sProbe] ↺ [RETRY: %s] [%dms] [%s] %s %s",
        category or "Net", tostring(reason or "重试中"), elapsed_ms, mode_tag, action or "REQ", tostring(url or "")))
end

return Probe
