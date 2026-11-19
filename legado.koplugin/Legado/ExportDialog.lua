local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ffiUtil = require("ffi/util")
local util = require("util")
local DocSettings = require("docsettings")
local logger = require("logger")

local Icons = require("Legado.res.icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local ZipUtil = require("Legado.Helper.ZipUtil")
local image_meta = require("Legado.Helper.image_meta")
local Error = require("Legado.Helper.Error")

local CbzExporter = {
    bookinfo = nil,
    output_file = nil,
    cache_chapters = nil,
    reportProgress = nil,
}
function CbzExporter:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o.init then o:init() end
    return o
end
function CbzExporter:createMimetype()
    return "application/vnd.comicbook+zip"
end
function CbzExporter:createComicInfo(total_pages)
    return ZipUtil.createComicInfo(self.bookinfo, total_pages)
end
function CbzExporter:package()
    if not H.is_tbl(self.bookinfo) then
        return { success = false, error = "无效的书籍信息"}
    end
    if not (H.is_tbl(self.cache_chapters) and #self.cache_chapters > 0) then
        return {success = false, error = "没有可导出的章节"}
    end
    self.bookinfo.name = self.bookinfo.name or "未知书名"
    self.bookinfo.author = self.bookinfo.author or "未知作者"

    local output_path = self.output_file
    local cbz_path_tmp = output_path .. '.tmp'

    if util.fileExists(cbz_path_tmp) then
        pcall(util.removeFile, cbz_path_tmp)
    end

    local function get_image_ext(filename)
        return image_meta.get_image_ext(filename)
    end

    local cbz
    local new_ok, writer = pcall(ZipUtil.Writer.new, ZipUtil.Writer)
    if not new_ok or not writer then
        local err_msg = "无法加载任何压缩库"
        return {
            success = false,
            error = err_msg
        }
    end
    cbz = writer
    local open_ok, open_err = cbz:open(cbz_path_tmp)
    if not open_ok then
        local err_msg = string.format("无法创建 CBZ 文件: %s", tostring(open_err))
        return {
            success = false,
            error = err_msg
        }
    end

    local chapter_reader
    local function addFile(path, content, no_compress)
        local ok, err = cbz:add(path, content, no_compress)
        if not ok then error("无法写入 " .. path .. ": " .. tostring(err), 0) end
    end

    local write_ok, write_err = pcall(function()
        addFile("mimetype", self:createMimetype(), true)
        local image_index = 1
        local total_pages = 0
        for current_progress, chapter in ipairs(self.cache_chapters) do
            local path = chapter.cacheFilePath
            if not H.is_str(path) then error("章节缓存路径无效", 0) end
            if path:match("%.cbz$") then
                chapter_reader = ZipUtil.Reader:new()
                if not chapter_reader then error("无法创建章节解压器", 0) end
                local ok, err = chapter_reader:open(path)
                if not ok then error("无法解压章节: " .. tostring(err), 0) end
                chapter_reader:iterate(function(entry)
                    if entry.path:find("ComicInfo%.xml$") then return true end
                    local ext = get_image_ext(entry.path)
                    if entry.mode == "file" and ext then
                        local data, extract_err = chapter_reader:extractToMemory(entry.path)
                        if not data then error("无法读取图片: " .. tostring(extract_err), 0) end
                        addFile(string.format("%04d.%s", image_index, ext), data)
                        image_index = image_index + 1
                        total_pages = total_pages + 1
                    end
                    return true
                end)
                chapter_reader:close()
                chapter_reader = nil
            else
                local ext = get_image_ext(path)
                if not H.is_str(ext) then error("不支持的章节缓存: " .. path, 0) end
                local data = util.readFromFile(path, "rb")
                if not data then error("无法读取章节图片: " .. path, 0) end
                addFile(string.format("%04d.%s", image_index, ext:lower()), data)
                image_index = image_index + 1
                total_pages = total_pages + 1
            end
            if H.is_func(self.reportProgress) then self.reportProgress(current_progress) end
        end
        if total_pages == 0 then error("没有可导出的图片", 0) end
        addFile("ComicInfo.xml", self:createComicInfo(total_pages), true)
    end)
    if chapter_reader then pcall(chapter_reader.close, chapter_reader) end
    local close_ok, closed, close_err = pcall(cbz.close, cbz)
    if not write_ok or not close_ok or not closed then
        pcall(util.removeFile, cbz_path_tmp)
        return {success = false, error = tostring(not write_ok and write_err
            or (not close_ok and closed or close_err) or "无法关闭 CBZ 文件")}
    end

    local renamed, rename_err = os.rename(cbz_path_tmp, output_path)
    if not renamed then
        pcall(util.removeFile, cbz_path_tmp)
        return {success = false, error = "无法重命名 CBZ 文件: " .. tostring(rename_err)}
    end

    return {
        success = true,
        path = output_path
    }
end

local active_exports = {}

local M = {
    bookinfo = nil,
    chapter_count = nil,
    chapter_cache_status = nil,
    temp_disable_multithread = nil,
}

function M:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o.init then o:init() end
    return o
end

function M:_getChapterCount(book_cache_id)
    if not (H.is_str(book_cache_id) and book_cache_id ~= "") then
        logger.err("getChapterCount err - book_cache_id ->", tostring(book_cache_id))
        return 0
    end
    if H.is_num(self.chapter_count) and self.chapter_count >= 0 then
        return self.chapter_count
    end
    self.chapter_count = Backend:getChapterCount(book_cache_id)
    return self.chapter_count
end
function M:showExportSuccessDialog(result, open_callback)
    local filename = result.path and result.path:match("([^/\\]+)$") or "未知"
    local output_dir = result.path and result.path:match("(.+)[/\\]") or Env.getHomeDir()

    MessageBox:confirm(
        string.format("导出成功！\n\n文件：%s\n位置：%s", filename, output_dir),
        function(open_file)
            if open_file and result.path and H.is_func(open_callback) then
                UIManager:nextTick(function()
                    open_callback(result.path)
                end)
            end
        end,
        {
            ok_text = "打开",
            cancel_text = "完成"
        }
    )
end

function M:showExportErrorDialog(error_info, retry_callback)
    local error_msg = "导出失败"
    if H.is_tbl(error_info) then
        error_msg = error_info.error or "未知错误"
    elseif H.is_str(error_info) then
        error_msg = error_info
    end
    local can_retry = H.is_func(retry_callback)
    MessageBox:confirm(
        error_msg,
        function(retry)
            if retry and H.is_func(retry_callback) then
                retry_callback()
            end
        end,
        {
            no_ok_button = not can_retry,
            ok_text = "重试",
            cancel_text = can_retry and "完成" or "知道了"
        }
    )
end

function M:prepareChaptersForExport(bookinfo, only_cached, completion_callback)
    if not H.is_func(completion_callback) then
        completion_callback = function(success, result) end
    end
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        return completion_callback(false, { error = "书籍信息错误" })
    end

    local book_cache_id = bookinfo.cache_id
    local chapter_count = self:_getChapterCount(book_cache_id)

    if not chapter_count or chapter_count == 0 then
        return completion_callback(false, { error = "该书没有章节, 请刷新目录" })
    end

    local cache_status
    if H.is_tbl(self.chapter_cache_status) then
        cache_status = self.chapter_cache_status
    else
        cache_status = Backend:analyzeCacheStatus(book_cache_id, nil, only_cached and bookinfo.book_self_id or nil)
        if not (H.is_tbl(cache_status) and H.is_tbl(cache_status.cached_chapters) and H.is_tbl(cache_status.uncached_chapters)) then
            return completion_callback(false, { error = "查询章节缓存状态出错" })
        end
    end

    if only_cached then
        return completion_callback(true, { chapters = cache_status.cached_chapters, total_count = chapter_count })
    end

    if cache_status.uncached_count == 0 then
        return completion_callback(true, { chapters = cache_status.cached_chapters, total_count = chapter_count })
    end

    local down_completion_callback = function(is_complete)
        if is_complete == true then
            local final_chapters = Backend:getBookChapterPlusCache(book_cache_id)
            completion_callback(true, { chapters = final_chapters, total_count = chapter_count })
        else
            completion_callback(false, { error = "缓存章节失败: "})
        end
    end

    self:startCacheChapters(bookinfo, cache_status.uncached_chapters or {}, chapter_count, nil, down_completion_callback)
end

function M:cacheAllChapters(completion_callback)
    local bookinfo = self.bookinfo
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        return MessageBox:error("书籍信息错误")
    end
    if not H.is_func(completion_callback) then
        completion_callback = function(success) end
    end
    local book_cache_id = bookinfo.cache_id

    TaskProg.loading("正在统计已缓存章节", function()
        return Backend:analyzeCacheStatus(book_cache_id)
    end, function(state, response)
        if not (state == true and H.is_tbl(response) and H.is_tbl(response.cached_chapters) and H.is_tbl(response.uncached_chapters)) then
            return MessageBox:error("查询章节缓存状态出错")
        end

        local chapter_count = response.total_count
        local cached_count = response.cached_count
        local uncached_count = response.uncached_count

        if uncached_count == 0 then
            return MessageBox:success(string.format("%s 个章节已全部缓存！",chapter_count))
        end

        MessageBox:confirm(string.format(
            "书名：<<%s>>\n作者：%s\n\n总章节：%d\n已缓存：%d\n待缓存：%d\n\n是否开始缓存全书？",
            bookinfo.name or "未命名",
            bookinfo.author or "未知作者",
            chapter_count,
            cached_count,
            uncached_count
        ), function(result)
            if not result then return completion_callback(false) end
            self:startCacheChapters(bookinfo, response.uncached_chapters or {}, chapter_count, nil, completion_callback)
        end, {
            ok_text = "开始缓存",
            cancel_text = "取消"
        })
    end)
end

function M:cacheSelectedChapters(start_chapter_index, down_chapter_count, completion_callback)
    local bookinfo = self.bookinfo
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id and H.is_num(start_chapter_index)) then
        return MessageBox:error("书籍信息错误")
    end
    if not H.is_func(completion_callback) then
        completion_callback = function(success) end
    end

    local book_cache_id = bookinfo.cache_id
    local start_index = tonumber(start_chapter_index)
    local actual_chapter_count = self:_getChapterCount(book_cache_id )

    if start_index < 0 then start_index = 0 end
    if not (H.is_num(actual_chapter_count) and actual_chapter_count > 0) then
        return MessageBox:error("该书章节列表为空，请手动刷新目录后再缓存")
    end

    if start_index >= actual_chapter_count then
        return MessageBox:notice("已经是最后一章")
    end

    local target_chapter_count
    if H.is_num(down_chapter_count) then
        target_chapter_count = start_index + down_chapter_count + 1
        if target_chapter_count > actual_chapter_count then
            target_chapter_count = actual_chapter_count
            MessageBox:notice(string.format("超出书籍总章数，将缓存至最后一章。实际缓存章节数：%d", target_chapter_count - start_index))
        end
    else
        target_chapter_count = actual_chapter_count
    end

    TaskProg.loading("正在统计已缓存章节", function()
        return Backend:analyzeCacheStatusForRange(book_cache_id , start_index, target_chapter_count - 1)
    end, function(state, response)
        if not (state == true and H.is_tbl(response) and H.is_tbl(response.cached_chapters) and H.is_tbl(response.uncached_chapters)) then
            return MessageBox:error("查询章节缓存状态出错")
        end

        local uncached_in_range = {}
        local total_in_range = target_chapter_count - start_index
        local cached_in_range = 0

        for _, chapter in ipairs(response.uncached_chapters) do
            local chapter_index = tonumber(chapter.chapters_index)
            if chapter_index and chapter_index >= start_index and chapter_index < target_chapter_count then
                table.insert(uncached_in_range, chapter)
            end
        end

        cached_in_range = total_in_range - #uncached_in_range
        if #uncached_in_range == 0 then
            return MessageBox:success(string.format("选定章节已全部缓存！\n选定章节：%d", total_in_range))
        end

        MessageBox:confirm(string.format(
            "书名：<<%s>>\n起始章节：第%d章\n\n选定章节：%d\n已缓存：%d\n待缓存：%d\n\n是否开始缓存？",
            bookinfo.name or "未命名",
            start_index + 1,
            total_in_range,
            cached_in_range,
            #uncached_in_range
        ), function(result)
            if result then
                self:startCacheChapters(nil, uncached_in_range, target_chapter_count, nil, completion_callback, true)
            end
        end, {
            ok_text = "开始缓存",
            cancel_text = "取消"
        })
    end)
end

function M:startCacheChapters(bookinfo, uncached_chapters, chapter_count, retry_count, completion_callback, skip_cache_integrity_check)
    bookinfo = bookinfo or self.bookinfo
    retry_count = retry_count or 0

    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        return MessageBox:error("书籍信息错误")
    end
    if not H.is_func(completion_callback) then
        completion_callback = function() end
    end

    if not H.is_tbl(uncached_chapters) or #uncached_chapters == 0 then
        MessageBox:error("没有需要缓存的章节")
        return completion_callback(false)
    end

    local uncached_count = #uncached_chapters

    local title_text = bookinfo.name or "缓存章节"
    if retry_count > 0 then
        title_text = title_text .. string.format("（重试 %d）", retry_count)
    end
    local cache_msg = TaskProg.showBar(string.format(
        "已处理 0/%d · 成功 0 · 失败 0\n下载中：等待开始\n最近失败：无", uncached_count), {
        title = title_text,
        max = uncached_count,
        dismissable = true,
        detailed = true,
    })
    local active_chapters = {}
    local failed_count = 0
    local last_error = "无"

    if not retry_count then retry_count = 0 end
    local retry_func = function(retry_chapters)
        retry_count = retry_count + 1
        self:startCacheChapters(bookinfo, retry_chapters or uncached_chapters, chapter_count, retry_count, completion_callback, skip_cache_integrity_check)
    end

    local cache_complete = false
    local handleCacheSuccess = function()
        if cache_msg and cache_msg.close then
            cache_msg:close()
        end
        cache_complete = true

        if not skip_cache_integrity_check then
            self:checkCacheIntegrity(bookinfo, chapter_count, completion_callback, function()
                retry_func()
            end)
        else
            if H.is_func(completion_callback) then
                completion_callback(true)
            end
            MessageBox:success("缓存完成")
        end
    end

    local showRetryDialog = function(err_msg, retry_chapters)
        err_msg = Error.extract_message(err_msg)
        local error_title = "⚠ 缓存出错"
        local is_timeout = err_msg:find("超时")
        local is_toc_empty = err_msg:find("目录为空") or err_msg:find("TOC") or err_msg:find("章节列表")

        if is_timeout then
            error_title = "⚠ 下载超时"
        elseif is_toc_empty then
            error_title = "⚠ 目录为空"
        end

            local settings = Backend:getSettings()
            local current_threads = Backend:normalizeDownloadThreads(settings.download_threads)
            local has_multithread = current_threads > 1 and not self.temp_disable_multithread

            local other_buttons_list = {{
                {
                    text = "查看已缓存",
                    callback = function()
                        self:checkCacheIntegrity(bookinfo, chapter_count, completion_callback, function()
                            retry_func(retry_chapters)
                        end)
                    end
                }
            }}

            if has_multithread then
                table.insert(other_buttons_list[1], {
                    text = "停用多线程并重试",
                    callback = function()
                        self.temp_disable_multithread = true
                        logger.info("User disabled multi-threading for this session")
                        retry_func(retry_chapters)
                    end
                })
            end

            MessageBox:confirm(
                string.format("%s\n\n%s\n\n已重试%s次，是否继续重试？", error_title, err_msg, retry_count),
                function(result)
                    if result then
                        retry_func(retry_chapters)
                    else
                        if H.is_func(completion_callback) then
                            completion_callback(false)
                        end
                    end
                end,
                {
                    ok_text = "重试",
                    cancel_text = "取消",
                    other_buttons_first = true,
                    other_buttons = other_buttons_list
                })
    end

    local cache_progress_callback
    local handleCacheError = function(err_msg, failed_chapters)
        if cache_msg and cache_msg.close then
            cache_msg:close()
        end
        cache_complete = true
        showRetryDialog(err_msg, failed_chapters)
    end

    cache_progress_callback = function(progress, err_msg, failed_chapters, detail)
        if cache_complete then return end
        if detail then
            local chapter = detail.chapter
            active_chapters[chapter.chapters_index] = detail.state == "started" and chapter or nil
            failed_count = detail.failed
            if detail.state == "failed" then
                last_error = (chapter.title or "未命名章节") .. "——" .. Error.extract_message(detail.error or "下载失败")
            end
        end
        if progress == false or progress == true then
            if progress == true then
                handleCacheSuccess()
            else
                handleCacheError(err_msg or "缓存章节失败", failed_chapters)
            end
        elseif H.is_num(progress) then
            if cache_msg and cache_msg.reportProgress then
                cache_msg:reportProgress(progress)
            end
            if cache_msg and cache_msg.setDetails then
                local active, titles = {}, {}
                for _, chapter in pairs(active_chapters) do active[#active + 1] = chapter end
                table.sort(active, function(a, b) return a.chapters_index < b.chapters_index end)
                local active_count = #active
                for i = 1, math.min(2, active_count) do
                    titles[i] = active[i].title or "未命名章节"
                end
                local active_text = active_count > 0 and table.concat(titles, "、") or "等待剩余任务完成"
                if active_count > 2 then active_text = active_text .. " 等" end
                cache_msg:setDetails(string.format(
                    "已处理 %d/%d · 成功 %d · 失败 %d\n下载中（%d章）：%s\n最近失败：%s",
                    progress, uncached_count, progress - failed_count, failed_count,
                    active_count, active_text, last_error))
            end
        end
    end

    Backend:preLoadingChapters(uncached_chapters, nil, cache_progress_callback, self.temp_disable_multithread)
end

function M:checkCacheIntegrity(bookinfo, chapter_count, completion_callback, retry_callback)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return end

    local book_cache_id = bookinfo.cache_id

    TaskProg.loading("正在检查缓存完整性", function()
        return Backend:analyzeCacheStatusForRange(book_cache_id, 0, chapter_count - 1, true)
    end, function(state, cache_status)
        if not (state == true and H.is_tbl(cache_status) and H.is_tbl(cache_status.cached_chapters) and H.is_tbl(cache_status.uncached_chapters)) then
            MessageBox:error("查询章节缓存状态出错")
            return completion_callback(false)
        end

        local cached_count = cache_status.cached_count
        local missing_count = cache_status.uncached_count

        if missing_count == 0 then
            MessageBox:confirm(
                string.format("✓ 缓存完成\n\n书名：%s\n总章节：%d\n已缓存：%d",
                    bookinfo.name or "未命名",
                    chapter_count,
                    cached_count),
                function()
                    if H.is_func(completion_callback) then completion_callback(true) end
                end,
                {
                    no_ok_button = true,
                    cancel_text = "确定"
                }
            )
        else
            local missing_text = ""
            local max_display = 10
            for i, missing in ipairs(cache_status.uncached_chapters) do
                if i > max_display then
                    missing_text = missing_text .. string.format("\n...还有 %d 章未缓存", missing_count - max_display)
                    break
                end
                missing_text = missing_text .. string.format("\n第 %d 章: %s", missing.chapters_index + 1, missing.title or "")
            end

            MessageBox:confirm(string.format(
                "缓存不完整！\n\n书名：<<%s>>\n总章节：%d\n已缓存：%d\n未缓存：%d\n%s\n\n是否重新缓存缺失章节？",
                bookinfo.name or "未命名",
                chapter_count,
                cached_count,
                missing_count,
                missing_text
            ), function(result)
                if result then
                    if H.is_func(retry_callback) then retry_callback() end
                else
                    if H.is_func(completion_callback) then completion_callback(false) end
                end
            end, {
                ok_text = "重新缓存",
                cancel_text = "取消"
            })
        end
    end)
end

function M:_getExportOutputPath(bookinfo, settings, is_comic)
    local filename = FS.getSafeFilename(string.format("%s-%s",
        bookinfo.name or "未知书名", bookinfo.author or "未知作者"))
    return FS.joinPath(settings.output_path or Env.getHomeDir(), filename .. (is_comic and ".cbz" or ".epub"))
end

function M:_buildEpubFile(bookinfo, chapters, export_settings, only_cached, report_progress)
    if not (H.is_tbl(bookinfo) and H.is_tbl(chapters) and #chapters > 0) then
        return {success = false, error = "无效的书籍信息或章节列表" }
    end

    local book_cache_id = bookinfo.cache_id
    bookinfo.name = bookinfo.name or "未知书名"
    bookinfo.author = bookinfo.author or "未知作者"

    local epub_chapters = {}
    for _, cache_chapter in ipairs(chapters) do
        if H.is_tbl(cache_chapter) and not cache_chapter.isVolume
                and H.is_str(cache_chapter.cacheFilePath) and util.fileExists(cache_chapter.cacheFilePath) then
            local file_ext = cache_chapter.cacheFilePath:match("%.([^.]+)$")
            local chapters_index = cache_chapter.chapters_index
            table.insert(epub_chapters, {
                chapters_index = chapters_index,
                title = cache_chapter.title or string.format("第%d章", chapters_index + 1),
                cache_ext = file_ext,
                cache_path = cache_chapter.cacheFilePath,
            })
        end
    end

    if #epub_chapters == 0 then
        return {success = false, error = "没有可导出的章节" }
    end

    local output_path = self:_getExportOutputPath(bookinfo, export_settings)

    local cover_path = require("Legado.Helper.ImageUtil").get_default_cover_cache(book_cache_id)
    if not cover_path and not only_cached and bookinfo.coverUrl then
        local ok
        ok, cover_path = pcall(function()
            return Backend:download_cover_img(book_cache_id, bookinfo.coverUrl)
        end)
        if not (H.is_str(cover_path) and util.fileExists(cover_path)) then
            logger.warn("EPUB导出: 封面下载失败", cover_path)
            cover_path = nil
        end
    end

    local custom_css = nil
    if H.is_str(export_settings.custom_css_path) and util.fileExists(export_settings.custom_css_path) then
        custom_css = util.readFromFile(export_settings.custom_css_path, "r")
    end

    local EpubHelper = require("Legado/EpubHelper")
    local exporter = EpubHelper.EpubExporter:new():init({
        report_progress = report_progress,
        title = bookinfo.name,
        author = bookinfo.author,
        description = bookinfo.intro,
        cover_path = cover_path,
        custom_css = custom_css,
        chapters = epub_chapters,
        toc = Backend:getBookChapterPlusCache(book_cache_id, bookinfo.book_self_id),
        output_path = output_path,
        book_cache_id = book_cache_id
    })

    local ok, build_result = pcall(function()
        return exporter:build()
    end)

    if not ok then return {success = false, error = tostring(build_result)} end
    return build_result
end

function M:_processEpubExport(bookinfo, chapters, only_cached, export_settings)
    export_settings = export_settings or self:getEpubExportSettings()
    TaskProg.loading{
        text = "正在导出 EPUB，请稍候",
        update_interval = 0.5,
        min_visible_time = 0.8,
        completion_text = function(ok, result)
            return ok and H.is_tbl(result) and result.success and "EPUB 导出成功" or "EPUB 导出失败"
        end,
        dismissable = true,
        on_progress = true,
        runnable = function(ctx)
            return self:_buildEpubFile(bookinfo, chapters, export_settings, only_cached, ctx.progress)
        end,
        callback = function(state, build_result)
            active_exports[self:_getExportOutputPath(bookinfo, export_settings)] = nil
            if state == true and H.is_tbl(build_result) and build_result.success then
                self:showExportSuccessDialog(build_result, function(path)
                    self:showReaderUI(path)
                end)
            else
                self:showExportErrorDialog(H.is_tbl(build_result) and build_result.error
                    or (H.is_str(build_result) and build_result) or "EPUB构建失败", function()
                    self:_generateBookFile(bookinfo, only_cached, false, export_settings)
                end)
            end
        end,
    }
end

function M:_processCbzExport(bookinfo, chapters, only_cached, export_settings)
    export_settings = export_settings or self:getEpubExportSettings()
    local output_path = self:_getExportOutputPath(bookinfo, export_settings, true)

    local cache_msg = TaskProg.showBar("缓存进度", {
        title = "导出进度",
        max = #chapters,
    })

    local exporter = CbzExporter:new({
        bookinfo = bookinfo,
        output_file = output_path,
        cache_chapters = chapters,
        reportProgress = function(current_progress)
            if H.is_num(current_progress) and cache_msg and cache_msg.reportProgress then
                cache_msg:reportProgress(current_progress)
            end
        end,
    })

    local success, result = pcall(function()
        return exporter:package()
    end)

    active_exports[output_path] = nil
    if cache_msg and cache_msg.close then cache_msg:close() end
    if success and H.is_tbl(result) and result.success then
        self:showExportSuccessDialog(result, function(path)
            self:showReaderUI(path)
        end)
    else
        self:showExportErrorDialog(H.is_tbl(result) and tostring(result.error) or tostring(result), function()
            self:_generateBookFile(bookinfo, only_cached, true, export_settings)
        end)
    end
end

function M:_generateBookFile(bookinfo, only_cached, is_comic, export_settings)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        self:showExportErrorDialog("书籍信息错误")
        return
    end
    export_settings = export_settings or self:getEpubExportSettings()
    local output_path = self:_getExportOutputPath(bookinfo, export_settings, is_comic)
    if active_exports[output_path] then
        MessageBox:notice("该文件正在导出，请等待完成")
        return
    end
    active_exports[output_path] = true
    local callback = function(chapters)
        if not is_comic then
            self:_processEpubExport(bookinfo, chapters, only_cached, export_settings)
        else
            self:_processCbzExport(bookinfo, chapters, only_cached, export_settings)
        end
    end
    self:prepareChaptersForExport(bookinfo, only_cached, function(success, result)
        if success and H.is_tbl(result) and H.is_tbl(result.chapters) then
            callback(result.chapters)
        else
            active_exports[output_path] = nil
            self:showExportErrorDialog(H.is_tbl(result) and result.error or "准备章节失败")
        end
    end)
end

function M:exportBook(only_cached)
    local bookinfo = self.bookinfo
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        self:showExportErrorDialog("书籍信息错误")
        return
    end

    local book_cache_id = bookinfo.cache_id
    local chapter_count = self:_getChapterCount(book_cache_id)
    if not chapter_count or chapter_count == 0 then
        self:showExportErrorDialog(only_cached and "缺少本地章节目录，无法离线导出" or "该书没有章节,请刷新")
        return
    end

    TaskProg.loading("正在统计已缓存章节", function()
        return Backend:analyzeCacheStatus(book_cache_id, nil, only_cached and bookinfo.book_self_id or nil)
    end, function(state, response)
        if not (state == true and H.is_tbl(response) and H.is_tbl(response.cached_chapters) and H.is_tbl(response.uncached_chapters)) then
            return self:showExportErrorDialog("查询章节缓存状态出错")
        end

        self.chapter_cache_status = response
        local cached_count = self.chapter_cache_status.cached_count
        local route = Backend:bookReaderRoute(book_cache_id)
        local is_comic = route == "comic"
            or (route ~= "reader" and Backend:bookContentType(bookinfo) == "comic")
        local export_type = is_comic and "CBZ" or "EPUB"
        local export_settings = self:getEpubExportSettings()
        local output_path = self:_getExportOutputPath(bookinfo, export_settings, is_comic)

        local export_select_callback = function(cached_only)
            if cached_only and cached_count == 0 then
                self:showExportErrorDialog("没有已缓存的章节")
                return
            end
            local function start_export()
                UIManager:nextTick(function()
                    self:_generateBookFile(bookinfo, cached_only, is_comic, export_settings)
                end)
            end
            if util.fileExists(output_path) then
                MessageBox:confirm("文件已存在，是否替换？\n\n" .. output_path
                    .. "\n\n导出失败将保留原文件。", function(confirmed)
                    if confirmed then start_export() end
                end, {ok_text = "替换并导出", cancel_text = "取消"})
            else
                start_export()
            end
        end

        local other_buttons = {{
            text = "自定义设置",
            callback = function()
                self:showEpubExportSettings(function()
                    UIManager:nextTick(function() self:exportBook(only_cached) end)
                end)
            end,
        }}
        if not only_cached then
            table.insert(other_buttons, {
                text = "全部章节",
                callback = function() export_select_callback(false) end,
            })
        end
        local hint = only_cached and "仅导出本地缓存，不下载章节或封面"
            or "全部章节需要下载所有章节，可能需要一些时间"
        hint = hint .. "\n\n输出文件：" .. output_path
        if not is_comic then
            local css_path = export_settings.custom_css_path
            local style = css_path and (css_path:match("([^/\\]+)$") or css_path) or "默认样式"
            hint = hint .. "\n样式：" .. style
        end
        MessageBox:confirm(string.format(
            "是否导出 <<%s>> 为 %s 文件？\n\n作者：%s\n总章节数：%d\n已缓存章节：%d\n\n%s",
            bookinfo.name or "未命名",
            export_type,
            bookinfo.author or "未知作者",
            chapter_count,
            cached_count,
            hint
        ), function(result)
            if not result then return end
            export_select_callback(true)
        end, {
            ok_text = "仅已缓存",
            cancel_text = "取消",
            other_buttons_first = true,
            other_buttons = {other_buttons},
        })
    end)
end

function M:showReaderUI(book_path)
    if not H.is_str(book_path) then return end
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(book_path, true)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(book_path, nil, true)
    end
end

function M:getEpubExportSettings()
    local settings = Backend:getSettings()
    return {
        output_path = settings.epub_output_path,
        custom_css_path = settings.epub_custom_css_path,
    }
end

function M:saveEpubExportSettings(export_settings)
    local settings = Backend:getSettings()
    settings.epub_output_path = export_settings.output_path
    settings.epub_custom_css_path = export_settings.custom_css_path
    return Backend:saveSettings(settings)
end

function M:showEpubExportSettings(on_saved)
    local dialog
    local export_settings = self:getEpubExportSettings()

    local function saved(message)
        if H.is_func(on_saved) then
            on_saved()
        else
            MessageBox:success(message)
        end
    end

    local function getOutputPathText()
        if export_settings.output_path then
            return export_settings.output_path
        else
            return Env.getHomeDir()
        end
    end

    local function getCSSStatusText()
        if export_settings.custom_css_path then
            return Icons.UNICODE_STAR
        else
            return Icons.UNICODE_STAR_OUTLINE
        end
    end

    local buttons = {{{
        text = string.format("%s 自定义输出路径", Icons.FA_FOLDER),
        callback = function()
            UIManager:close(dialog)
            local PathChooser = require("ui/widget/pathchooser")
            local path_chooser = PathChooser:new{
                title = "选择 EPUB 输出目录",
                path = getOutputPathText(),
                select_directory = true,
                onConfirm = function(output_dir)
                    export_settings.output_path = output_dir
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        saved("输出路径已设置为：" .. output_dir)
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end
            }
            UIManager:show(path_chooser)
        end,
    }}, {{
        text = string.format("%s 自定义 CSS 样式  %s", Icons.FA_PAINT_BRUSH, getCSSStatusText()),
        callback = function()
            UIManager:close(dialog)
            local css_dialog
            local css_buttons = {{{
                text = "选择 CSS 文件",
                callback = function()
                    UIManager:close(css_dialog)
                    local PathChooser = require("ui/widget/pathchooser")
                    local path_chooser = PathChooser:new{
                        title = "选择 CSS 文件",
                        path = Env.getHomeDir(),
                        select_directory = false,
                        select_file = true,
                        file_filter = function(filename)
                            return filename:match("%.css$")
                        end,
                        onConfirm = function(css_file)
                            export_settings.custom_css_path = css_file
                            Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                                saved("CSS 文件已设置：" .. css_file)
                            end, function(err)
                                MessageBox:error("设置失败：" .. tostring(err))
                            end)
                        end
                    }
                    UIManager:show(path_chooser)
                end,
            }}, {{
                text = "移除自定义 CSS",
                enabled = export_settings.custom_css_path ~= nil,
                callback = function()
                    UIManager:close(css_dialog)
                    export_settings.custom_css_path = nil
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        saved("已移除自定义 CSS，将使用默认样式")
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end,
            }}}

            css_dialog = require("ui/widget/buttondialog"):new{
                title = "CSS 样式设置",
                title_align = "center",
                buttons = css_buttons,
            }
            UIManager:show(css_dialog)
        end,
    }}, {{
        text = "重置为默认设置",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("确定要重置所有导出设置为默认值吗？", function(result)
                if result then
                    export_settings.output_path = nil
                    export_settings.custom_css_path = nil
                    Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                        saved("已重置为默认设置")
                    end, function(err)
                        MessageBox:error("设置失败：" .. tostring(err))
                    end)
                end
            end, {
                ok_text = "重置",
                cancel_text = "取消"
            })
        end,
    }}}

    dialog = require("ui/widget/buttondialog"):new{
        title = "EPUB 导出设置",
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return M
