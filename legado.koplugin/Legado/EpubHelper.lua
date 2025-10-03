local util = require("util")
local H = require("Legado/Helper")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

--[[
    EpubHelper - EPUB 工具集

    功能：
    1. 章节 HTML 生成（用于 Backend.lua 缓存章节）
    2. EPUB 导出完整功能（用于 LibraryView 导出 EPUB）
    3. 支持自定义封面、CSS、元数据
    4. 自动兼容 KOReader 新旧版本的压缩库
]]

local M = {}

-- EPUB 导出器配置
local EpubExporter = {
    default_author = "未知作者",
    default_title = "未命名图书",
    default_css = nil,
    default_cover = nil,
}

-- CSS 文件路径
local mianCss = string.format("%s/%s", H.getPluginDirectory(), "Legado/main.css.lua")
local resCss = "resources/legado.css"

-- ============================================================
-- 章节标题分割函数（用于章节 HTML 和 EPUB 导出）
-- ============================================================
local function split_title_advanced(title)
    if type(title) ~= 'string' or title == "" then
        return nil, nil
    end
    local words = util.splitToChars(title)

    if not H.is_tbl(words) or #words == 0 then
        return nil, nil
    end

    -- 查找隔断符号的位置
    local count = 0
    local segmentation = {
        ["\u{0020}"] = true,
        ["\u{00A0}"] = true,
        ["\u{3000}"] = true,
        ["\u{2000}"] = true,
        ["\u{2001}"] = true,
        ["\u{2002}"] = true,
        ["\u{2003}"] = true,
        ["\u{2004}"] = true,
        ["\u{2005}"] = true,
        ["\u{2006}"] = true,
        ["\u{2007}"] = true,
        ["\u{2008}"] = true,
        ["\u{2009}"] = true,
        ["\u{200A}"] = true,
        ["\u{202F}"] = true,
        ["\u{205F}"] = true,
        ["、"] = true,
        ["："] = true,
        ["》"] = true,
        ["——"] = true
    }
    local need_clean = {
        ["、"] = true,
        ["："] = true,
        ["》"] = true,
        ["——"] = true
    }
    local is_need_clean
    for i, v in ipairs(words) do
        if i > 1 and segmentation[v] == true then
            if need_clean[v] then
                is_need_clean = true
            end
            break
        end
        count = count + 1
    end

    local words_len = #words
    if count > 0 and count < words_len then
        local part_end = count
        local subpart_start = count + 1
        -- 跳过字符
        if is_need_clean == true then
            subpart_start = subpart_start + 1
        end

        if subpart_start > words_len then
            -- 去掉结尾字符
            return "", table.concat(words, "", 1, words_len - 1)
        end
        local part = table.concat(words, "", 1, part_end)
        local subpart = table.concat(words, "", subpart_start)
        return part, subpart
    end

    -- 回退支持: 中文"第X章/节/卷"开头
    local matched = title:match("^(第[%d一二三四五六七八九十百千万零〇两]+[章节卷集篇回话页季部])")
    if matched and #matched < #title then
        local part = matched
        local subpart = title:sub(#matched + 1)
        return part, subpart
    end

    return "", title
end

-- ============================================================
-- 章节缓存相关函数（用于 Backend.lua）
-- ============================================================

-- 添加 CSS 资源到书籍缓存目录
M.addCssRes = function(book_cache_id)
    local book_cache_path = H.getBookCachePath(book_cache_id)
    local book_css_path = string.format("%s/%s", book_cache_path, resCss)

    if not util.fileExists(book_css_path) then
        H.copyFileFromTo(mianCss, book_css_path)
    end
    return book_css_path
end

-- 生成章节 HTML（用于缓存章节）
M.addchapterT = function(title, content)
    title = title or ""
    content = content or ""
    local html = [=[
<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title><link href="%s" type="text/css" rel="stylesheet"/><style>p + p {margin-top: 0.5em;}</style>
</head><body><h2 class="head"><span class="chapter-sequence-number">%s</span><br />%s</h2>
<div>%s</div></body></html>]=]
    local part, subpart = split_title_advanced(title)
    return string.format(html, title, resCss, part or "", subpart or "", content)
end

-- ============================================================
-- EPUB 导出器（用于 LibraryView 导出 EPUB）
-- ============================================================

-- 生成简单的UUID
local function generateUUID()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    math.randomseed(os.time() + os.clock() * 1000000)
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

function EpubExporter:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--[[
    初始化导出器
    @param options table 配置选项
        - title: 书名
        - author: 作者
        - description: 简介（可选）
        - cover_path: 封面图片路径（可选）
        - custom_css: 自定义CSS内容（可选）
        - chapters: 章节列表
        - output_path: 输出路径
        - book_cache_id: 书籍缓存ID
]]
function EpubExporter:init(options)
    self.title = options.title or self.default_title
    self.author = options.author or self.default_author
    self.description = options.description
    self.cover_path = options.cover_path or self.default_cover
    self.custom_css = options.custom_css or self.default_css
    self.chapters = options.chapters or {}
    self.output_path = options.output_path
    self.book_cache_id = options.book_cache_id
    self.book_cache_path = H.getBookCachePath(self.book_cache_id)

    -- 获取封面文件扩展名和 MIME 类型
    if self.cover_path then
        local ext = self.cover_path:match("%.([^.]+)$")
        if ext then
            ext = ext:lower()
            self.cover_ext = ext
            -- 设置 MIME 类型
            if ext == "jpg" or ext == "jpeg" then
                self.cover_mime = "image/jpeg"
            elseif ext == "png" then
                self.cover_mime = "image/png"
            elseif ext == "gif" then
                self.cover_mime = "image/gif"
            elseif ext == "webp" then
                self.cover_mime = "image/webp"
            else
                self.cover_mime = "image/jpeg"
                self.cover_ext = "jpg"
            end
        else
            self.cover_ext = "jpg"
            self.cover_mime = "image/jpeg"
        end
    end

    return self
end

-- 创建OPF文件（核心元数据文件）
function EpubExporter:createOPF()
    local manifest_items = {}
    local spine_items = {}

    -- 添加封面
    table.insert(manifest_items, '<item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>')
    if self.cover_path then
        local cover_filename = string.format("cover.%s", self.cover_ext or "jpg")
        local cover_mime = self.cover_mime or "image/jpeg"
        table.insert(manifest_items, string.format(
            '<item id="cover-image" href="Images/%s" media-type="%s"/>',
            cover_filename, cover_mime
        ))
    end

    -- 添加CSS
    table.insert(manifest_items, '<item id="stylesheet" href="resources/legado.css" media-type="text/css"/>')

    -- 添加章节
    for i, chapter in ipairs(self.chapters) do
        local chapter_id = string.format("chapter%d", i)
        table.insert(manifest_items, string.format(
            '<item id="%s" href="Text/chapter%d.xhtml" media-type="application/xhtml+xml"/>',
            chapter_id, i
        ))
        table.insert(spine_items, string.format('<itemref idref="%s"/>', chapter_id))
    end

    -- 封面在spine中
    table.insert(spine_items, 1, '<itemref idref="cover"/>')

    -- 构建 description 元数据（如果有）
    local description_meta = ""
    if self.description and self.description ~= "" then
        -- 转义 XML 特殊字符
        local escaped_desc = self.description:gsub("&", "&amp;")
                                            :gsub("<", "&lt;")
                                            :gsub(">", "&gt;")
                                            :gsub("\"", "&quot;")
                                            :gsub("'", "&apos;")
        description_meta = string.format("    <dc:description>%s</dc:description>\n", escaped_desc)
    end

    local opf_template = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>%s</dc:title>
    <dc:creator>%s</dc:creator>
%s    <dc:language>zh-CN</dc:language>
    <dc:identifier id="BookId">urn:uuid:%s</dc:identifier>
    <meta name="cover" content="cover-image"/>
    <meta property="dcterms:modified">%s</meta>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="nav" href="Text/nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
%s
  </manifest>
  <spine toc="ncx">
%s
  </spine>
</package>]]

    local uuid = generateUUID()
    local timestamp = os.date("%Y-%m-%dT%H:%M:%SZ")
    local manifest_str = "    " .. table.concat(manifest_items, "\n    ")
    local spine_str = "    " .. table.concat(spine_items, "\n    ")

    return string.format(opf_template, self.title, self.author, description_meta, uuid, timestamp, manifest_str, spine_str)
end

-- 创建NCX文件（导航文件）
function EpubExporter:createNCX()
    local nav_points = {}

    for i, chapter in ipairs(self.chapters) do
        local nav_point = string.format([[
    <navPoint id="navPoint-%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="Text/chapter%d.xhtml"/>
    </navPoint]], i, i, chapter.title or ("第" .. i .. "章"), i)
        table.insert(nav_points, nav_point)
    end

    local ncx_template = [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <docAuthor><text>%s</text></docAuthor>
  <navMap>
%s
  </navMap>
</ncx>]]

    local uuid = generateUUID()
    local nav_str = table.concat(nav_points, "\n")

    return string.format(ncx_template, uuid, self.title, self.author, nav_str)
end

-- 创建封面页面
function EpubExporter:createCoverPage()
    local cover_template = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>Cover</title>
    <style type="text/css">
        .pic {
            margin: 50%% 30%% 0 30%%;
            padding: 2px 2px;
            border: 1px solid #f5f5dc;
            background-color: rgba(250,250,250, 0);
            border-radius: 1px;
        }
    </style>
</head>
<body style="text-align: center;">
%s
<h1 style="margin-top: 5%%; font-size: 110%%;">%s</h1>
<div class="author" style="margin-top: 0;"><b>%s</b> <span style="font-size: smaller;">/ 著</span></div>
</body>
</html>]]

    local cover_image = ""
    if self.cover_path then
        local cover_filename = string.format("cover.%s", self.cover_ext or "jpg")
        cover_image = string.format('<div class="pic"><img src="../Images/%s" style="width: 100%%; height: auto;"/></div>', cover_filename)
    end

    return string.format(cover_template, cover_image, self.title, self.author)
end

-- 创建导航页面（EPUB3）
function EpubExporter:createNavPage()
    local nav_items = {}

    for i, chapter in ipairs(self.chapters) do
        table.insert(nav_items, string.format(
            '        <li><a href="chapter%d.xhtml">%s</a></li>',
            i, chapter.title or ("第" .. i .. "章")
        ))
    end

    local nav_template = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
    <title>目录</title>
</head>
<body>
    <nav epub:type="toc" id="toc">
        <h1>目录</h1>
        <ol>
%s
        </ol>
    </nav>
</body>
</html>]]

    local nav_str = table.concat(nav_items, "\n")
    return string.format(nav_template, nav_str)
end

-- 创建章节页面
function EpubExporter:createChapterPage(index, chapter)
    local title = chapter.title or ("第" .. index .. "章")
    local content = chapter.content or ""

    local part, subpart = split_title_advanced(title)

    local chapter_template = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>%s</title>
    <link href="../resources/legado.css" type="text/css" rel="stylesheet"/>
    <style>p + p {margin-top: 0.5em;}</style>
</head>
<body>
    <h2 class="head">
        <span class="chapter-sequence-number">%s</span><br />%s
    </h2>
    <div>%s</div>
</body>
</html>]]

    return string.format(chapter_template, title, part or "", subpart or "", content)
end

-- 创建container.xml（EPUB必需文件）
function EpubExporter:createContainer()
    return [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
end

-- 创建mimetype文件（EPUB必需文件）
function EpubExporter:createMimetype()
    return "application/epub+zip"
end

-- 构建EPUB文件
function EpubExporter:build()
    -- 清理失败的缓存文件（.tmp 文件）
    if self.book_cache_path and lfs.attributes(self.book_cache_path, "mode") == "directory" then
        for file in lfs.dir(self.book_cache_path) do
            if file:match("%.tmp$") then
                local tmp_file = self.book_cache_path .. "/" .. file
                pcall(function()
                    util.removeFile(tmp_file)
                    logger.dbg("Cleaned up tmp file:", tmp_file)
                end)
            end
        end
    end

    -- 打包EPUB
    return self:packageEpub()
end

-- 打包EPUB文件（使用 Archiver 或 ZipWriter）
function EpubExporter:packageEpub()
    local epub_path = self.output_path
    if not epub_path then
        logger.warn("未指定输出路径")
        return {
            success = false,
            error = "未指定输出路径"
        }
    end

    -- 创建临时文件
    local epub_path_tmp = epub_path .. ".tmp"

    -- 根据 KOReader 版本选择压缩库
    -- 2025.08 (202508000000) 之后优先使用 Archiver
    local epub_lib
    local epub
    local mtime
    local no_compression

    local ko_version = require("version"):getNormalizedCurrentVersion()
    local use_archiver = ko_version and ko_version >= 202508000000

    if use_archiver then
        -- KOReader 2025.08+ 使用新版 Archiver
        local ok, Archiver = pcall(require, "ffi/archiver")
        if ok and Archiver then
            epub_lib = "archiver"
            mtime = os.time()

            epub = Archiver.Writer:new{}
            if not epub:open(epub_path_tmp, "epub") then
                logger.warn("无法创建 EPUB 文件 (archiver):", epub_path_tmp)
                return {
                    success = false,
                    error = "无法创建 EPUB 文件"
                }
            end

            -- mimetype 必须不压缩存储
            epub:setZipCompression("store")
            epub:addFileFromMemory("mimetype", self:createMimetype(), mtime)
            epub:setZipCompression("deflate")
        else
            -- 降级使用 ZipWriter
            use_archiver = false
        end
    end

    if not use_archiver then
        -- KOReader 2025.08 之前或 Archiver 不可用，使用 ZipWriter
        local ok, ZipWriter = pcall(require, "ffi/zipwriter")
        if ok and ZipWriter then
            epub_lib = "zipwriter"
            no_compression = true

            epub = ZipWriter:new{}
            if not epub:open(epub_path_tmp) then
                logger.warn("无法创建 EPUB 文件 (zipwriter):", epub_path_tmp)
                return {
                    success = false,
                    error = "无法创建 EPUB 文件"
                }
            end
            epub:add("mimetype", "application/epub+zip", true)
        else
            logger.warn("无法加载任何压缩库")
            return {
                success = false,
                error = "无法创建 EPUB 文件：压缩库不可用"
            }
        end
    end

    -- 辅助函数：兼容两种压缩库的文件添加
    local function addFile(filename, content, no_compress)
        if epub_lib == "zipwriter" then
            epub:add(filename, content, no_compress or no_compression)
        else
            epub:addFileFromMemory(filename, content, mtime)
        end
    end

    -- container.xml
    addFile("META-INF/container.xml", self:createContainer())

    -- CSS
    local css_content
    if self.custom_css then
        css_content = self.custom_css
    else
        local default_css_path = string.format("%s/Legado/main.css.lua", H.get_plugin_path())
        if util.fileExists(default_css_path) then
            local f = io.open(default_css_path, "r")
            if f then
                css_content = f:read("*all")
                f:close()
            end
        end
    end
    if css_content then
        addFile("OEBPS/resources/legado.css", css_content)
    end

    -- 封面图片
    if self.cover_path and util.fileExists(self.cover_path) then
        local f = io.open(self.cover_path, "rb")
        if f then
            local cover_data = f:read("*all")
            f:close()
            local cover_filename = string.format("cover.%s", self.cover_ext or "jpg")
            -- 图片不需要压缩
            addFile("OEBPS/Images/" .. cover_filename, cover_data, true)
        end
    end

    -- 封面页
    addFile("OEBPS/Text/cover.xhtml", self:createCoverPage())

    -- 导航页
    addFile("OEBPS/Text/nav.xhtml", self:createNavPage())

    -- 章节
    for i, chapter in ipairs(self.chapters) do
        local chapter_content = self:createChapterPage(i, chapter)
        addFile(string.format("OEBPS/Text/chapter%d.xhtml", i), chapter_content)
    end

    -- OPF
    addFile("OEBPS/content.opf", self:createOPF())

    -- NCX
    addFile("OEBPS/toc.ncx", self:createNCX())

    -- 关闭压缩库
    if epub and epub.close then
        epub:close()
    end

    -- 重命名临时文件为最终文件
    local success = os.rename(epub_path_tmp, epub_path)

    if success then
        logger.info("EPUB 创建成功:", epub_path)
        logger.info("标题:", self.title, "作者:", self.author)

        -- 清理缓存目录（可选）
        collectgarbage()
        collectgarbage()

        return {
            success = true,
            path = epub_path,
            title = self.title,
            author = self.author
        }
    else
        logger.warn("无法重命名 EPUB 文件")
        return {
            success = false,
            error = "无法重命名 EPUB 文件"
        }
    end
end

-- 导出 EpubExporter 类
M.EpubExporter = EpubExporter

return M
