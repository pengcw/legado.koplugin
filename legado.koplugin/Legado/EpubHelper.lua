local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local logger = require("logger")
local image_meta = require("Legado.Helper.image_meta")

local M = {}

local EpubExporter = {
    default_author = "未知作者",
    default_title = "未命名图书",
    default_css = nil,
    default_cover = nil,
}

local resCss = "../resources/legado.css"
local epubCss = "resources/legado.css"
local defaultCss = "Legado/res/main.css"

local function split_title_advanced(title)
    if type(title) ~= 'string' or title == "" then
        return nil, nil
    end
    local words = util.splitToChars(title)

    if not H.is_tbl(words) or #words == 0 then
        return nil, nil
    end

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
        ["—"] = true,
        ["."] = true
    }
    local need_clean = {
        ["、"] = true,
        ["："] = true,
        ["》"] = true,
        ["—"] = true,
        ["."] = true
    }
    local all_blank = true
    for _, w in ipairs(words) do
        if not segmentation[w] then
            all_blank = false
            break
        end
    end
    if all_blank then return "", title end
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
        if is_need_clean == true then
            while subpart_start <= words_len and need_clean[words[subpart_start]] do
                subpart_start = subpart_start + 1
            end
        end

        if subpart_start > words_len then
            return "", table.concat(words, "", 1, words_len - 1)
        end
        local part = table.concat(words, "", 1, part_end)
        local subpart = table.concat(words, "", subpart_start)
        return part, subpart
    end

    local CN_NUM = { ["一"]=true, ["二"]=true, ["三"]=true, ["四"]=true, ["五"]=true,
        ["六"]=true, ["七"]=true, ["八"]=true, ["九"]=true, ["十"]=true,
        ["百"]=true, ["千"]=true, ["万"]=true, ["零"]=true, ["〇"]=true, ["两"]=true }
    local CN_SUFFIX = { ["章"]=true, ["节"]=true, ["卷"]=true, ["集"]=true, ["篇"]=true,
        ["回"]=true, ["话"]=true, ["页"]=true, ["季"]=true, ["部"]=true }
    if words[1] == "第" and #words >= 3 then
        local j = 2
        while j <= #words and (CN_NUM[words[j]] or (type(words[j]) == "string" and words[j]:match("^%d$"))) do
            j = j + 1
        end
        if j > 2 and j <= #words and CN_SUFFIX[words[j]] then
            local part = table.concat(words, "", 1, j)
            local subpart = table.concat(words, "", j + 1)
            return part, subpart
        end
    end

    return "", title
end

M.split_title_advanced = split_title_advanced
M.split_title = split_title_advanced

M.escape_xml = function(text)
    local escaped = tostring(text or "")
    escaped = escaped:gsub("&", "&amp;")
    escaped = escaped:gsub("<", "&lt;")
    escaped = escaped:gsub(">", "&gt;")
    return escaped
end

M.escape_xml_attr = function(value, quote)
    local escaped = M.escape_xml(value)
    if quote == '"' then
        return escaped:gsub('"', "&quot;")
    else
        return escaped:gsub("'", "&apos;")
    end
end

M.addCssRes = function(book_cache_id)
    local resources_dir = FS.joinPath(Env.getTempDirectory(), "resources")
    local css_path = FS.joinPath(resources_dir, "legado.css")
    if not util.fileExists(css_path) then
        FS.checkAndCreateFolder(resources_dir)
        local source_path = FS.joinPath(Env.getPluginDirectory(), defaultCss)
        if util.fileExists(source_path) then
            FS.copyFileFromTo(source_path, css_path)
        end
    end
    return css_path
end

M.prepareCacheResources = function()
    local css_path = M.addCssRes()
    local marker = FS.joinPath(Env.getTempDirectory(), ".nomedia")
    if not util.fileExists(marker) then
        local file, err = io.open(marker, "wb")
        if file then
            file:close()
        else
            logger.warn("Legado .nomedia creation failed:", err)
        end
    end
    return css_path
end

M.format_title_header = function(title, ch_idx)
    local ch_title = title
    if (not ch_title or ch_title == "") and ch_idx ~= nil then
        ch_title = string.format("第%d章", ch_idx + 1)
    end
    ch_title = ch_title or ""
    local safe_title = M.escape_xml(ch_title)

    local part, subpart = split_title_advanced(ch_title)
    local title_header = safe_title
    if part and part ~= "" and subpart and subpart ~= "" then
        title_header = string.format(
            '<span class="chapter-sequence-number">%s</span><br />%s',
            M.escape_xml(part),
            M.escape_xml(subpart)
        )
    end
    return safe_title, title_header
end

M.addchapterT = function(title, content)
    content = content or ""
    local safe_title, title_header = M.format_title_header(title)
    local html = [=[
<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title><link href="%s" type="text/css" rel="stylesheet"/><style>p + p {margin-top: 0.5em;}</style>
</head><body><h2 class="head">%s</h2>
<div class="legado-chapter-v2">%s</div></body></html>]=]
    return string.format(html, safe_title, resCss, title_header, content)
end

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

function EpubExporter:init(options)
    self.title = options.title or self.default_title
    self.author = options.author or self.default_author
    self.description = options.description
    self.cover_path = options.cover_path or self.default_cover
    self.custom_css = options.custom_css or self.default_css
    self.chapters = options.chapters or {}
    self.output_path = options.output_path
    self.book_cache_id = options.book_cache_id
    self.book_cache_path = Env.getBookCachePath(self.book_cache_id)

    if self.cover_path then
        local ext = image_meta.get_image_ext(self.cover_path) or "jpg"
        self.cover_ext = ext
        self.cover_mime = image_meta.get_mime_type(ext)
    end

    return self
end

function EpubExporter:createOPF()
    local manifest_items = {}
    local spine_items = {}

    table.insert(manifest_items, '<item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>')
    if self.cover_path then
        local cover_filename = string.format("cover.%s", self.cover_ext or "jpg")
        local cover_mime = self.cover_mime or "image/jpeg"
        table.insert(manifest_items, string.format(
            '<item id="cover-image" href="Images/%s" media-type="%s"/>',
            cover_filename, cover_mime
        ))
    end

    table.insert(manifest_items, '<item id="stylesheet" href="Text/resources/legado.css" media-type="text/css"/>')

    for _, chapter in ipairs(self.chapters) do
        local chapter_index = chapter.chapters_index
        local chapter_id = string.format("chapter%d", chapter_index)
        table.insert(manifest_items, string.format(
            '<item id="%s" href="Text/chapter%d.xhtml" media-type="application/xhtml+xml"/>',
            chapter_id, chapter_index
        ))
        table.insert(spine_items, string.format('<itemref idref="%s"/>', chapter_id))
    end

    table.insert(spine_items, 1, '<itemref idref="cover"/>')

    local description_meta = ""
    if H.is_str(self.description) and self.description ~= "" then
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

function EpubExporter:createNCX()
    local nav_points = {}

    for _, chapter in ipairs(self.chapters) do
        local chapter_index = chapter.chapters_index
        local nav_point = string.format([[
    <navPoint id="navPoint-%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="Text/chapter%d.xhtml"/>
    </navPoint]], chapter_index, chapter_index, chapter.title or ("第" .. (chapter_index + 1) .. "章"), chapter_index)
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
    if H.is_str(self.cover_path) then
        local cover_filename = string.format("cover.%s", self.cover_ext or "jpg")
        cover_image = string.format('<div class="pic"><img src="../Images/%s" style="width: 100%%; height: auto;"/></div>', cover_filename)
    end

    return string.format(cover_template, cover_image, self.title, self.author)
end

function EpubExporter:createNavPage()
    local nav_items = {}

    for _, chapter in ipairs(self.chapters) do
        local chapter_index = chapter.chapters_index
        table.insert(nav_items, string.format(
            '        <li><a href="chapter%d.xhtml">%s</a></li>',
            chapter_index, chapter.title or ("第" .. (chapter_index + 1) .. "章")
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

function EpubExporter:createChapterPage(index, chapter)
    local title = chapter.title or ("第" .. index .. "章")
    local content = chapter.content or ""
    local safe_title, title_header = M.format_title_header(title, index - 1)

    local chapter_template = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>%s</title>
    <link href="resources/legado.css" type="text/css" rel="stylesheet"/>
    <style>p + p {margin-top: 0.5em;}</style>
</head>
<body>
    <h2 class="head">%s</h2>
    <div>%s</div>
</body>
</html>]]

    return string.format(chapter_template, safe_title, title_header, content)
end

function EpubExporter:createContainer()
    return [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
end

function EpubExporter:createMimetype()
    return "application/epub+zip"
end

function EpubExporter:build()

    if H.is_str(self.book_cache_path) and util.directoryExists(self.book_cache_path) then
        util.findFiles(self.book_cache_path, function(path, fname, attr)
            if attr and attr.mode == "file" and H.is_str(fname) and fname:match("%.tmp$")then
                pcall(function()
                    util.removeFile(path)
                    logger.dbg("Cleaned up tmp file:", path)
                end)
            end
        end, false)
    end

    return self:packageEpub()
end

function EpubExporter:packageEpub()
    local epub_path = self.output_path
    if not epub_path then
        logger.warn("未指定输出路径")
        return {
            success = false,
            error = "未指定输出路径"
        }
    end

    local epub_path_tmp = epub_path .. ".tmp"
    local ZipWrite = require("Legado.Helper.ZipUtil").Writer
    local new_ok, writer = pcall(ZipWrite.new, ZipWrite)
    if not new_ok or not writer then
        logger.warn("无法加载任何压缩库")
        return {
            success = false,
            error = "无法创建 EPUB 文件：压缩库不可用"
        }
    end
    if not writer:open(epub_path_tmp) then
        logger.warn("无法创建 EPUB 文件:", epub_path_tmp)
        return {
            success = false,
            error = "无法创建 EPUB 文件"
        }
    end

    local mimetype_ok, mimetype_err = writer:add("mimetype", self:createMimetype(), true)
    if not mimetype_ok then
        writer:close()
        logger.warn("无法写入 mimetype:", mimetype_err)
        return {
            success = false,
            error = "无法创建 EPUB 文件：mimetype 写入失败"
        }
    end

    local function addFile(filename, content, no_compress)
        local add_ok, add_err = writer:add(filename, content, no_compress)
        if not add_ok then
            logger.warn("添加 EPUB 文件失败:", filename, tostring(add_err))
        end
    end

    addFile("META-INF/container.xml", self:createContainer())

    if H.is_str(self.cover_path) and util.fileExists(self.cover_path) then
        local cover_data = util.readFromFile(self.cover_path, "rb")
        local cover_filename = string.format("cover.%s", self.cover_ext or "jpg")
        addFile("OEBPS/Images/" .. cover_filename, cover_data, true)
    end
    addFile("OEBPS/Text/cover.xhtml", self:createCoverPage())
    addFile("OEBPS/Text/nav.xhtml", self:createNavPage())

    local cache_ext
    local cache_file_path
    local chapter_content
    local file_index
    for _, chapter in ipairs(self.chapters) do

        file_index = chapter.chapters_index
        cache_ext = chapter.cache_ext
        cache_file_path = chapter.cache_path
        chapter_content = ""

        if cache_ext == "txt" then
            chapter_content = util.readFromFile(cache_file_path, "r") or ""
            chapter.content = chapter_content:gsub("([^\n]+)", "<p>%1</p>")
            chapter_content = self:createChapterPage(file_index, chapter)
        elseif cache_ext == "html" or cache_ext == "xhtml" then
            chapter_content = util.readFromFile(cache_file_path, "r") or ""
            chapter_content = chapter_content:gsub('href="%.%./resources/legado%.css"', 'href="' .. epubCss .. '"')
            if self.custom_css_path then
                chapter_content = chapter_content:gsub('<p%s+style="text%-indent:%s*0em;"><span%s+class="duokan%-dropcaps%-two">(.)</span>', '<p>%1')
            end
        elseif image_meta.is_image_extension(cache_ext) then
            local img_data = util.readFromFile(cache_file_path, "rb")
            if img_data then
                 chapter.content = string.format("<img src='resources/chapter%d.%s'><img>", file_index, cache_ext)
                 chapter_content = self:createChapterPage(file_index, chapter)
                 addFile(string.format("OEBPS/Text/resources/chapter%d.%s", file_index, cache_ext), img_data)
            end
        end

        addFile(string.format("OEBPS/Text/chapter%d.xhtml", file_index), chapter_content)
    end

    addFile("OEBPS/content.opf", self:createOPF())

    addFile("OEBPS/toc.ncx", self:createNCX())

    local resources_path = FS.joinPath(self.book_cache_path, "resources")
    if util.directoryExists(resources_path) then
        util.findFiles(resources_path, function(file_path, fname, attr)
            if attr and attr.mode == "file" and H.is_str(fname) and fname ~= "" then
                if fname ~= "legado.css" then
                    local file_content = util.readFromFile(file_path)
                    if file_content and #file_content > 0 then
                        addFile("OEBPS/Text/resources/" .. fname, file_content)
                    else
                        logger.warn("Empty or unreadable resource file:", file_path)
                    end
                end
            end
        end, false)
    end

    local css_content = self.custom_css
        or util.readFromFile(FS.joinPath(Env.getPluginDirectory(), defaultCss), "r")
    if css_content then
        addFile("OEBPS/Text/resources/legado.css", css_content)
    end

    if writer and writer.close then
        writer:close()
    end

    local success = os.rename(epub_path_tmp, epub_path)
    if success then

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

M.EpubExporter = EpubExporter

return M
