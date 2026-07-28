local sha = require("ffi/sha2")
local M = {}

M.base64 = function(str)
    return sha.bin_to_base64(str)
end

M.md5 = function(str)
    return sha.md5(str)
end

return M
