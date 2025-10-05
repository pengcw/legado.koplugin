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

local CbzExporter = {}
function CbzExporter:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function CbzExporter:init(options)
    self.bookinfo = options.bookinfo
    self.output_path = options.output_path
    self.cache_chapters = options.cache_chapters
    self.reportProgress = options.reportProgress

    self.bookinfo.name = self.bookinfo.name or "未知书名"
    self.bookinfo.author = self.bookinfo.author or "未知作者"
    return self
end
function CbzExporter:createMimetype()
    return "application/vnd.comicbook+zip"
end
function CbzExporter:createComicInfo(bookinfo, total_pages)
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
            local output_dir = self.output_path or H.getHomeDir()
            local safe_filename = util.getSafeFilename(string.format("%s-%s",self.bookinfo.name, self.bookinfo.author))
            local output_path = H.joinPath(output_dir, safe_filename .. ".cbz")
            local cbz_path_tmp = output_path .. '.tmp'
            local valid_chapters = self.cache_chapters

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

            for _, cache_chapter in ipairs(valid_chapters) do

                -- 如果是 CBZ 文件，需要解压并提取图片
                if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) and cache_chapter.cacheFilePath:match("%.cbz$") then
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
                                        -- archiver
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

                current_progress = current_progress + 1
                if H.is_func(self.reportProgress) then
                    self.reportProgress(current_progress)
                end
            end

            local comic_info = self:createComicInfo(self.bookinfo, total_pages)
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
            
            os.rename(cbz_path_tmp, output_path)

            return {
                success = true,
                path = output_path
            }
end

local M = {}

function M:exportBookToCbz(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        MessageBox:error("书籍信息错误")
        return
    end

    local chapter_count = Backend:getChapterCount(bookinfo.cache_id)
    if not chapter_count or chapter_count == 0 then
        MessageBox:error("该书没有章节")
        return
    end

    local loading_msg
    if chapter_count > 100 then
        loading_msg = MessageBox:showloadingMessage("正在统计已缓存章节...")
    end

    -- TODO 统计前尝试刷新最新章节
    UIManager:nextTick(function()
        local cached_count = 0
        local book_cache_id = bookinfo.cache_id

        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if H.is_tbl(chapter) and chapter.cacheFilePath and  
                util.fileExists(chapter.cacheFilePath) then
                cached_count = cached_count + 1
            end
        end

        if loading_msg then
            if loading_msg.close then
                loading_msg:close()
            else
                UIManager:close(loading_msg)
            end
        end

        MessageBox:confirm(string.format(
            "是否导出 <<%s>> 为 CBZ 文件？\n\n作者：%s\n总章节数：%d\n已缓存章节：%d\n\n全部导出需要下载所有章节，可能需要一些时间",
            bookinfo.name or "未命名",
            bookinfo.author or "未知作者",
            chapter_count,
            cached_count
        ), function(result)
            if not result then return end
            UIManager:nextTick(function()
                self:startCbzExport(bookinfo, chapter_count, false)
            end)
        end, {
            ok_text = "全部导出",
            cancel_text = "取消",
            other_buttons = {{
                {
                    text = "仅已缓存",
                    callback = function()
                        if cached_count == 0 then
                            MessageBox:error("没有已缓存的章节")
                            return
                        end
                        UIManager:nextTick(function()
                            self:startCbzExport(bookinfo, chapter_count, true)
                        end)
                    end
                },
            }}
        })
    end)
end

function M:startCbzExport(bookinfo, chapter_count, only_cached)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        MessageBox:error("书籍信息错误")
        return
    end

    local book_cache_id = bookinfo.cache_id

    local all_chapters = Backend:getBookChapterPlusCache(book_cache_id)

    local cached_chapters = {}
    local missing_count = 0

    for i, chapter in ipairs(all_chapters) do
        local cache_chapter = Backend:getCacheChapterFilePath(chapter, true)
        local is_cached = cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath)

        if is_cached then
            table.insert(cached_chapters, cache_chapter)
        else
            missing_count = missing_count + 1
        end
    end

    if only_cached then
        MessageBox:notice(string.format('跳过 %d 个未缓存章节，开始生成 CBZ', missing_count))
        self:generateCbzFile(bookinfo, chapter_count, cached_chapters)
        return
    end

    if missing_count == 0 then
        MessageBox:notice('所有章节已缓存，开始生成 CBZ')
        self:generateCbzFile(bookinfo, chapter_count, cached_chapters)
        return
    end

    local dialog_title = string.format("缓存书籍 %d/%d 章", missing_count, chapter_count)
    local loading_msg = missing_count > 10 and
        MessageBox:progressBar(dialog_title, {title = "正在下载章节", max = missing_count}) or
        MessageBox:showloadingMessage(dialog_title, {progress_max = missing_count})

    if not (loading_msg and loading_msg.reportProgress and loading_msg.close) then
        MessageBox:error("进度显示控件生成失败")
        return
    end

    local cache_complete = false
    local cache_cancelled = false

    local cache_progress_callback = function(progress, err_msg)
        if progress == false or progress == true then
            loading_msg:close()
            cache_complete = true

            if progress == true and not cache_cancelled then
                -- 缓存完成，开始生成CBZ
                self:generateCbzFile(bookinfo, chapter_count)
            elseif err_msg then
                MessageBox:error('缓存章节出错：', tostring(err_msg))
            elseif cache_cancelled then
                MessageBox:notice('已取消导出')
            end
        elseif H.is_num(progress) then
            loading_msg:reportProgress(progress)
        end
    end

    Backend:preLoadingChapters(all_chapters, nil, cache_progress_callback)

    -- TODO 添加取消按钮
    if loading_msg.cancel then
        loading_msg:setCancelCallback(function()
            cache_cancelled = true
            if not cache_complete then
                loading_msg:close()
                MessageBox:notice('已取消缓存')
            end
        end)
    end
end

function M:generateCbzFile(bookinfo, chapter_count, cached_chapters_param)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        MessageBox:error("书籍信息错误")
        return
    end

    local book_cache_id = bookinfo.cache_id

    local valid_chapters = cached_chapters_param or {}

    if not cached_chapters_param then
        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if chapter then
                local cache_chapter = Backend:getCacheChapterFilePath(chapter)
                if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
                    table.insert(valid_chapters, cache_chapter)
                end
            end
        end
    end

    local actual_chapter_count = #valid_chapters

    if actual_chapter_count == 0 then
        MessageBox:error("没有可导出的章节")
        return
    end

    local export_msg = MessageBox:progressBar("正在生成 CBZ 文件", {
        title = "导出进度",
        max = actual_chapter_count
    })

    if not export_msg then
        export_msg = MessageBox:showloadingMessage("正在生成 CBZ 文件")
    end

    local export_settings = self:getEpubExportSettings()
    
    local EpubHelper = require("Legado/EpubHelper")
    local exporter = CbzExporter:new():init({
        bookinfo = bookinfo,
        output_path = export_settings.output_path,
        cache_chapters = valid_chapters,
        reportProgress = function(current_progress)
            export_msg:reportProgress(current_progress)
        end,
    })

    UIManager:nextTick(function()
        local success, result = pcall(function()
            return exporter:package()
        end)

        if export_msg then
            if export_msg.close then
                export_msg:close()
            else
                UIManager:close(export_msg)
            end
        end

        if success and result then
            if result.success then
                local filename = result.path and result.path:match("([^/\\]+)$") or "未知"
                local output_dir = result.path and result.path:match("(.+)[/\\]") or H.getHomeDir()
                MessageBox:confirm(
                    string.format("CBZ 导出成功！\n\n文件：%s\n位置：%s", filename, output_dir),
                    function(open_file)
                        if open_file and result.path then
                            UIManager:close(self.book_menu)
                            UIManager:nextTick(function()
                                self:showReaderUI(result.path)
                            end)
                        end
                    end,
                    {
                        ok_text = "打开",
                        cancel_text = "完成"
                    }
                )
            else
                MessageBox:confirm(
                    "CBZ 导出失败：" .. (result.error or "未知错误"),
                    function(retry)
                        if retry then
                            self:exportBookToCbz(bookinfo)
                        end
                    end,
                    {
                        ok_text = "重试",
                        cancel_text = "完成"
                    }
                )
            end
        else
            MessageBox:confirm(
                "CBZ 导出失败：" .. tostring(result),
                function(retry)
                    if retry then
                        self:exportBookToCbz(bookinfo)
                    end
                end,
                {
                    ok_text = "重试",
                    cancel_text = "完成"
                }
            )
        end
    end)
end

function M:exportBookToEpub(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        MessageBox:error("书籍信息错误")
        return
    end

    local chapter_count = Backend:getChapterCount(bookinfo.cache_id)
    if not chapter_count or chapter_count == 0 then
        MessageBox:error("该书没有章节")
        return
    end

    -- 显示加载提示（统计章节可能需要时间）
    local loading_msg
    if chapter_count > 100 then
        loading_msg = MessageBox:showloadingMessage("正在统计已缓存章节...")
    end

    UIManager:nextTick(function()
        local cached_count = 0

        local book_cache_id = bookinfo.cache_id
        local book_cache_path = H.getBookCachePath(book_cache_id)

        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if chapter and chapter.cacheFilePath then
                if util.fileExists(chapter.cacheFilePath) then
                    cached_count = cached_count + 1
                end
            end
        end

        if loading_msg then
            if loading_msg.close then
                loading_msg:close()
            else
                UIManager:close(loading_msg)
            end
        end

        MessageBox:confirm(string.format(
            "是否导出 <<%s>> 为 EPUB 文件？\n\n作者：%s\n总章节数：%d\n已缓存章节：%d\n\n全部导出需要下载所有章节，可能需要一些时间",
            bookinfo.name or "未命名",
            bookinfo.author or "未知作者",
            chapter_count,
            cached_count
        ), function(result)
            if not result then
                return
            end

            -- 开始导出流程（下载缺失章节）
            self:startEpubExport(bookinfo, chapter_count, false)
        end, {
            ok_text = "全部导出",
            cancel_text = "取消",
            other_buttons = {{
                {
                    text = "仅已缓存",
                    callback = function()
                        if cached_count == 0 then
                            MessageBox:error("没有已缓存的章节")
                            return
                        end
                        UIManager:nextTick(function()
                            self:startEpubExport(bookinfo, chapter_count, true)
                        end)
                    end
                },
                {
                    text = "设置",
                    callback = function()
                        UIManager:nextTick(function()
                            self:showEpubExportSettings()
                        end)
                    end
                }
            }}
        })
    end)
end

function M:startEpubExport(bookinfo, chapter_count, only_cached)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        MessageBox:error("书籍信息错误")
        return
    end

    local book_cache_id = bookinfo.cache_id

    -- 生成全书章节列表，检查缓存是否存在
    local all_chapters = {}
    local missing_count = 0
    local cached_chapters = {}  -- 保存已缓存章节信息

    for i = 0, chapter_count - 1 do
        local chapter = Backend:getChapterInfoCache(book_cache_id, i)
        if chapter then
            -- 检查缓存文件是否实际存在（不依赖数据库标志）
            local cache_chapter = Backend:getCacheChapterFilePath(chapter, true)
            local is_cached = cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath)

            if not is_cached then
                -- 添加到待下载列表
                chapter.call_event = 'next'
                table.insert(all_chapters, chapter)
                missing_count = missing_count + 1
            else
                -- 保存已缓存章节信息
                table.insert(cached_chapters, cache_chapter)
            end
        end
    end

    if only_cached then
        MessageBox:notice(string.format('跳过 %d 个未缓存章节，开始生成 EPUB', missing_count))
        self:generateEpubFile(bookinfo, chapter_count, cached_chapters)
        return
    end

    if missing_count == 0 then
        MessageBox:notice('所有章节已缓存，开始生成 EPUB')
        self:generateEpubFile(bookinfo, chapter_count, cached_chapters)
        return
    end

    -- 缓存缺失的章节
    local dialog_title = string.format("缓存书籍 %d/%d 章", missing_count, chapter_count)
    local loading_msg = missing_count > 10 and
        MessageBox:progressBar(dialog_title, {title = "正在下载章节", max = missing_count}) or
        MessageBox:showloadingMessage(dialog_title, {progress_max = missing_count})

    if not (loading_msg and loading_msg.reportProgress and loading_msg.close) then
        return MessageBox:error("进度显示控件生成失败")
    end

    local cache_cancelled = false
    local cache_complete = false

    local cache_progress_callback = function(progress, err_msg)
        if progress == false or progress == true then
            loading_msg:close()
            cache_complete = true

            if progress == true and not cache_cancelled then
                UIManager:nextTick(function()
                    self:generateEpubFile(bookinfo, chapter_count)
                end)
            elseif err_msg then
                MessageBox:error('缓存章节出错：', tostring(err_msg))
            elseif cache_cancelled then
                MessageBox:notice('已取消导出')
            end
        end
        if H.is_num(progress) then
            loading_msg:reportProgress(progress)
        end
    end

    -- 第一个参数支持传入待下载章节列表
    Backend:preLoadingChapters(all_chapters, nil, cache_progress_callback)

    if loading_msg.cancel then
        loading_msg:setCancelCallback(function()
            cache_cancelled = true
            if not cache_complete then
                loading_msg:close()
                MessageBox:notice('已取消缓存')
            end
        end)
    end
end

-- 将已缓存章节生成 epub
function M:generateEpubFile(bookinfo, chapter_count, cached_chapters_param)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        MessageBox:error("书籍信息错误")
        return
    end

    local book_cache_id = bookinfo.cache_id
    bookinfo.name = bookinfo.name or "未知书名"
    bookinfo.author = bookinfo.author or "未知作者"
    
    -- 准备章节数据（如果传入了缓存章节列表，直接使用, 否则重新检测收集）
    local valid_chapters = cached_chapters_param or {}

    if not cached_chapters_param then
        for i = 0, chapter_count - 1 do
            local chapter = Backend:getChapterInfoCache(book_cache_id, i)
            if chapter then
                local cache_chapter = Backend:getCacheChapterFilePath(chapter)
                if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
                    table.insert(valid_chapters, cache_chapter)
                end
            end
        end
    end

    local actual_chapter_count = #valid_chapters

    if actual_chapter_count == 0 then
        MessageBox:error("没有可导出的章节")
        return
    end

    local export_settings = self:getEpubExportSettings()
    local function build_epub()

            local chapters = {}
            for _, cache_chapter in ipairs(valid_chapters) do
                if H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath) and util.fileExists(cache_chapter.cacheFilePath) then
                    local file_ext = cache_chapter.cacheFilePath:match("%.([^.]+)$")
                    local chapters_index = cache_chapter.chapters_index
                    -- 当仅缓存的时候, 这里章节不一定是连续的
                    table.insert(chapters, {
                        chapters_index = chapters_index,
                        title = cache_chapter.title or string.format("第%d章", chapters_index + 1),
                        cache_ext = file_ext,
                        cache_path = cache_chapter.cacheFilePath,
                    })
                end
            end

            local output_dir = export_settings.output_path or H.getHomeDir()
            local safe_filename = util.getSafeFilename(string.format("%s-%s",bookinfo.name, bookinfo.author))
            local output_path = H.joinPath(output_dir, safe_filename .. ".epub")

            if util.fileExists(output_path) then
                pcall(util.removeFile, output_path)
            end

            local cover_path = nil
            if bookinfo.coverUrl then
                --logger.info("EPUB导出: 从网络下载封面 -", bookinfo.coverUrl)
                cover_path, _ = Backend:download_cover_img(book_cache_id, bookinfo.coverUrl)
                if not H.is_str(cover_path) and util.fileExists(cover_path) then
                    logger.warn("EPUB导出: 封面下载失败")
                else
                    -- logger.info("EPUB导出: 封面下载成功 -", cover_path)
                end
            else
                logger.warn("EPUB导出: 无封面URL，跳过封面")
            end

            --logger.info("EPUB导出: 最终封面路径 -", cover_path or "无")

            local custom_css = nil
            local use_custom_css = false
            if export_settings.custom_css_path then
                if util.fileExists(export_settings.custom_css_path) then
                    custom_css = util.readFromFile(export_settings.custom_css_path, "r")
                    use_custom_css = true
                end
            end

            local EpubHelper = require("Legado/EpubHelper")
            local exporter = EpubHelper.EpubExporter:new():init({
                title = bookinfo.name,
                author = bookinfo.author,
                description = bookinfo.intro,
                cover_path = cover_path,
                custom_css = custom_css,
                chapters = chapters,
                output_path = output_path,
                book_cache_id = book_cache_id
            })
            
            local build_result = exporter:build()
            return build_result
    end

    MessageBox:loading("正在生成 EPUB 文件", function()
            return build_epub()
        end, function(state, result)
            if state == true and H.is_tbl(result) then
                if result.success then
                    local filename = result.path and result.path:match("([^/\\]+)$") or "未知"
                    local output_dir = result.path and result.path:match("(.+)[/\\]") or H.getHomeDir()
                    MessageBox:confirm(
                        string.format("EPUB 导出成功！\n\n文件：%s\n位置：%s", filename, output_dir),
                        function(open_file)
                            if open_file and result.path then
                                UIManager:close(self.book_menu)
                                UIManager:nextTick(function()
                                    self:showReaderUI(result.path)
                                end)
                            end
                        end,
                        {
                            ok_text = "打开",
                            cancel_text = "完成"
                        }
                    )
                else
                    MessageBox:confirm(
                        "EPUB 导出失败：" .. (H.is_tbl(result) and result.error or "未知错误"),
                        function(retry)
                            if retry then
                                -- 重试导出
                                self:exportBookToEpub(bookinfo)
                            end
                        end,
                        {
                            ok_text = "重试",
                            cancel_text = "完成"
                        }
                    )
                end
            else
                 MessageBox:confirm(
                    "EPUB 导出失败：build 过程错误",
                    function(retry)
                        if retry then
                            self:exportBookToEpub(bookinfo)
                        end
                    end,
                    {
                        ok_text = "重试",
                        cancel_text = "完成"
                    }
                )
            end
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
    local export_settings = self:getEpubExportSettings()
    local dialog

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
                        MessageBox:notice("输出路径已设置为：" .. output_dir)
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
                                MessageBox:notice("CSS 文件已设置：" .. css_file)
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
                        MessageBox:notice("已移除自定义 CSS，将使用默认样式")
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
                        MessageBox:notice("已重置为默认设置")
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