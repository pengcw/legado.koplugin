-------------------------------------------------------------------
-- identical to the socket.ftp module except that it uses
-- async wrapped Copas sockets

local copas = require("Legado.vendor.copas")
local socket = require("socket")
local ftp = require("socket.ftp")
local ltn12 = require("ltn12")
local url = require("socket.url")


local create = function() return copas.wrap(socket.tcp()) end
local forwards = { -- setting these will be forwarded to the original smtp module
  PORT = true,
  TIMEOUT = true,
  PASSWORD = true,
  USER = true
}

copas.ftp = setmetatable({}, {
    -- use original module as metatable, to lookup constants like socket.TIMEOUT, etc.
    __index = ftp,
    -- Setting constants is forwarded to the luasocket.ftp module.
    __newindex = function(self, key, value)
        if forwards[key] then ftp[key] = value return end
        return rawset(self, key, value)
      end,
    })
local _M = copas.ftp

---[[ copy of Luasocket stuff here untile PR #133 is accepted
-- a copy of the version in LuaSockets' ftp.lua
-- no 'create' can be passed in the string form, hence a local copy here
local default = {
    path = "/",
    scheme = "ftp"
}

-- a copy of the version in LuaSockets' ftp.lua
-- no 'create' can be passed in the string form, hence a local copy here
local function parse(u)
    local t = socket.try(url.parse(u, default))
    socket.try(t.scheme == "ftp", "wrong scheme '" .. t.scheme .. "'")
    socket.try(t.host, "missing hostname")
    local pat = "^type=(.)$"
    if t.params then
        t.type = socket.skip(2, string.find(t.params, pat))
        socket.try(t.type == "a" or t.type == "i",
            "invalid type '" .. t.type .. "'")
    end
    return t
end

-- parses a simple form into the advanced form
-- if `body` is provided, a PUT, otherwise a GET.
-- If GET, then a field `target` is added to store the results
_M.parseRequest = function(u, body)
  local t = parse(u)
  if body then
    t.source = ltn12.source.string(body)
  else
    t.target = {}
    t.sink = ltn12.sink.table(t.target)
  end
end
--]]

_M.put = socket.protect(function(putt, body)
    if type(putt) == "string" then
      putt = _M.parseRequest(putt, body)
      _M.put(putt)
      return table.concat(putt.target)
    else
      putt.create = putt.create or create
      return ftp.put(putt)
    end
end)

_M.get = socket.protect(function(gett)
    if type(gett) == "string" then
      gett = _M.parseRequest(gett)
      _M.get(gett)
      return table.concat(gett.target)
    else
      gett.create = gett.create or create
      return ftp.get(gett)
    end
end)

_M.command = function(cmdt)
  cmdt.create = cmdt.create or create
  return ftp.command(cmdt)
end

return _M
