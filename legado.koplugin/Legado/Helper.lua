local util = require("util")

local M = {}

M.base64 = function(str)
    return require("ffi/sha2").bin_to_base64(str)
end

M.md5 = function(str)
    return require("ffi/sha2").md5(str)
end

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

M.foreach = function(t, f)
    for k, v in pairs(t) do
        f(k, v)
    end
end

M.join = function(l, s)
    return table.concat(M.map(l, tostring), s, 1)
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

return M