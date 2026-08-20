--- Timer wheel implementation
--
-- Efficient timer for timeout related timers: fast insertion, deletion, and
-- execution (all as O(1) implemented), but with lesser precision.
--
-- This module will not provide the timer/runloop itself. Use your own runloop
-- and call `wheel:step` to check and execute timers.
--
-- Implementation:
-- Consider a stack of rings, a timer beyond the current ring size is in the
-- next ring (or beyond). Precision is based on a slot with a specific size.
--
-- The code explicitly avoids using `pairs`, `ipairs` and `next` to ensure JIT
-- compilation when using LuaJIT

local default_now  -- return time in seconds
if ngx then
  default_now = ngx.now
else
  local ok, socket = pcall(require, "socket")
  if ok then
    default_now = socket.gettime
  else
    default_now = nil -- we don't have a default
  end
end

local ok, new_tab = pcall(require, "table.new")
if not ok then
  new_tab = function(narr, nrec) return {} end
end

local xpcall = require("Legado.vendor.coxpcall").xpcall
local default_err_handler = function(err)
  io.stderr:write(debug.traceback("TimerWheel callback failed with: " .. tostring(err)).."\n")
end

local math_floor = math.floor
local math_huge = math.huge
local EMPTY = {}

local _M = {}


--- Creates a new timer wheel.
-- @tparam table opts the options table
-- @tparam[opt=0.050] number opts.precision the precision of the timer wheel in seconds (slot size),
-- @tparam[opt] int opts.ringsize number of slots in each ring, defaults to 72000 (1
-- hour span, with `precision == 0.050`)
-- @tparam[opt] function opts.now a function returning the curent time in seconds. Defaults
-- to `ngx.now` or `luasocket.gettime` if available.
-- @tparam[opt] function opts.err_handler a function to use as error handler in an `xpcall` when
-- executing the callback. The default will write the stacktrace to `stderr`.
-- @treturn wheel the timerwheel object
function _M.new(opts)
  assert(opts ~= _M, "new should not be called with colon ':' notation")

  opts = opts or EMPTY
  assert(type(opts) == "table", "expected options to be a table")

  local precision = opts.precision or 0.050  -- in seconds, 50ms by default
  local ringsize  = opts.ringsize or 72000   -- #slots per ring, default 1 hour = 60 * 60 / 0.050
  local now       = opts.now or default_now  -- function to get time in seconds
  local err_handler = opts.err_handler or default_err_handler
  opts = nil   -- luacheck: ignore

  assert(type(precision) == "number" and precision > 0,
    "expected 'precision' to be number > 0")
  assert(type(ringsize) == "number" and ringsize > 0 and math_floor(ringsize) == ringsize,
    "expected 'ringsize' to be an integer number > 0")
  assert(type(now) == "function",
    "expected 'now' to be a function, got: " .. type(now))
  assert(type(err_handler) == "function",
    "expected 'err_handler' to be a function, got: " .. type(err_handler))

  local start     = now()
  local position  = 1  -- position next up in first ring of timer wheel
  local id_count  = 0  -- counter to generate unique ids (all negative)
  local id_list   = {} -- reverse lookup table to find timers by id
  local rings     = {} -- list of rings, index 1 is the current ring
  local rings_n   = 0  -- the number of the last ring in the rings list
  local count     = 0  -- how many timers do we have
  local wheel     = {} -- the returned wheel object

  -- because we assume hefty setting and cancelling, we're reusing tables
  -- to prevent excessive GC.
  local tables    = {} -- list of tables to be reused
  local tables_n  = 0  -- number of tables in the list

  --- Checks and executes timers.
  -- Call this function (at least) every `precision` seconds.
  -- @return `true`
  function wheel:step()
    local new_position = math_floor((now() - start) / precision) + 1
    local ring = rings[1] or EMPTY

    while position < new_position do

      -- get the expired slot, and remove it from the ring
      local slot = ring[position]
      ring[position] = nil

      -- forward pointers
      position = position + 1
      if position > ringsize then
        -- current ring is done, remove it and forward pointers
        for i = 1, rings_n do
          -- manual loop, since table.remove won't deal with holes
          rings[i] = rings[i + 1]
        end
        rings_n = rings_n - 1

        ring = rings[1] or EMPTY
        start = start + ringsize * precision
        position = 1
        new_position = new_position - ringsize
      end

      -- only deal with slot after forwarding pointers, to make sure that
      -- any cb inserting another timer, does not end up in the slot being
      -- handled
      if slot then
        -- deal with the slot
        local ids = slot.ids
        local args = slot.arg
        for i = 1, slot.n do
          local id  = slot[i];  slot[i]  = nil; slot[id] = nil
          local cb  = ids[id];  ids[id]  = nil
          local arg = args[id]; args[id] = nil
          id_list[id] = nil
          count = count - 1
          xpcall(cb, err_handler, arg)
        end

        slot.n = 0
        -- delete the slot
        tables_n = tables_n + 1
        tables[tables_n] = slot
      end

    end
    return true
  end

  --- Gets the number of timers.
  -- @treturn int number of timers
  function wheel:count()
    return count
  end

  --- Sets a timer.
  -- @tparam number expire_in in how many seconds should the timer expire
  -- @tparam function cb callback function to execute upon expiring (NOTE: the
  -- callback will run within an `xpcall`)
  -- @param arg parameter to be passed to `cb` when executing
  -- @treturn int the id of the newly set timer
  -- @usage
  -- local cb = function(arg)
  --   print("timer executed with: ", arg)  --> "timer executed with: hello world"
  -- end
  -- local id = wheel:set(5, cb, "hello world")
  --
  -- -- do stuff here, while regularly calling `wheel:step()`
  --
  -- wheel:cancel(id)  -- cancel the timer again
  function wheel:set(expire_in, cb, arg)
    local time_expire = now() + expire_in
    local pos = math_floor((time_expire - start) / precision) + 1
    if pos < position then
      -- we cannot set it in the past
      pos = position
    end
    local ring_idx = math_floor((pos - 1) / ringsize) + 1
    local slot_idx = pos - (ring_idx - 1) * ringsize

    -- fetch actual ring table
    local ring = rings[ring_idx]
    if not ring then
      ring = new_tab(ringsize, 0)
      rings[ring_idx] = ring
      if ring_idx > rings_n then
        rings_n = ring_idx
      end
    end

    -- fetch actual slot
    local slot = ring[slot_idx]
    if not slot then
      if tables_n == 0 then
        slot = { n = 0, ids = {}, arg = {} }
      else
        slot = tables[tables_n]
        tables_n = tables_n - 1
      end
      ring[slot_idx] = slot
    end

    -- get new id
    local id = id_count - 1 -- use negative idx to not interfere with array part
    id_count = id

    -- store timer
    -- if we do not do this check, it will go unnoticed and lead to very
    -- hard to find bugs (`count` will go out of sync)
    slot.ids[id] = cb or error("the callback parameter is required", 2)
    slot.arg[id] = arg
    local idx = slot.n + 1
    slot.n = idx
    slot[idx] = id
    slot[id] = idx
    id_list[id] = slot
    count = count + 1

    return id
  end

  --- Cancels a timer.
  -- @tparam int id the timer id to cancel
  -- @treturn boolean `true` if cancelled, `false` if not found
  function wheel:cancel(id)
    local slot = id_list[id]
    if slot then
      local idx = slot[id]
      slot[id] = nil
      slot.ids[id] = nil
      slot.arg[id] = nil
      local n = slot.n
      if idx ~= n then
        local moved_id = slot[n]
        slot[idx] = moved_id
        slot[moved_id] = idx
      end
      slot[n] = nil
      slot.n = n - 1
      id_list[id] = nil
      count = count - 1
      return true
    end
    return false
  end

  --- Looks up the next expiring timer.
  -- Note: traverses the wheel, O(n) operation!
  -- @tparam[opt] number max_ahead maximum time (in seconds)
  -- to look ahead
  -- @treturn number number of seconds until next timer expires (can be negative), or
  -- 'nil' if there is no timer from now to `max_ahead`
  -- @usage
  -- local t = wheel:peek(10)
  -- if t then
  --   print("next timer expires in ", t," seconds")
  -- else
  --   print("no timer scheduled for the next 10 seconds")
  -- end
  function wheel:peek(max_ahead)
    if count == 0 then
      return nil
    end
    local time_now = now()

    -- convert max_ahead from seconds to positions
    if max_ahead then
      max_ahead = math_floor((time_now + max_ahead - start) / precision)
    else
      max_ahead = math_huge
    end

    local position_idx = position
    local ring_idx = 1
    local ring = rings[ring_idx] or EMPTY -- TODO: if EMPTY then we can skip it?
    local ahead_count = 0
    while ahead_count < max_ahead do

      local slot = ring[position_idx]
      if slot then
        if slot[1] then
          -- we have a timer
          return ((ring_idx - 1) * ringsize + position_idx) * precision +
                 start - time_now
        end
      end

      -- there is nothing in this position
      position_idx = position_idx + 1
      ahead_count = ahead_count + 1
      if position_idx > ringsize then
        position_idx = 1
        ring_idx = ring_idx + 1
        ring = rings[ring_idx] or EMPTY
      end
    end

    -- we hit max_ahead, without finding a timer
    return nil
  end

  if _G._TEST then   -- export test variables only when testing
    -- wheel._rings = rings
    wheel._tables = tables
  end

  return wheel
end

return _M
