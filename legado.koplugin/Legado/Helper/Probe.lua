local logger = require("logger")

local Probe = {
    ENABLED = false,
    LOG_LEVEL = "info",
    DETAIL_LEVEL = "verbose",
    CATEGORIES = nil,
    _http_inflight = 0,
    _http_seq = 0,
    _spore_inflight = 0,
    _spore_seq = 0,
    _span_seq = 0,
}

local DISABLED_SPAN = { disabled = true }
local socket_mod
local copas_checked = false
local copas_mod

local function now()
    if not socket_mod then socket_mod = require("socket") end
    return socket_mod.gettime()
end

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

local function get_copas()
    if not copas_checked then
        copas_checked = true
        local ok, loaded = pcall(require, "Legado.vendor.copas")
        if ok then
            copas_mod = loaded
            init_copas_thread_tracking(copas_mod)
        end
    end
    return copas_mod
end

get_copas()

local function category_enabled(category)
    local categories = Probe.CATEGORIES
    return categories == nil or categories[category or "Net"] == true
end

local function should_emit(category, kind)
    if not Probe.ENABLED or not category_enabled(category) then return false end
    local level = Probe.DETAIL_LEVEL
    if level == "errors" then
        return kind == "fail" or kind == "retry"
    elseif level == "lifecycle" then
        return kind ~= "event"
    end
    return true
end

local function resolve(value)
    if type(value) ~= "function" then return value end
    local ok, resolved = pcall(value)
    if ok then return resolved end
    return "<probe supplier error>"
end

local function span_id(span)
    return type(span) == "table" and span.span_id or nil
end

local function started_at(span)
    if type(span) == "table" then return span.started_at end
    if type(span) == "number" then return span end
end

local function elapsed_ms(span, finished_at)
    local started = started_at(span)
    return started and math.floor((finished_at - started) * 1000 + 0.5) or 0
end

local function format_context(context, span, timestamp)
    local tags = {}
    local trace_id = type(context) == "table" and context.trace_id or nil
    if trace_id ~= nil and trace_id ~= "" then
        tags[#tags + 1] = string.format("[trace=%s]", tostring(trace_id))
    end
    local id = span_id(span)
    if id then tags[#tags + 1] = string.format("[span=%s]", id) end
    local parent = type(context) == "table" and context.parent_span or nil
    if parent then tags[#tags + 1] = string.format("[parent=%s]", tostring(parent)) end
    if timestamp then tags[#tags + 1] = string.format("[ts=%.6f]", timestamp) end
    return #tags > 0 and (" " .. table.concat(tags, " ")) or ""
end

local function log(message)
    local writer = logger[Probe.LOG_LEVEL] or logger.info
    writer(message)
end

function Probe.set_enabled(enabled)
    Probe.ENABLED = enabled == true
end

function Probe.is_enabled(category, kind)
    return should_emit(category, kind or "event")
end

function Probe.set_categories(categories)
    Probe.CATEGORIES = categories
end

function Probe.set_detail_level(level)
    if level ~= "errors" and level ~= "lifecycle" and level ~= "verbose" then
        return false, "invalid probe detail level"
    end
    Probe.DETAIL_LEVEL = level
    return true
end

function Probe.is_copas()
    local co = coroutine.running()
    if not co then return false end

    local copas = get_copas()
    if copas then
        if copas.running then return true end
        if copas._active_threads and copas._active_threads[co] then return true end
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

function Probe.context(trace_id, parent)
    local parent_id = type(parent) ~= "table" and parent or span_id(parent)
    if (trace_id == nil or trace_id == "") and parent_id == nil then return nil end
    return {
        trace_id = trace_id ~= nil and trace_id ~= "" and tostring(trace_id) or nil,
        parent_span = parent_id,
    }
end

function Probe.child_context(context, parent)
    local parent_id = (type(parent) ~= "table" and parent or span_id(parent))
        or (type(context) == "table" and context.parent_span or nil)
    local trace_id = type(context) == "table" and context.trace_id or nil
    if not trace_id and not parent_id then return nil end
    return {
        trace_id = trace_id,
        parent_span = parent_id,
    }
end

function Probe.start(category, action, url, timeout_info, context)
    if not Probe.ENABLED or not category_enabled(category) then return DISABLED_SPAN end
    local timestamp = now()
    Probe._span_seq = Probe._span_seq + 1
    local span = {
        started_at = timestamp,
        span_id = string.format("%x-%d", math.floor(timestamp * 1000000), Probe._span_seq),
    }
    if not should_emit(category, "start") then return span end
    local mode_tag = Probe.get_mode_tag()
    local context_tag = format_context(context, span, timestamp)
    local timeout = resolve(timeout_info)
    local to_str = timeout and (" " .. tostring(timeout)) or ""
    log(string.format("[%sProbe] ▶ [START] [%s]%s %s %s%s",
        category or "Net", mode_tag, context_tag, resolve(action) or "REQ",
        tostring(resolve(url) or ""), to_str))
    return span
end

function Probe.done(category, action, url, t_start, status_code, size_or_summary, ext, context)
    if t_start == DISABLED_SPAN or not should_emit(category, "done") then return end
    local timestamp = now()
    local elapsed = elapsed_ms(t_start, timestamp)
    local mode_tag = Probe.get_mode_tag()
    local context_tag = format_context(context, t_start, timestamp)
    local resolved_ext = resolve(ext)
    local ext_tag = (resolved_ext and resolved_ext ~= "" and resolved_ext ~= "-")
        and (string.format("[%s] ", resolved_ext)) or ""
    log(string.format("[%sProbe] ✔ [DONE: %s] [%dms] [%s] %s[%s]%s %s %s",
        category or "Net", tostring(resolve(status_code) or "200 OK"), elapsed,
        tostring(resolve(size_or_summary) or "-"), ext_tag, mode_tag, context_tag,
        resolve(action) or "REQ", tostring(resolve(url) or "")))
end

function Probe.fail(category, action, url, t_start, reason, context)
    if t_start == DISABLED_SPAN or not should_emit(category, "fail") then return end
    local timestamp = now()
    local elapsed = elapsed_ms(t_start, timestamp)
    local mode_tag = Probe.get_mode_tag()
    local context_tag = format_context(context, t_start, timestamp)
    log(string.format("[%sProbe] ✘ [FAIL: %s] [%dms] [%s]%s %s %s",
        category or "Net", tostring(resolve(reason) or "未知错误"), elapsed,
        mode_tag, context_tag, resolve(action) or "REQ", tostring(resolve(url) or "")))
end

function Probe.retry(category, action, url, t_start, reason, context)
    if t_start == DISABLED_SPAN or not should_emit(category, "retry") then return end
    local timestamp = now()
    local elapsed = elapsed_ms(t_start, timestamp)
    local mode_tag = Probe.get_mode_tag()
    local context_tag = format_context(context, t_start, timestamp)
    log(string.format("[%sProbe] ↺ [RETRY: %s] [%dms] [%s]%s %s %s",
        category or "Net", tostring(resolve(reason) or "重试中"), elapsed,
        mode_tag, context_tag, resolve(action) or "REQ", tostring(resolve(url) or "")))
end

function Probe.event(category, action, detail, context)
    if not should_emit(category, "event") then return end
    local timestamp = now()
    local mode_tag = Probe.get_mode_tag()
    local context_tag = format_context(context, nil, timestamp)
    log(string.format("[%sProbe] • [%s]%s [%s] %s",
        category or "Net", mode_tag, context_tag, resolve(action) or "EVENT",
        tostring(resolve(detail) or "")))
end

function Probe.eventf(category, action, context, fmt, ...)
    if not should_emit(category, "event") then return end
    Probe.event(category, action, string.format(fmt, ...), context)
end

function Probe.http_enter(url)
    if not should_emit("Http", "event") then return nil end
    Probe._http_seq = Probe._http_seq + 1
    Probe._http_inflight = Probe._http_inflight + 1
    local co = coroutine.running()
    local token = {
        id = Probe._http_seq,
        co = co and tostring(co) or "main",
        url = tostring(url or ""),
    }
    Probe.event("Http", "ENTER", function()
        return string.format("req=%d active=%d co=%s %s",
            token.id, Probe._http_inflight, token.co, token.url)
    end)
    return token
end

function Probe.http_leave(token, outcome)
    if not token then return end
    Probe._http_inflight = math.max(0, Probe._http_inflight - 1)
    if not should_emit("Http", "event") then return end
    Probe.event("Http", "LEAVE", function()
        return string.format("req=%d active=%d co=%s outcome=%s",
            token.id, Probe._http_inflight, token.co, tostring(outcome or "return"))
    end)
end

function Probe.spore_enter(action)
    if not should_emit("Spore", "event") then return nil end
    Probe._spore_seq = Probe._spore_seq + 1
    Probe._spore_inflight = Probe._spore_inflight + 1
    local co = coroutine.running()
    local token = {
        id = Probe._spore_seq,
        co = co and tostring(co) or "main",
        action = tostring(action or "request"),
    }
    Probe.event("Spore", "ENTER", function()
        return string.format("req=%d active=%d co=%s action=%s",
            token.id, Probe._spore_inflight, token.co, token.action)
    end)
    return token
end

function Probe.spore_leave(token, outcome)
    if not token then return end
    Probe._spore_inflight = math.max(0, Probe._spore_inflight - 1)
    if not should_emit("Spore", "event") then return end
    Probe.event("Spore", "LEAVE", function()
        return string.format("req=%d active=%d co=%s action=%s outcome=%s",
            token.id, Probe._spore_inflight, token.co, token.action, tostring(outcome or "return"))
    end)
end

return Probe
