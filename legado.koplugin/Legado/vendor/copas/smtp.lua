-------------------------------------------------------------------
-- identical to the socket.smtp module except that it uses
-- async wrapped Copas sockets

local copas = require("Legado.vendor.copas")
local smtp = require("socket.smtp")
local socket = require("socket")

local create = function() return copas.wrap(socket.tcp()) end
local forwards = { -- setting these will be forwarded to the original smtp module
  PORT = true,
  SERVER = true,
  TIMEOUT = true,
  DOMAIN = true,
  TIMEZONE = true
}

copas.smtp = setmetatable({}, {
    -- use original module as metatable, to lookup constants like socket.SERVER, etc.
    __index = smtp,
    -- Setting constants is forwarded to the luasocket.smtp module.
    __newindex = function(self, key, value)
        if forwards[key] then smtp[key] = value return end
        return rawset(self, key, value)
      end,
    })
local _M = copas.smtp

_M.send = function(mailt)
  mailt.create = mailt.create or create
  return smtp.send(mailt)
end

return _M