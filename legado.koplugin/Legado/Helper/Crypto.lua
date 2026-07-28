local M = {}

M.base64 = function(str)
    return require("ffi/sha2").bin_to_base64(str)
end

M.md5 = function(str)
    return require("ffi/sha2").md5(str)
end

return M
