local Env = require("Legado.Helper.Env")

local M = {}

M.load_script = function(path)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid path"
    end
    local plg_path = Env.getPluginDirectory()
    local norm_path = path:gsub("%.", "/")
    local fullpath = string.format("%s/%s.lua", plg_path, norm_path)
    local ok, result = pcall(dofile, fullpath)
    if not ok then
        return nil, "require error: " .. tostring(result)
    end
    return result, fullpath
end

return M
