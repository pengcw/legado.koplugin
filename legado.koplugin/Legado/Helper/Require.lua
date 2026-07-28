local Env = require("Legado.Helper.Env")

local M = {}

M.require = function(path)
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

M.require_on_exported_call = function(require_path)
    return setmetatable({}, {
        __index = function(_, k)
            return function(...)
                return require(require_path)[k](...)
            end
        end
    })
end

M.require_on_index = function(require_path)
    return setmetatable({}, {
        __index = function(_, key)
            return require(require_path)[key]
        end,

        __newindex = function(_, key, value)
            require(require_path)[key] = value
        end
    })
end

return M
