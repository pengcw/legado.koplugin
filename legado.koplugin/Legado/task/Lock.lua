-- Legado/task/Lock.lua
local H = require("Legado/Helper")

local M = {}

local function to_lock_name(target)
    if type(target) == "string" then return target end
    if type(target) == "table" and target.book_cache_id and target.chapters_index ~= nil then
        return string.format("chapter:%s:%s", tostring(target.book_cache_id), tostring(target.chapters_index))
    end
    return tostring(target)
end

function M.isLocked(dbManager, target)
    if not (dbManager and dbManager.isConnected) then return false end
    local now_time = os.time()
    local sql, params
    if target ~= nil then
        sql = "SELECT 1 FROM task_locks WHERE lock_name = ? AND expire_time > ?"
        params = { to_lock_name(target), now_time }
    else
        sql = "SELECT 1 FROM task_locks WHERE expire_time > ? LIMIT 1"
        params = { now_time }
    end
    local ok, res = pcall(function() return dbManager:execute(sql, params) end)
    return ok and type(res) == "table" and #res > 0
end

function M.cleanExpired(dbManager)
    if not (dbManager and dbManager.isConnected) then return false end
    local now_time = os.time()
    pcall(function() dbManager:execute("DELETE FROM task_locks WHERE expire_time <= ?", { now_time }) end)
    return true
end

function M.setLock(dbManager, targets, is_locked, ttl, owner_id)
    if not (dbManager and dbManager.isConnected and targets) then return false end
    local list = (type(targets) == "table" and targets[1]) and targets or { targets }
    local now_time = os.time()
    owner_id = owner_id or "main"
    ttl = ttl or 7200
    local expire_time = now_time + ttl

    return dbManager:transaction(function()
        for _, item in ipairs(list) do
            local lock_name = to_lock_name(item)
            if is_locked then
                dbManager:execute("INSERT OR REPLACE INTO task_locks (lock_name, owner_id, acquire_time, expire_time) VALUES (?, ?, ?, ?)",
                    { lock_name, owner_id, now_time, expire_time })
            else
                if owner_id == "FORCE" then
                    dbManager:execute("DELETE FROM task_locks WHERE lock_name = ?", { lock_name })
                else
                    dbManager:execute("DELETE FROM task_locks WHERE lock_name = ? AND owner_id = ?", { lock_name, owner_id })
                end
            end
        end
    end, { enable_savepoint = true })()
end

function M.withLock(dbManager, target, fn, ttl, owner_id)
    if not H.is_func(fn) then return false, "invalid_function" end
    if M.isLocked(dbManager, target) then
        return false, "lock_acquired_failed"
    end
    
    owner_id = owner_id or "main"
    M.setLock(dbManager, target, true, ttl, owner_id)
    local ok, res1, res2 = pcall(fn)
    M.setLock(dbManager, target, false, nil, owner_id)
    
    if not ok then error(res1) end
    return true, res1, res2
end

return M
