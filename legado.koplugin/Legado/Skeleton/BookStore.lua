local Backend = require("Legado/Backend")
local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local Probe = require("Legado.Helper.Probe")
local ffiUtil = require("ffi/util")
local DocSettings = require("docsettings")
local M = { _epub_revision = {} }

local function ensure_directory(dir)
    if not (H.is_str(dir) and dir ~= "") then return nil, "整本缓存保存目录无效" end
    if util.directoryExists(dir) then return dir end
    pcall(FS.checkAndCreateFolder, dir)
    if util.directoryExists(dir) then return dir end
    return nil, "整本缓存保存目录不可用，且无法创建：" .. dir
end

function M:getPath(book_cache_id, book_name)
    if not book_cache_id then return nil end
    return Env.getVirtualBookEpubPath(book_cache_id, book_name, Backend:getFullBookCacheOutputDir())
end

function M:location(book_cache_id, epub_path)
    if not (H.is_str(book_cache_id) and book_cache_id ~= "") then return nil end
    local record = Backend:getLuaConfig(self:getLocationRecord(book_cache_id))
    if H.is_str(epub_path) and epub_path ~= "" then
        local old = record:readSetting("path")
        if old ~= epub_path then
            record:saveSetting("path", epub_path):flush()
        end
        return epub_path
    end
    local p = record:readSetting("path")
    return H.is_str(p) and p or nil
end

function M:getLocationRecord(book_cache_id)
    return FS.joinPath(Env.getBookCachePath(book_cache_id), "virtual_book_location.lua")
end

function M:isSupported()
    return require("Legado.Skeleton.Epub").isSupported()
end

function M:isPlaceholder(content)
    return require("Legado.Skeleton.Epub").isPlaceholderHtml(content)
end

function M:isUsable(path, book_cache_id)
    if not (H.is_str(path) and util.fileExists(path)) then return false end

    local ds = DocSettings:open(path)
    if not ds or ds:readSetting("book_cache_id") ~= book_cache_id then return false end

    local SkeletonEpub = require("Legado.Skeleton.Epub")
    local version = ds:readSetting("virtual_book_schema_version") or 0
    local chapters_count = ds:readSetting("virtual_book_chapters_count") or 0
    return version >= SkeletonEpub.SKELETON_SCHEMA_VERSION and chapters_count > 0
end

function M:ensureEpub(bookinfo, _, custom_output_path)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        return nil, "invalid bookinfo"
    end
    local book_cache_id = bookinfo.cache_id
    local output_dir, dir_err
    if custom_output_path then
        output_dir = util.splitFilePathName(custom_output_path)
        output_dir, dir_err = ensure_directory(output_dir)
    else
        output_dir, dir_err = Backend:ensureFullBookCacheOutputDir()
    end
    if not output_dir then return nil, dir_err end

    local epub_path = custom_output_path or Env.getVirtualBookEpubPath(
        book_cache_id,
        string.format("%s-%s", bookinfo.name or bookinfo.title or "未知书名", bookinfo.author or "未知作者"),
        output_dir
    )
    if not epub_path then return nil, "cannot resolve epub path" end

    local SkeletonEpub = require("Legado.Skeleton.Epub")
    if not custom_output_path and not (FS.getFileSize(epub_path) > 1024) then
        local old_path = self:location(book_cache_id)
        if H.is_str(old_path) and old_path ~= "" and old_path ~= epub_path and util.fileExists(old_path) then
            local ok_mv = FS.moveFile(old_path, epub_path)
            if not ok_mv then
                ok_mv = FS.copyRecursive(old_path, epub_path) and util.removeFile(old_path)
            end
            if ok_mv then
                local old_sdr, new_sdr = old_path .. ".sdr", epub_path .. ".sdr"
                if util.pathExists(old_sdr) then
                    local ok_sdr = FS.moveFile(old_sdr, new_sdr)
                    if not ok_sdr then
                        ok_sdr = FS.copyRecursive(old_sdr, new_sdr)
                        if ok_sdr then
                            pcall(function() ffiUtil.purgeDir(old_sdr) util.removePath(old_sdr) end)
                        end
                    end
                end
                self:location(book_cache_id, epub_path)
            else
                logger.warn("virtual book recover move failed:", old_path, epub_path)
            end
        end
    end

    local SKELETON_SCHEMA_VERSION = SkeletonEpub.SKELETON_SCHEMA_VERSION or 3
    if FS.getFileSize(epub_path) > 1024 then
        local ds = DocSettings:open(epub_path)
        local ver = ds and ds:readSetting("virtual_book_schema_version")
        local stored_book_cache_id = ds and ds:readSetting("book_cache_id")
        local stored_chapters_count = ds and ds:readSetting("virtual_book_chapters_count")
        if not ver or stored_book_cache_id ~= book_cache_id or not H.is_num(stored_chapters_count) or stored_chapters_count < 1 then
            local preserve_ver = ver and stored_book_cache_id == book_cache_id
            local restored, metadata = SkeletonEpub.restoreDocSettings(epub_path, book_cache_id)
            ver = restored and (metadata.schema_version or preserve_ver) or nil
        end
        if ver and ver >= SKELETON_SCHEMA_VERSION then
            self:location(book_cache_id, epub_path)
            return epub_path
        end
    end

    local chapters = Backend:getReadableChapters(book_cache_id)
    if not H.is_tbl(chapters) or #chapters == 0 then
        return nil, "目录为空或获取失败，请先刷新书籍目录"
    end

    local cover_path = bookinfo.cover_path or Backend:get_default_cover_cache(book_cache_id)
    if not cover_path then
        local ImageUtil = require("Legado.Helper.ImageUtil")
        cover_path = ImageUtil.get_default_cover_cache(book_cache_id)
    end

    local toc = {}
    local chapters_content = {}
    for i, ch in ipairs(chapters) do
        local ch_idx = ch.chapters_index or (i - 1)
        table.insert(toc, {
            index = ch_idx,
            title = ch.title or ch.name or string.format("第%d章", ch_idx + 1),
        })
        local ch_cache = Backend:getCacheChapterFilePath(ch, true)
        local cache_file = (ch_cache and ch_cache.cacheFilePath) or ch.cacheFilePath
        if cache_file and util.fileExists(cache_file) and not cache_file:lower():match("%.cbz$") then
            local data = util.readFromFile(cache_file)
            if data and data ~= "" and not SkeletonEpub.isPlaceholderHtml(data) then
                chapters_content[ch_idx] = data
            end
        end
    end

    local ok_build, err_build = SkeletonEpub.buildSkeleton({
        bookinfo = {
            title = bookinfo.name or bookinfo.title or "未知书名",
            author = bookinfo.author or "未知作者",
            description = bookinfo.intro or "",
            cache_id = book_cache_id,
        },
        toc = toc,
        chapters_content = chapters_content,
        cover_path = cover_path,
        output_path = epub_path,
    })

    if not ok_build then return nil, err_build end
    self:location(book_cache_id, epub_path)
    return epub_path
end

function M:syncNewChapters(book_cache_id, book_name, on_appended)
    if not book_cache_id then return false end
    local bookinfo = Backend:getBookInfoCache(book_cache_id)
    local full_name = (bookinfo and bookinfo.name) and string.format("%s-%s", bookinfo.name, bookinfo.author or "未知作者") or book_name
    local epub_path = self:getPath(book_cache_id, full_name)
    if not (epub_path and util.fileExists(epub_path)) then return false end

    local chapters = Backend:getReadableChapters(book_cache_id)
    if not (H.is_tbl(chapters) and #chapters > 0) then return false end

    local ds = DocSettings:open(epub_path)
    local epub_ch_count = ds and ds:readSetting("virtual_book_chapters_count")
    if not epub_ch_count then
        epub_ch_count = #chapters
        if ds then ds:saveSetting("virtual_book_chapters_count", epub_ch_count):flush() end
        return false
    end

    if #chapters > epub_ch_count then
        local SkeletonEpub = require("Legado.Skeleton.Epub")
        local new_toc = {}
        local new_contents = {}
        for i = epub_ch_count + 1, #chapters do
            local ch = chapters[i]
            local ch_idx = ch.chapters_index or (i - 1)
            table.insert(new_toc, {
                index = ch_idx,
                title = ch.title or ch.name or string.format("第%d章", ch_idx + 1),
            })
            local ch_cache = Backend:getCacheChapterFilePath(ch, true)
            local cache_file = (ch_cache and ch_cache.cacheFilePath) or ch.cacheFilePath
            if cache_file and util.fileExists(cache_file) and not cache_file:lower():match("%.cbz$") then
                local data = util.readFromFile(cache_file)
                if data and data ~= "" and not SkeletonEpub.isPlaceholderHtml(data) then
                    new_contents[ch_idx] = data
                end
            end
        end

        if #new_toc > 0 then
            local ok, err = SkeletonEpub.appendChapters(epub_path, new_toc, new_contents, book_cache_id)
            if ok then
                self._epub_revision = self._epub_revision or {}
                self._epub_revision[epub_path] = (self._epub_revision[epub_path] or 0) + 1
                if ds then ds:saveSetting("virtual_book_chapters_count", #chapters):flush() end
                if on_appended then on_appended(epub_path) end
                return true
            else
                logger.warn("syncVirtualBookNewChapters append failed: " .. tostring(err))
            end
        end
    end
    return false
end

function M:syncChapters(book_cache_id, chapters_map, book_name)
    if not book_cache_id or not chapters_map or next(chapters_map) == nil then return false end
    local bookinfo = Backend:getBookInfoCache(book_cache_id)
    local full_name = (bookinfo and bookinfo.name) and string.format("%s-%s", bookinfo.name, bookinfo.author or "未知作者") or book_name
    local epub_path = self:getPath(book_cache_id, full_name)
    if not epub_path or not util.fileExists(epub_path) then return false end

    local count = 0
    for _ in pairs(chapters_map) do count = count + 1 end

    local title_toc = {}
    for ch_idx in pairs(chapters_map) do
        if H.is_num(ch_idx) then
            local chapter = Backend:getChapterInfoCache(book_cache_id, ch_idx)
            if H.is_tbl(chapter) then
                title_toc[ch_idx + 1] = { title = chapter.title }
            end
        end
    end

    local t_inject_start = Probe.start("Inject", "批量注入", string.format("共%d章 (book_id: %s)", count, tostring(book_cache_id)))
    local SkeletonEpub = require("Legado.Skeleton.Epub")
    local ok, err, changed = SkeletonEpub.updateChapters(epub_path, chapters_map, {
        toc = title_toc,
        get_toc = function()
            return Backend:getReadableChapters(book_cache_id)
        end,
    }, book_cache_id)

    if not ok and H.is_tbl(bookinfo)
            and tostring(err):find("^skeleton_structure_mismatch:") then
        logger.warn("virtual book structure mismatch, rebuilding:", tostring(err))
        pcall(util.removeFile, epub_path)
        if util.fileExists(epub_path) then
            err = "rebuild skeleton failed: cannot remove damaged epub"
        else
            local rebuilt_path, rebuild_err = self:ensureEpub(bookinfo, nil, epub_path)
            if rebuilt_path and util.fileExists(rebuilt_path) then
                ok, err, changed = SkeletonEpub.updateChapters(rebuilt_path, chapters_map, {
                    toc = title_toc,
                    get_toc = function()
                        return Backend:getReadableChapters(book_cache_id)
                    end,
                }, book_cache_id)
                if ok then changed = true end
            else
                err = "rebuild skeleton failed: " .. tostring(rebuild_err or err)
            end
        end
    end

    if ok then
        if changed ~= false then
            self._epub_revision = self._epub_revision or {}
            self._epub_revision[epub_path] = (self._epub_revision[epub_path] or 0) + 1
        end
        Probe.done("Inject", "批量注入完成", string.format("共%d章 (book_id: %s)", count, tostring(book_cache_id)), t_inject_start, "200 OK")
    else
        Probe.fail("Inject", "批量注入失败", string.format("共%d章 (book_id: %s)", count, tostring(book_cache_id)), t_inject_start, tostring(err))
    end
    return ok, err, changed
end

function M:syncChapter(book_cache_id, chapter_idx, raw_content, book_name)
    return self:syncChapters(book_cache_id, { [chapter_idx] = raw_content }, book_name)
end

function M:createTransformHook(book_cache_id)
    local SkeletonEpub = require("Legado.Skeleton.Epub")
    return {
        transformEntry = function(_, path)
            local ch_idx = SkeletonEpub.parseChapterIndexFromEntryPath(path)
            if ch_idx and Backend.dbManager then
                local ch = Backend.dbManager:findChapterByIndex(book_cache_id, ch_idx)
                local ch_cache = ch and Backend:getCacheChapterFilePath(ch, true)
                local cache_file = (ch_cache and ch_cache.cacheFilePath) or (ch and ch.cacheFilePath)
                if cache_file and util.fileExists(cache_file) and not cache_file:lower():match("%.cbz$") then
                    local raw = util.readFromFile(cache_file)
                    if raw and raw ~= "" and not SkeletonEpub.isPlaceholderHtml(raw) then
                        return SkeletonEpub.formatChapterXhtml(ch_idx, ch.title or ch.name, raw)
                    end
                end
            end
            return nil
        end
    }
end

return M
