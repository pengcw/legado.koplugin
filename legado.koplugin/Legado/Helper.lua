local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Device = require("device")
local ffiUtil = require("ffi/util")
local DataStorage = require("datastorage")

local M = {
    plugin_path = nil,
    plugin_name = nil
}

M.initialize = function(name, path)
    M.plugin_name = name
    -- fix Android path
    if type(path) == "string" then
        path = path:gsub("/+", "/")
    end
    M.plugin_path = path
end

M.get_plugin_path = function()
    return M.plugin_path
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

M.okeys = function(t)
    local r = {}
    for k in M.opairs(t) do
        r[#r + 1] = k
    end
    return r
end

M.opairs = (function()
    local __gen_order_index = function(t)
        local orderedIndex = {}
        for key in pairs(t) do
            table.insert(orderedIndex, key)
        end
        table.sort(orderedIndex)
        return orderedIndex
    end

    local nextpair = function(t, state)
        local key
        if state == nil then

            t.__orderedIndex = __gen_order_index(t)
            key = t.__orderedIndex[1]
        else

            for i = 1, table.getn(t.__orderedIndex) do
                if t.__orderedIndex[i] == state then
                    key = t.__orderedIndex[i + 1]
                end
            end
        end

        if key then
            return key, t[key]
        end

        t.__orderedIndex = nil
        return
    end

    return function(t)
        return nextpair, t, nil
    end
end)()

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

M.tbl_extend = (function()
    local run_behavior = setmetatable({
        ["error"] = function(_, k, _)
            error("Key already exists: ", k)
        end,
        ["keep"] = function()
        end,
        ["force"] = function(t, k, v)
            t[k] = v
        end
    }, {
        __index = function(_, k)
            error(k .. " is not a valid behavior")
        end
    })

    return function(behavior, ...)
        local new_table = {}
        local tables = {...}
        for i = 1, #tables do
            local b = tables[i]
            for k, v in pairs(b) do
                if v then
                    if new_table[k] then
                        run_behavior[behavior](new_table, k, v)
                    else
                        new_table[k] = v
                    end
                end
            end
        end
        return new_table
    end
end)()

M.flatten = function(tbl)
    local result = {}
    local function flatten(arr)
        local n = #arr
        for i = 1, n do
            local v = arr[i]
            if type(v) == "table" then
                flatten(v)
            elseif v then
                table.insert(result, v)
            end
        end
    end
    flatten(tbl)

    return result
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

M.b_to_n = function(b)
    return b and 1 or 0
end

M.n_to_b = function(n)
    return n == 1
end
-- 路径转换
M.replaceAllInvalidChars = function(str)
    if util.replaceAllInvalidChars then 
            return util.replaceAllInvalidChars(str)
    end
    if str then
        return str:gsub('[\\,%/,:,%*,%?,%",%<,%>,%|]','_')
    end
end

M.errorHandler = function(err)
    err = tostring(err)
    -- remove stacktrace
    local detail = err:match("%.lua:%d+:%s*(.*)")
    if not detail then
        detail = err:match(".*%.lua:%d+:%s*(.*)")
    end
    return detail or err
end

M.isFileOlderThan = function(filepath, seconds)

    local attributes = lfs.attributes(filepath)
    if not attributes then
        return nil, "File not found or unable to access file."
    end

    local file_time = attributes.creation or attributes.modification
    if not file_time then
        return nil, "No valid file time found."
    end

    local time_difference = os.time() - file_time

    return time_difference > seconds, time_difference
end

M.moveFile = function(from, to)
    local mv_bin = Device:isAndroid() and "/system/bin/mv" or "/bin/mv"
    return ffiUtil.execute(mv_bin, from, to) == 0
end
M.copyRecursive = function(from, to)
    local cp_bin = Device:isAndroid() and "/system/bin/cp" or "/bin/cp"
    return ffiUtil.execute(cp_bin, "-r", from, to) == 0
end
M.copyFileFromTo = function(from, to)
    ffiUtil.copyFile(from, to)
    return true
end
M.base64 = function(str)
    return require("ffi/sha2").bin_to_base64(str)
end
M.md5 = function(str)
    return require("ffi/sha2").md5(str)
end

M.joinPath = function(path1, path2)
    if string.sub(path2, 1, 1) == "/" then
        return path2
    end
    if string.sub(path1, -1, -1) ~= "/" then
        path1 = path1 .. "/"
    end
    return path1 .. path2
end

M.checkAndCreateFolder = function(d_path)
    if not util.pathExists(d_path) then
        util.makePath(d_path)
    end
    return d_path
end

M.getUserSettingsPath = function()
    return M.joinPath(DataStorage:getSettingsDir(), M.plugin_name .. '.lua')
end

M.getUserPatchesDirectory = function()
    local patches_dir = M.joinPath(DataStorage:getDataDir(), 'patches')
    return M.checkAndCreateFolder(patches_dir)
end

M.getKoreaderDirectory = function()
    return DataStorage:getDataDir()
end

M.getTempDirectory = function()
    local plugin_cache_dir = M.plugin_name .. '.cache'
    local plugin_cache_path = M.joinPath(DataStorage:getDataDir(), 'cache/' .. plugin_cache_dir)
    return M.checkAndCreateFolder(plugin_cache_path)
end

M.getPluginDirectory = function()
    local plugin_path_bak = table.concat({DataStorage:getDataDir(), "/plugins/", M.plugin_name, '.koplugin'})
    return M.plugin_path or plugin_path_bak
end

M.getBookCachePath = function(book_cache_id)
    assert(type(book_cache_id) == "string", "Error: The variable is not a string.")
    local plugin_cache_path = M.getTempDirectory()
    local book_cache_path = M.joinPath(plugin_cache_path, book_cache_id .. '.sdr')
    M.checkAndCreateFolder(book_cache_path)
    M.checkAndCreateFolder(M.joinPath(book_cache_path,"resources"))
    return book_cache_path
end

M.getCoverCacheFilePath = function(book_cache_id)
    local book_cache_path = M.getBookCachePath(book_cache_id)
    return M.joinPath(book_cache_path, 'cover')
end

M.getChapterCacheFilePath = function(book_cache_id, chapters_index, book_name)
    book_name = util.getSafeFilename(book_name)
    local book_cache_path = M.getBookCachePath(book_cache_id)
    local chapter_cache_name =  string.format("%s-%s", book_name or "", chapters_index)
    return M.joinPath(book_cache_path, chapter_cache_name)
end

return M
