local Hmac = {}
Hmac.__index = Hmac
local MAX_KEY, MAX_DATA = 16384, 256 * 1024
local function fail(kind, message) return nil, {kind=kind, message=message} end
local function valid_hex(value, limit)
    return type(value) == 'string' and #value <= limit * 2
        and #value % 2 == 0 and not value:find('[^%x]')
end
function Hmac.new(loader)
    return setmetatable({loader=loader or function() return require('ffi/sha2') end}, Hmac)
end
function Hmac:digest(args)
    if type(args) ~= 'table' then return fail('invalid_argument', 'invalid HMAC request') end
    if args.algorithm ~= 'HMACMD5' then return fail('unsupported', 'unsupported host HMAC algorithm') end
    if type(args.keyHex) == 'string' and #args.keyHex > MAX_KEY * 2
            or type(args.dataHex) == 'string' and #args.dataHex > MAX_DATA * 2 then
        return fail('limit_exceeded', 'HMAC input too large')
    end
    if not valid_hex(args.keyHex, MAX_KEY) or not valid_hex(args.dataHex, MAX_DATA) then
        return fail('invalid_argument', 'invalid HMAC hexadecimal input')
    end
    if not self.checked then
        self.checked = true
        local ok, sha = pcall(self.loader)
        if ok and type(sha) == 'table' and type(sha.hmac) == 'function'
                and type(sha.md5) == 'function' and type(sha.hex_to_bin) == 'function' then
            self.sha = sha
        end
    end
    if not self.sha then return fail('unsupported', 'KOReader HMAC helper unavailable') end
    local ok, output = pcall(function()
        return self.sha.hmac(self.sha.md5,
            self.sha.hex_to_bin(args.keyHex), self.sha.hex_to_bin(args.dataHex))
    end)
    if not ok or type(output) ~= 'string' or #output ~= 32 or output:find('[^%x]') then
        return fail('operation_failed', 'HMAC operation failed')
    end
    return output:lower()
end
function Hmac:handlers()
    return {['crypto.hmac'] = function(args) return self:digest(args) end}
end
return Hmac
