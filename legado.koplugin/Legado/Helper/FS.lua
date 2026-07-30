local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local Device = require("device")
local ffiUtil = require("ffi/util")

local M = {}

M.replaceAllInvalidChars = function(str)
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

M.getSafeFilename = function(str, path, limit, limit_ext)
    local safe_name = util.getSafeFilename(str, path, limit, limit_ext)
    -- fix util.getSafeFilename < 2025.11
    return safe_name:gsub("[\r\n]", " "):gsub("\t", " ")
end

M.checkAndCreateFolder = function(d_path)
    if not util.directoryExists(d_path) then
        util.makePath(d_path)
        if not util.directoryExists(d_path) then
            os.execute(string.format('mkdir -p "%s"', d_path))
        end
    end
    return d_path
end

return M
