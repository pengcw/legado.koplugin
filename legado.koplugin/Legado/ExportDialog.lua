local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ffiUtil = require("ffi/util")
local util = require("util")
local DocSettings = require("docsettings")
local logger = require("logger")

local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local CbzExporter = {
    bookinfo = nil,
    output_path = nil,
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
    local function escape_xml(str)
                if not str then return "" end
                return str:gsub("&", "&amp;")
                        :gsub("<", "&lt;")
                        :gsub(">", "&gt;")
                        :gsub("\"", "&quot;")
                        :gsub("'", "&apos;")
            end
        return string.format([[<?xml version="1.0" encoding="utf-8"?>
<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Title>%s</Title>
  <Series>%s</Series>
  <Writer>%s</Writer>
  <Publisher>Legado</Publisher>
  <Genre>%s</Genre>
  <PageCount>%d</PageCount>
  <Summary>%s</Summary>
  <LanguageISO>zh</LanguageISO>
  <Manga>Yes</Manga>
</ComicInfo>]],
                escape_xml(self.bookinfo.name),
                escape_xml(self.bookinfo.name),
                escape_xml(self.bookinfo.author),
                escape_xml(self.bookinfo.kind or "漫画"),
                total_pages,
                escape_xml(self.bookinfo.intro or "")
            )
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

    local output_dir = self.output_path or H.getHomeDir()
    local safe_filename = util.getSafeFilename(string.format("%s-%s",self.bookinfo.name, self.bookinfo.author))
    local output_path = H.joinPath(output_dir, safe_filename .. ".cbz")
    local cbz_path_tmp = output_path .. '.tmp'

    if util.fileExists(output_path) then
        pcall(util.removeFile, output_path)
    end
    if util.fileExists(cbz_path_tmp) then
        pcall(util.removeFile, cbz_path_tmp)
    end

    local function get_image_ext(filename)
        local extension = filename:match("%.(%w+)$")
        if extension then
            local valid_extensions = {
                jpg = true, jpeg = true, png = true, 
                gif = true, webp = true, bmp = true
            }
            if valid_extensions[extension:lower()] then
                return extension
            end
        end
        return nil
    end

    local cbz
    local cbz_lib
    local tmp_base
    local main_temp_dir
    
    local use_archiver = true
    local ok, Archiver = pcall(require, "ffi/archiver")
    if ok and Archiver then
        cbz_lib = "archiver"
        cbz = Archiver.Writer:new{}
        if not cbz:open(cbz_path_tmp, "epub") then
            local err_msg = string.format("无法创建 CBZ 文件: %s", tostring(cbz.err))
            return {
                success = false,
                error = err_msg
            }
        end
            cbz:setZipCompression("store")
            cbz:addFileFromMemory("mimetype", self:createMimetype(), os.time())
            cbz:setZipCompression("deflate")
    else
        use_archiver = false
    end

    if not use_archiver then
        local ok, ZipWriter = pcall(require, "ffi/zipwriter")
        if ok and ZipWriter then
            cbz_lib = "zipwriter"
            cbz = ZipWriter:new{}
            if not cbz:open(cbz_path_tmp) then
                local err_msg = string.format("无法创建 CBZ 文件: %s", tostring(cbz.err))
                return {
                    success = false,
                    error = err_msg
                }
            end

            tmp_base = H.joinPath(H.getTempDirectory(), ".tmp.sdr")
            H.checkAndCreateFolder(tmp_base)
            local run_stamp = tostring(os.time()) .. "_" .. tostring(math.floor(math.random() * 100000))
            main_temp_dir = H.joinPath(tmp_base, "cbz_temp_" .. run_stamp)
            H.checkAndCreateFolder(main_temp_dir)

            cbz:add("mimetype",  self:createMimetype(), true)
        else
            local err_msg = "无法加载任何压缩库"
            return {
                success = false,
                error = err_msg
            }
        end
    end

    -- 合并所有章节的图片到一个 CBZ
    local current_progress = 0
    local image_index = 1
    local total_pages = 0

    for _, cache_chapter in ipairs(self.cache_chapters) do

        if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) then
            -- 如果是 CBZ 文件，需要解压并提取图片
            if cache_chapter.cacheFilePath:match("%.cbz$") then
            -- 根据已有库选择使用处理方式
                if cbz_lib == "archiver" then
                            local chapter_cbz
                            chapter_cbz = Archiver.Reader:new()
                            chapter_cbz:open(cache_chapter.cacheFilePath) 
                                
                            for entry in chapter_cbz:iterate() do
                                    
                                local ext = get_image_ext(entry.path)
                                if entry.mode == "file" and ext then
                                    
                                    local img_data = chapter_cbz:extractToMemory(entry.path)
                                    if img_data then
                                        local new_name = string.format("%04d.%s", image_index, ext)
                                        
                                        cbz:addFileFromMemory(new_name, img_data, os.time())
                                        
                                        image_index = image_index + 1
                                        total_pages = total_pages + 1
                                    end
                                end
                            end
                        
                            chapter_cbz:close()
                        else
                            -- 兼容旧版本处理压缩文件
                            -- 为每个章节创建独立的临时目录
                            local chapter_temp_dir = H.joinPath(main_temp_dir, "chapter_" .. current_progress)
                            -- logger.info(chapter_temp_dir)
                            H.checkAndCreateFolder(chapter_temp_dir)
                            
                            -- 解压 CBZ 到临时目录
                            local cache_path_escaped = cache_chapter.cacheFilePath:gsub("'", "'\\''")
                            local target_escaped = chapter_temp_dir:gsub("'", "'\\''")
                            local unzip_cmd = string.format("unzip -qqo '%s' -d '%s'", 
                                cache_path_escaped, target_escaped)
                            local result = os.execute(unzip_cmd)
                            
                            if result == 0 then
                                
                                local image_files = {}
                                
                                -- 先收集所有图片文件
                                util.findFiles(chapter_temp_dir, function(path, fname, attr)
                                    if get_image_ext(fname) then
                                        table.insert(image_files, {
                                            path = path,
                                            name = fname
                                        })
                                    end
                                end, false)
                                
                                -- 按文件名排序
                                table.sort(image_files, function(a, b)
                                    local num_a = tonumber(a.name:match("^(%d+)")) or 0
                                    local num_b = tonumber(b.name:match("^(%d+)")) or 0
                                    return num_a < num_b
                                end)
                                
                                -- 将图片添加到 CBZ
                                for _, file in ipairs(image_files) do
                                    local file_path = H.joinPath(chapter_temp_dir, file.path)
                                    
                                    local img_data = util.readFromFile(file_path, "rb")
                                    if img_data then
                                            local ext = get_image_ext(file.name) or "jpg"
                                            local new_name = string.format("%04d.%s", image_index, ext:lower())
                                            
                                            -- 使用 zipwriter 添加图片（启用压缩）
                                            cbz:add(new_name, img_data, false) -- false = 使用压缩

                                            --logger.info("添加图片:", new_name, "来自:", file)
                                            image_index = image_index + 1
                                            total_pages = total_pages + 1
                                    end
                                end
                                
                                if util.directoryExists(chapter_temp_dir) then
                                    ffiUtil.purgeDir(chapter_temp_dir)
                                    util.removePath(chapter_temp_dir)
                                end
                        else
                                logger.warn("解压失败:", cache_path_escaped)
                                if util.directoryExists(chapter_temp_dir) then
                                    ffiUtil.purgeDir(chapter_temp_dir)
                                    util.removePath(chapter_temp_dir)
                                end
                            end
                        end
                end
            
            -- 章节也可能是单图片
            else
                local img_ext = get_image_ext(cache_chapter.cacheFilePath)
                if H.is_str(img_ext) and util.fileExists(cache_chapter.cacheFilePath) then
                    local img_data = util.readFromFile(cache_chapter.cacheFilePath, "rb")
                    if img_data then
                        local new_name = string.format("%04d.%s", image_index, img_ext:lower())
                        if cbz_lib == "archiver" then
                            cbz:addFileFromMemory(new_name, img_data, os.time())
                        else
                            cbz:add(new_name, img_data, false)
                        end
                        image_index = image_index + 1
                        total_pages = total_pages + 1
                    end
                end
            end

        current_progress = current_progress + 1
        if H.is_func(self.reportProgress) then
            self.reportProgress(current_progress)
        end
    end

    local comic_info = self:createComicInfo(total_pages)
    if cbz_lib == "zipwriter" then
        cbz:add("ComicInfo.xml", comic_info, true)
    else
        cbz:addFileFromMemory("ComicInfo.xml", comic_info, os.time())
    end

    if cbz and cbz.close then
        cbz:close()
    end

    if util.fileExists(output_path) then
        util.removeFile(output_path)
    end

    if cbz_lib == "zipwriter" and util.directoryExists(tmp_base) then
        ffiUtil.purgeDir(tmp_base)
        util.removePath(tmp_base)
    end
    
    if util.fileExists(cbz_path_tmp) then
        os.rename(cbz_path_tmp, output_path)
    end

    return {
        success = true,
        path = output_path
    }
end

local M = {
    bookinfo = nil,
    chapter_count = nil,
    chapter_cache_status = nil,
    -- 临时禁用多线程（本次会话）
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
    local output_dir = result.path and result.path:match("(.+)[/\\]") or H.getHomeDir()
    
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
    MessageBox:confirm(
        error_msg,
        function(retry)
            if retry and H.is_func(retry_callback) then
                retry_callback()
            end
        end,
        {
            ok_text = "重试",
            cancel_text = "完成"
        }
    )
end

-- 回调函数：准备需要的章节缓存
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

    -- 检查缓存状态
    -- { total_count = 0, cached_count = 0, uncached_count = 0, cached_chapters = {}, uncached_chapters = {} }
    local cache_status
    if H.is_tbl(self.chapter_cache_status) then
        cache_status = self.chapter_cache_status
    else
        cache_status = Backend:analyzeCacheStatus(book_cache_id)
        if not (H.is_tbl(cache_status) and H.is_tbl(cache_status.cached_chapters) and H.is_tbl(cache_status.uncached_chapters)) then
            return completion_callback(false, { error = "查询章节缓存状态出错" })
        end
    end

    -- 如果只需要缓存的章节，直接返回
    if only_cached then
        return completion_callback(true, { chapters = cache_status.cached_chapters, total_count = chapter_count })
    end

    -- 如果没有缺失的章节，直接返回
    if cache_status.uncached_count == 0 then
        return completion_callback(true, { chapters = cache_status.cached_chapters, total_count = chapter_count })
    end

    local down_completion_callback = function(is_complete)
        if is_complete == true then
            -- 重新获取所有章节（包含新缓存的）
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

    MessageBox:loading("正在统计已缓存章节", function()
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
            if not result then return completion_callback(false) end -- 用户点击取消
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

    -- 确定目标章节数
    local target_chapter_count
    if H.is_num(down_chapter_count) then
        -- start_chapter_index 从0开始，所以 +1
        target_chapter_count = start_index + down_chapter_count + 1
        -- 处理超出总章数的情况
        if target_chapter_count > actual_chapter_count then
            target_chapter_count = actual_chapter_count
            MessageBox:notice(string.format("超出书籍总章数，将缓存至最后一章。实际缓存章节数：%d", target_chapter_count - start_index))
        end
    else
        -- 如果没有指定下载章数，则缓存到最后一章
        target_chapter_count = actual_chapter_count
    end

    MessageBox:loading("正在统计已缓存章节", function()
        return Backend:analyzeCacheStatusForRange(book_cache_id , start_index, target_chapter_count - 1)
    end, function(state, response)
        if not (state == true and H.is_tbl(response) and H.is_tbl(response.cached_chapters) and H.is_tbl(response.uncached_chapters)) then
            return MessageBox:error("查询章节缓存状态出错")
        end
        
        -- 筛选出从当前章节到目标章节的未缓存章节
        local uncached_in_range = {}
        local total_in_range = target_chapter_count - start_index
        local cached_in_range = 0

        for _, chapter in ipairs(response.uncached_chapters) do
            local chapter_index = tonumber(chapter.chapters_index)
            if chapter_index and chapter_index >= start_index and chapter_index < target_chapter_count then
                table.insert(uncached_in_range, chapter)
            end
        end

        -- 计算范围内已缓存数量
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

    local title_text = string.format("%s - 正在缓存 %d/%d 章节", bookinfo.name, uncached_count, chapter_count)
    if retry_count > 0 then
        title_text = title_text .. string.format(" (重试 %d)", retry_count)
    end
    local cache_msg = MessageBox:progressBar("缓存进度", {
        title = title_text,
        max = uncached_count
    }) or MessageBox:showloadingMessage("正在缓存章节...")

    if not retry_count then retry_count = 0 end
    local retry_func = function()
        retry_count = retry_count + 1
        self:startCacheChapters(bookinfo, uncached_chapters, chapter_count, retry_count, completion_callback, skip_cache_integrity_check)
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

    local showRetryDialog = function(err_msg)
        local error_title = "⚠ 缓存出错"
        local is_timeout = err_msg:find("超时")
        local is_toc_empty = err_msg:find("目录为空") or err_msg:find("TOC") or err_msg:find("章节列表")

        if is_timeout then
            error_title = "⚠ 下载超时"
        elseif is_toc_empty then
            error_title = "⚠ 目录为空"
        end

            -- 检查是否启用了多线程
            local settings = Backend:getSettings()
            local current_threads = tonumber(settings.download_threads) or 1
            local has_multithread = current_threads > 1 and not self.temp_disable_multithread

            local other_buttons_list = {{
                {
                    text = "查看已缓存",
                    callback = function()
                        self:checkCacheIntegrity(bookinfo, chapter_count, completion_callback, function()
                            retry_func()
                        end)
                    end
                }
            }}

            -- 如果启用了多线程，添加"停用多线程并重试"按钮
            if has_multithread then
                table.insert(other_buttons_list[1], {
                    text = "停用多线程并重试",
                    callback = function()
                        self.temp_disable_multithread = true
                        logger.info("User disabled multi-threading for this session")
                        retry_func()
                    end
                })
            end

            -- 所有错误统一提供重试选项
            MessageBox:confirm(
                string.format("%s\n\n%s\n\n已自动重试%s次仍失败，是否继续重试？", error_title, err_msg, retry_count),
                function(result)
                    if result then
                        retry_func()
                    else
                        -- 用户取消重试，调用完成回调
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

    local handleCacheError = function(err_msg)
        if cache_msg and cache_msg.close then
            cache_msg:close()
        end
        cache_complete = true

        -- 首次出错自动重试一次
        if retry_count == 0 then
            UIManager:scheduleIn(1, function()
                self:startCacheChapters(bookinfo, uncached_chapters, chapter_count, 1, completion_callback, skip_cache_integrity_check)
            end)
            return
        end

        -- 重试后仍失败，显示重试对话框
        showRetryDialog(err_msg)
    end

    local cache_progress_callback = function(progress, err_msg)
        if progress == false or progress == true then
            if progress == true then
                handleCacheSuccess()
            elseif err_msg then
                handleCacheError(err_msg)
            end
        elseif H.is_num(progress) then
            if cache_msg and cache_msg.reportProgress then
                cache_msg:reportProgress(progress)
            end
        end
    end

    Backend:preLoadingChapters(uncached_chapters, nil, cache_progress_callback, self.temp_disable_multithread)
end

function M:checkCacheIntegrity(bookinfo, chapter_count, completion_callback, retry_callback)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return end

    local book_cache_id = bookinfo.cache_id

    MessageBox:loading("正在检查缓存完整性", function()
        return Backend:analyzeCacheStatusForRange(book_cache_id, 0, chapter_count - 1, true)
    end, function(state, cache_status)
        if not (state == true and H.is_tbl(cache_status) and H.is_tbl(cache_status.cached_chapters) and H.is_tbl(cache_status.uncached_chapters)) then
            return MessageBox:error("查询章节缓存状态出错")
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
                    -- 用户点击确定后，调用完成回调
                    if H.is_func(completion_callback) then completion_callback(true) end
                end,
                {
                    no_ok_button = true,
                    cancel_text = "确定"
                }
            )
        else
            -- 构建缺失章节列表文本
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

function M:_buildEpubFile(bookinfo, chapters, export_settings)
    if not (H.is_tbl(bookinfo) and H.is_tbl(chapters) and #chapters > 0) then
        return {success = false, error = "无效的书籍信息或章节列表" }
    end

    local book_cache_id = bookinfo.cache_id
    bookinfo.name = bookinfo.name or "未知书名"
    bookinfo.author = bookinfo.author or "未知作者"

    local epub_chapters = {}
    for _, cache_chapter in ipairs(chapters) do
        if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) and util.fileExists(cache_chapter.cacheFilePath) then
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

    local output_dir = export_settings.output_path or H.getHomeDir()
    local safe_filename = util.getSafeFilename(string.format("%s-%s", bookinfo.name, bookinfo.author))
    local output_path = H.joinPath(output_dir, safe_filename .. ".epub")

    if util.fileExists(output_path) then pcall(util.removeFile, output_path) end

    local cover_path
    if bookinfo.coverUrl then
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
        title = bookinfo.name,
        author = bookinfo.author,
        description = bookinfo.intro,
        cover_path = cover_path,
        custom_css = custom_css,
        chapters = epub_chapters,
        output_path = output_path,
        book_cache_id = book_cache_id
    })
    
    local ok, build_result = pcall(function()
        return exporter:build()
    end)

    return build_result
end

function M:_processEpubExport(bookinfo, chapters, only_cached)
    local export_settings = self:getEpubExportSettings()
    MessageBox:loading("正在统计已缓存章节", function()
        return self:_buildEpubFile(bookinfo, chapters, export_settings)
    end, function(state, build_result)
        if state == true and H.is_tbl(build_result) and build_result.success then
            self:showExportSuccessDialog(build_result, function(path)
                self:showReaderUI(path)
            end)
        else
            self:showExportErrorDialog(H.is_tbl(build_result) and build_result.error or "EPUB构建失败", function()
                self:_generateBookFile(bookinfo, only_cached, false)
            end)
        end
    end)
end

function M:_processCbzExport(bookinfo, chapters, only_cached)
    local export_settings = self:getEpubExportSettings()

    local cache_msg = MessageBox:progressBar("缓存进度", {
        title = "导出进度",
        max = #chapters
    })

    local exporter = CbzExporter:new({
        bookinfo = bookinfo,
        output_path = export_settings.output_path,
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

    if cache_msg and cache_msg.close then cache_msg:close() end
    if success and H.is_tbl(result) and result.success then
        self:showExportSuccessDialog(result, function(path)
            self:showReaderUI(path)
        end)
    else
        self:showExportErrorDialog(H.is_tbl(result) and tosring(result.error) or tostring(result), function()
            self:_generateBookFile(bookinfo, only_cached, true)
        end)
    end
end

function M:_generateBookFile(bookinfo, only_cached, is_comic)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        self:showExportErrorDialog("书籍信息错误")
        return
    end
    local callback = function(chapters)
        if not is_comic then
            self:_processEpubExport(bookinfo, chapters, only_cached)
        else
            self:_processCbzExport(bookinfo, chapters, only_cached)
        end
    end
    self:prepareChaptersForExport(bookinfo, only_cached, function(success, result)
        if success and H.is_tbl(result) and H.is_tbl(result.chapters) then
            callback(result.chapters)
        else
            self:showExportErrorDialog(H.is_tbl(result) and result.error or "准备章节失败")
        end
    end)
end

function M:exportBook()
    local bookinfo = self.bookinfo
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        self:showExportErrorDialog("书籍信息错误")
        return
    end

    local book_cache_id = bookinfo.cache_id
    local chapter_count = self:_getChapterCount(book_cache_id)
    if not chapter_count or chapter_count == 0 then
        self:showExportErrorDialog("该书没有章节,请刷新")
        return
    end

    MessageBox:loading("正在统计已缓存章节", function()
        return Backend:analyzeCacheStatus(book_cache_id)
    end, function(state, response)
        if not (state == true and H.is_tbl(response) and H.is_tbl(response.cached_chapters) and H.is_tbl(response.uncached_chapters)) then
            return self:showExportErrorDialog("查询章节缓存状态出错")
        end

        self.chapter_cache_status = response
        local cached_count = self.chapter_cache_status.cached_count
        local is_comic = Backend:isBookTypeComic(book_cache_id)
        local export_type = is_comic and "CBZ" or "EPUB"
    
        local export_select_callback = function(only_cached)
            if only_cached and cached_count == 0 then
                self:showExportErrorDialog("没有已缓存的章节")
                return
            end
            UIManager:nextTick(function()
                self:_generateBookFile(bookinfo, only_cached, is_comic)
            end)
        end
    
        MessageBox:confirm(string.format(
            "是否导出 <<%s>> 为 %s 文件？\n\n作者：%s\n总章节数：%d\n已缓存章节：%d\n\n全书导出需要下载所有章节，可能需要一些时间",
            bookinfo.name or "未命名",
            export_type,
            bookinfo.author or "未知作者",
            chapter_count,
            cached_count
        ), function(result)
            if not result then return end
            export_select_callback(true)
        end, {
            ok_text = "仅已缓存",
            cancel_text = "取消",
            other_buttons_first = true,
            other_buttons = {{
                {
                    text = "自定义设置",
                    callback = function()
                        self:showEpubExportSettings()
                    end
                }, {
                    text = "全书导出",
                    callback = function()
                        export_select_callback(false)
                    end
                }
            }}
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

function M:showEpubExportSettings()
    local dialog
    local export_settings = self:getEpubExportSettings()

    local function getOutputPathText()
        if export_settings.output_path then
            return export_settings.output_path
        else
            return H.getHomeDir()
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
                        MessageBox:success("输出路径已设置为：" .. output_dir)
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
                        path = H.getHomeDir(),
                        select_directory = false,
                        select_file = true,
                        file_filter = function(filename)
                            return filename:match("%.css$")
                        end,
                        onConfirm = function(css_file)
                            export_settings.custom_css_path = css_file
                            Backend:HandleResponse(self:saveEpubExportSettings(export_settings), function()
                                MessageBox:success("CSS 文件已设置：" .. css_file)
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
                        MessageBox:success("已移除自定义 CSS，将使用默认样式")
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
                        MessageBox:success("已重置为默认设置")
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
