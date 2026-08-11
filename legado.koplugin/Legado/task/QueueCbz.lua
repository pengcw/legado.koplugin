-- QueueCbz.lua
local logger = require("logger")
local util = require("util")
local TaskQueue = require("Legado.task.Queue")
local ZipUtil = require("Legado.Helper.ZipUtil")
local ZipWrite = ZipUtil.Writer
local ImageUtil = require("Legado.Helper.ImageUtil")

local M = {}
M.__index = M

local function apply_params(obj, params)
    if type(params) == "table" then
        for k, v in pairs(params) do
            obj.params[k] = v
        end
    end
    return obj
end

setmetatable(M, {
    __call = function(cls, initial_params)
        local obj = cls:new()
        if initial_params then
            apply_params(obj, initial_params)
        end
        return obj
    end
})

local function valid_entry_name(name)
    if type(name) ~= "string" or name == "" then return false end
    name = name:gsub("\\", "/")
    if name:sub(1, 1) == "/" then return false end
    if name:match("^%a+:") then return false end
    for part in name:gmatch("[^/]+") do
        if part == ".." then return false end
    end
    return true
end

function M:new()
    local o = setmetatable({}, M)
    o.channel_name = nil
    o.channel = nil
    o.writer = nil
    o.output = nil
    o.images = nil
    o.total = 0
    o.completed = 0
    o.succeeded = 0
    o.failed = 0
    o.aborted = false
    o.finished = false
    o.params = {}
    return o
end

function M:_finalize(is_aborted)
    if self.finished then return end
    self.finished = true
    self.aborted = is_aborted or self.aborted

    local close_ok = true
    if self.writer then
        -- 收尾条目（如 ComicInfo.xml）：在关闭 zip 前追加，PageCount 可用实际写入数
        if type(self.params.finalize_callback) == "function" then
            local entries_ok, entries = pcall(self.params.finalize_callback, {
                aborted = self.aborted,
                total = self.total,
                completed = self.completed,
                succeeded = self.succeeded,
                failed = self.failed,
            })
            if entries_ok and type(entries) == "table" then
                for _, entry in ipairs(entries) do
                    if type(entry) == "table" and entry.name and type(entry.data) == "string" then
                        local add_ok, add_err = pcall(self.writer.add, self.writer, entry.name, entry.data, entry.no_compression)
                        if not add_ok or add_err == false then
                            close_ok = false
                            logger.warn("finalize entry add failed:", entry.name, tostring(add_err))
                            break
                        end
                    end
                end
            end
        end
        local ok, ret = pcall(self.writer.close, self.writer)
        close_ok = close_ok and (ok and ret ~= false)
        self.writer = nil
    end

    -- 成功：未中止且写入完整；容忍模式（allow_failed）下只要成功条目 > 0 即算成功
    local success = not self.aborted and close_ok
        and ((self.params.allow_failed and self.succeeded > 0) or self.succeeded == self.total)
    if not success and not self.params.keep_partial and self.output then
        pcall(os.remove, self.output)
    end
    
    if self.params.on_finish then
        pcall(self.params.on_finish, self.aborted, {
            output = self.output,
            total = self.total,
            completed = self.completed,
            succeeded = self.succeeded,
            failed = self.failed,
            success = success
        })
    end

    if self.channel then
        local channel_name = self.channel_name
        self.channel = nil
        self.channel_name = nil
        if channel_name then
            pcall(TaskQueue.destroyChannel, TaskQueue, channel_name)
        end
    end
end

function M:start(params)
    if params then
        apply_params(self, params)
    end
    
    if self.channel or self.writer then
        return nil, "CBZ writer is already running"
    end

    self.output = self.params.output
    self.images = self.params.images
    local downimg = self.params.downimg

    if type(self.output) ~= "string" or self.output == "" then return nil, "missing output" end
    if type(self.images) ~= "table" then return nil, "missing images" end
    if type(downimg) ~= "function" then return nil, "missing downimg" end

    for i, item in ipairs(self.images) do
        if type(item) ~= "table" then return nil, "invalid image item at index " .. i end
        if not valid_entry_name(item.name) then return nil, "invalid zip entry name at index " .. i end
    end

    self.total = #self.images
    self.completed = 0
    self.succeeded = 0
    self.failed = 0
    self.aborted = false
    self.finished = false

    local max_workers = math.max(math.floor(tonumber(self.params.max_workers) or 3), 1)
    local max_retries = math.max(math.floor(tonumber(self.params.max_retries) or 2), 0)

    local new_ok, writer = pcall(ZipWrite.new, ZipWrite)
    if not new_ok or not writer then
        return nil, "failed to init zip backend: " .. tostring(writer)
    end
    if not writer:open(self.output) then
        return nil, "failed to open cbz: " .. self.output
    end
    self.writer = writer

    self.channel_name = self.params.channel_name or ("cbz_writer_" .. tostring(self))
    self.channel = TaskQueue:createChannel(self.channel_name, max_workers, nil)

    if self.params.on_start then pcall(self.params.on_start, self.total) end

    if self.total == 0 then
        self:_finalize(false)
        return true
    end

    self.channel:executeBatch({
        items = self.images,
        max_retries = max_retries,
        timeout = self.params.timeout or 1200,
        returns_string = true,
        task_func = function(item)
            if type(item) ~= "table" then return false, "invalid item" end
            -- Preset entries (e.g., mimetype) return data directly, no download.
            if item.data ~= nil then return item.data end
            local url = item.url
            if type(url) ~= "string" or url == "" then return false, "missing url" end
            local data = downimg(url, item)
            if type(data) ~= "string" or #data == 0 then return false, "empty image data" end
            return data
        end,
        on_start = function(index, item, retry)
            if self.params.on_item_start then pcall(self.params.on_item_start, index, item, retry) end
        end,
        on_item_end = function(index, item, success, result, retries_used)
            if self.aborted then return true end
            -- External cancel check (e.g., chapter task aborted)
            if type(self.params.check_running) == "function" and self.params.check_running() then
                self.aborted = true
                return true
            end
            self.completed = self.completed + 1
            if not success or (type(result) ~= "string" or #result == 0) then
                self.failed = self.failed + 1
                local err_msg = success and "empty image data" or tostring(result)
                
                if self.params.on_progress then
                    pcall(self.params.on_progress, self.completed, self.total, index, item, false, err_msg, retries_used)
                end

                if not self.params.allow_failed then
                    logger.warn(string.format("CBZBatchWriter: download failed for [%s]: %s", item.name, err_msg))
                    self.aborted = true
                    return true -- No failure allowed, return true to abort task.
                end
                return false
            end

            local add_ok, ret, add_err = pcall(self.writer.add, self.writer, item.name, result, true) -- true 表示无需再压缩
            if not add_ok or ret == false then
                self.failed = self.failed + 1
                self.aborted = true
                local add_msg = add_ok and (add_err or "zip add failed") or tostring(ret)
                logger.err("CBZBatchWriter: ZIP add failed:", item.name, add_msg)
                
                if self.params.on_progress then
                    pcall(self.params.on_progress, self.completed, self.total, index, item, false, add_msg, retries_used)
                end
                return true -- Write failed, critical error, abort.
            end

            self.succeeded = self.succeeded + 1
            if self.params.on_progress then
                pcall(self.params.on_progress, self.completed, self.total, index, item, true, nil, retries_used)
            end
            
            return false
        end,
        on_batch_end = function(aborted, results)
            self:_finalize(aborted)
        end
    })
    return true
end

function M:cancel()
    if self.finished then return false end
    self.aborted = true
    if self.channel then 
        self.channel:clearTasks() 
    end
    return true
end

function M:getStatus()
    local status = {
        output = self.output,
        total = self.total,
        completed = self.completed,
        succeeded = self.succeeded,
        failed = self.failed,
        aborted = self.aborted,
        finished = self.finished,
    }
    
    if self.channel then
        local busy, queued, active = self.channel:hasTasks()
        status.busy = busy
        status.queued = queued
        status.active = active
    else
        status.busy = false
        status.queued = 0
        status.active = 0
    end
    return status
end

-- ==========================================
-- Serial download + zip pack in calling thread (usually child process).
-- Errors always throw via error() (caller wraps with pcall).
-- img_sources: URL string, or { url=..., name=... } table.
-- opts.allow_failed=false aborts on any failure (default tolerates failures).
-- ==========================================
function M.from_urls(filePath, img_sources, check_running_callback, opts)
    if type(filePath) ~= "string" or filePath == "" then
        error("Cbz param error: invalid filePath")
    end
    if type(img_sources) ~= "table" or #img_sources == 0 then
        error("Cbz param error: invalid img_sources")
    end
    opts = opts or {}
    local cbz_path_tmp = filePath .. '.downloading'
    if util.fileExists(cbz_path_tmp) then
        if type(check_running_callback) == "function" and check_running_callback() then
            error("Other threads downloading, cancelled")
        else
            util.removeFile(cbz_path_tmp)
        end
    end
    local new_ok, writer = pcall(ZipWrite.new, ZipWrite)
    if not new_ok or not writer then
        error("CreateCBZ init zip backend err: " .. tostring(writer))
    end
    if not writer:open(cbz_path_tmp) then
        error("CreateCBZ cbz:open err: " .. cbz_path_tmp)
    end

    local mimetype_ok, mimetype_err = writer:add("mimetype", "application/vnd.comicbook+zip", true)
    if not mimetype_ok then
        writer:close()
        error("CreateCBZ write mimetype err: " .. tostring(mimetype_err))
    end

    local succeeded = 0
    local strict = (opts.allow_failed == false)
    local function abort(msg)
        writer:close()
        error(msg)
    end

    -- On failure: return false and continue by default; strict mode errors out.
    local function process_one(i, img_src)
        if type(check_running_callback) == "function" and check_running_callback() then
            abort("Other threads downloading, cancelled")
        end
        local url = img_src
        local custom_name = nil
        if type(img_src) == "table" then
            url = img_src.url
            custom_name = img_src.name
        end
        if type(url) ~= "string" or url == "" then
            if strict then abort(string.format("CreateCBZ invalid url at index %d", i)) end
            logger.warn("CreateCBZ: invalid url at index", i)
            return false
        end
        local imgdata, img_extension = ImageUtil.download_image(url, {
            timeout = opts.timeout,
            maxtime = opts.maxtime,
            headers = opts.headers,
        })
        if not imgdata then
            if strict then abort(string.format("CreateCBZ download err: %s", tostring(img_extension))) end
            logger.dbg('CreateCBZ download err:', url, tostring(img_extension))
            return false
        end

        local img_name
        if custom_name and custom_name ~= "" then
            img_name = custom_name
        else
            img_name = string.format("%d.%s", i, img_extension)
        end
        if not valid_entry_name(img_name) then
            if strict then abort("CreateCBZ invalid zip entry name: " .. img_name) end
            logger.warn("CreateCBZ: invalid entry name skipped:", img_name)
            return false
        end
        local add_ok, add_err = writer:add(img_name, imgdata, true)
        if not add_ok then
            if strict then abort(string.format("CreateCBZ zip add err: %s (%s)", img_name, tostring(add_err))) end
            logger.warn("CreateCBZ: zip add failed, skipped:", img_name, add_err)
            return false
        end
        succeeded = succeeded + 1
        return true
    end

    for i, img_src in ipairs(img_sources) do
        process_one(i, img_src)
    end
    -- ComicInfo.xml（zip 末尾追加，PageCount = 实际成功图片数）
    if succeeded > 0 then
        local comic_ok, comic_err = writer:add("ComicInfo.xml", ZipUtil.createComicInfo(opts.comic_info, succeeded), true)
        if not comic_ok then
            logger.warn("CreateCBZ: ComicInfo.xml add failed:", tostring(comic_err))
        end
    end
    writer:close()
    if succeeded == 0 then
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        error("CreateCBZ: no image downloaded")
    end
    if util.fileExists(filePath) then
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        error('exist target file, cancelled')
    end
    local ok_rename, rename_err = os.rename(cbz_path_tmp, filePath)
    if not ok_rename then
        error(string.format("CreateCBZ rename err: %s", tostring(rename_err)))
    end
    return filePath
end

-- ==========================================
-- Async batch CBZ pack (main process only: relies on TaskQueue event loop, do not call in child)
-- Images downloaded in parallel via TaskQueue child processes, main thread writes zip.
-- Renames ".downloading" temp file to target and triggers on_finish when done.
-- params:
--   output        : target .cbz path
--   images        : array of URL strings, or { url=, name= } tables
--   opts          : { max_workers, max_retries, timeout, allow_failed }
--   check_running : optional cancel check (return true to abort)
--   on_progress   : optional progress callback (same as start())
--   on_finish     : function(aborted, result) completion callback
-- returns ok, err; ok=true means task started (async execution).
-- ==========================================
function M:from_urls_async(params)
    if type(params) ~= "table" then return nil, "missing params" end
    local filePath = params.output
    local img_sources = params.images
    local opts = params.opts or {}
    local on_finish = params.on_finish

    if type(filePath) ~= "string" or filePath == "" then return nil, "missing output" end
    if type(img_sources) ~= "table" or #img_sources == 0 then return nil, "missing images" end

    local items = { { name = "mimetype", data = "application/vnd.comicbook+zip" } }
    local strict = (opts.allow_failed == false)
    for i, src in ipairs(img_sources) do
        local url = src
        local custom_name = nil
        if type(src) == "table" then
            url = src.url
            custom_name = src.name
        end
        if type(url) ~= "string" or url == "" then
            if strict then return nil, string.format("invalid image url at index %d", i) end
            logger.warn("from_urls_async: invalid url at index", i)
        else
            local ext = ImageUtil.get_url_extension(url)
            if ext == "" then ext = "png" end
            local name = custom_name
            if not (name and name ~= "") then
                name = string.format("%d.%s", i, ext)
            end
            if not valid_entry_name(name) then
                if strict then return nil, "invalid zip entry name: " .. name end
                logger.warn("from_urls_async: invalid entry name skipped:", name)
            else
                table.insert(items, { name = name, url = url })
            end
        end
    end
    if #items <= 1 then return nil, "no valid image urls" end

    local cbz_path_tmp = filePath .. '.downloading'
    if util.fileExists(cbz_path_tmp) then
        util.removeFile(cbz_path_tmp)
    end

    local image_succeeded = 0
    local ok, err = self:start({
        output = cbz_path_tmp,
        images = items,
        downimg = function(url, item)
            local data = ImageUtil.download_image(url, {
                timeout = opts.timeout,
                maxtime = opts.maxtime,
                headers = opts.headers,
            })
            return data
        end,
        max_workers = opts.max_workers,
        max_retries = opts.max_retries,
        timeout = opts.timeout,
        allow_failed = (opts.allow_failed ~= false),
        -- on_finish handles rename or cleanup uniformly
        keep_partial = true,
        check_running = params.check_running,
        -- Append PageCount = actual image count to ComicInfo.xml at zip end
        -- Generated by default (opts.comic_info can pass title, etc.)
        finalize_callback = function(result)
            -- Skip ComicInfo append on abort (tmp will be cleaned up)
            if result.aborted or image_succeeded <= 0 then
                return nil
            end
            return { { name = "ComicInfo.xml", data = ZipUtil.createComicInfo(opts.comic_info, image_succeeded), no_compression = true } }
        end,
        on_progress = function(completed, total, index, item, ok, err_msg, retries)
            if ok and item and item.name ~= "mimetype" then
                image_succeeded = image_succeeded + 1
            end
            if type(params.on_progress) == "function" then
                pcall(params.on_progress, completed, total, index, item, ok, err_msg, retries)
            end
        end,
        on_finish = function(aborted, result)
            -- Only count image pages (mimetype not counted)
            local success = (result and not aborted and result.success and image_succeeded > 0)
            if success and util.fileExists(cbz_path_tmp) then
                if util.fileExists(filePath) then
                    util.removeFile(cbz_path_tmp)
                    success = false
                else
                    local ok_rename, rename_err = os.rename(cbz_path_tmp, filePath)
                    if not ok_rename then
                        logger.err("from_urls_async: rename failed:", tostring(rename_err))
                        util.removeFile(cbz_path_tmp)
                        success = false
                    end
                end
            elseif util.fileExists(cbz_path_tmp) then
                util.removeFile(cbz_path_tmp)
            end
            if type(on_finish) == "function" then
                pcall(on_finish, not success, {
                    output = filePath,
                    success = success,
                    total = result and result.total,
                    completed = result and result.completed,
                    succeeded = result and result.succeeded,
                    failed = result and result.failed,
                })
            end
        end,
    })
    return ok, err
end

return M