local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local ffi = require("ffi")
ffi.cdef[[int mkstemp(char *);]]

local M = {}

M.replaceAllInvalidChars = function(str)
    local util = require("util")
    if util.replaceAllInvalidChars then
        return util.replaceAllInvalidChars(str)
    end
    if str then
        return str:gsub('[\\,%/,:,%*,%?,%",%<,%>,%|]', '_')
    end
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
    local Device = require("device")
    local mv_bin = Device:isAndroid() and "/system/bin/mv" or "/bin/mv"
    return ffiUtil.execute(mv_bin, from, to) == 0
end

M.formatFileSize = function(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1048576 then
        return string.format("%.2f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.2f KB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

M.copyRecursive = function(from, to)
    local Device = require("device")
    local cp_bin = Device:isAndroid() and "/system/bin/cp" or "/bin/cp"
    return ffiUtil.execute(cp_bin, "-r", from, to) == 0
end

M.copyFileFromTo = function(from, to)
    ffiUtil.copyFile(from, to)
    return true
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

M.writeAtomic = function(path, data, temp_dir, sync)
    if type(path) ~= "string" or path == "" or type(data) ~= "string" then return false end
    local custom_temp_dir = temp_dir ~= nil
    if temp_dir == nil then
        temp_dir = path:match("^(.*)/[^/]+$") or "."
        if temp_dir == "" then temp_dir = "/" end
    end
    if type(temp_dir) ~= "string" or temp_dir == "" then return false end

    local template = custom_temp_dir and M.joinPath(temp_dir, ".legado-write-XXXXXX")
        or path .. ".tmp-XXXXXX"
    local name = ffi.new("char[?]", #template + 1)
    ffi.copy(name, template, #template)
    local ok, fd = pcall(ffi.C.mkstemp, name)
    if not ok or fd < 0 then return false end
    local temporary = ffi.string(name)
    if ffi.C.close(fd) ~= 0 then
        os.remove(temporary)
        return false
    end

    local file = io.open(temporary, "wb")
    if not file then
        os.remove(temporary)
        return false
    end
    local written, synced = pcall(function()
        return file:write(data) ~= nil and (sync == false or ffiUtil.fsyncOpenedFile(file) == true)
    end)
    local closed = file:close() == true
    if written and synced and closed and os.rename(temporary, path) then return true end
    os.remove(temporary)
    return false
end

M.getSafeFilename = function(str, path, limit, limit_ext)
    local util = require("util")
    local safe_name = util.getSafeFilename(str, path, limit, limit_ext)
    return safe_name:gsub("[\r\n]", " "):gsub("\t", " ")
end

M.checkAndCreateFolder = function(d_path)
    local util = require("util")
    if not util.directoryExists(d_path) then
        util.makePath(d_path)
        if not util.directoryExists(d_path) then
            os.execute(string.format('mkdir -p "%s"', d_path))
        end
    end
    return d_path
end

M.getFileSize = function(path)
    local util = require("util")
    if not (path and util.fileExists(path)) then return 0 end
    local size = lfs.attributes(path, "size")
    if type(size) == "number" then return size end
    local f = io.open(path, "rb")
    if f then
        local sz = f:seek("end")
        f:close()
        return sz or 0
    end
    return 0
end

M.getDirectorySize = function(path)
    local util = require("util")
    if not (path and util.directoryExists(path)) then return 0 end
    local total = 0

    local function scan(dir)
        local ok, iterator, directory = pcall(lfs.dir, dir)
        if not ok or not iterator then return end
        for entry in iterator, directory do
            if entry ~= "." and entry ~= ".." then
                local child = M.joinPath(dir, entry)
                local attr = lfs.attributes(child)
                if attr and attr.mode == "file" then
                    total = total + (attr.size or 0)
                elseif attr and attr.mode == "directory" then
                    scan(child)
                end
            end
        end
    end

    scan(path)
    return total
end

return M
