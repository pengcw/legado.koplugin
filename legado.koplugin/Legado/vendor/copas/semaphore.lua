local copas = require("Legado.vendor.copas")

local coroutine_running = coroutine.running
if _VERSION=="Lua 5.1" and not jit then     -- obsolete: only for Lua 5.1 compatibility
  coroutine_running = require("Legado.vendor.coxpcall").running
end

local DEFAULT_TIMEOUT = 10

local semaphore = {}
semaphore.__index = semaphore


-- registry, semaphore indexed by the coroutines using them.
local registry = setmetatable({}, { __mode="kv" })


-- create a new semaphore
-- @param max maximum number of resources the semaphore can hold (this maximum does NOT include resources that have been given but not yet returned).
-- @param start (optional, default 0) the initial resources available
-- @param seconds (optional, default 10) default semaphore timeout in seconds, or `math.huge` to have no timeout.
function semaphore.new(max, start, seconds)
  local timeout = tonumber(seconds or DEFAULT_TIMEOUT) or -1
  if timeout < 0 then
    error("expected timeout (2nd argument) to be a number greater than or equal to 0, got: " .. tostring(seconds), 2)
  end
  if type(max) ~= "number" or max < 1 then
    error("expected max resources (1st argument) to be a number greater than 0, got: " .. tostring(max), 2)
  end

  local self = setmetatable({
      count = start or 0,
      max = max,
      timeout = timeout,
      q_tip = 1,    -- position of next entry waiting
      q_tail = 1,   -- position where next one will be inserted
      queue = {},
      to_flags = setmetatable({}, { __mode = "k" }), -- timeout flags indexed by coroutine
    }, semaphore)

  return self
end


do
  local destroyed_func = function()
    return nil, "destroyed"
  end

  local destroyed_semaphore_mt = {
    __index = function()
      return destroyed_func
    end
  }

  -- destroy a semaphore.
  -- Releases all waiting threads with `nil+"destroyed"`
  function semaphore:destroy()
    self:release_all()
    self.destroyed = true
    setmetatable(self, destroyed_semaphore_mt)
    return true
  end
end


-- Gives resources.
-- @param given (optional, default 1) number of resources to return. Must be
-- a finite number greater than or equal to 0. If more than the maximum are
-- returned then it will be capped at the maximum and error "too many" will
-- be returned.
function semaphore:give(given)
  local err
  given = given or 1
  if given < 0 or given == math.huge or given ~= given then
    error("expected given resources (1st argument) to be a finite number greater than or equal to 0, got: " .. tostring(given), 2)
  end
  local count = self.count + given
  --print("now at",count, ", after +"..given)
  if count > self.max then
    count = self.max
    err = "too many"
  end

  while self.q_tip < self.q_tail do
    local i = self.q_tip
    local nxt = self.queue[i] -- there can be holes, so nxt might be nil
    if not nxt then
      self.q_tip = i + 1
    elseif not copas.issleeping(nxt.co) then
      -- stale entry; 'nxt.co' was canceled externally (eg. via
      -- copas.removethread/future:cancel) and will never resume to
      -- consume or give back resources. Drop it without touching 'count',
      -- and regardless of how much it had requested, so it doesn't block
      -- waiters behind it that request less than it did.
      self.queue[i] = nil
      self.to_flags[nxt.co] = nil
      self.q_tip = i + 1
      nxt.co = nil
    elseif count >= nxt.requested then
      -- release it
      self.queue[i] = nil
      self.to_flags[nxt.co] = nil
      count = count - nxt.requested
      self.q_tip = i + 1
      copas.wakeup(nxt.co)
      nxt.co = nil
    else
      break -- we ran out of resources
    end
  end

  if self.q_tip == self.q_tail then  -- reset queue
    self.queue = {}
    self.q_tip = 1
    self.q_tail = 1
  end

  self.count = count
  if err then
    return nil, err
  end
  return true
end



local function timeout_handler(co)
  local self = registry[co]
  --print("checking timeout ", co)
  if not self then
    return
  end

  for i = self.q_tip, self.q_tail do
    local item = self.queue[i]
    if item and co == item.co then
      self.queue[i] = nil
      self.to_flags[co] = true
      --print("marked timeout ", co)
      copas.wakeup(co)
      return
    end
  end
  -- nothing to do here...
end


-- Requests resources from the semaphore.
-- Waits if there are not enough resources available before returning.
-- @param requested (optional, default 1) the number of resources requested.
-- Must be a number greater than or equal to 1, and not NaN.
-- @param timeout (optional, defaults to semaphore timeout) timeout in
-- seconds. If 0 it will either succeed or return immediately with error "timeout".
-- If `math.huge` it will wait forever.
-- @return true, or nil+"destroyed"
function semaphore:take(requested, timeout)
  requested = requested or 1
  if requested < 1 or requested ~= requested then
    error("expected requested resources (1st argument) to be a number greater than or equal to 1, got: " .. tostring(requested), 2)
  end
  if self.q_tail == 1 and self.count >= requested then
    -- nobody is waiting before us, and there is enough in store
    self.count = self.count - requested
    return true
  end

  if requested > self.max then
    return nil, "too many"
  end

  local to = timeout or self.timeout
  if to == 0 then
    return nil, "timeout"
  end

  -- get in line
  local co = coroutine_running()
  self.to_flags[co] = nil
  registry[co] = self
  copas.timeout(to, timeout_handler)

  self.queue[self.q_tail] = {
    co = co,
    requested = requested,
    --timeout = nil, -- flag indicating timeout
  }
  self.q_tail = self.q_tail + 1

  copas.pauseforever() -- block until woken
  registry[co] = nil

  if self.to_flags[co] then
    -- a timeout happened
    self.to_flags[co] = nil
    return nil, "timeout"
  end

  copas.timeout(0)

  if self.destroyed then
    return nil, "destroyed"
  end

  return true
end

-- returns current available resources
function semaphore:get_count()
  return self.count
end

-- returns total shortage for requested resources
function semaphore:get_wait()
  local wait = 0
  for i = self.q_tip, self.q_tail - 1 do
    local item = self.queue[i]
    if item and copas.issleeping(item.co) then
      wait = wait + item.requested
    end
  end
  return wait - self.count
end


-- Releases every currently queued waiter, regardless of `max`.
-- Feeds `get_wait()` into `give()` in `max`-sized chunks, since a single
-- `give()` call is capped at `max` and would otherwise strand waiters
-- beyond it.
function semaphore:release_all()
  local wait = self:get_wait()
  while wait > 0 do
    if wait > self.max then
      self:give(self.max)
    else
      self:give(wait)
    end
    wait = wait - self.max
  end
end


return semaphore
