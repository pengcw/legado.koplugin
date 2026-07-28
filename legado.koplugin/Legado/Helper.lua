local util = require("util")
local logger = require("logger")

local M = {}

M.if_nil = function(a, b)
    if nil == a then
        return b
    end
    return a
end

M.is_str = function(s)
    return "string" == type(s)
end
M.is_num = function(s)
    return "number" == type(s)
end

M.is_func = function(s)
    return "function" == type(s)
end

M.is_tbl = function(t)
    return "table" == type(t)
end

M.is_boolean = function(t)
    return "boolean" == type(t)
end

M.is_userdata = function(t)
    return "userdata" == type(t)
end

M.is_nested = function(t)
    return t and type(t[1]) == "table" or false
end

M.is_list = function(t)
    if type(t) ~= "table" then
        return false
    end

    local count = 0

    for k, _ in pairs(t) do
        if "number" == type(k) then
            count = count + 1
        else
            return false
        end
    end

    if count > 0 then
        return true
    else
        return getmetatable(t) ~= {}
    end
end

M.okeys = function(t)
    local r = {}
    for k in M.opairs(t) do
        r[#r + 1] = k
    end
    return r
end

M.all = function(iterable, fn)
    for k, v in pairs(iterable) do
        if not fn(k, v) then
            return false
        end
    end

    return true
end

M.keys = function(t)
    local r = {}
    for k in pairs(t) do
        r[#r + 1] = k
    end
    return r
end

M.values = function(t)
    local r = {}
    for _, v in pairs(t) do
        r[#r + 1] = v
    end
    return r
end

M.map = function(t, f)
    local _t = {}
    for i, value in pairs(t) do
        local k, kv, v = i, f(value, i)
        _t[v and kv or k] = v or kv
    end
    return _t
end

M.join = function(l, s)
    return table.concat(M.map(l, tostring), s, 1)
end

M.foreachv = function(t, f)
    for i, v in M.opairs(t) do
        f(i, v)
    end
end

M.foreach = function(t, f)
    for k, v in pairs(t) do
        f(k, v)
    end
end

M.mapv = function(t, f)
    local _t = {}
    for i, value in M.opairs(t) do
        local _, kv, v = i, f(value, i)
        table.insert(_t, v or kv)
    end
    return _t
end

-- pay attention to infinite recursion
M.deep_equal = function(a, b)
    return util.tableEquals(a, b, true)
end

M.b_to_n = function(b)
    return b and 1 or 0
end

M.n_to_b = function(n)
    return n == 1
end

local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
for k, v in pairs(FS) do
    M[k] = v
end
for k, v in pairs(Env) do
    M[k] = v
end

return M