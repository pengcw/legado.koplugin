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

--- Lazy-loads a Lua module on first access.
--- Avoid if module has require side-effects, C/C# interop, custom metamethods, or needs `pairs()` iteration.
M.lazy_require = function(require_path)
    local proxy = {}
    setmetatable(proxy, {
        __index = function(t, key)
            local module = require(require_path)
            setmetatable(t, {
                __index = module,
                __newindex = function(_, k, v)
                    module[k] = v
                end
            })
            return module[key]
        end,
        __newindex = function(t, key, value)
            local module = require(require_path)
            setmetatable(t, {
                __index = module,
                __newindex = function(_, k, v)
                    module[k] = v
                end
            })
            module[key] = value
        end
    })
    return proxy
end

return M
