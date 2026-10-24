local socket = require("socket")
local UIManager = require("ui/uimanager")
local Probe = require("Legado.Helper.Probe")

local RateGate = {}
RateGate.__index = RateGate

local function default_now()
    return socket.gettime() * 1000
end

local function default_schedule(delay_ms, callback)
    if UIManager and UIManager.scheduleIn then
        return UIManager:scheduleIn(math.max(0, delay_ms) / 1000, callback)
    end
    return nil
end

local function default_unschedule(timer)
    if timer and UIManager and UIManager.unschedule then
        pcall(UIManager.unschedule, UIManager, timer)
    end
end

function RateGate.parse(rate)
    if type(rate) ~= "string" then return nil end
    local count, interval_ms = rate:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
    if not count then
        interval_ms = rate:match("^%s*(%d+)%s*$")
        count = interval_ms and "1" or nil
    end
    count = tonumber(count)
    interval_ms = tonumber(interval_ms)
    if not count or not interval_ms or count < 1 or interval_ms < 1 then
        return nil
    end
    return count, interval_ms
end

function RateGate:new(opts)
    opts = opts or {}
    return setmetatable({
        buckets = {},
        waiters = {},
        now = opts.now or default_now,
        schedule = opts.schedule or default_schedule,
        unschedule = opts.unschedule or default_unschedule,
    }, self)
end

function RateGate:_cancel_timer(bucket)
    if bucket.timer then
        self.unschedule(bucket.timer)
        bucket.timer = nil
    end
end

function RateGate:_schedule(bucket)
    if bucket.timer or #bucket.queue == 0 then return end
    local delay_ms = math.max(0, bucket.started_at + bucket.interval_ms - self.now())
    local callback = function()
        bucket.timer = nil
        self:_drain(bucket)
    end
    bucket.timer = callback
    self.schedule(delay_ms, callback)
    if bucket.timer then
        Probe.eventf("RateLimit", "等待书源并发限制", nil,
            "source=%s rate=%d/%d wait_ms=%d queued=%d",
            tostring(bucket.key), bucket.limit, bucket.interval_ms,
            math.floor(delay_ms + 0.5), #bucket.queue)
    end
end

function RateGate:_drain(bucket)
    local now = self.now()
    if now >= bucket.started_at + bucket.interval_ms then
        bucket.started_at = now
        bucket.used = 0
    end

    while bucket.used < bucket.limit and #bucket.queue > 0 do
        local waiter = table.remove(bucket.queue, 1)
        if self.waiters[waiter.id] == waiter then
            self.waiters[waiter.id] = nil
            if not waiter.is_cancelled or not waiter.is_cancelled() then
                bucket.used = bucket.used + 1
                pcall(waiter.grant)
            end
        end
    end

    if #bucket.queue > 0 then
        self:_schedule(bucket)
    end
end

function RateGate:acquire(key, rate, waiter_id, grant, is_cancelled)
    local limit, interval_ms = RateGate.parse(rate)
    if type(key) ~= "string" or key == "" or not limit or type(grant) ~= "function" then
        if type(grant) == "function" then pcall(grant) end
        return false
    end

    local bucket = self.buckets[key]
    if not bucket then
        bucket = {
            key = key,
            limit = limit,
            interval_ms = interval_ms,
            started_at = self.now(),
            used = 0,
            queue = {},
            timer = nil,
        }
        self.buckets[key] = bucket
    elseif bucket.limit ~= limit or bucket.interval_ms ~= interval_ms then
        self:_cancel_timer(bucket)
        bucket.limit = limit
        bucket.interval_ms = interval_ms
        bucket.started_at = self.now()
        bucket.used = 0
    end

    local id = tostring(waiter_id)
    self:cancel(id)
    local waiter = {
        id = id,
        grant = grant,
        is_cancelled = is_cancelled,
    }
    self.waiters[id] = waiter
    bucket.queue[#bucket.queue + 1] = waiter
    self:_drain(bucket)
    return true
end

function RateGate:cancel(waiter_id)
    local waiter = self.waiters[tostring(waiter_id)]
    if not waiter then return false end
    self.waiters[waiter.id] = nil
    return true
end

function RateGate:cancel_task(task_id)
    local prefix = tostring(task_id) .. ":"
    for id in pairs(self.waiters) do
        if id:sub(1, #prefix) == prefix then
            self.waiters[id] = nil
        end
    end
end

function RateGate:reset(key)
    if key then
        local bucket = self.buckets[key]
        if bucket then
            self:_cancel_timer(bucket)
            for _, waiter in ipairs(bucket.queue) do
                self.waiters[waiter.id] = nil
            end
        end
        self.buckets[key] = nil
    else
        for _, bucket in pairs(self.buckets) do
            self:_cancel_timer(bucket)
        end
        self.buckets = {}
        self.waiters = {}
    end
end

local default_gate = RateGate:new()
default_gate.new = function(_, opts) return RateGate:new(opts) end
default_gate.parse = RateGate.parse

return default_gate
