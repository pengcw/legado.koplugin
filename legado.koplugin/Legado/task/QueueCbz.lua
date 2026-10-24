local logger = require("logger")
local util = require("util")
local TaskQueue = require("Legado.task.Queue")
local ZipUtil = require("Legado.Helper.ZipUtil")
local ZipWrite = ZipUtil.Writer
local ImageUtil = require("Legado.Helper.ImageUtil")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Probe = require("Legado.Helper.Probe")

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
        if type(self.params.finalize_callback) == "function" then
            local entries_ok, entries = pcall(self.params.finalize_callback, {
                aborted = self.aborted,
                total = self.total,
                completed = self.completed,
                succeeded = self.succeeded,
                failed = self.failed,
            })
            if not entries_ok then
                close_ok = false
                logger.err("CBZ finalize_callback failed:", tostring(entries))
            elseif type(entries) == "table" then
                for _, entry in ipairs(entries) do
                    if type(entry) == "table" and entry.name and type(entry.data) == "string" then
                        local call_ok, add_ok, add_err = pcall(self.writer.add, self.writer, entry.name, entry.data, entry.no_compression)
                        if not call_ok then
                            close_ok = false
                            logger.warn("finalize entry add panic:", entry.name, tostring(add_ok))
                            break
                        end
                        if add_ok ~= true then
                            close_ok = false
                            logger.warn("finalize entry add failed:", entry.name, tostring(add_err or add_ok))
                            break
                        end
                    end
                end
            end
        end
        local close_call_ok, close_ret, close_err = pcall(self.writer.close, self.writer)
        if not close_call_ok then
            close_ok = false
            logger.err("CBZ writer close panic:", tostring(close_ret))
        elseif close_ret == false then
            close_ok = false
            logger.err("CBZ writer close failed:", tostring(close_err or "unknown error"))
        end
        self.writer = nil
    end

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
    local open_ok, open_err = writer:open(self.output)
    if not open_ok then
        pcall(writer.close, writer)
        return nil, "failed to open cbz: " .. self.output .. (open_err and (": " .. tostring(open_err)) or "")
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
                    return true
                end
                return false
            end

            local add_ok, ret, add_err = pcall(self.writer.add, self.writer, item.name, result, true)
            if not add_ok or ret == false then
                self.failed = self.failed + 1
                self.aborted = true
                local add_msg = add_ok and (add_err or "zip add failed") or tostring(ret)
                logger.err("CBZBatchWriter: ZIP add failed:", item.name, add_msg)

                if self.params.on_progress then
                    pcall(self.params.on_progress, self.completed, self.total, index, item, false, add_msg, retries_used)
                end
                return true
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

function M.from_urls(filePath, img_sources, check_running_callback, opts)
    if type(filePath) ~= "string" or filePath == "" then
        error("Cbz param error: invalid filePath")
    end
    if type(img_sources) ~= "table" or #img_sources == 0 then
        error("Cbz param error: invalid img_sources")
    end
    opts = opts or {}
    local max_workers = math.max(1, math.floor(tonumber(opts.max_workers) or 4))
    local total_items = #img_sources
    local desc = opts.chapter_desc or (opts.comic_info and opts.comic_info.name) or filePath

    local t_cbz_start = Probe.start("Chapter", "CBZ打包", desc, string.format("(%dP, workers=%d)", total_items, max_workers))

    local cbz_path_tmp = filePath .. '.downloading'
    if util.fileExists(cbz_path_tmp) then
        if type(check_running_callback) == "function" and check_running_callback() then
            Probe.retry("Chapter", "CBZ已取消", desc, t_cbz_start, "Other threads downloading")
            error("Other threads downloading, cancelled")
        else
            util.removeFile(cbz_path_tmp)
        end
    end
    local new_ok, writer = pcall(ZipWrite.new, ZipWrite)
    if not new_ok or not writer then
        Probe.fail("Chapter", "CBZ初始化失败", desc, t_cbz_start, tostring(writer))
        error("CreateCBZ init zip backend err: " .. tostring(writer))
    end
    local open_ok, open_err = writer:open(cbz_path_tmp)
    if not open_ok then
        pcall(writer.close, writer)
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        Probe.fail("Chapter", "CBZ打开失败", desc, t_cbz_start, tostring(open_err))
        error("CreateCBZ cbz:open err: " .. cbz_path_tmp .. (open_err and (": " .. tostring(open_err)) or ""))
    end

    local mimetype_ok, mimetype_err = writer:add("mimetype", "application/vnd.comicbook+zip", true)
    if not mimetype_ok then
        pcall(writer.close, writer)
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        Probe.fail("Chapter", "CBZ写入mimetype失败", desc, t_cbz_start, tostring(mimetype_err))
        error("CreateCBZ write mimetype err: " .. tostring(mimetype_err))
    end

    local downloaded_entries = {}
    local succeeded = 0
    local strict = (opts.allow_failed == false)
    local function abort(msg)
        pcall(writer.close, writer)
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        Probe.fail("Chapter", "CBZ失败", desc, t_cbz_start, tostring(msg))
        error(msg)
    end

    local function download_one(i, img_src)
        if type(check_running_callback) == "function" and check_running_callback() then
            abort("Other threads downloading, cancelled")
        end
        local t_img_start = H.timestamp()
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
            headers = opts.headers,
        })
        if not imgdata then
            if strict then abort(string.format("CreateCBZ download err: %s", tostring(img_extension))) end
            logger.dbg('CreateCBZ download err:', url, tostring(img_extension))
            Probe.retry("Chapter", "图片下载跳过", string.format("%d.img", i), t_img_start, string.format("原因: %s [进度 %d/%d]", tostring(img_extension), i, total_items))
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

        downloaded_entries[i] = {
            name = img_name,
            data = imgdata,
            t_start = t_img_start,
        }
        return true
    end

    local ok_copas, copas = pcall(require, "Legado.vendor.copas")
    if ok_copas and copas and max_workers > 1 and total_items > 1 then
        local next_idx = 1
        local active_workers = max_workers
        local has_aborted = false
        local abort_err = nil

        for w = 1, max_workers do
            copas.addnamedthread(string.format("cbz_worker_%d", w), function()
                while not has_aborted do
                    local cur_i = next_idx
                    next_idx = next_idx + 1
                    if cur_i > total_items then break end

                    local ok, res = pcall(download_one, cur_i, img_sources[cur_i])
                    if not ok then
                        has_aborted = true
                        abort_err = res
                        break
                    end
                end
                active_workers = active_workers - 1
            end)
        end

        while active_workers > 0 and not has_aborted do
            copas.step(0.02)
        end

        if has_aborted then
            abort(tostring(abort_err or "copas worker aborted"))
        end
    else
        for i, img_src in ipairs(img_sources) do
            download_one(i, img_src)
        end
    end

    for i = 1, total_items do
        local entry = downloaded_entries[i]
        if entry and entry.data then
            local add_ok, add_err = writer:add(entry.name, entry.data, true)
            if not add_ok then
                if strict then abort(string.format("CreateCBZ zip add err: %s (%s)", entry.name, tostring(add_err))) end
                logger.warn("CreateCBZ: zip add failed, skipped:", entry.name, add_err)
            else
                succeeded = succeeded + 1
                Probe.done("Chapter", "图片落盘", entry.name, entry.t_start, "200 OK", Probe.format_bytes(#entry.data), string.format("进度 %d/%d", succeeded, total_items))
            end
        end
    end

    if succeeded > 0 then
        local comic_ok, comic_err = writer:add("ComicInfo.xml", ZipUtil.createComicInfo(opts.comic_info, succeeded), true)
        if not comic_ok then
            logger.warn("CreateCBZ: ComicInfo.xml add failed:", tostring(comic_err))
        end
    end
    local close_ok, close_err = writer:close()
    if not close_ok then
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        Probe.fail("Chapter", "CBZ关闭失败", desc, t_cbz_start, tostring(close_err))
        error("CreateCBZ cbz:close err: " .. tostring(close_err))
    end
    if succeeded == 0 then
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        Probe.fail("Chapter", "CBZ无图片成功", desc, t_cbz_start, "no image downloaded")
        error("CreateCBZ: no image downloaded")
    end
    if util.fileExists(filePath) then
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        Probe.fail("Chapter", "CBZ目标文件已存在", desc, t_cbz_start, "exist target file")
        error('exist target file, cancelled')
    end
    local ok_rename, rename_err = os.rename(cbz_path_tmp, filePath)
    if not ok_rename then
        if util.fileExists(cbz_path_tmp) then util.removeFile(cbz_path_tmp) end
        Probe.fail("Chapter", "CBZ重命名失败", desc, t_cbz_start, tostring(rename_err))
        error(string.format("CreateCBZ rename err: %s", tostring(rename_err)))
    end

    local cbz_sz = FS.getFileSize(filePath)
    Probe.done("Chapter", "CBZ完成", desc, t_cbz_start, "200 OK", Probe.format_bytes(cbz_sz), string.format("%d/%dP", succeeded, total_items))
    return filePath
end

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
                headers = opts.headers,
            })
            return data
        end,
        max_workers = opts.max_workers,
        max_retries = opts.max_retries,
        timeout = opts.timeout,
        allow_failed = (opts.allow_failed ~= false),
        keep_partial = true,
        check_running = params.check_running,
        finalize_callback = function(result)
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