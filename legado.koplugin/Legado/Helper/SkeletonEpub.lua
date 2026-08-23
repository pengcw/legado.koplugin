local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")
local ZipUtil = require("Legado.Helper.ZipUtil")
local image_meta = require("Legado.Helper.image_meta")
local logger = require("logger")

local M = {}

local SKELETON_SCHEMA_VERSION = 4
M.SKELETON_SCHEMA_VERSION = SKELETON_SCHEMA_VERSION

-- 增量 patch 垃圾回收阈值：垃圾超过该值时触发全量重写
local PATCH_WASTE_REWRITE_THRESHOLD = 20 * 1024 * 1024 -- 20MB
local PATCH_WASTE_REWRITE_RATIO = 0.5 -- 或超过文件大小 50%

function M.isSupported()
    local ok, writer = pcall(ZipUtil.Writer.new, ZipUtil.Writer)
    return ok and writer ~= nil
end

local DEFAULT_CSS = [[
body { font-family: sans-serif; margin: 5%; line-height: 1.6; text-align: justify; }
h2 { text-align: center; margin-bottom: 1em; }
h2.head { text-align: left; font-weight: bold; font-size: 1.2em; margin: 1em 0 1.5em 0; line-height: 1.4; color: #3f83e8; }
.chapter-sequence-number { font-size: 0.8em; opacity: 0.8; }
p { text-indent: 2em; margin: 0.5em 0; text-align: justify; line-height: 1.6; }
p + p { margin-top: 0.5em; }
span.duokan-dropcaps-two { float: left; font-size: 2.2em; line-height: 1.1; margin-right: 0.1em; margin-bottom: -0.1em; font-weight: bold; }
div.duokan-image-single { text-align: center; margin: 1em auto; }
img.picture-80 { max-width: 85%; margin: 0.5em auto; display: block; }
.legado-placeholder-box {
  margin: 4em auto;
  padding: 1.8em;
  max-width: 85%;
  border: 1px dashed #888;
  border-radius: 10px;
  text-align: center;
  background-color: rgba(128, 128, 128, 0.05);
}
.legado-placeholder-icon {
  font-size: 2em;
  margin-bottom: 0.3em;
}
.legado-placeholder-title {
  font-size: 1.15em;
  font-weight: bold;
  margin-bottom: 0.5em;
}
.legado-placeholder-desc {
  font-size: 0.95em;
  opacity: 0.75;
  margin-bottom: 1.2em;
  line-height: 1.5;
}
.legado-placeholder-hint {
  font-size: 0.85em;
  opacity: 0.65;
  border-top: 1px solid rgba(128, 128, 128, 0.25);
  padding-top: 0.8em;
  margin-top: 0.6em;
  line-height: 1.4;
}
]]

local PLACEHOLDER_TEMPLATE = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title><link rel="stylesheet" href="../Styles/legado.css" type="text/css"/></head>
<body>
  <div class="legado-ch" id="ch_%d" data-chapter-index="%d">
    <h2 class="head">%s</h2>
    <div class="legado-placeholder-box">
      <div class="legado-placeholder-icon">⚡</div>
      <div class="legado-placeholder-title">正在获取本章正文内容</div>
      <div class="legado-placeholder-desc">后台正在连接书源下载中，请稍候…</div>
      <div class="legado-placeholder-hint">💡 提示：如遇空白或加载缓慢，可点击菜单【强制刷新本章】或【切换书源】</div>
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

function M.formatBodyHtml(content)
    if type(content) ~= "string" or content == "" then
        return "<p></p>"
    end
    -- 如果是完整 HTML 文档，提取 body 内部并剥除重复 h2
    local body_inner = content:match("<body[^>]*>(.-)</body>")
    if body_inner then
        content = body_inner:gsub("<h[1-6][^>]*>.-</h[1-6]>", "")
    end

    -- 如果包含 HTML 段落标签则直接返回
    if content:find("<p[ >]") or content:find("<div[ >]") then
        return content
    end

    local paragraphs = {}
    for line in content:gmatch("([^\r\n]+)") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            -- 转义特殊 xml 字符
            trimmed = trimmed:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            table.insert(paragraphs, "<p>" .. trimmed .. "</p>")
        end
    end
    return table.concat(paragraphs, "\n")
end

function M.formatPlaceholderXhtml(ch_idx, title)
    local ch_title = title or string.format("第%d章", ch_idx + 1)
    local ok_epub, EpubHelper = pcall(require, "Legado.EpubHelper")
    local part, subpart
    if ok_epub and EpubHelper and EpubHelper.split_title_advanced then
        part, subpart = EpubHelper.split_title_advanced(ch_title)
    end
    local title_header = ch_title
    if part and part ~= "" and subpart and subpart ~= "" then
        title_header = string.format('<span class="chapter-sequence-number">%s</span><br />%s', part, subpart)
    end
    return string.format(PLACEHOLDER_TEMPLATE, ch_title, ch_idx, ch_idx, title_header)
end

function M.formatChapterXhtml(ch_idx, title, raw_content)
    local ch_title = title or string.format("第%d章", ch_idx + 1)
    local body_html = M.formatBodyHtml(raw_content)
    local ok_epub, EpubHelper = pcall(require, "Legado.EpubHelper")
    local part, subpart
    if ok_epub and EpubHelper and EpubHelper.split_title_advanced then
        part, subpart = EpubHelper.split_title_advanced(ch_title)
    end
    local title_header = ch_title
    if part and part ~= "" and subpart and subpart ~= "" then
        title_header = string.format('<span class="chapter-sequence-number">%s</span><br />%s', part, subpart)
    end
    return string.format(REAL_TEMPLATE, ch_title, ch_idx, ch_idx, title_header, body_html)
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

    -- 1. mimetype (必须首个写入且不压缩 store: true)
    writer:add("mimetype", "application/epub+zip", true)

    -- 2. META-INF/container.xml
    local container_xml = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
    writer:add("META-INF/container.xml", container_xml, true)

    -- 3. CSS 样式
    writer:add("OEBPS/Styles/legado.css", options.custom_css or DEFAULT_CSS, true)

    -- 4. 封面图片与页面处理
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

    local title_escaped = (bookinfo.title or "未知书名"):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local author_escaped = (bookinfo.author or "未知作者"):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local raw_cache_id = (bookinfo.cache_id or "default")
    local book_id_escaped = ("legado-skeleton-book_" .. raw_cache_id):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    local meta_cover_tag = ""
    if cover_bytes then
        local cover_img_entry = string.format("OEBPS/Images/cover.%s", cover_ext)
        writer:add(cover_img_entry, cover_bytes, true)
        table.insert(manifest_buf, string.format('<item id="cover-image" href="Images/cover.%s" media-type="%s"/>', cover_ext, cover_media_type))
        meta_cover_tag = '<meta name="cover" content="cover-image"/>'

        local cover_xhtml = string.format([[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Cover</title><style type="text/css">body { margin: 0; padding: 0; text-align: center; background-color: #ffffff; } div.cover-box { margin: 0 auto; text-align: center; } img.cover-img { max-width: 100%%; max-height: 100vh; display: block; margin: 0 auto; }</style></head>
<body>
  <div class="cover-box"><img class="cover-img" src="../Images/cover.%s" alt="Cover"/></div>
</body>
</html>]], cover_ext)
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

    -- 5. 构造章节 manifest, spine, toc.ncx
    for i, ch in ipairs(toc) do
        local ch_idx = ch.index or (i - 1)
        local ch_id = string.format("ch_%d", ch_idx)
        local ch_file = string.format("Text/chapter_%d.xhtml", ch_idx)
        local ch_title = ch.title or string.format("第%d章", ch_idx + 1)
        local ch_title_escaped = ch_title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

        table.insert(manifest_buf, string.format('<item id="%s" href="%s" media-type="application/xhtml+xml"/>', ch_id, ch_file))
        table.insert(spine_buf, string.format('<itemref idref="%s"/>', ch_id))
        table.insert(ncx_nav_buf, string.format([[
    <navPoint id="nav_%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s"/>
    </navPoint>]], ch_idx, i, ch_title_escaped, ch_file))
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
</package>]], title_escaped, author_escaped, book_id_escaped, book_id_escaped, raw_cache_id:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"),
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

    -- 6. 写入章节内容（已缓存写入正文，其余写入占位）
    for _, ch in ipairs(toc) do
        local ch_idx = ch.index or (ch.chapters_index or 0)
        local ch_file = string.format("OEBPS/Text/chapter_%d.xhtml", ch_idx)
        local ch_title = ch.title or string.format("第%d章", ch_idx + 1)
        local raw_content = chapters_content[ch_idx]

        if raw_content and raw_content ~= "" and not M.isPlaceholderHtml(raw_content) then
            local xhtml = M.formatChapterXhtml(ch_idx, ch_title, raw_content)
            writer:add(ch_file, xhtml, true)
        else
            local xhtml = M.formatPlaceholderXhtml(ch_idx, ch_title)
            writer:add(ch_file, xhtml, true)
        end
    end

    local ok_close, err_close = writer:close()
    if not ok_close then
        return false, "failed to close zip writer: " .. tostring(err_close)
    end

    -- 原子重命名
    local ok_rename, err_rename = os.rename(tmp_output_path, output_path)
    if not ok_rename then
        return false, "failed to rename temp epub to target: " .. tostring(err_rename)
    end

    -- 记录初始章节数与 Schema 版本至 DocSettings
    local DocSettings = require("docsettings")
    local ds = DocSettings:open(output_path)
    if ds then
        ds:saveSetting("virtual_book_schema_version", SKELETON_SCHEMA_VERSION)
        ds:saveSetting("virtual_book_chapters_count", #toc)
        ds:saveSetting("book_cache_id", raw_cache_id)
        if ds.flush then ds:flush() end
    end

    return true, output_path
end

function M.updateChapters(epub_path, updated_chapters_map, options)
    options = options or {}
    if not util.fileExists(epub_path) then
        return false, "epub file does not exist"
    end
    if not updated_chapters_map or not next(updated_chapters_map) then
        return true -- 无需更新
    end

    -- 构造条目路径 -> 新内容（仅目标章节）
    local updates = {}
    for ch_idx, raw_content in pairs(updated_chapters_map) do
        local ch_path = M.getChapterEntryPath(ch_idx)
        local ch_title = (options.toc and options.toc[ch_idx + 1] and options.toc[ch_idx + 1].title) or string.format("第%d章", ch_idx + 1)
        updates[ch_path] = M.formatChapterXhtml(ch_idx, ch_title, raw_content)
    end

    -- 优先增量 patch：只追加写入目标章节 + 重写中央目录，不动其他条目
    local patcher = ZipUtil.Patcher:new()
    local ok_open, err_open = patcher:open(epub_path)
    if ok_open then
        local need_rewrite = options.force_rewrite
        if not need_rewrite then
            local attr = lfs.attributes(epub_path)
            local fsize = attr and attr.size or 0
            if patcher.waste_bytes > math.max(PATCH_WASTE_REWRITE_THRESHOLD, fsize * PATCH_WASTE_REWRITE_RATIO) then
                need_rewrite = true
            end
        end
        if not need_rewrite then
            local ok_c, err_c, intact = patcher:commit(updates)
            if ok_c then return true end
            if not intact then
                -- 写入阶段失败，文件可能已损坏，不再回退重写（避免读取已损坏的源）
                return false, "incremental patch failed: " .. tostring(err_c)
            end
            -- 前置失败（如无 truncate 的环境）：文件未动，回退全量重写
            logger.warn("SkeletonEpub.updateChapters incremental patch unavailable, falling back to rewrite: " .. tostring(err_c))
        end
    else
        logger.warn("SkeletonEpub.updateChapters patcher open failed, falling back to rewrite: " .. tostring(err_open))
    end

    -- 全量流式重写（垃圾回收 / patch 不可用）
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

function M.appendChapters(epub_path, new_toc, new_contents)
    if not (util.fileExists(epub_path) and H.is_tbl(new_toc) and #new_toc > 0) then
        return false, "invalid parameters"
    end
    new_contents = new_contents or {}

    -- 只读取 opf/ncx 两个条目（几十 KB），不再全量读入
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
            local ch_title_escaped = ch_title:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

            table.insert(new_manifest_items, string.format('    <item id="%s" href="%s" media-type="application/xhtml+xml"/>', ch_id, ch_file))
            table.insert(new_spine_items, string.format('    <itemref idref="%s"/>', ch_id))
            table.insert(new_ncx_items, string.format([[    <navPoint id="nav_%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s"/>
    </navPoint>]], ch_idx, max_play_order, ch_title_escaped, ch_file))

            local raw = new_contents[ch_idx]
            if raw and raw ~= "" and not M.isPlaceholderHtml(raw) then
                updates[ch_entry_path] = M.formatChapterXhtml(ch_idx, ch_title, raw)
            else
                updates[ch_entry_path] = M.formatPlaceholderXhtml(ch_idx, ch_title)
            end
        end
    end

    if #new_manifest_items > 0 then
        local manifest_str = table.concat(new_manifest_items, "\n") .. "\n  </manifest>"
        -- 用函数替换避免替换串中的 %（章节标题可能含 %）被 gsub 当转义符
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

    -- 优先增量 patch（新增章节 + 替换 opf/ncx）
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
            local ok_c, err_c, intact = patcher:commit(updates)
            if ok_c then return true end
            if not intact then
                -- 写入阶段失败，文件可能已损坏，不再回退重写（避免读取已损坏的源）
                return false, "incremental patch failed: " .. tostring(err_c)
            end
            -- 前置失败（如无 truncate 的环境）：文件未动，回退全量重写
            logger.warn("SkeletonEpub.appendChapters incremental patch unavailable, falling back to rewrite: " .. tostring(err_c))
        end
    else
        logger.warn("SkeletonEpub.appendChapters patcher open failed, falling back to rewrite: " .. tostring(err_p))
    end

    -- 全量流式重写
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
