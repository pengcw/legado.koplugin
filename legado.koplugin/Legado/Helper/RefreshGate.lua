local UIManager = require("ui/uimanager")
local time = require("ui/time")
local Probe = require("Legado.Helper.Probe")

local RefreshGate = {}
RefreshGate.__index = RefreshGate

local function probe_context(context)
    return Probe.context(context and context._warm_trace_id,
        context and context._warm_probe_span)
end

function RefreshGate:new(options)
    options = options or {}
    return setmetatable({
        idle_seconds = tonumber(options.idle_seconds) or 5,
        max_wait_seconds = tonumber(options.max_wait_seconds),
        prepare = options.prepare,
        is_valid = options.is_valid or function() return true end,
        can_refresh = options.can_refresh or function() return true end,
        on_refresh = options.on_refresh or function() end,
        timer = nil,
        input_hook = nil,
        context = nil,
        priority = nil,
        last_input = nil,
        generation = 0,
    }, self)
end

function RefreshGate:_release()
    if self.timer then
        pcall(UIManager.unschedule, UIManager, self.timer)
        self.timer = nil
    end
    if self.input_hook and UIManager.event_hook then
        pcall(UIManager.event_hook.unregister, UIManager.event_hook, "InputEvent", self.input_hook)
        self.input_hook = nil
    end
end

function RefreshGate:cancel()
    self.generation = self.generation + 1
    self:_release()
    self.context = nil
    self.priority = nil
    self.requested_at = nil
    self.preparing = nil
    self.prepared = nil
    self.dispatching = nil
end

function RefreshGate:_ensure_hook()
    if self.input_hook or not UIManager.event_hook then return end
    self.input_hook = function()
        self.last_input = UIManager:getTime()
    end
    UIManager.event_hook:register("InputEvent", self.input_hook)
end

function RefreshGate:_try_refresh(generation)
    local context = self.context
    if not context or generation ~= self.generation or self.dispatching then return end
    if not self.is_valid(context) then
        Probe.eventf("Refresh", "请求失效", probe_context(context),
            "priority=%s book_id=%s", tostring(self.priority), tostring(context.book_cache_id or "-"))
        self:cancel()
        return
    end

    local urgent = self.priority == "urgent"
    local now = UIManager:getTime()
    local idle = now >= (self.last_input or now) + time.s(self.idle_seconds)
    if self.prepare and not self.prepared then
        local max_wait = self.max_wait_seconds and self.requested_at
            and now >= self.requested_at + time.s(self.max_wait_seconds)
        if self.preparing or (not urgent and
                (not self.can_refresh(context) or (not idle and not max_wait))) then
            self:_schedule_check(generation)
            return
        end
        self.preparing = true
        Probe.eventf("Refresh", "准备刷新", probe_context(context),
            "priority=%s max_wait=%s", tostring(self.priority), tostring(max_wait or false))
        self.prepare(self.priority, context, function()
            if generation ~= self.generation then return end
            self.preparing = nil
            self.prepared = true
            self:_try_refresh(generation)
        end)
        return
    end

    if not self.can_refresh(context) or (not urgent and not idle) then
        self:_schedule_check(generation)
        return
    end

    local request_priority = self.priority
    self.dispatching = true
    local current_generation = self.generation
    Probe.eventf("Refresh", "安排刷新", probe_context(context),
        "priority=%s book_id=%s idle=%s", tostring(request_priority),
        tostring(context.book_cache_id or "-"), tostring(idle))
    UIManager:nextTick(function()
        if current_generation ~= self.generation then return end
        self.dispatching = nil
        if not self.is_valid(context) then
            self:cancel()
            Probe.eventf("Refresh", "刷新被丢弃", probe_context(context),
                "generation=%s", tostring(current_generation))
            return
        end
        local now = UIManager:getTime()
        local idle = now >= (self.last_input or now) + time.s(self.idle_seconds)
        if not self.can_refresh(context) or (not urgent and not idle) then
            self:_schedule_check(current_generation)
            return
        end
        self:cancel()
        pcall(self.on_refresh, context)
    end)
end

function RefreshGate:_schedule_check(generation)
    if self.timer or generation ~= self.generation then return end
    local timer = function()
        self.timer = nil
        self:_try_refresh(generation)
    end
    self.timer = timer
    UIManager:scheduleIn(1, timer)
end

function RefreshGate:request(priority, context)
    context = context or {}

    local same_book = self.context
        and self.context.book_cache_id == context.book_cache_id
        and self.context.epub_path == context.epub_path
    if same_book and self.priority == "urgent" then priority = "urgent" end
    local now = UIManager:getTime()
    local requested_at = same_book and not self.preparing and not self.prepared
        and self.requested_at or now

    Probe.eventf("Refresh", "收到刷新请求", probe_context(context),
        "priority=%s book_id=%s", tostring(priority), tostring(context.book_cache_id or "-"))
    self:_release()
    self.context = context
    self.priority = priority == "urgent" and "urgent" or "idle"
    self.last_input = now
    self.requested_at = requested_at
    self.preparing = nil
    self.prepared = nil
    self.dispatching = nil
    self.generation = self.generation + 1
    self:_ensure_hook()
    self:_try_refresh(self.generation)
end

function RefreshGate:destroy()
    Probe.event("Refresh", "释放调度器", "destroy")
    self:cancel()
end

return RefreshGate
