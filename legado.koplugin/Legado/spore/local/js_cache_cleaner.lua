local M = {}
local LIMIT = 16 * 1024 * 1024
local started = false

local function is_directory(lfs, path)
    local attr = lfs.symlinkattributes(path)
    return attr and attr.mode == "directory"
end

function M.clean_js(root)
    if type(root) ~= "string" or root == "" then return end
    local lfs = require("libs/libkoreader-lfs")
    local parent = root .. "/resources"
    local dir = parent .. "/js"
    if not is_directory(lfs, root) or not is_directory(lfs, parent)
        or not is_directory(lfs, dir) then return end

    local lock = dir .. "/.write.lock"
    if not lfs.mkdir(lock) then return end
    local ok, result = pcall(function()
        local total, files = 0, {}
        for name in lfs.dir(dir) do
            if name:match("^http%-") or name:match("^bootstrap%-") then
                local path = dir .. "/" .. name
                local info = lfs.symlinkattributes(path)
                if info and info.mode == "file" then
                    local size = tonumber(info.size) or 0
                    total = total + size
                    files[#files + 1] = {
                        path = path, size = size,
                        modified = tonumber(info.modification) or 0,
                    }
                end
            end
        end
        if total > LIMIT then
            table.sort(files, function(a, b) return a.modified < b.modified end)
            for _, file in ipairs(files) do
                if total <= LIMIT then break end
                if os.remove(file.path) then total = total - file.size end
            end
        end
        return total
    end)
    lfs.rmdir(lock)
    return ok and result or nil
end

function M.start()
    if started then return end
    started = true
    local root = require("Legado.Helper.Env").getTempDirectory()
    if not root then return end
    require("Legado.task.Queue").spawnProcess(function()
        return M.clean_js(root)
    end, nil, 60)
end

return M
