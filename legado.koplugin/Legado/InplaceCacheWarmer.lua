local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")
local ffiUtil = require("ffi/util")
local util = require("util")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local Probe = require("Legado.Helper.Probe")
local TaskQueueV2 = require("Legado.task.v2")

local Warmer = {}
Warmer.__index = Warmer

local warm_sequence = 0
local stale_cleaned = false

local function cleanup_dir(path)
    if not path then return end
    pcall(ffiUtil.purgeDir, path)
    pcall(util.removePath, path)
end

local function cleanup_stale_dirs()
    if stale_cleaned then return end
    stale_cleaned = true
    local root = Env.getTempDirectory()
    pcall(function()
        for entry in lfs.dir(root) do
            if entry:match("^cr3warm_") then
                local path = FS.joinPath(root, entry)
                if lfs.attributes(path, "mode") == "directory" then
                    cleanup_dir(path)
                end
            end
        end
    end)
end

local function create_cache_dir()
    local root = Env.getTempDirectory()
    for _ = 1, 10 do
        warm_sequence = warm_sequence + 1
        local path = FS.joinPath(root, string.format("cr3warm_%d_%d",
            math.floor(socket.gettime() * 1000000), warm_sequence))
        if not lfs.attributes(path) then
            FS.checkAndCreateFolder(path)
            if lfs.attributes(path, "mode") == "directory" then return path end
        end
    end
end

local function snapshot(path)
    local attr = lfs.attributes(path)
    return attr and attr.size, attr and attr.modification
end

local function request_target(request)
    local file = request.doc and request.doc.file or "-"
    local name = type(file) == "string" and file:match("[^/]+$") or nil
    return string.format("%s revision=%s priority=%s",
        name or tostring(file), tostring(request.revision), tostring(request.priority))
end

function Warmer:new(on_ready)
    cleanup_stale_dirs()
    return setmetatable({ on_ready = on_ready }, self)
end

function Warmer:_finish(job, ok, cache_path, state)
    if self.job ~= job then return end
    self.job = nil

    if not ok then
        Probe.fail("Warm", "缓存预热任务", job.target, job.t_start,
            string.format("state=%s reason=%s", tostring(state), tostring(cache_path)), job.probe_context)
    end

    if self.pending then
        if ok then
            Probe.done("Warm", "缓存预热任务", job.target, job.t_start,
                "SUPERSEDED", nil, "discard", job.probe_context)
        end
        self:_launch()
        return
    end

    local invalid_reason
    if not ok then
        invalid_reason = tostring(state or "task_failed")
    elseif type(cache_path) ~= "string" or cache_path == "" then
        invalid_reason = "cache_path_missing"
    elseif cache_path:sub(1, #job.cache_dir + 1) ~= job.cache_dir .. "/" then
        invalid_reason = "cache_path_outside_warm_dir"
    elseif not cache_path:match("%.cr3$") then
        invalid_reason = "cache_extension_invalid"
    elseif lfs.attributes(cache_path, "mode") ~= "file" then
        invalid_reason = "cache_file_missing"
    end
    if invalid_reason then cache_path = nil end

    local request = job.request
    local size, modified = snapshot(request.doc.file)
    if size ~= request.size or modified ~= request.modified then
        invalid_reason = "epub_changed"
        cache_path = nil
    end
    if cache_path then
        Probe.done("Warm", "缓存预热任务", job.target, job.t_start,
            "CACHE_READY", Probe.format_bytes(lfs.attributes(cache_path, "size")), nil, job.probe_context)
    elseif ok then
        Probe.fail("Warm", "缓存预热任务", job.target, job.t_start,
            invalid_reason or "cache_invalid", job.probe_context)
    end
    self.on_ready(request, cache_path)
end

function Warmer:_launch()
    local request = self.pending
    self.pending = nil
    if not request then return end

    local cache_dir = create_cache_dir()
    if not cache_dir then
        self.on_ready(request)
        return
    end

    local storage_factor = 20
    if G_reader_settings and G_reader_settings.readSetting then
        storage_factor = tonumber(G_reader_settings:readSetting("cre_storage_size_factor")) or storage_factor
    end

    local doc = request.doc
    local target = request_target(request)
    local probe_context = Probe.context(string.format("warm:%s:r%s:%d",
        tostring(request.context and request.context.book_cache_id or "-"),
        tostring(request.revision), warm_sequence))
    if request.context then request.context._warm_trace_id = probe_context.trace_id end
    local timeout = 45
    local t_start = Probe.start("Warm", "缓存预热任务", target,
        function() return string.format("(timeout=%ss)", timeout) end, probe_context)
    if request.context then request.context._warm_probe_span = t_start end
    local task = TaskQueueV2.spawn(function(ctx)
        local child_context = Probe.child_context(probe_context, t_start)
        local t_child = Probe.start("Warm", "子进程预热", target, nil, child_context)
        local stage_context = Probe.child_context(probe_context, t_child)
        if ctx and ctx.throw_if_cancelled then ctx.throw_if_cancelled() end

        local t_cache = Probe.start("Warm", "初始化隔离缓存", target, nil, stage_context)
        local cre = require("document/credocument"):engineInit()
        cre.initCache(cache_dir, 0, true, storage_factor)
        Probe.done("Warm", "初始化隔离缓存", target, t_cache, "200 OK", nil, nil, stage_context)

        if doc.setCallback then doc:setCallback(nil) end
        local t_load = Probe.start("Warm", "加载 EPUB", target, nil, stage_context)
        if not doc._document:loadDocument(doc.file) then
            Probe.fail("Warm", "加载 EPUB", target, t_load, "loadDocument=false", stage_context)
            Probe.fail("Warm", "子进程预热", target, t_child, "loadDocument=false", child_context)
            return nil
        end
        Probe.done("Warm", "加载 EPUB", target, t_load, "200 OK", nil, nil, stage_context)
        doc._loaded = true
        if doc.isPartialRerenderingEnabled and doc:isPartialRerenderingEnabled() then
            doc:enablePartialRerendering(false)
        end

        local t_render = Probe.start("Warm", "完整排版", target, nil, stage_context)
        doc._document:renderDocument()
        Probe.done("Warm", "完整排版", target, t_render, "200 OK", nil, nil, stage_context)
        if ctx and ctx.throw_if_cancelled then ctx.throw_if_cancelled() end

        local t_toc = Probe.start("Warm", "更新目录页图", target, nil, stage_context)
        doc._document:updateTocAndPageMap()
        Probe.done("Warm", "更新目录页图", target, t_toc, "200 OK", nil, nil, stage_context)
        local cache_path = doc:getCacheFilePath()

        local t_close = Probe.start("Warm", "关闭并写入缓存", target, nil, stage_context)
        doc._document:close()
        local function cache_size()
            return Probe.format_bytes(cache_path and lfs.attributes(cache_path, "size"))
        end
        Probe.done("Warm", "关闭并写入缓存", target, t_close, "200 OK",
            cache_size, nil, stage_context)
        Probe.done("Warm", "子进程预热", target, t_child, "200 OK",
            cache_size, nil, child_context)
        return cache_path
    end, {
        timeout = timeout,
        retry = 0,
    })

    local job = {
        task = task,
        request = request,
        cache_dir = cache_dir,
        target = target,
        probe_context = probe_context,
        t_start = t_start,
    }
    self.job = job
    task:on("done", function(ok, value, state)
        local finished, err = pcall(self._finish, self, job, ok, value, state)
        cleanup_dir(job.cache_dir)
        job.cache_dir = nil
        if not finished then error(err) end
    end)
end

function Warmer:request(doc, revision, priority, context)
    local size, modified = snapshot(doc.file)
    local request = {
        doc = doc,
        revision = revision,
        priority = priority,
        context = context,
        size = size,
        modified = modified,
    }

    if self.pending and self.pending.priority == "urgent" then
        request.priority = "urgent"
    elseif self.job and self.job.request.priority == "urgent" then
        request.priority = "urgent"
    end

    local job = self.job
    if not job then
        Probe.event("Warm", "收到预热请求", function() return request_target(request) end)
        self.pending = request
        self:_launch()
        return
    end

    local running = job.request
    if running.doc == doc and running.revision == revision then
        local promoted = running.priority ~= "urgent" and request.priority == "urgent"
        running.priority = request.priority
        context._warm_trace_id = running.context._warm_trace_id
        context._warm_probe_span = running.context._warm_probe_span
        running.context = context
        if promoted then
            Probe.event("Warm", "预热请求升级", function() return request_target(request) end)
        else
            Probe.event("Warm", "合并重复预热请求", function() return request_target(request) end)
        end
        return
    end

    Probe.event("Warm", "替换待预热版本", function()
        return string.format("running_revision=%s next=%s",
            tostring(running.revision), request_target(request))
    end)
    self.pending = request
    if request.priority == "urgent" and running.priority ~= "urgent" then
        job.task:cancel("cache_warmer_superseded")
    end
end

function Warmer:cancel()
    self.pending = nil
    local job = self.job
    if job then Probe.event("Warm", "取消预热任务", function() return job.target end) end
    self.job = nil
    if job and job.task and not job.task:is_done() then
        job.task:cancel("cache_warmer_cancelled")
    end
end

return Warmer
