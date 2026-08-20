-------------------------------------------------------------------------------
-- Copas - Coroutine Oriented Portable Asynchronous Services
--
-- A dispatcher based on coroutines that can be used by TCP/IP servers.
-- Uses LuaSocket as the interface with the TCP/IP stack.
--
-- Authors: Andre Carregal, Javier Guerra, and Fabio Mascarenhas
-- Contributors: Diego Nehab, Mike Pall, David Burgess, Leonardo Godinho,
--               Thomas Harning Jr., and Gary NG
--
-- Copyright 2005-2013 - Kepler Project (www.keplerproject.org), 2015-2026 Thijs Schreijer
--
-- $Id: copas.lua,v 1.37 2009/04/07 22:09:52 carregal Exp $
-------------------------------------------------------------------------------


-- load either LuaSocket, or LuaSystem
-- note: with luasocket we don't use 'sleep' but 'select' with no sockets
local socket, system do
  if pcall(require, "socket") then
    -- found LuaSocket
    socket = require "socket"
  end

  -- try LuaSystem as fallback
  if pcall(require, "system") then
    system = require "system"
  end

  if not (socket or system) then
    error("Neither LuaSocket nor LuaSystem found, Copas requires at least one of them")
  end
end

local binaryheap = require "Legado.vendor.binaryheap"
local gettime = (socket or system).gettime
local block_sleep = (socket or system).sleep
local ssl -- only loaded upon demand

local core_timer_thread
local WATCH_DOG_TIMEOUT = 120
local UDP_DATAGRAM_MAX = (socket or {})._DATAGRAMSIZE or 8192
local TIMEOUT_PRECISION = 0.1  -- 100ms
local fnil = function() end


local coroutine_create = coroutine.create
local coroutine_running = coroutine.running
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status


-- nil-safe versions for pack/unpack
local _unpack = unpack or table.unpack
local unpack = function(t, i, j) return _unpack(t, i or 1, j or t.n or #t) end
local pack = function(...) return { n = select("#", ...), ...} end


local pcall = pcall
if _VERSION=="Lua 5.1" and not jit then     -- obsolete: only for Lua 5.1 compatibility
  pcall = require("Legado.vendor.coxpcall").pcall
  coroutine_running = require("Legado.vendor.coxpcall").running
end

-- 仅恢复协程安全的 socket.protect（Lua 实现）：copas.http/ftp 的 request 用 protect 包装，
-- 原始 luasocket 的 protect 是 C 实现，会在 copas yield 时触发 "yield across C-call boundary"。
-- 不重定义 socket.newtry/try（它们的 err_mt intermediate table 会污染 socket.http 错误路径——
-- 真实 bug：getBookshelf "Copas 'try' error intermediate table"）。
do
  local function statusHandler(status, ...)
    if status then return ... end
    local err = (...)
    if type(err) == "table" and getmetatable(err) == nil then
      return nil, err
    else
      error(err)
    end
  end

  function socket.protect(func)
    return function (...)
            return statusHandler(pcall(func, ...))
          end
  end
end




-- Setup the Copas meta table to auto-load submodules and define a default method
local copas do
  local submodules = { "ftp", "future", "http", "lock", "queue", "semaphore", "smtp", "timer" }
  for i, key in ipairs(submodules) do
    submodules[key] = true
    submodules[i] = nil
  end

  copas = setmetatable({},{
    __index = function(self, key)
      if submodules[key] then
        self[key] = require("Legado.vendor.copas."..key)
        submodules[key] = nil
        return rawget(self, key)
      end
    end,
    __call = function(self, ...)
      return self.loop(...)
    end,
  })
end


-- Meta information is public even if beginning with an "_"
copas._COPYRIGHT   = "Copyright (C) 2005-2013 Kepler Project, 2015-2026 Thijs Schreijer"
copas._DESCRIPTION = "Coroutine Oriented Portable Asynchronous Services"
copas._VERSION     = "Copas 4.12.0"

-- Close the socket associated with the current connection after the handler finishes
copas.autoclose = true

-- indicator for the loop running
copas.running = false

-- gettime method from either LuaSocket or LuaSystem: time in (fractional) seconds, since epoch.
copas.gettime = gettime

-------------------------------------------------------------------------------
-- Object names, to track names of thread/coroutines and sockets
-------------------------------------------------------------------------------
local object_names = setmetatable({}, {
  __mode = "k",
  __index = function(self, key)
    local name = tostring(key)
    if key ~= nil then
      rawset(self, key, name)
    end
    return name
  end
})

-------------------------------------------------------------------------------
-- Simple set implementation
-- tracks at the waiting coroutine per socket in the set.
-- Sets exist for reading and writing. So each socket can have a reader and writer
-- simultaneously, but only one reader and one writer at a time.
-------------------------------------------------------------------------------

local function newsocketset()
  local set = {}

  do  -- set implementation
    local reverse = {}

    -- Adds a socket to the set, does nothing if it exists
    -- @return skt if added, or nil if it existed
    function set:insert(skt)
      if not reverse[skt] then
        self[#self + 1] = skt
        reverse[skt] = #self
        return skt
      end
    end

    -- Removes socket from the set, does nothing if not found
    -- @return skt if removed, or nil if it wasn't in the set
    function set:remove(skt)
      local index = reverse[skt]
      if index then
        reverse[skt] = nil
        local top = self[#self]
        self[#self] = nil
        if top ~= skt then
          reverse[top] = index
          self[index] = top
        end
        return skt
      end
    end

  end

  do  -- single-waiter implementation
    -- the set instance (read or write) determines what operation the coroutine is waiting for
    local waiters = setmetatable({}, { __mode = "k" }) -- coroutine by socket

    -- Registers the coroutine as the socket's waiter, to be resumed
    -- once the socket becomes ready.
    -- @return true on success, or nil + error message if another coroutine
    -- is already waiting on this socket read/write.
    function set:claim(skt, co)
      if waiters[skt] then
        return nil, "Operation already in progress"
      end
      waiters[skt] = co
      return true
    end

    -- Clears and returns the coroutine waiting on the socket read/write operation, or nil if
    -- none is waiting.
    function set:release(skt)
      local co = waiters[skt]
      waiters[skt] = nil
      return co
    end

    -- Drops the socket from the set and discards its waiting coroutine (if
    -- any), without resuming it. Only call this when the socket is being
    -- discarded outright and no waiter is expected to be woken through the
    -- normal readiness path (e.g. the socket object itself is being thrown
    -- away). Do not use this as a general substitute for `remove`: if a
    -- waiter still needs to observe the outcome (for example a coroutine
    -- waiting on a socket that is being closed, which is resumed via the
    -- normal tick()/release() path with a "closed" result), purging here
    -- would silently drop it instead.
    function set:purge(skt)
      waiters[skt] = nil
      self:remove(skt)
    end

  end

  return set
end



-- Threads immediately resumable
local _resumable = {} do
  local resumelist = {}

  function _resumable:push(co)
    resumelist[#resumelist + 1] = co
  end

  function _resumable:clear_resumelist()
    local lst = resumelist
    resumelist = {}
    return lst
  end

  function _resumable:done()
    return resumelist[1] == nil
  end

  function _resumable:count()
    return #resumelist + #_resumable
  end

end



-- Similar to the socket set above, but tailored for the use of
-- sleeping threads
local _sleeping = {} do

  local heap = binaryheap.minUnique()
  local lethargy = setmetatable({}, { __mode = "k" }) -- list of coroutines sleeping without a wakeup time


  -- Required base implementation
  -----------------------------------------
  _sleeping.insert = fnil
  _sleeping.remove = fnil

  -- push a new timer on the heap
  function _sleeping:push(sleeptime, co)
    if sleeptime < 0 then
      lethargy[co] = true
    elseif sleeptime == 0 then
      _resumable:push(co)
    else
      heap:insert(gettime() + sleeptime, co)
    end
  end

  -- find the thread that should wake up to the time, if any
  function _sleeping:pop(time)
    if time < (heap:peekValue() or math.huge) then
      return
    end
    return heap:pop()
  end

  -- additional methods for time management
  -----------------------------------------
  function _sleeping:getnext()  -- returns delay until next sleep expires, or nil if there is none
    local t = heap:peekValue()
    if t then
      -- never report less than 0, because select() might block
      return math.max(t - gettime(), 0)
    end
  end

  function _sleeping:wakeup(co)
    if lethargy[co] then
      lethargy[co] = nil
      _resumable:push(co)
      return true
    end
    if heap:remove(co) then
      _resumable:push(co)
      return true
    end
    return nil, "not sleeping"
  end

  -- non-destructive check; unlike wakeup/cancel it doesn't remove 'co'
  function _sleeping:issleeping(co)
    if lethargy[co] then
      return true
    end
    return heap:valueByPayload(co) ~= nil
  end

  function _sleeping:cancel(co)
    lethargy[co] = nil
    heap:remove(co)
  end

  function _sleeping:cancelall()
    while heap:size() > 0 do heap:pop() end
    heap:insert(gettime() + TIMEOUT_PRECISION, core_timer_thread)
    -- lethargy is weak; copas's idle GC sweeps will clean it within a few steps
  end

  -- @param tos number of timeouts running
  function _sleeping:done(tos)
    -- return true if we have nothing more to do
    -- the timeout task doesn't qualify as work (fallbacks only),
    -- the lethargy also doesn't qualify as work ('dead' tasks),
    -- but the combination of a timeout + a lethargy can be work
    return heap:size() == 1       -- 1 means only the timeout-timer task is running
           and not (tos > 0 and next(lethargy))
  end

  -- gets number of threads in binaryheap and lethargy
  function _sleeping:status()
    local c = 0
    for _ in pairs(lethargy) do c = c + 1 end

    return heap:size(), c
  end

end   -- _sleeping



-------------------------------------------------------------------------------
-- Tracking coroutines and sockets
-------------------------------------------------------------------------------

local _servers = newsocketset() -- servers being handled
local _threads = setmetatable({}, {__mode = "k"})  -- registered threads added with addthread()
local _canceled = setmetatable({}, {__mode = "k"}) -- threads that are canceled and pending removal
local _autoclose = setmetatable({}, {__mode = "kv"}) -- sockets (value) to close when a thread (key) exits
local _autoclose_r = setmetatable({}, {__mode = "kv"}) -- reverse: sockets (key) to close when a thread (value) exits


-- for each socket we log the last read and last write times to enable the
-- watchdog to follow up if it takes too long.
-- tables contain the time, indexed by the socket
local _reading_log = {}
local _writing_log = {}

local _closed = {} -- track sockets that have been closed (list/array)

local _reading = newsocketset() -- sockets currently being read
local _writing = newsocketset() -- sockets currently being written
local _isSocketTimeout = { -- set of errors indicating a socket-timeout
  ["timeout"] = true,      -- default LuaSocket timeout
  ["wantread"] = true,     -- LuaSec specific timeout
  ["wantwrite"] = true,    -- LuaSec specific timeout
}

-------------------------------------------------------------------------------
-- Coroutine based socket timeouts.
-------------------------------------------------------------------------------
local user_timeouts_connect
local user_timeouts_send
local user_timeouts_receive
do
  local timeout_mt = {
    __mode = "k",
    __index = function(self, skt)
      -- if there is no timeout found, we insert one automatically, to block forever
      self[skt] = math.huge
      return self[skt]
    end,
  }

  user_timeouts_connect = setmetatable({}, timeout_mt)
  user_timeouts_send = setmetatable({}, timeout_mt)
  user_timeouts_receive = setmetatable({}, timeout_mt)
end

local useSocketTimeoutErrors = setmetatable({},{ __mode = "k" })


-- sto = socket-time-out
local sto_timeout, sto_timed_out, sto_change_queue, sto_error do

  local socket_register = setmetatable({}, { __mode = "k" })    -- socket by coroutine
  local operation_register = setmetatable({}, { __mode = "k" }) -- operation "read"/"write" by coroutine
  local timeout_flags = setmetatable({}, { __mode = "k" })      -- true if timedout, by coroutine


  -- The callback called when a socket timeout occurs.
  local function socket_callback(co)
    local skt = socket_register[co]
    local queue = operation_register[co]

    -- flag the timeout and resume the coroutine
    timeout_flags[co] = true
    _resumable:push(co)

    -- release our claim on the socket and stop watching it; the timer, not
    -- the readiness path, is resuming `co`, so nothing else will do this
    if queue == "read" then
      _reading:release(skt)
      _reading:remove(skt)
    elseif queue == "write" then
      _writing:release(skt)
      _writing:remove(skt)
    else
      error("bad queue name; expected 'read'/'write', got: "..tostring(queue))
    end
  end


  -- Sets a socket timeout.
  -- Calling it as `sto_timeout()` will cancel the timeout.
  -- @param skt (socket) the socket on which to operate, use 'nil' to cancel the current timeout
  -- @param queue (string) the queue the socket is currently in: "read" or "write"
  -- @param use_connect_to (bool) if truthy, use the connect timeout instead of the
  --   read/write timeout implied by queue. Needed because connect also uses the "write"
  --   queue, so the queue value alone cannot distinguish connect from send operations.
  -- @return true
  function sto_timeout(skt, queue, use_connect_to)
    local co = coroutine_running()
    socket_register[co] = skt
    operation_register[co] = queue
    timeout_flags[co] = nil
    if skt then
      local to = (use_connect_to and user_timeouts_connect[skt]) or
                 (queue == "read" and user_timeouts_receive[skt]) or
                 user_timeouts_send[skt]
      copas.timeout(to, socket_callback)
    else
      copas.timeout(0)
    end
    return true
  end


  -- Changes the timeout to a different queue (read/write).
  -- Only usefull with ssl-handshakes and "wantread", "wantwrite" errors, when
  -- the queue has to be changed, so the timeout handler knows where to find the socket.
  -- @param queue (string) the new queue the socket is in, must be either "read" or "write"
  -- @return true
  function sto_change_queue(queue)
    operation_register[coroutine_running()] = queue
    return true
  end


  -- Responds with `true` if the operation timed-out.
  function sto_timed_out()
    return timeout_flags[coroutine_running()]
  end


  -- Returns the proper timeout error
  function sto_error(err)
    return useSocketTimeoutErrors[coroutine_running()] and err or "timeout"
  end


  -- only in case of testing export some internals
  if _G._TEST then
    copas._socket_register = socket_register
    copas._operation_register = operation_register
    copas._timeout_flags = timeout_flags
  end
end



-------------------------------------------------------------------------------
-- Coroutine based socket I/O functions.
-------------------------------------------------------------------------------

-- Claims the socket for the current coroutine and yields to wait for it to
-- become ready, returning `true` once resumed.
-- @return nil + error if another coroutine is already waiting on this
-- socket (a bug in the caller, not a Copas failure).
local function wait_on(queue, skt)
  local claimed, err = queue:claim(skt, coroutine_running())
  if not claimed then
    return nil, err
  end
  queue:insert(skt)
  coroutine_yield(skt, queue)
  return true
end


-- Returns "tcp"" for plain TCP and "ssl" for ssl-wrapped sockets, so truthy
-- for tcp based, and falsy for udp based.
local isTCP do
  local lookup = {
    tcp = "tcp",
    SSL = "ssl",
  }

  function isTCP(socket)
    return lookup[tostring(socket):sub(1,3)]
  end
end


-- POSIX: a 0-byte read on a stream socket (TCP/SSL) is a no-op and must
-- return immediately without waiting on `select`. UDP is different: a
-- 0-byte datagram is a distinct payload, so it must still wait.
-- See https://github.com/lunarmodules/copas/issues/223
local function is_zero_byte_tcp_read(client, pattern)
  return pattern == 0 and isTCP(client)
end


function copas.close(skt, ...)
  _closed[#_closed+1] = skt
  return skt:close(...)
end


-- nil or negative is indefinitly
function copas.settimeout(skt, timeout)
  timeout = timeout or -1
  if type(timeout) ~= "number" then
    return nil, "timeout must be 'nil' or a number"
  end

  return copas.settimeouts(skt, timeout, timeout, timeout)
end


-- negative is indefinitly, nil means do not change
function copas.settimeouts(skt, connect, send, read)

  if connect ~= nil and type(connect) ~= "number" then
    return nil, "connect timeout must be 'nil' or a number"
  end
  if connect then
    if connect < 0 then
      connect = nil
    end
    user_timeouts_connect[skt] = connect
  end


  if send ~= nil and type(send) ~= "number" then
    return nil, "send timeout must be 'nil' or a number"
  end
  if send then
    if send < 0 then
      send = nil
    end
    user_timeouts_send[skt] = send
  end


  if read ~= nil and type(read) ~= "number" then
    return nil, "read timeout must be 'nil' or a number"
  end
  if read then
    if read < 0 then
      read = nil
    end
    user_timeouts_receive[skt] = read
  end


  return true
end

-- reads a pattern from a client and yields to the reading set on timeouts
-- UDP: a UDP socket expects a second argument to be a number, so it MUST
-- be provided as the 'pattern' below defaults to a string. Will throw a
-- 'bad argument' error if omitted.
-- SECURITY: the default pattern "*l" has no maximum length, matching LuaSocket
-- and Lua file-io semantics. It buffers until a newline/EOF/error, and the
-- per-operation timeout resets on every partial receive, so it does not bound
-- the accumulated size either. Do not use the default line-read directly on
-- untrusted/remote input without an application-enforced size limit; use a
-- numeric (sized) pattern or receivepartial with your own cumulative cap instead.
function copas.receive(client, pattern, part)
  if is_zero_byte_tcp_read(client, pattern) then
    copas.pause() -- yield so a tight receive(0) loop can't starve other coroutines
    return part or "", nil, nil
  end

  local s, err
  pattern = pattern or "*l"
  local current_log = _reading_log
  sto_timeout(client, "read")

  repeat
    s, err, part = client:receive(pattern, part)

    -- guarantees that high throughput doesn't take other threads to starvation
    if (math.random(100) > 90) then
      copas.pause()
    end

    if s then
      current_log[client] = nil
      sto_timeout()
      return s, err, part

    elseif not _isSocketTimeout[err] then
      current_log[client] = nil
      sto_timeout()
      return s, err, part

    elseif sto_timed_out() then
      current_log[client] = nil
      sto_timeout()
      return nil, sto_error(err), part
    end

    local queue, direction
    if err == "wantwrite" then -- wantwrite may be returned during SSL renegotiations
      queue = _writing
      direction = "write"
      current_log = _writing_log
    else
      queue = _reading
      direction = "read"
      current_log = _reading_log
    end

    current_log[client] = gettime()
    sto_change_queue(direction)
    local ok, werr = wait_on(queue, client)
    if not ok then
      current_log[client] = nil
      sto_timeout()
      return nil, werr, part
    end
  until false
end

-- receives data from a client over UDP. Not available for TCP.
-- (this is a copy of receive() method, adapted for receivefrom() use)
function copas.receivefrom(client, size)
  local s, err, port
  size = size or UDP_DATAGRAM_MAX
  sto_timeout(client, "read")

  repeat
    s, err, port = client:receivefrom(size) -- upon success err holds ip address

    -- garantees that high throughput doesn't take other threads to starvation
    if (math.random(100) > 90) then
      copas.pause()
    end

    if s then
      _reading_log[client] = nil
      sto_timeout()
      return s, err, port

    elseif err ~= "timeout" then
      _reading_log[client] = nil
      sto_timeout()
      return s, err, port

    elseif sto_timed_out() then
      _reading_log[client] = nil
      sto_timeout()
      return nil, sto_error(err), port
    end

    _reading_log[client] = gettime()
    local ok, werr = wait_on(_reading, client)
    if not ok then
      _reading_log[client] = nil
      sto_timeout()
      return nil, werr, port
    end
  until false
end

-- same as above but with special treatment when reading chunks,
-- unblocks on any data received.
function copas.receivepartial(client, pattern, part)
  if is_zero_byte_tcp_read(client, pattern) then
    copas.pause() -- yield so a tight receive(0) loop can't starve other coroutines
    return part or "", nil, nil
  end

  local s, err
  pattern = pattern or "*l"
  local orig_size = #(part or "")
  local current_log = _reading_log
  sto_timeout(client, "read")

  repeat
    s, err, part = client:receive(pattern, part)

    -- guarantees that high throughput doesn't take other threads to starvation
    if (math.random(100) > 90) then
      copas.pause()
    end

    if s or (type(part) == "string" and #part > orig_size) then
      current_log[client] = nil
      sto_timeout()
      return s, err, part

    elseif not _isSocketTimeout[err] then
      current_log[client] = nil
      sto_timeout()
      return s, err, part

    elseif sto_timed_out() then
      current_log[client] = nil
      sto_timeout()
      return nil, sto_error(err), part
    end

    local queue, direction
    if err == "wantwrite" then
      queue = _writing
      direction = "write"
      current_log = _writing_log
    else
      queue = _reading
      direction = "read"
      current_log = _reading_log
    end

    current_log[client] = gettime()
    sto_change_queue(direction)
    local ok, werr = wait_on(queue, client)
    if not ok then
      current_log[client] = nil
      sto_timeout()
      return nil, werr, part
    end
  until false
end
copas.receivePartial = copas.receivepartial  -- compat: receivePartial is deprecated

-- sends data to a client. The operation is buffered and
-- yields to the writing set on timeouts
-- Note: from and to parameters will be ignored by/for UDP sockets
function copas.send(client, data, from, to)
  local s, err
  from = from or 1
  local lastIndex = from - 1
  local current_log = _writing_log
  sto_timeout(client, "write")

  repeat
    s, err, lastIndex = client:send(data, lastIndex + 1, to)

    -- guarantees that high throughput doesn't take other threads to starvation
    if (math.random(100) > 90) then
      copas.pause()
    end

    if s then
      current_log[client] = nil
      sto_timeout()
      return s, err, lastIndex

    elseif not _isSocketTimeout[err] then
      current_log[client] = nil
      sto_timeout()
      return s, err, lastIndex

    elseif sto_timed_out() then
      current_log[client] = nil
      sto_timeout()
      return nil, sto_error(err), lastIndex
    end

    local queue, direction
    if err == "wantread" then
      queue = _reading
      direction = "read"
      current_log = _reading_log
    else
      queue = _writing
      direction = "write"
      current_log = _writing_log
    end

    current_log[client] = gettime()
    sto_change_queue(direction)
    local ok, werr = wait_on(queue, client)
    if not ok then
      current_log[client] = nil
      sto_timeout()
      return nil, werr, lastIndex
    end
  until false
end

function copas.sendto(client, data, ip, port)
  -- deprecated; for backward compatibility only, since UDP doesn't block on sending
  return client:sendto(data, ip, port)
end

-- waits until connection is completed
function copas.connect(skt, host, port)
  skt:settimeout(0)
  local ret, err, tried_more_than_once
  sto_timeout(skt, "write", true)

  repeat
    ret, err = skt:connect(host, port)

    -- non-blocking connect on Windows results in error "Operation already
    -- in progress" to indicate that it is completing the request async. So essentially
    -- it is the same as "timeout"
    if ret or (err ~= "timeout" and err ~= "Operation already in progress") then
      _writing_log[skt] = nil
      sto_timeout()
      -- Once the async connect completes, Windows returns the error "already connected"
      -- to indicate it is done, so that error should be ignored. Except when it is the
      -- first call to connect, then it was already connected to something else and the
      -- error should be returned
      if (not ret) and (err == "already connected" and tried_more_than_once) then
        return 1
      end
      return ret, err

    elseif sto_timed_out() then
      _writing_log[skt] = nil
      sto_timeout()
      return nil, sto_error(err)
    end

    tried_more_than_once = tried_more_than_once or true
    _writing_log[skt] = gettime()
    local ok, werr = wait_on(_writing, skt)
    if not ok then
      _writing_log[skt] = nil
      sto_timeout()
      return nil, werr
    end
  until false
end


-- Wraps a tcp socket in an ssl socket and configures it. If the socket was
-- already wrapped, it does nothing and returns the socket.
-- @param wrap_params the parameters for the ssl-context
-- @return wrapped socket, or throws an error
local function ssl_wrap(skt, wrap_params)
  if isTCP(skt) == "ssl" then return skt end -- was already wrapped
  if not wrap_params then
    error("cannot wrap socket into a secure socket (using 'ssl.wrap()') without parameters/context")
  end

  ssl = ssl or require("ssl")
  local nskt = assert(ssl.wrap(skt, wrap_params)) -- assert, because we do not want to silently ignore this one!!

  -- KOReader plugin patch: honor wrap_params.sni (luasec SNI must be set before handshake;
  -- Cloudflare/Envoy terminate connections without SNI). luasec's sni() has inconsistent
  -- return conventions across versions, so failures are ignored (same as SSEClient).
  if wrap_params.sni and nskt.sni then
    pcall(nskt.sni, nskt, wrap_params.sni)
  end

  nskt:settimeout(0)  -- non-blocking on the ssl-socket
  copas.settimeouts(nskt, user_timeouts_connect[skt],
    user_timeouts_send[skt], user_timeouts_receive[skt]) -- copy copas user-timeout to newly wrapped one

  local co = _autoclose_r[skt]
  if co then
    -- socket registered for autoclose, move registration to wrapped one
    _autoclose[co] = nskt
    _autoclose_r[skt] = nil
    _autoclose_r[nskt] = co
  end

  local sock_name = object_names[skt]
  if sock_name ~= tostring(skt) then
    -- socket had a custom name, so copy it over
    object_names[nskt] = sock_name
  end
  return nskt
end


-- For each luasec method we have a subtable, allows for future extension.
-- Required structure:
-- {
--   wrap = ... -- parameter to 'wrap()'; the ssl parameter table, or the context object
--   sni = {                  -- parameters to 'sni()'
--     names = string | table -- 1st parameter
--     strict = bool          -- 2nd parameter
--   }
-- }
local function normalize_sslt(sslt)
  local t = type(sslt)
  local r = setmetatable({}, {
    __index = function(self, key)
      -- a bug if this happens, here as a sanity check, just being careful since
      -- this is security stuff
      error("accessing unknown 'ssl_params' table key: "..tostring(key))
    end,
  })
  if t == "nil" then
    r.wrap = false
    r.sni = false

  elseif t == "table" then
    if sslt.wrap or sslt.sni then
      -- has the target definition (current format), copy our known keys
      r.wrap = sslt.wrap or false -- 'or false' because we do not want nils
      r.sni = sslt.sni or false -- 'or false' because we do not want nils
    else
      -- neither of our own keys is truthy, so treat it as a flat luasec
      -- context/wrap-params table (backward compatibility), or garbage.
      -- There are no default TLS settings, so we cannot detect/reject a bad
      -- table here. But we do not need to; LuaSec validates its mandatory
      -- fields (mode, protocol, etc.) itself and throws on anything
      -- incomplete, so this can never fail open into silent plaintext.
      r.wrap = sslt
      r.sni = false
    end

  elseif t == "userdata" then
    -- it's an ssl-context object for the handshake
    -- backward compatibility
    r.wrap = sslt
    r.sni = false

  else
    error("ssl parameters; did not expect type "..tostring(sslt))
  end

  return r
end


---
-- Peforms an (async) ssl handshake on a connected TCP client socket.
-- NOTE: if not ssl-wrapped already, then replace all previous socket references, with the returned new ssl wrapped socket
-- Throws error and does not return nil+error, as that might silently fail
-- in code like this;
--   copas.addserver(s1, function(skt)
--       skt = copas.wrap(skt, sparams)
--       skt:dohandshake()   --> without explicit error checking, this fails silently and
--       skt:send(body)      --> continues unencrypted
-- @param skt Regular LuaSocket CLIENT socket object
-- @param wrap_params Table with ssl parameters
-- @return wrapped ssl socket, or throws an error
function copas.dohandshake(skt, wrap_params)
  ssl = ssl or require("ssl")

  local nskt = ssl_wrap(skt, wrap_params)

  sto_timeout(nskt, "write", true)
  local queue

  repeat
    local success, err = nskt:dohandshake()

    if success then
      sto_timeout()
      return nskt

    elseif not _isSocketTimeout[err] then
      sto_timeout()
      error("TLS/SSL handshake failed: " .. tostring(err))

    elseif sto_timed_out() then
      sto_timeout()
      error("TLS/SSL handshake timeout: " .. tostring(err))

    elseif err == "wantwrite" then
      sto_change_queue("write")
      queue = _writing

    elseif err == "wantread" then
      sto_change_queue("read")
      queue = _reading

    else
      error("TLS/SSL handshake failed: " .. tostring(err))
    end

    local ok, werr = wait_on(queue, nskt)
    if not ok then
      sto_timeout()
      error("TLS/SSL handshake failed: " .. tostring(werr))
    end
  until false
end

-- flushes a client write buffer (deprecated)
function copas.flush()
end

-- wraps a TCP socket to use Copas methods (send, receive, flush and settimeout)
local _skt_mt_tcp = {
      __tostring = function(self)
        return tostring(self.socket).." (copas wrapped)"
      end,

      __index = {
        send = function (self, data, from, to)
          return copas.send (self.socket, data, from, to)
        end,

        receive = function (self, pattern, prefix)
          if user_timeouts_receive[self.socket] == 0 then
            return copas.receivepartial(self.socket, pattern, prefix)
          end
          return copas.receive(self.socket, pattern, prefix)
        end,

        receivepartial = function (self, pattern, prefix)
          return copas.receivepartial(self.socket, pattern, prefix)
        end,

        flush = function (self)
          return copas.flush(self.socket)
        end,

        settimeout = function (self, time)
          return copas.settimeout(self.socket, time)
        end,

        settimeouts = function (self, connect, send, receive)
          return copas.settimeouts(self.socket, connect, send, receive)
        end,

        -- TODO: socket.connect is a shortcut, and must be provided with an alternative
        -- if ssl parameters are available, it will also include a handshake
        connect = function(self, ...)
          local res, err = copas.connect(self.socket, ...)
          -- sni errors out if it fails, so we do not need to check for errors here.
          -- sni() itself returns nothing on success, so its result must not be folded into 'res'.
          if res then
            if self.ssl_params.sni then self:sni() end
            if self.ssl_params.wrap then res, err = self:dohandshake() end
          end
          return res, err
        end,

        close = function(self, ...)
          return copas.close(self.socket, ...)
        end,

        -- TODO: socket.bind is a shortcut, and must be provided with an alternative
        bind = function(self, ...) return self.socket:bind(...) end,

        -- TODO: is this DNS related? hence blocking?
        getsockname = function(self, ...)
          local ok, ip, port, family = pcall(self.socket.getsockname, self.socket, ...)
          if ok then
            return ip, port, family
          else
            return nil, "not implemented by LuaSec"
          end
        end,

        getstats = function(self, ...) return self.socket:getstats(...) end,

        setstats = function(self, ...) return self.socket:setstats(...) end,

        listen = function(self, ...) return self.socket:listen(...) end,

        accept = function(self, ...) return self.socket:accept(...) end,

        setoption = function(self, ...)
          local ok, res, err = pcall(self.socket.setoption, self.socket, ...)
          if ok then
            return res, err
          else
            return nil, "not implemented by LuaSec"
          end
        end,

        getoption = function(self, ...)
          local ok, val, err = pcall(self.socket.getoption, self.socket, ...)
          if ok then
            return val, err
          else
            return nil, "not implemented by LuaSec"
          end
        end,

        -- TODO: is this DNS related? hence blocking?
        getpeername = function(self, ...)
          local ok, ip, port, family = pcall(self.socket.getpeername, self.socket, ...)
          if ok then
            return ip, port, family
          else
            return nil, "not implemented by LuaSec"
          end
        end,

        shutdown = function(self, ...) return self.socket:shutdown(...) end,

        sni = function(self, names, strict)
          local sslp = self.ssl_params
          self.socket = ssl_wrap(self.socket, sslp.wrap)
          if names == nil then
            names = sslp.sni.names
            strict = sslp.sni.strict
          end
          -- sni() throws on bad parameters by itself, and returns nothing on success
          return self.socket:sni(names, strict)
        end,

        dohandshake = function(self, wrap_params)
          -- copas.dohandshake() either returns the wrapped ssl socket, or throws
          self.socket = copas.dohandshake(self.socket, wrap_params or self.ssl_params.wrap)
          return self
        end,

        getalpn = function(self, ...)
          local ok, proto, err = pcall(self.socket.getalpn, self.socket, ...)
          if ok then
            return proto, err
          else
            return nil, "not a tls socket"
          end
        end,

        getsniname = function(self, ...)
          local ok, name, err = pcall(self.socket.getsniname, self.socket, ...)
          if ok then
            return name, err
          else
            return nil, "not a tls socket"
          end
        end,
      }
}

-- wraps a UDP socket, copy of TCP one adapted for UDP.
local _skt_mt_udp = {__index = { }}
for k,v in pairs(_skt_mt_tcp) do _skt_mt_udp[k] = _skt_mt_udp[k] or v end
for k,v in pairs(_skt_mt_tcp.__index) do _skt_mt_udp.__index[k] = v end

_skt_mt_udp.__index.send        = function(self, ...) return self.socket:send(...) end

_skt_mt_udp.__index.sendto      = function(self, ...) return self.socket:sendto(...) end


_skt_mt_udp.__index.receive =     function (self, size)
                                    return copas.receive (self.socket, (size or UDP_DATAGRAM_MAX))
                                  end

_skt_mt_udp.__index.receivefrom = function (self, size)
                                    return copas.receivefrom (self.socket, (size or UDP_DATAGRAM_MAX))
                                  end

                                  -- TODO: is this DNS related? hence blocking?
_skt_mt_udp.__index.setpeername = function(self, ...) return self.socket:setpeername(...) end

_skt_mt_udp.__index.setsockname = function(self, ...) return self.socket:setsockname(...) end

                                    -- do not close client, as it is also the server for udp.
_skt_mt_udp.__index.close       = function(self, ...) return true end

_skt_mt_udp.__index.settimeouts = function (self, connect, send, receive)
                                    return copas.settimeouts(self.socket, connect, send, receive)
                                  end



---
-- Wraps a LuaSocket socket object in an async Copas based socket object.
-- @param skt The socket to wrap
-- @param[opt] sslt Table with ssl parameters (see 'sslparams' in the reference docs).
-- Omit the parameter to disable TLS entirely.
-- @return wrapped socket object
function copas.wrap (skt, sslt)
  if (getmetatable(skt) == _skt_mt_tcp) or (getmetatable(skt) == _skt_mt_udp) then
    return skt -- already wrapped
  end

  skt:settimeout(0)

  if isTCP(skt) then
    return setmetatable ({socket = skt, ssl_params = normalize_sslt(sslt)}, _skt_mt_tcp)
  else
    return setmetatable ({socket = skt}, _skt_mt_udp)
  end
end

--- Wraps a handler in a function that deals with wrapping the socket and doing the
-- optional ssl handshake.
function copas.handler(handler, sslparams)
  -- TODO: pass a timeout value to set, and use during handshake
  return function (skt, ...)
    skt = copas.wrap(skt, sslparams) -- this call will normalize the sslparams table
    local sslp = skt.ssl_params
    -- sni doesn't return an error, just throws on bad params, so no error checking needed.
    -- the wrapped dohandshake does the same, so also no error handling needed.
    if sslp.sni then skt:sni(sslp.sni.names, sslp.sni.strict) end
    if sslp.wrap then skt:dohandshake(sslp.wrap) end
    return handler(skt, ...)
  end
end


--------------------------------------------------
-- Error handling
--------------------------------------------------

local _errhandlers = setmetatable({}, { __mode = "k" })   -- error handler per coroutine


function copas.gettraceback(msg, co, skt)
  local co_str = co == nil and "nil" or copas.getthreadname(co)
  local skt_str = skt == nil and "nil" or copas.getsocketname(skt)
  local msg_str = msg == nil and "" or tostring(msg)
  if msg_str == "" then
    msg_str = ("(coroutine: %s, socket: %s)"):format(msg_str, co_str, skt_str)
  else
    msg_str = ("%s (coroutine: %s, socket: %s)"):format(msg_str, co_str, skt_str)
  end

  if type(co) == "thread" then
    -- regular Copas coroutine
    return debug.traceback(co, msg_str)
  end
  -- not a coroutine, but the main thread, this happens if a timeout callback
  -- (see `copas.timeout` causes an error (those callbacks run on the main thread).
  return debug.traceback(msg_str, 2)
end


local function _deferror(msg, co, skt)
  print(copas.gettraceback(msg, co, skt))
end


function copas.seterrorhandler(err, default)
  assert(err == nil or type(err) == "function", "Expected the handler to be a function, or nil")
  if default then
    assert(err ~= nil, "Expected the handler to be a function when setting the default")
    _deferror = err
  else
    _errhandlers[coroutine_running()] = err
  end
end
copas.setErrorHandler = copas.seterrorhandler  -- deprecated; old casing


function copas.geterrorhandler(co)
  co = co or coroutine_running()
  return _errhandlers[co] or _deferror
end


-- if `bool` is truthy, then the original socket errors will be returned in case of timeouts;
-- `timeout, wantread, wantwrite, Operation already in progress`. If falsy, it will always
-- return `timeout`.
function copas.useSocketTimeoutErrors(bool)
  useSocketTimeoutErrors[coroutine_running()] = not not bool -- force to a boolean
end

-------------------------------------------------------------------------------
-- Thread handling
-------------------------------------------------------------------------------

local function _doTick (co, skt, ...)
  if not co then return end

  -- if a coroutine was canceled/removed, don't resume it
  if _canceled[co] then
    _canceled[co] = nil -- also clean up the registry
    _threads[co] = nil
    return
  end

  -- res: the socket (being read/write on) or the time to sleep
  -- new_q: either _writing, _reading, or _sleeping
  -- local time_before = gettime()
  local ok, res, new_q = coroutine_resume(co, skt, ...)
  -- local duration = gettime() - time_before
  -- if duration > 1 then
  --   duration = math.floor(duration * 1000)
  --   pcall(_errhandlers[co] or _deferror, "task ran for "..tostring(duration).." milliseconds.", co, skt)
  -- end

  if new_q == _reading or new_q == _writing then
    -- we're yielding to wait on a socket; the claim was already taken by
    -- the coroutine itself before it yielded (see wait_on below), so by
    -- construction this can't fail here
    new_q:insert (res)
    return
  elseif new_q == _sleeping then
    -- we're yielding to sleep
    new_q:insert (res)
    new_q:push (res, co)
    return
  end

  -- coroutine is terminating

  if ok and coroutine_status(co) ~= "dead" then
    -- it called coroutine.yield from a non-Copas function which is unexpected
    ok = false
    res = "coroutine.yield was called without a resume first, user-code cannot yield to Copas"
  end

  if not ok then
    local k, e = pcall(_errhandlers[co] or _deferror, res, co, skt)
    if not k then
      print("Failed executing error handler: " .. tostring(e))
    end
  end

  local skt_to_close = _autoclose[co]
  if skt_to_close then
    skt_to_close:close()
    _autoclose[co] = nil
    _autoclose_r[skt_to_close] = nil
  end

  _errhandlers[co] = nil
end


local _accept do
  local client_counters = setmetatable({}, { __mode = "k" })

  -- accepts a connection on socket input
  function _accept(server_skt, handler)
    local client_skt = server_skt:accept()
    if client_skt then
      local count = (client_counters[server_skt] or 0) + 1
      client_counters[server_skt] = count
      object_names[client_skt] = object_names[server_skt] .. ":client_" .. count

      client_skt:settimeout(0)
      copas.settimeouts(client_skt, user_timeouts_connect[server_skt],  -- copy server socket timeout settings
        user_timeouts_send[server_skt], user_timeouts_receive[server_skt])

      local co = coroutine_create(handler)
      object_names[co] = object_names[server_skt] .. ":handler_" .. count

      if copas.autoclose then
        _autoclose[co] = client_skt
        _autoclose_r[client_skt] = co
      end

      _doTick(co, client_skt)
    end
  end
end

-------------------------------------------------------------------------------
-- Adds a server/handler pair to Copas dispatcher
-------------------------------------------------------------------------------

do
  local function addTCPserver(server, handler, timeout, name)
    server:settimeout(0)
    if name then
      object_names[server] = name
    end
    _servers[server] = handler
    _reading:insert(server)
    if timeout then
      copas.settimeout(server, timeout)
    end
  end

  local function addUDPserver(server, handler, timeout, name)
    server:settimeout(0)
    local co = coroutine_create(handler)
    if name then
      object_names[server] = name
    end
    object_names[co] = object_names[server]..":handler"
    _reading:insert(server)
    if timeout then
      copas.settimeout(server, timeout)
    end
    _doTick(co, server)
  end


  function copas.addserver(server, handler, timeout, name)
    if isTCP(server) then
      addTCPserver(server, handler, timeout, name)
    else
      addUDPserver(server, handler, timeout, name)
    end
  end
end


function copas.removeserver(server, keep_open)
  local skt = server
  local mt = getmetatable(server)
  if mt == _skt_mt_tcp or mt == _skt_mt_udp then
    skt = server.socket
  end

  _servers:remove(skt)
  _reading:remove(skt)

  if keep_open then
    return true
  end
  return server:close()
end



-------------------------------------------------------------------------------
-- Adds an new coroutine thread to Copas dispatcher
-------------------------------------------------------------------------------
function copas.addnamedthread(name, handler, ...)
  if type(name) == "function" and type(handler) == "string" then
    -- old call, flip args for compatibility
    name, handler = handler, name
  end

  -- create a coroutine that skips the first argument, which is always the socket
  -- passed by the scheduler, but `nil` in case of a task/thread
  local thread = coroutine_create(function(_, ...)
    copas.pause()
    return handler(...)
  end)
  if name then
    object_names[thread] = name
  end

  _threads[thread] = true -- register this thread so it can be removed
  _doTick (thread, nil, ...)
  return thread
end


function copas.addthread(handler, ...)
  return copas.addnamedthread(nil, handler, ...)
end


function copas.removethread(thread)
  -- if the specified coroutine is registered, add it to the canceled table so
  -- that next time it tries to resume it exits.
  _canceled[thread] = _threads[thread or 0]
  _sleeping:cancel(thread)
end



-------------------------------------------------------------------------------
-- Sleep/pause management functions
-------------------------------------------------------------------------------

-- yields the current coroutine and wakes it after 'sleeptime' seconds.
-- If sleeptime < 0 then it sleeps until explicitly woken up using 'wakeup'
-- TODO: deprecated, remove in next major
function copas.sleep(sleeptime)
  coroutine_yield((sleeptime or 0), _sleeping)
end


-- yields the current coroutine and wakes it after 'sleeptime' seconds.
-- if sleeptime < 0 then it sleeps 0 seconds.
function copas.pause(sleeptime)
  local s = gettime()
  if sleeptime and sleeptime > 0 then
    coroutine_yield(sleeptime, _sleeping)
  else
    coroutine_yield(0, _sleeping)
  end
  return gettime() - s
end


-- yields the current coroutine until explicitly woken up using 'wakeup'
function copas.pauseforever()
  local s = gettime()
  coroutine_yield(-1, _sleeping)
  return gettime() - s
end


-- Wakes up a sleeping coroutine 'co'.
-- @return true on success, or nil+"not sleeping" if 'co' wasn't sleeping
-- (eg. it was already woken up, finished, or canceled through `copas.removethread`).
function copas.wakeup(co)
  return _sleeping:wakeup(co)
end


-- Checks whether a coroutine 'co' is currently sleeping (paused or
-- paused-forever), without waking it up. Useful to detect a coroutine
-- that was canceled (eg. through `copas.removethread`) while it was
-- expected to still be waiting.
function copas.issleeping(co)
  return _sleeping:issleeping(co)
end



-------------------------------------------------------------------------------
-- Timeout management
-------------------------------------------------------------------------------

do
  local timeout_register = setmetatable({}, { __mode = "k" })
  local timerwheel = require("Legado.vendor.timerwheel").new({
      now = gettime,
      precision = TIMEOUT_PRECISION,
      ringsize = math.floor(60*60*24/TIMEOUT_PRECISION),  -- ring size 1 day
      err_handler = function(err)
        return _deferror(err, core_timer_thread)
      end,
    })

  core_timer_thread = copas.addnamedthread("copas_core_timer", function()
    while true do
      copas.pause(TIMEOUT_PRECISION)
      timerwheel:step()
    end
  end)

  -- get the number of timeouts running
  function copas.gettimeouts()
    return timerwheel:count()
  end

  --- Sets the timeout for the current coroutine.
  -- @param delay delay (seconds), use 0 (or math.huge) to cancel the timerout
  -- @param callback function with signature: `function(coroutine)` where coroutine is the routine that timed-out
  -- @return true
  function copas.timeout(delay, callback)
    local co = coroutine_running()
    local existing_timer = timeout_register[co]

    if existing_timer then
      timerwheel:cancel(existing_timer)
    end

    if delay > 0 and delay ~= math.huge then
      timeout_register[co] = timerwheel:set(delay, callback, co)
    elseif delay == 0 or delay == math.huge then
      timeout_register[co] = nil
    else
      error("timout value must be greater than or equal to 0, got: "..tostring(delay))
    end

    return true
  end

end


-------------------------------------------------------------------------------
-- main tasks: manage readable and writable socket sets
-------------------------------------------------------------------------------
-- a task is an object with a required method `step()` that deals with a
-- single step for that task.

local _tasks = {} do
  function _tasks:add(tsk)
    _tasks[#_tasks + 1] = tsk
  end
end


-- a task to check ready to read events
local _readable_task = {} do

  _readable_task._events = {}

  local function tick(skt)
    local handler = _servers[skt]
    if handler then
      _accept(skt, handler)
    else
      _reading:remove(skt)
      _doTick(_reading:release(skt), skt)
    end
  end

  function _readable_task:step()
    for _, skt in ipairs(self._events) do
      tick(skt)
    end
  end

  _tasks:add(_readable_task)
end


-- a task to check ready to write events
local _writable_task = {} do

  _writable_task._events = {}

  local function tick(skt)
    _writing:remove(skt)
    _doTick(_writing:release(skt), skt)
  end

  function _writable_task:step()
    for _, skt in ipairs(self._events) do
      tick(skt)
    end
  end

  _tasks:add(_writable_task)
end



-- sleeping threads task
local _sleeping_task = {} do

  function _sleeping_task:step()
    local now = gettime()

    local co = _sleeping:pop(now)
    while co do
      -- we're pushing them to _resumable, since that list will be replaced before
      -- executing. This prevents tasks running twice in a row with pause(0) for example.
      -- So here we won't execute, but at _resumable step which is next
      _resumable:push(co)
      co = _sleeping:pop(now)
    end
  end

  _tasks:add(_sleeping_task)
end



-- resumable threads task
local _resumable_task = {} do

  function _resumable_task:step()
    -- replace the resume list before iterating, so items placed in there
    -- will indeed end up in the next copas step, not in this one, and not
    -- create a loop
    local resumelist = _resumable:clear_resumelist()

    for _, co in ipairs(resumelist) do
      _doTick(co)
    end
  end

  _tasks:add(_resumable_task)
end


-------------------------------------------------------------------------------
-- Checks for reads and writes on sockets
-------------------------------------------------------------------------------
local _select_plain do

  local last_cleansing = 0
  local duration = function(t2, t1) return t2-t1 end

  if not socket then
    -- socket module unavailable, switch to luasystem sleep
    _select_plain = block_sleep
  else
    -- use socket.select to handle socket-io
    _select_plain = function(timeout)
      local err
      local now = gettime()

      -- remove any closed sockets to prevent select from hanging on them
      if _closed[1] then
        for i, skt in ipairs(_closed) do
          _closed[i] = { _reading:remove(skt), _writing:remove(skt) }
        end
      end

      _readable_task._events, _writable_task._events, err = socket.select(_reading, _writing, timeout)
      local r_events, w_events = _readable_task._events, _writable_task._events

      -- inject closed sockets in readable/writeable task so they can error out properly
      if _closed[1] then
        for i, skts in ipairs(_closed) do
          _closed[i] = nil
          r_events[#r_events+1] = skts[1]
          w_events[#w_events+1] = skts[2]
        end
      end

      if duration(now, last_cleansing) > WATCH_DOG_TIMEOUT then
        last_cleansing = now

        -- Check all sockets selected for reading, and check how long they have been waiting
        -- for data already, without select returning them as readable
        for skt,time in pairs(_reading_log) do
          if not r_events[skt] and duration(now, time) > WATCH_DOG_TIMEOUT then
            -- This one timedout while waiting to become readable, so move
            -- it in the readable list and try and read anyway, despite not
            -- having been returned by select
            _reading_log[skt] = nil
            r_events[#r_events + 1] = skt
            r_events[skt] = #r_events
          end
        end

        -- Do the same for writing
        for skt,time in pairs(_writing_log) do
          if not w_events[skt] and duration(now, time) > WATCH_DOG_TIMEOUT then
            _writing_log[skt] = nil
            w_events[#w_events + 1] = skt
            w_events[skt] = #w_events
          end
        end
      end

      if err == "timeout" and #r_events + #w_events > 0 then
        return nil
      else
        return err
      end
    end
  end
end



-------------------------------------------------------------------------------
-- Dispatcher loop step.
-- Listen to client requests and handles them
-- Returns false if no socket-data was handled, or true if there was data
-- handled (or nil + error message)
-------------------------------------------------------------------------------

local copas_stats
local min_ever, max_ever

local _select = _select_plain

-- instrumented version of _select() to collect stats
local _select_instrumented = function(timeout)
  if copas_stats then
    local step_duration = gettime() - copas_stats.step_start
    copas_stats.duration_max = math.max(copas_stats.duration_max, step_duration)
    copas_stats.duration_min = math.min(copas_stats.duration_min, step_duration)
    copas_stats.duration_tot = copas_stats.duration_tot + step_duration
    copas_stats.steps = copas_stats.steps + 1
  else
    copas_stats = {
      duration_max = -1,
      duration_min = 999999,
      duration_tot = 0,
      steps = 0,
    }
  end

  local err = _select_plain(timeout)

  local now = gettime()
  copas_stats.time_start = copas_stats.time_start or now
  copas_stats.step_start = now

  return err
end


function copas.step(timeout)
  -- Need to wake up the select call in time for the next sleeping event
  if not _resumable:done() then
    timeout = 0
  else
    timeout = math.min(_sleeping:getnext(), timeout or math.huge)
  end

  local err = _select(timeout)

  for _, tsk in ipairs(_tasks) do
    tsk:step()
  end

  if err then
    if err == "timeout" then
      if timeout + 0.01 > TIMEOUT_PRECISION and math.random(100) > 90 then
        -- we were idle, so occasionally do a GC sweep to ensure lingering
        -- sockets are closed, and we don't accidentally block the loop from
        -- exiting
        collectgarbage()
      end
      return false
    end
    return nil, err
  end

  return true
end


-------------------------------------------------------------------------------
-- Check whether there is something to do.
-- returns false if there are no sockets for read/write nor tasks scheduled
-- (which means Copas is in an empty spin)
-------------------------------------------------------------------------------
function copas.finished()
  return #_reading == 0 and #_writing == 0 and _resumable:done() and _sleeping:done(copas.gettimeouts())
end


local resetexit do
  local exit_semaphore, exiting

  function resetexit()
    exit_semaphore = copas.semaphore.new(1, 0, math.huge)
    exiting = false
  end

  -- Signals tasks to exit. But only if they check for it. By calling `copas.exiting`
  -- they can check if they should exit. Or by calling `copas.waitforexit` they can
  -- wait until the exit signal is given.
  function copas.exit()
    if exiting then return end
    exiting = true
    exit_semaphore:destroy()
  end

  -- returns whether Copas is in the process of exiting. Exit can be started by
  -- calling `copas.exit()`.
  function copas.exiting()
    return exiting
  end

  -- Pauses the current coroutine until Copas is exiting. To be used as an exit
  -- signal for tasks that need to clean up before exiting.
  function copas.waitforexit()
    exit_semaphore:take(1)
  end
end


--- Forcibly cancels all pending work and signals exit.
-- Intended for test teardown only. Abandons all registered threads and sockets
-- without giving them a chance to clean up. After this call copas.finished()
-- will return true and the loop will exit. The module is left in a clean state
-- ready for the next copas.loop() call.
function copas.cancelall()
  -- 1. clear resumable queue
  _resumable:clear_resumelist()

  -- 2. drain sleeping heap
  _sleeping:cancelall()

  -- 3. close and drain reading sockets
  while _reading[1] do
    copas.close(_reading[1])
    _reading:remove(_reading[1])
  end

  -- 4. close and drain writing sockets
  while _writing[1] do
    copas.close(_writing[1])
    _writing:remove(_writing[1])
  end

  -- 5. remove all servers
  while _servers[1] do
    copas.removeserver(_servers[1])
  end

  -- 6. clear non-weak ancillary tables
  _closed = {}
  _reading_log = {}
  _writing_log = {}

  -- 7. signal exit
  copas.exit()
end


local _getstats do
  local _getstats_instrumented, _getstats_plain


  function _getstats_plain(enable)
    -- this function gets hit if turned off, so turn on if true
    if enable == true then
      _select = _select_instrumented
      _getstats = _getstats_instrumented
      -- reset stats
      min_ever = nil
      max_ever = nil
      copas_stats = nil
    end
    return {}
  end


  -- convert from seconds to millisecs, with microsec precision
  local function useconds(t)
    return math.floor((t * 1000000) + 0.5) / 1000
  end
  -- convert from seconds to seconds, with millisec precision
  local function mseconds(t)
    return math.floor((t * 1000) + 0.5) / 1000
  end


  function _getstats_instrumented(enable)
    if enable == false then
      _select = _select_plain
      _getstats = _getstats_plain
      -- instrumentation disabled, so switch to the plain implementation
      return _getstats(enable)
    end
    if (not copas_stats) or (copas_stats.step == 0) then
      return {}
    end
    local stats = copas_stats
    copas_stats = nil
    min_ever = math.min(min_ever or 9999999, stats.duration_min)
    max_ever = math.max(max_ever or 0, stats.duration_max)
    stats.duration_min_ever = min_ever
    stats.duration_max_ever = max_ever
    stats.duration_avg = stats.duration_tot / stats.steps
    stats.step_start = nil
    stats.time_end = gettime()
    stats.time_tot = stats.time_end - stats.time_start
    stats.time_avg = stats.time_tot / stats.steps

    stats.duration_avg = useconds(stats.duration_avg)
    stats.duration_max = useconds(stats.duration_max)
    stats.duration_max_ever = useconds(stats.duration_max_ever)
    stats.duration_min = useconds(stats.duration_min)
    stats.duration_min_ever = useconds(stats.duration_min_ever)
    stats.duration_tot = useconds(stats.duration_tot)
    stats.time_avg = useconds(stats.time_avg)
    stats.time_start = mseconds(stats.time_start)
    stats.time_end = mseconds(stats.time_end)
    stats.time_tot = mseconds(stats.time_tot)
    return stats
  end

  _getstats = _getstats_plain
end


function copas.status(enable_stats)
  local res = _getstats(enable_stats)
  res.running = not not copas.running
  res.timeout = copas.gettimeouts()
  res.timer, res.inactive = _sleeping:status()
  res.read = #_reading
  res.write = #_writing
  res.active = _resumable:count()
  return res
end


-------------------------------------------------------------------------------
-- Dispatcher endless loop.
-- Listen to client requests and handles them forever
-------------------------------------------------------------------------------
function copas.loop(initializer, timeout)
  if type(initializer) == "function" then
    copas.addnamedthread("copas_initializer", initializer)
  else
    timeout = initializer or timeout
  end

  resetexit()
  copas.running = true
  while true do
    copas.step(timeout)
    if copas.finished() then
      if copas.exiting() then
        break
      end
      copas.exit()
    end
  end
  copas.running = false
end


-------------------------------------------------------------------------------
-- Naming sockets and coroutines.
-------------------------------------------------------------------------------
do
  local function realsocket(skt)
    local mt = getmetatable(skt)
    if mt == _skt_mt_tcp or mt == _skt_mt_udp then
      return skt.socket
    else
      return skt
    end
  end


  function copas.setsocketname(name, skt)
    assert(type(name) == "string", "expected arg #1 to be a string")
    skt = assert(realsocket(skt), "expected arg #2 to be a socket")
    object_names[skt] = name
  end


  function copas.getsocketname(skt)
    skt = assert(realsocket(skt), "expected arg #1 to be a socket")
    return object_names[skt]
  end
end


function copas.setthreadname(name, coro)
  assert(type(name) == "string", "expected arg #1 to be a string")
  coro = coro or coroutine_running()
  assert(type(coro) == "thread", "expected arg #2 to be a coroutine or nil")
  object_names[coro] = name
end


function copas.getthreadname(coro)
  coro = coro or coroutine_running()
  assert(type(coro) == "thread", "expected arg #1 to be a coroutine or nil")
  return object_names[coro]
end

-------------------------------------------------------------------------------
-- Debug functionality.
-------------------------------------------------------------------------------
do
  copas.debug = {}

  local log_core    -- if truthy, the core-timer will also be logged
  local debug_log   -- function used as logger


  local debug_yield = function(skt, queue)
    local name = object_names[coroutine_running()]

    if log_core or name ~= "copas_core_timer" then
      if queue == _sleeping then
        debug_log("yielding '", name, "' to SLEEP for ", skt," seconds")

      elseif queue == _writing then
        debug_log("yielding '", name, "' to WRITE on '", object_names[skt], "'")

      elseif queue == _reading then
        debug_log("yielding '", name, "' to READ on '", object_names[skt], "'")

      else
        debug_log("thread '", name, "' yielding to unexpected queue; ", tostring(queue), " (", type(queue), ")", debug.traceback())
      end
    end

    return coroutine.yield(skt, queue)
  end


  local debug_resume = function(coro, skt, ...)
    local name = object_names[coro]

    if skt then
      debug_log("resuming '", name, "' for socket '", object_names[skt], "'")
    else
      if log_core or name ~= "copas_core_timer" then
        debug_log("resuming '", name, "'")
      end
    end
    return coroutine.resume(coro, skt, ...)
  end


  local debug_create = function(f)
    local f_wrapped = function(...)
      local results = pack(f(...))
      debug_log("exiting '", object_names[coroutine_running()], "'")
      return unpack(results)
    end

    return coroutine.create(f_wrapped)
  end


  debug_log = fnil


  -- enables debug output for all coroutine operations.
  function copas.debug.start(logger, core)
    log_core = core
    debug_log = logger or print
    coroutine_yield = debug_yield
    coroutine_resume = debug_resume
    coroutine_create = debug_create
  end


  -- disables debug output for coroutine operations.
  function copas.debug.stop()
    debug_log = fnil
    coroutine_yield = coroutine.yield
    coroutine_resume = coroutine.resume
    coroutine_create = coroutine.create
  end

  do
    local call_id = 0

    -- Description table of socket functions for debug output.
    -- each socket function name has TWO entries;
    -- 'name_in' and 'name_out', each being an array of names/descriptions of respectively
    -- input parameters and return values.
    -- If either table has a 'callback' key, then that is a function that will be called
    -- with the parameters/return-values for further inspection.
    local args = {
      settimeout_in = {
        "socket ",
        "seconds",
        "mode   ",
      },
      settimeout_out = {
        "success",
        "error  ",
      },
      connect_in = {
        "socket ",
        "address",
        "port   ",
      },
      connect_out = {
        "success",
        "error  ",
      },
      getfd_in = {
        "socket ",
        -- callback = function(...)
        --   print(debug.traceback("called from:", 4))
        -- end,
      },
      getfd_out = {
        "fd",
      },
      send_in = {
        "socket   ",
        "data     ",
        "idx-start",
        "idx-end  ",
      },
      send_out = {
        "last-idx-send    ",
        "error            ",
        "err-last-idx-send",
      },
      receive_in = {
        "socket ",
        "pattern",
        "prefix ",
      },
      receive_out = {
        "received    ",
        "error       ",
        "partial data",
      },
      dirty_in = {
        "socket",
        -- callback = function(...)
        --   print(debug.traceback("called from:", 4))
        -- end,
      },
      dirty_out = {
        "data in read-buffer",
      },
      close_in = {
        "socket",
        -- callback = function(...)
        --   print(debug.traceback("called from:", 4))
        -- end,
      },
      close_out = {
        "success",
        "error",
      },
    }
    local function print_call(func, msg, ...)
      print(msg)
      local arg = pack(...)
      local desc = args[func] or {}
      for i = 1, math.max(arg.n, #desc) do
        local value = arg[i]
        if type(value) == "string" then
          local xvalue = value:sub(1,30)
          if xvalue ~= value then
            xvalue = xvalue .."(...truncated)"
          end
          print("\t"..(desc[i] or i)..": '"..tostring(xvalue).."' ("..type(value).." #"..#value..")")
        else
          print("\t"..(desc[i] or i)..": '"..tostring(value).."' ("..type(value)..")")
        end
      end
      if desc.callback then
        desc.callback(...)
      end
    end

    local debug_mt = {
      __index = function(self, key)
        local value = self.__original_socket[key]
        if type(value) ~= "function" then
          return value
        end
        return function(self2, ...)
            local my_id = call_id + 1
            call_id = my_id
            local results

            if self2 ~= self then
              -- there is no self
              print_call(tostring(key).."_in", my_id .. "-calling '"..tostring(key) .. "' with; ", self, ...)
              results = pack(value(self, ...))
            else
              print_call(tostring(key).."_in", my_id .. "-calling '" .. tostring(key) .. "' with; ", self.__original_socket, ...)
              results = pack(value(self.__original_socket, ...))
            end
            print_call(tostring(key).."_out", my_id .. "-results '"..tostring(key) .. "' returned; ", unpack(results))
            return unpack(results)
          end
      end,
      __tostring = function(self)
        return tostring(self.__original_socket)
      end
    }


    -- wraps a socket (copas or luasocket) in a debug version printing all calls
    -- and their parameters/return values. Extremely noisy!
    -- returns the wrapped socket.
    -- NOTE: only for plain sockets, will not support TLS
    function copas.debug.socket(original_skt)
      if (getmetatable(original_skt) == _skt_mt_tcp) or (getmetatable(original_skt) == _skt_mt_udp) then
        -- already wrapped as Copas socket, so recurse with the original luasocket one
        original_skt.socket = copas.debug.socket(original_skt.socket)
        return original_skt
      end

      local proxy = setmetatable({
        __original_socket = original_skt
      }, debug_mt)

      return proxy
    end
  end
end


return copas
