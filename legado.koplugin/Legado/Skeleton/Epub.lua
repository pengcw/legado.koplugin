local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local ZipUtil = require("Legado.Helper.ZipUtil")
local image_meta = require("Legado.Helper.image_meta")
local logger = require("logger")
local DocSettings = require("docsettings")
local EpubHelper = require("Legado/EpubHelper")

local ReviewLink = require("Legado.Helper.ReviewLink")
local M = {}

local SKELETON_SCHEMA_VERSION = 6
M.SKELETON_SCHEMA_VERSION = SKELETON_SCHEMA_VERSION

local PATCH_WASTE_REWRITE_THRESHOLD = 20 * 1024 * 1024
local PATCH_WASTE_REWRITE_RATIO = 0.5

function M.isSupported()
    local ok, writer = pcall(ZipUtil.Writer.new, ZipUtil.Writer)
    return ok and writer ~= nil
end

function M.readSkeletonMetadata(epub_path)
    if not (H.is_str(epub_path) and util.fileExists(epub_path)) then
        return nil, "epub file does not exist"
    end

    local reader = ZipUtil.Reader:new()
    local ok_open, err_open = reader:open(epub_path)
    if not ok_open then
        return nil, err_open or "failed to open epub reader"
    end
    local opf_data = reader:extractToMemory("OEBPS/content.opf")
    reader:close()
    if not opf_data then
        return nil, "invalid skeleton epub structure"
    end

    local book_cache_id = opf_data:match("legado:book_cache_id[^>]*>([^<]+)<")
        or opf_data:match("<dc:identifier[^>]*>legado%-skeleton%-book_([^<]+)<")
    if not H.is_str(book_cache_id) or book_cache_id == "" then
        return nil, "skeleton book_cache_id not found"
    end

    local chapter_count = 0
    for _ in opf_data:gmatch('id="ch_[^"]+"') do
        chapter_count = chapter_count + 1
    end
    if chapter_count == 0 then
        return nil, "skeleton chapters not found"
    end

    return {
        book_cache_id = book_cache_id,
        review_links_version = tonumber(opf_data:match('name="legado:review_links" content="(%d+)"')),
        schema_version = tonumber(opf_data:match("legado:schema_version[^>]*>(%d+)<")),
        chapters_count = chapter_count,
    }
end

function M.restoreDocSettings(epub_path, expected_book_cache_id)
    local metadata, err = M.readSkeletonMetadata(epub_path)
    if not metadata then return false, err end
    if expected_book_cache_id and metadata.book_cache_id ~= expected_book_cache_id then
        return false, "book_cache_id mismatch"
    end

    local ds = DocSettings:open(epub_path)
    if not ds then return false, "failed to open doc settings" end
    ds:saveSetting("provider", "legado")
    ds:saveSetting("is_skeleton_epub", true)
    ds:saveSetting("book_cache_id", metadata.book_cache_id)
    ds:saveSetting("alternative_toc", false)
    ds:saveSetting("virtual_book_chapters_count", metadata.chapters_count)
    if metadata.schema_version then
        ds:saveSetting("virtual_book_schema_version", metadata.schema_version)
    end
    if ds.flush then ds:flush() end
    return true, metadata
end

local DEFAULT_CSS = [[
body { font-family: sans-serif; margin: 5%; line-height: 1.6; text-align: justify; }
h2 { text-align: center; margin-bottom: 1em; }
h2.head { font-family: "小标宋"; text-align: left; font-weight: 700; font-size: 1.1em; margin: 1em 2em 2em 0; color: #3f83e8; line-height: 140%; }
h2.head span { font-family: "仿宋"; font-size: .7em; background-color: #3f83e8; border-radius: 9px; padding: 4px; color: #fff; }
p { text-indent: 2em; margin: 0.5em 0; text-align: justify; line-height: 1.6; }
p + p { margin-top: 0.5em; }
span.duokan-dropcaps-two { float: left; font-size: 2.2em; line-height: 1.1; margin-right: 0.1em; margin-bottom: -0.1em; font-weight: bold; }
div.duokan-image-single { text-align: center; margin: 1em auto; }
img.picture-80 { max-width: 85%; margin: 0.5em auto; display: block; }
.legado-placeholder-ch h2.head { margin-bottom: 0.6em; }
.legado-placeholder-box {
  margin: 1em auto;
  padding: 0.8em;
  max-width: 92%;
  border: 1px dashed #888;
  border-radius: 10px;
  text-align: center;
  background-color: rgba(128, 128, 128, 0.05);
}
.legado-placeholder-icon {
  font-size: 1.5em;
  margin-bottom: 0.1em;
}
.legado-placeholder-title {
  font-size: 1.05em;
  font-weight: bold;
  margin-bottom: 0.25em;
}
.legado-placeholder-desc {
  font-size: 0.9em;
  opacity: 0.75;
  margin-bottom: 0.5em;
  line-height: 1.3;
}
.legado-placeholder-hint {
  font-size: 0.8em;
  opacity: 0.65;
  border-top: 1px solid rgba(128, 128, 128, 0.25);
  padding-top: 0.35em;
  margin-top: 0.3em;
  line-height: 1.3;
}
]]

local PLACEHOLDER_TEMPLATE = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title><link rel="stylesheet" href="../Styles/legado.css" type="text/css"/></head>
<body>
  <div class="legado-ch legado-placeholder-ch" id="ch_%d" data-chapter-index="%d">
    <h2 class="head">%s</h2>
    <div class="legado-placeholder-box">
      <div class="legado-placeholder-icon">⚡</div>
      <div class="legado-placeholder-title">正文暂未加载</div>
      <div class="legado-placeholder-desc">正文正在加载，请稍候。</div>
      <div class="legado-placeholder-hint">长时间未加载？检查网络、书源或 Legado 插件。</div>
    </div>
  </div>
</body>
</html>]]

local REAL_TEMPLATE = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title><link rel="stylesheet" href="../Styles/legado.css" type="text/css"/></head>
<body>
  <div class="legado-ch" id="ch_%d" data-chapter-index="%d">
    <h2 class="head">%s</h2>
    %s
  </div>
</body>
</html>]]

local function get_title_markup(ch_idx, title)
    return EpubHelper.format_title_header(title, ch_idx)
end

function M.formatBodyHtml(content)
    if type(content) ~= "string" or content == "" then
        return "<p></p>"
    end

    local is_html_doc = content:find("<body", 1, true) ~= nil
    local has_block_tag = content:find("<p[ >]") or content:find("<div[ >]")
    if not is_html_doc and not has_block_tag then
        local paragraphs = {}
        for line in content:gmatch("([^\r\n]+)") do
            local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                table.insert(paragraphs, "<p>" .. EpubHelper.escape_xml(trimmed) .. "</p>")
            end
        end
        return table.concat(paragraphs, "\n")
    end

    local body_inner = content:match("<body[^>]*>(.-)</body>")
    if body_inner then
        content = body_inner:gsub("<h[1-6][^>]*>.-</h[1-6]>", "")
    end

    if content:find("legado%-chapter%-v2", 1, true) then
        return content
    end

    if content:find("<p[^>]*>%s*<div") or content:find("<br>") or content:find("<[iI][mM][gG][^>]-[^/]>") then
        content = content:gsub("<p[^>]*>%s*(<div class=\"duokan%-image%-single\">.-</div>)%s*</p>", "%1")
        content = content:gsub("<br%s*>", "<br />")
        content = content:gsub("<[iI][mM][gG](%s+.-)/?>", function(attrs)
            local trimmed = attrs:gsub("%s*/%s*$", ""):gsub("%s+$", "")
            return "<img" .. trimmed .. " />"
        end)
    end

    return content
end

function M.formatPlaceholderXhtml(ch_idx, title)
    local safe_title, title_header = get_title_markup(ch_idx, title)
    return string.format(PLACEHOLDER_TEMPLATE, safe_title, ch_idx, ch_idx, title_header)
end

function M.formatChapterXhtml(ch_idx, title, raw_content)
    local safe_title, title_header = get_title_markup(ch_idx, title)
    local body_html = M.formatBodyHtml(raw_content)
    return string.format(REAL_TEMPLATE, safe_title, ch_idx, ch_idx, title_header, body_html)
end

function M.formatImageXhtml(ch_idx, title, ext)
    local safe_title, title_header = get_title_markup(ch_idx, title)
    local res_src = string.format("resources/chapter_%d.%s", ch_idx, ext)
    local body_html = string.format('<div class="duokan-image-single"><img class="picture-80" src="%s" alt=""/></div>', res_src)
    return string.format(REAL_TEMPLATE, safe_title, ch_idx, ch_idx, title_header, body_html)
end

function M.collectChapterResources(html, book_cache_id)
    if type(html) ~= "string" or html == "" or type(book_cache_id) ~= "string" or book_cache_id == "" then
        return nil
    end
    local names = {}
    for name in html:gmatch('src%s*=%s*["\']resources/([%w%.%-_]+)["\']') do
        names[name] = true
    end
    for name in html:gmatch('url%s*%(%s*["\']?resources/([%w%.%-_]+)["\']?%s*%)') do
        names[name] = true
    end
    if not next(names) then return nil end
    local book_cache_path = Env.getBookCachePath(book_cache_id)
    local resources = {}
    for name in pairs(names) do
        if name ~= "legado.css" then
            local filepath = string.format("%s/resources/%s", book_cache_path, name)
            local data = util.fileExists(filepath) and util.readFromFile(filepath) or nil
            if data and data ~= "" then
                resources[string.format("OEBPS/Text/resources/%s", name)] = data
            else
                logger.warn("SkeletonEpub.collectChapterResources: resource file missing or empty, skipped: %s", tostring(filepath))
            end
        end
    end
    if not next(resources) then return nil end
    return resources
end

function M.resolveChapterContent(ch_idx, title, raw_content, book_cache_id)
    if type(raw_content) == "string" and raw_content ~= "" then
        local ext = image_meta.sniff_format(raw_content)
        if ext and ext ~= "" then
            local res_entry = string.format("OEBPS/Text/resources/chapter_%d.%s", ch_idx, ext)
            return M.formatImageXhtml(ch_idx, title, ext), { [res_entry] = raw_content }
        end
    end
    local xhtml = M.formatChapterXhtml(ch_idx, title, raw_content)
    local resources
    if type(raw_content) == "string" and raw_content ~= "" and book_cache_id and book_cache_id ~= "" then
        resources = M.collectChapterResources(raw_content, book_cache_id)
    end
    if ReviewLink.EPUB_FALLBACK_ENABLED and book_cache_id then
        xhtml = ReviewLink.epub_links(xhtml, {book_cache_id = book_cache_id, chapters_index = ch_idx})
    end
    return xhtml, resources
end

function M.buildSkeleton(options)
    options = options or {}
    local bookinfo = options.bookinfo or {}
    local toc = options.toc or {}
    local chapters_content = options.chapters_content or {}
    local output_path = options.output_path
    if not output_path or output_path == "" then
        return false, "output_path is required"
    end
    if #toc == 0 then
        return false, "toc is empty"
    end

    local tmp_output_path = output_path .. ".tmp"
    if util.fileExists(tmp_output_path) then
        pcall(util.removeFile, tmp_output_path)
    end

    local writer = ZipUtil.Writer:new()
    local ok_open, err_open = writer:open(tmp_output_path)
    if not ok_open then
        return false, "failed to open zip writer: " .. tostring(err_open)
    end

    writer:add("mimetype", "application/epub+zip", true)

    local container_xml = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
    writer:add("META-INF/container.xml", container_xml, true)

    writer:add("OEBPS/Styles/legado.css", options.custom_css or DEFAULT_CSS, true)

    local cover_path = options.cover_path
    local cover_bytes, cover_ext, cover_media_type
    if cover_path and util.fileExists(cover_path) then
        cover_bytes = util.readFromFile(cover_path)
        if cover_bytes and #cover_bytes > 0 then
            cover_ext = (cover_path:match("%.([^%.]+)$") or "jpeg"):lower()
            if cover_ext == "jpg" then cover_ext = "jpeg" end
            cover_media_type = (cover_ext == "png" and "image/png")
                or (cover_ext == "webp" and "image/webp")
                or (cover_ext == "gif" and "image/gif")
                or "image/jpeg"
        end
    end

    local manifest_buf = {
        '<item id="css" href="Styles/legado.css" media-type="text/css"/>',
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    }
    local spine_buf = {}
    local ncx_nav_buf = {}

    local title_escaped = EpubHelper.escape_xml(bookinfo.title or "未知书名")
    local author_escaped = EpubHelper.escape_xml(bookinfo.author or "未知作者")
    local description_escaped = EpubHelper.escape_xml(bookinfo.description or bookinfo.intro or "")
    local raw_cache_id = (bookinfo.cache_id or "default")
    local book_id_escaped = EpubHelper.escape_xml("legado-skeleton-book_" .. raw_cache_id)

    local meta_cover_tag = ""
    if cover_bytes then
        local cover_img_entry = string.format("OEBPS/Images/cover.%s", cover_ext)
        writer:add(cover_img_entry, cover_bytes, true)
        table.insert(manifest_buf, string.format('<item id="cover-image" href="Images/cover.%s" media-type="%s"/>', cover_ext, cover_media_type))
        meta_cover_tag = '<meta name="cover" content="cover-image"/>'

        local cover_xhtml = string.format([[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Cover</title><style type="text/css">
body { margin: 0; padding: 0; text-align: center; background-color: #ffffff; }
div.cover-box { width: 50%%; margin: 10%% auto 0 auto; padding: 3px; border: 1px solid #f5f5dc; border-radius: 2px; }
img.cover-img { width: 100%%; height: auto; display: block; margin: 0 auto; }
h1 { margin-top: 6%%; font-size: 110%%; }
.author { margin-top: 0; }
</style></head>
<body>
  <div class="cover-box"><img class="cover-img" src="../Images/cover.%s" alt="Cover"/></div>
  <h1>%s</h1>
  <div class="author"><b>%s</b> <span style="font-size: smaller;">/ 著</span></div>
</body>
</html>]], cover_ext, title_escaped, author_escaped)
        writer:add("OEBPS/Text/cover.xhtml", cover_xhtml, true)
        table.insert(manifest_buf, '<item id="cover-page" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>')
        table.insert(spine_buf, '<itemref idref="cover-page"/>')
    else
        local cover_xhtml = string.format([[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Cover</title><link rel="stylesheet" href="../Styles/legado.css" type="text/css"/></head>
<body>
  <div class="cover-container" style="text-align: center; margin-top: 30%%;">
    <h1 style="font-size: 2em; margin-bottom: 0.5em;">%s</h1>
    <p style="font-size: 1.2em; color: #555;">%s 著</p>
  </div>
</body>
</html>]], title_escaped, author_escaped)
        writer:add("OEBPS/Text/cover.xhtml", cover_xhtml, true)
        table.insert(manifest_buf, '<item id="cover-page" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>')
        table.insert(spine_buf, '<itemref idref="cover-page"/>')
    end

    if ReviewLink.EPUB_FALLBACK_ENABLED then
        table.insert(manifest_buf, '<item id="legado-review-fallback" href="Text/r.xhtml" media-type="application/xhtml+xml"/>')
    end
    for i, ch in ipairs(toc) do
        local ch_idx = ch.index or (i - 1)
        local ch_id = string.format("ch_%d", ch_idx)
        local ch_file = string.format("Text/chapter_%d.xhtml", ch_idx)
        local ch_title = ch.title or string.format("第%d章", ch_idx + 1)
        local ch_title_escaped = EpubHelper.escape_xml(ch_title)

        table.insert(manifest_buf, string.format('<item id="%s" href="%s" media-type="application/xhtml+xml"/>', ch_id, ch_file))
        table.insert(spine_buf, string.format('<itemref idref="%s"/>', ch_id))
        table.insert(ncx_nav_buf, string.format([[
    <navPoint id="nav_%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s#ch_%d"/>
    </navPoint>]], ch_idx, i, ch_title_escaped, ch_file, ch_idx))
    end

    if ReviewLink.EPUB_FALLBACK_ENABLED then
        table.insert(spine_buf, '<itemref idref="legado-review-fallback" linear="no"/>')
    end
    local opf_content = string.format([[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>%s</dc:title>
    <dc:creator>%s</dc:creator>
    <dc:identifier id="BookId">%s</dc:identifier>
    <dc:description>%s</dc:description>
    <dc:language>zh-CN</dc:language>
    <meta property="legado:book_cache_id">%s</meta>
    <meta property="legado:schema_version">%d</meta>
    %s
    %s
  </metadata>
  <manifest>
    %s
  </manifest>
  <spine toc="ncx">
    %s
  </spine>
  <guide>
    <reference type="cover" title="Cover" href="Text/cover.xhtml"/>
  </guide>
</package>]], title_escaped, author_escaped, book_id_escaped, description_escaped, EpubHelper.escape_xml(raw_cache_id),
        SKELETON_SCHEMA_VERSION,
        ReviewLink.EPUB_FALLBACK_ENABLED and '<meta name="legado:review_links" content="1"/>' or "",
        meta_cover_tag,
        table.concat(manifest_buf, "\n    "),
        table.concat(spine_buf, "\n    "))

    writer:add("OEBPS/content.opf", opf_content, true)

    local ncx_content = string.format([[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>
    %s
  </navMap>
</ncx>]], book_id_escaped, title_escaped, table.concat(ncx_nav_buf, "\n"))

    writer:add("OEBPS/toc.ncx", ncx_content, true)

    local seen_resources = {}
    local review_chapters = ReviewLink.EPUB_FALLBACK_ENABLED and {} or nil
    for _, ch in ipairs(toc) do
        local ch_idx = ch.index or (ch.chapters_index or 0)
        local ch_file = string.format("OEBPS/Text/chapter_%d.xhtml", ch_idx)
        local ch_title = ch.title or string.format("第%d章", ch_idx + 1)
        local raw_content = chapters_content[ch_idx]

        if raw_content and raw_content ~= "" and not M.isPlaceholderHtml(raw_content) then
            local xhtml, resources = M.resolveChapterContent(ch_idx, ch_title, raw_content, raw_cache_id)
            writer:add(ch_file, xhtml, true)
            if review_chapters then review_chapters[ch_idx] = xhtml end
            if resources then
                for res_entry, res_data in pairs(resources) do
                    if not seen_resources[res_entry] then
                        seen_resources[res_entry] = true
                        writer:add(res_entry, res_data, true)
                    end
                end
            end
        else
            local xhtml = M.formatPlaceholderXhtml(ch_idx, ch_title)
            writer:add(ch_file, xhtml, true)
        end
    end

    if review_chapters then
        writer:add("OEBPS/Text/r.xhtml", ReviewLink.fallback_page(nil, review_chapters), true)
    end
    local ok_close, err_close = writer:close()
    if not ok_close then
        return false, "failed to close zip writer: " .. tostring(err_close)
    end

    local ok_rename, err_rename = os.rename(tmp_output_path, output_path)
    if not ok_rename then
        return false, "failed to rename temp epub to target: " .. tostring(err_rename)
    end

    local DocSettings = require("docsettings")
    local ds = DocSettings:open(output_path)
    if ds then
        ds:saveSetting("virtual_book_schema_version", SKELETON_SCHEMA_VERSION)
        ds:saveSetting("virtual_book_chapters_count", #toc)
        ds:saveSetting("book_cache_id", raw_cache_id)
        ds:saveSetting("alternative_toc", false)
        if ds.flush then ds:flush() end
    end

    return true, output_path
end

local function add_review_fallback(epub_path, updates)
    if not ReviewLink.EPUB_FALLBACK_ENABLED then return true end
    local chapters = {}
    for path, html in pairs(updates) do
        local chapter = path:match('^OEBPS/Text/chapter_(%d+)%.xhtml$')
        if chapter then chapters[tonumber(chapter)] = html end
    end
    if not next(chapters) then return true end
    local reader = ZipUtil.Reader:new()
    local ok, err = reader:open(epub_path)
    if not ok then return false, err end
    local previous = reader:extractToMemory("OEBPS/Text/r.xhtml")
    local opf = updates["OEBPS/content.opf"] or reader:extractToMemory("OEBPS/content.opf")
    reader:close()
    if not opf then return false, "missing OPF for review fallback" end
    if not opf:find('id="legado-review-fallback"', 1, true) then
        opf = opf:gsub('</manifest>', '<item id="legado-review-fallback" href="Text/r.xhtml" media-type="application/xhtml+xml"/></manifest>', 1)
    end
    if not opf:find('idref="legado-review-fallback"', 1, true) then
        opf = opf:gsub('</spine>', '<itemref idref="legado-review-fallback" linear="no"/></spine>', 1)
    end
    if not opf:find('name="legado:review_links"', 1, true) then
        opf = opf:gsub('</metadata>', '<meta name="legado:review_links" content="1"/></metadata>', 1)
    end
    updates["OEBPS/content.opf"] = opf
    updates["OEBPS/Text/r.xhtml"] = ReviewLink.fallback_page(previous, chapters)
    return true
end

function M.updateChapters(epub_path, updated_chapters_map, options, book_cache_id)
    options = options or {}
    book_cache_id = book_cache_id or options.book_cache_id
    if not util.fileExists(epub_path) then
        return false, "epub file does not exist"
    end
    if not updated_chapters_map or not next(updated_chapters_map) then
        return true
    end

    local patcher = ZipUtil.Patcher:new()
    local ok_open, err_open = patcher:open(epub_path)
    if not ok_open then
        return false, "skeleton_structure_mismatch: " .. tostring(err_open)
    end

    local existing_entries = {}
    for _, entry in ipairs(patcher.entries or {}) do
        existing_entries[entry.path] = true
    end

    local structure_appended = false
    local missing_target = false
    for ch_idx in pairs(updated_chapters_map) do
        if H.is_num(ch_idx) and not existing_entries[M.getChapterEntryPath(ch_idx)] then
            missing_target = true
            break
        end
    end

    if missing_target then
        local ds = DocSettings:open(epub_path)
        local epub_ch_count = tonumber(ds and ds:readSetting("virtual_book_chapters_count"))
        local toc = options.get_toc and options.get_toc()
        if not (epub_ch_count and H.is_tbl(toc)) then
            return false, "skeleton_structure_mismatch: missing readable toc metadata"
        end

        local readable_pos = {}
        for i, ch in ipairs(toc) do
            local ch_idx = tonumber(ch and (ch.index or ch.chapters_index))
            if ch_idx ~= nil then readable_pos[ch_idx] = i end
        end

        for i, ch in ipairs(toc) do
            local ch_idx = tonumber(ch and (ch.index or ch.chapters_index))
            local path = ch_idx ~= nil and M.getChapterEntryPath(ch_idx) or nil
            if i <= epub_ch_count then
                if not (path and existing_entries[path]) then
                    return false, "skeleton_structure_mismatch: expected chapter entry missing"
                end
            elseif path and existing_entries[path] then
                return false, "skeleton_structure_mismatch: chapter metadata out of sync"
            end
        end

        for ch_idx in pairs(updated_chapters_map) do
            if H.is_num(ch_idx) and not existing_entries[M.getChapterEntryPath(ch_idx)] then
                local pos = readable_pos[ch_idx]
                if not pos or pos <= epub_ch_count then
                    return false, "skeleton_structure_mismatch: target chapter entry missing"
                end
            end
        end

        local new_toc = {}
        for i = epub_ch_count + 1, #toc do
            local ch = toc[i]
            local ch_idx = ch and (ch.index or ch.chapters_index)
            table.insert(new_toc, {
                index = ch_idx,
                title = ch and (ch.title or ch.name) or string.format("第%d章", i),
            })
        end
        if #new_toc == 0 then
            return false, "skeleton_structure_mismatch: target outside readable toc"
        end

        local ok_app, err_app = M.appendChapters(epub_path, new_toc, {}, book_cache_id)
        if not ok_app then
            return false, "append readable toc failed: " .. tostring(err_app)
        end
        structure_appended = true
        if ds then
            ds:saveSetting("virtual_book_chapters_count", #toc)
            if ds.flush then ds:flush() end
        end

        patcher = ZipUtil.Patcher:new()
        ok_open, err_open = patcher:open(epub_path)
        if not ok_open then
            return false, "skeleton_structure_mismatch: " .. tostring(err_open)
        end
        existing_entries = {}
        for _, entry in ipairs(patcher.entries or {}) do
            existing_entries[entry.path] = true
        end
        for ch_idx in pairs(updated_chapters_map) do
            if H.is_num(ch_idx) and not existing_entries[M.getChapterEntryPath(ch_idx)] then
                return false, "skeleton_structure_mismatch: appended target entry missing"
            end
        end
    end

    local updates = {}
    local resources = {}
    for ch_idx, raw_content in pairs(updated_chapters_map) do
        local ch_path = M.getChapterEntryPath(ch_idx)
        local ch_title = (options.toc and options.toc[ch_idx + 1] and options.toc[ch_idx + 1].title) or string.format("第%d章", ch_idx + 1)
        local xhtml, res = M.resolveChapterContent(ch_idx, ch_title, raw_content, book_cache_id)
        updates[ch_path] = xhtml
        if res then
            for k, v in pairs(res) do resources[k] = v end
        end
    end

    if not structure_appended and not options.force_rewrite then
        local unchanged = true
        for path in pairs(resources) do
            if not existing_entries[path] then unchanged = false; break end
        end
        if unchanged then
            local reader = ZipUtil.Reader:new()
            if reader and reader._mode == "archiver" and reader:open(epub_path) then
                for path, content in pairs(updates) do
                    local ok_read, old_content = pcall(reader.extractToMemory, reader, path)
                    if not ok_read or old_content ~= content then
                        unchanged = false
                        break
                    end
                end
                reader:close()
                if unchanged then return true, nil, false end
            end
        end
    end

    local ok_review, err_review = add_review_fallback(epub_path, updates)
    if not ok_review then return false, err_review end

    local need_rewrite = options.force_rewrite
    if not need_rewrite then
        local attr = lfs.attributes(epub_path)
        local fsize = attr and attr.size or 0
        if patcher.waste_bytes > math.max(PATCH_WASTE_REWRITE_THRESHOLD, fsize * PATCH_WASTE_REWRITE_RATIO) then
            need_rewrite = true
        end
    end
    if not need_rewrite then
        if next(resources) then
            for k, v in pairs(resources) do
                if not existing_entries[k] then updates[k] = v end
            end
        end
        local ok_c, err_c, intact = patcher:commit(updates)
        if ok_c then return true end
        if not intact then
            return false, "incremental patch failed: " .. tostring(err_c)
        end
        logger.warn("SkeletonEpub.updateChapters incremental patch unavailable, falling back to rewrite: " .. tostring(err_c))
    end

    for k, v in pairs(resources) do updates[k] = v end
    local tmp_output_path = epub_path .. ".update_tmp"
    if util.fileExists(tmp_output_path) then
        pcall(util.removeFile, tmp_output_path)
    end
    local ok_rw, err_rw = ZipUtil.rewriteWithUpdates(epub_path, tmp_output_path, updates)
    if not ok_rw then
        return false, "failed to rewrite epub: " .. tostring(err_rw)
    end
    local ok_rename, err_rename = os.rename(tmp_output_path, epub_path)
    if not ok_rename then
        return false, "failed to rename rewritten epub: " .. tostring(err_rename)
    end
    return true
end

function M.appendChapters(epub_path, new_toc, new_contents, book_cache_id)
    if not (util.fileExists(epub_path) and H.is_tbl(new_toc) and #new_toc > 0) then
        return false, "invalid parameters"
    end
    new_contents = new_contents or {}

    local reader = ZipUtil.Reader:new()
    local ok_open, err_open = reader:open(epub_path)
    if not ok_open then
        return false, "failed to open epub reader: " .. tostring(err_open)
    end
    local opf_data = reader:extractToMemory("OEBPS/content.opf")
    local ncx_data = reader:extractToMemory("OEBPS/toc.ncx")
    reader:close()
    if not (opf_data and ncx_data) then
        return false, "invalid skeleton epub structure (missing opf/ncx)"
    end

    local new_manifest_items = {}
    local new_spine_items = {}
    local new_ncx_items = {}
    local updates = {}
    local resources = {}

    local max_play_order = 0
    for order in ncx_data:gmatch('playOrder="(%d+)"') do
        local n = tonumber(order)
        if n and n > max_play_order then max_play_order = n end
    end

    for _, ch in ipairs(new_toc) do
        local ch_idx = ch.index
        if ch_idx then
            max_play_order = max_play_order + 1
            local ch_id = string.format("ch_%d", ch_idx)
            local ch_file = string.format("Text/chapter_%d.xhtml", ch_idx)
            local ch_entry_path = "OEBPS/" .. ch_file
            local ch_title = ch.title or string.format("第%d章", ch_idx + 1)
            local ch_title_escaped = EpubHelper.escape_xml(ch_title)

            table.insert(new_manifest_items, string.format('    <item id="%s" href="%s" media-type="application/xhtml+xml"/>', ch_id, ch_file))
            table.insert(new_spine_items, string.format('    <itemref idref="%s"/>', ch_id))
            table.insert(new_ncx_items, string.format([[    <navPoint id="nav_%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s#ch_%d"/>
    </navPoint>]], ch_idx, max_play_order, ch_title_escaped, ch_file, ch_idx))

            local raw = new_contents[ch_idx]
            if raw and raw ~= "" and not M.isPlaceholderHtml(raw) then
                local xhtml, res = M.resolveChapterContent(ch_idx, ch_title, raw, book_cache_id)
                updates[ch_entry_path] = xhtml
                if res then
                    for k, v in pairs(res) do resources[k] = v end
                end
            else
                updates[ch_entry_path] = M.formatPlaceholderXhtml(ch_idx, ch_title)
            end
        end
    end

    if #new_manifest_items > 0 then
        local manifest_str = table.concat(new_manifest_items, "\n") .. "\n  </manifest>"
        opf_data = opf_data:gsub("</manifest>", function() return manifest_str end, 1)

        local spine_str = table.concat(new_spine_items, "\n") .. "\n  </spine>"
        opf_data = opf_data:gsub("</spine>", function() return spine_str end, 1)

        updates["OEBPS/content.opf"] = opf_data
    end

    if #new_ncx_items > 0 then
        local ncx_str = table.concat(new_ncx_items, "\n") .. "\n  </navMap>"
        ncx_data = ncx_data:gsub("</navMap>", function() return ncx_str end, 1)
        updates["OEBPS/toc.ncx"] = ncx_data
    end

    local ok_review, err_review = add_review_fallback(epub_path, updates)
    if not ok_review then return false, err_review end

    local patcher = ZipUtil.Patcher:new()
    local ok_p, err_p = patcher:open(epub_path)
    if ok_p then
        local need_rewrite = false
        local attr = lfs.attributes(epub_path)
        local fsize = attr and attr.size or 0
        if patcher.waste_bytes > math.max(PATCH_WASTE_REWRITE_THRESHOLD, fsize * PATCH_WASTE_REWRITE_RATIO) then
            need_rewrite = true
        end
        if not need_rewrite then
            if next(resources) then
                local existing = {}
                for _, e in ipairs(patcher.entries) do existing[e.path] = true end
                for k, v in pairs(resources) do
                    if not existing[k] then updates[k] = v end
                end
            end
            local ok_c, err_c, intact = patcher:commit(updates)
            if ok_c then return true end
            if not intact then
                return false, "incremental patch failed: " .. tostring(err_c)
            end
            logger.warn("SkeletonEpub.appendChapters incremental patch unavailable, falling back to rewrite: " .. tostring(err_c))
        end
    else
        logger.warn("SkeletonEpub.appendChapters patcher open failed, falling back to rewrite: " .. tostring(err_p))
    end

    for k, v in pairs(resources) do updates[k] = v end
    local tmp_output_path = epub_path .. ".append_tmp"
    if util.fileExists(tmp_output_path) then
        pcall(util.removeFile, tmp_output_path)
    end
    local ok_rw, err_rw = ZipUtil.rewriteWithUpdates(epub_path, tmp_output_path, updates)
    if not ok_rw then
        return false, "failed to rewrite appended epub: " .. tostring(err_rw)
    end

    local ok_ren, err_ren = os.rename(tmp_output_path, epub_path)
    if not ok_ren then
        return false, "failed to rename appended epub: " .. tostring(err_ren)
    end

    return true
end

function M.getChapterEntryPath(ch_idx)
    return string.format("OEBPS/Text/chapter_%d.xhtml", ch_idx)
end

function M.parseChapterIndexFromEntryPath(path)
    if type(path) ~= "string" then return nil end
    local idx = path:match("chapter_(%d+)%.xhtml")
    return idx and tonumber(idx)
end

function M.isPlaceholderHtml(html_content)
    if type(html_content) ~= "string" then return false end
    if html_content:find("legado%-placeholder") ~= nil then return true end
    local body_inner = html_content:match("<body[^>]*>(.-)</body>")
    if body_inner then
        local clean = body_inner:gsub("<h[1-6][^>]*>.-</h[1-6]>", ""):gsub("<[^>]+>", ""):gsub("%s+", "")
        if #clean == 0 then
            return true
        end
    end
    return false
end

return M
