local copas = require("Legado.vendor.copas")
local gettime = copas.gettime

local coroutine_running = coroutine.running
if _VERSION=="Lua 5.1" and not jit then     -- obsolete: only for Lua 5.1 compatibility
  coroutine_running = require("Legado.vendor.coxpcall").running
end

local DEFAULT_TIMEOUT = 10

local lock = {}
lock.__index = lock


-- registry, locks indexed by the coroutines using them.
local registry = setmetatable({}, { __mode="kv" })



--- Creates a new lock.
-- @param seconds (optional) default timeout in seconds when acquiring the lock (defaults to 10),
-- set to `math.huge` to have no timeout.
-- @param not_reentrant (optional) if truthy the lock will not allow a coroutine to grab the same lock multiple times
-- @return the lock object
function lock.new(seconds, not_reentrant)
  local timeout = tonumber(seconds or DEFAULT_TIMEOUT) or -1
  if timeout < 0 then
    error("expected timeout (1st argument) to be a number greater than or equal to 0, got: " .. tostring(seconds), 2)
  end
  return setmetatable({
            timeout = timeout,
            not_reentrant = not_reentrant,
            queue = {},
            q_tip = 0,  -- index of the first in line waiting
            q_tail = 0, -- index where the next one will be inserted
            owner = nil, -- coroutine holding lock currently
            call_count = nil, -- recursion call count
            errors = setmetatable({}, { __mode = "k" }), -- error indexed by coroutine
          }, lock)
end



do
  local destroyed_func = function()
    return nil, "destroyed"
  end

  local destroyed_lock_mt = {
    __index = function()
      return destroyed_func
    end
  }

  --- destroy a lock.
  -- Releases all waiting threads with `nil+"destroyed"`
  function lock:destroy()
    --print("destroying ",self)
    for i = self.q_tip, self.q_tail do
      local co = self.queue[i]
      self.queue[i] = nil

      if co then
        self.errors[co] = "destroyed"
        --print("marked destroyed ", co)
        copas.wakeup(co)
      end
    end

    if self.owner then
      self.errors[self.owner] = "destroyed"
      --print("marked destroyed ", co)
    end
    self.queue = {}
    self.q_tip = 0
    self.q_tail = 0
    self.destroyed = true

    setmetatable(self, destroyed_lock_mt)
    return true
  end
end


local function timeout_handler(co)
  local self = registry[co]
  if not self then
    return
  end

  for i = self.q_tip, self.q_tail do
    if co == self.queue[i] then
      self.queue[i] = nil
      self.errors[co] = "timeout"
      --print("marked timeout ", co)
      copas.wakeup(co)
      return
    end
  end
  -- if we get here, we own it currently, or we finished it by now, or
  -- the lock was destroyed. Anyway, nothing to do here...
end


--- Acquires the lock.
-- If the lock is owned by another thread, this will yield control, until the
-- lock becomes available, or it times out.
-- If `timeout == 0` then it will immediately return (without yielding).
-- @param timeout (optional) timeout in seconds, defaults to the timeout passed to `new` (use `math.huge` to have no timeout).
-- @return wait-time on success, or nil+error+wait_time on failure. Errors can be "timeout", "destroyed", or "lock is not re-entrant"
function lock:get(timeout)
  local co = coroutine_running()
  local start_time

  -- is the lock already taken?
  if self.owner then
    -- are we re-entering?
    if co == self.owner and not self.not_reentrant then
      self.call_count = self.call_count + 1
      return 0
    end

    timeout = timeout or self.timeout
    if timeout == 0 then
      return nil, "timeout", 0
    end

    self.queue[self.q_tail] = co
    self.q_tail = self.q_tail + 1

    -- set up timeout
    registry[co] = self
    copas.timeout(timeout, timeout_handler)

    start_time = gettime()
    copas.pauseforever()

    local err = self.errors[co]
    self.errors[co] = nil
    registry[co] = nil

    --print("released ", co, err)
    if err ~= "timeout" then
      copas.timeout(0)
    end
    if err then
      return nil, err, gettime() - start_time
    end
  end

  -- it's ours to have
  self.owner = co
  self.call_count = 1
  return start_time and (gettime() - start_time) or 0
end


--- Releases the lock currently held.
-- Releasing a lock that is not owned by the current co-routine will return
-- an error.
-- returns true, or nil+err on an error
function lock:release()
  local co = coroutine_running()

  if co ~= self.owner then
    return nil, "cannot release a lock not owned"
  end

  self.call_count = self.call_count - 1
  if self.call_count > 0 then
    -- same coro is still holding it
    return true
  end

  -- need a loop, since individual coroutines might have been removed
  -- (or canceled externally, eg. via `copas.removethread`/`future:cancel`)
  -- so there might be holes, or stale entries whose wakeup will fail
  while self.q_tip < self.q_tail do
    local next_up = self.queue[self.q_tip]
    self.queue[self.q_tip] = nil
    self.q_tip = self.q_tip + 1
    if next_up and copas.wakeup(next_up) then
      self.owner = next_up
      return true
    end
    -- either an empty hole, or 'next_up' was canceled and will never resume
    -- to release the lock itself, so move on to the next waiter in line
  end
  -- queue is empty, reset pointers
  self.owner = nil
  self.q_tip = 0
  self.q_tail = 0
  return true
end



return lock
