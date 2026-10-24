local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local ffiUtil = require("ffi/util")
local ImageUtil = require("Legado.Helper.ImageUtil")
local socket_url = require("socket.url")
local utf8proc = require("Legado.Helper.utf8proc")
local httpReq = require("Legado.Helper.Http")
local EpubHelper = require("Legado/EpubHelper")
local ContentActions = require("Legado.Helper.ContentActions")

local M = {
    config = {
        enable_dropcaps = true,
        preserve_blank = true,
    }
}

local PATTERNS = {
    IMG_TAG            = "<[iI][mM][gG][^>]*>",
    IMG_SRC            = "(<[iI][mM][gG].-[sS][rR][cC]%s*=%s*)(['\"])(.-)%2([^>]*>)",
    IMAGE_XLINK        = '(<image.-href%s*=%s*)(["\'])(.-)%2([^>]*>)',
    LINK_TAG           = '(<link.-href%s*=%s*)(["\'])(.-)%2([^>]*>)',
    SCRIPT_TAG_1       = "<script[^>]*>(.-\n?)</script>",
    SCRIPT_TAG_2       = "<script[^>]*>[\x00-\xFF]-</script>",
    CSS_URL            = "url%s*%((%s*['\"]?)(.-)(['\"]?%s*)%)",
    FULLWIDTH_SPACE    = "\u{3000}",
}

function M.plain_text_replace(text, pattern, replacement, count)
    text = tostring(text or "")
    pattern = tostring(pattern or "")
    replacement = tostring(replacement or "")

    if pattern == "" then return text end
    local escaped_pattern = pattern:gsub("([%%().%+-*?[%]^$])", "%%%1")
    local safe_replacement = replacement:gsub("%%", "%%%%")
    return text:gsub(escaped_pattern, safe_replacement, count)
end

function M.split_paragraphs(text)
    if type(text) ~= "string" or text == "" then return {} end

    text = text:gsub("\r\n?", "\n"):gsub("\n+", function(s)
        return (#s >= 2) and "\n\n" or s
    end)

    local indentChinese = "\u{0020}\u{0020}\u{3000}"
    local indentEnglish = "\u{0020}\u{0020}"
    local paragraphs = {}
    local p_count = 0
    local allow_split = true
    local buffer = ""
    local prefix = nil
    local lines = {}
    local l_count = 0

    for raw_line in util.gsplit(text, "\n", false, true) do
        l_count = l_count + 1
        lines[l_count] = utf8proc.utf8_trim(raw_line)
    end

    local function isPunctuation(char)
        if not char then return false end
        local punctuationSet = {
            ["\u{0021}"]=true, ["\u{002C}"]=true, ["\u{002E}"]=true, ["\u{003A}"]=true, ["\u{003B}"]=true,
            ["\u{003F}"]=true, ["\u{3001}"]=true, ["\u{3002}"]=true, ["\u{FF0C}"]=true, ["\u{FF0E}"]=true,
            ["\u{FF1A}"]=true, ["\u{FF1B}"]=true, ["\u{FF1F}"]=true, ["\u{2026}"]=true, ["\u{00B7}"]=true,
            ["\u{2022}"]=true, ["\u{FF5E}"]=true
        }
        if punctuationSet[char] then return true end
        local code = ffiUtil.utf8charcode(char)
        if not code then return false end
        return (code >= 0x2000 and code <= 0x206F) or (code >= 0x3000 and code <= 0x303F) or (code >= 0xFF00 and code <= 0xFFEF)
    end

    for i, line in ipairs(lines) do
        if buffer ~= "" then
            line = buffer .. (line or "")
            buffer = ""
        end

        if line == "" then
            p_count = p_count + 1
            paragraphs[p_count] = line
        else
            if not prefix then
                prefix = util.hasCJKChar(line:sub(1, 9)) and indentChinese or indentEnglish
            end

            local word_end = line:match(util.UTF8_CHAR_PATTERN .. "$")
            local next_word_start = (lines[i + 1] or ""):match(util.UTF8_CHAR_PATTERN)
            local word_end_isPunctuation = isPunctuation(word_end)

            if prefix == indentChinese and (not word_end_isPunctuation or utf8proc.count(line) < 3) then
                allow_split = false
            else
                allow_split = util.isSplittable and util.isSplittable(word_end, next_word_start, word_end) or true
            end

            if not allow_split and i < #lines then
                if prefix == indentEnglish and not word_end_isPunctuation and not isPunctuation(next_word_start) then
                    line = line .. "\u{0020}"
                end
                buffer = buffer .. line
            else
                p_count = p_count + 1
                paragraphs[p_count] = prefix .. line
            end
        end
    end
    return paragraphs
end

function M.classify_content(text)
    if type(text) ~= "string" or text == "" then
        return false, false
    end

    local has_img = false
    local has_other = false

    local clean_text = text:gsub(PATTERNS.IMG_TAG, "")
    if clean_text:gsub(PATTERNS.FULLWIDTH_SPACE, ""):find("%S") then
        has_other = true
    end

    if text:find(PATTERNS.IMG_TAG) then
        has_img = true
    end

    return has_img, has_other
end

function M.has_img_tag(text)
    local has_img, _ = M.classify_content(text)
    return has_img
end

function M.has_other_content(text)
    local _, has_other = M.classify_content(text)
    return has_other
end

function M.get_content_type(txt, first_line)
    if type(txt) ~= "string" or txt == "" then return 1 end

    first_line = not first_line and (string.match(txt, "([^\n]*)\n?") or txt):lower() or first_line:lower()

    if string.match(first_line, "%.x?html$") then return 4 end

    local has_img, is_other = M.classify_content(txt)
    if string.find(first_line, "<img", 1, true) or has_img then
        return is_other and 3 or 2
    end

    return 1
end

function M.replace_css_urls(css_text, replace_fn)
    css_text = tostring(css_text or "")
    return (css_text:gsub(PATTERNS.CSS_URL, function(prefix, old_path, suffix)
        if type(old_path) ~= "string" or old_path == "" or old_path:lower():find("^data:") then return end
        local ok, new_path = pcall(replace_fn, old_path)
        if not ok or type(new_path) ~= "string" or new_path == "" then
            return "url(" .. prefix .. old_path .. suffix .. ")"
        end
        return "url(" .. prefix .. new_path .. suffix .. ")"
    end))
end

local function is_css_url(address)
    local path = (socket_url.parse(address) or {}).path or ""
    return path:lower():match("%.css$") ~= nil
end

local function book_chapter_resources(book_cache_id, filename, res_data, overwrite)
    if not book_cache_id then return end

    local catalogue = string.format("%s/resources", Env.getBookCachePath(book_cache_id))
    local relpath, filepath
    if H.is_str(filename) then
        relpath = string.format("resources/%s", filename)
        filepath = string.format("%s/%s", catalogue, filename)
    end

    if res_data and (overwrite or not util.fileExists(filepath or "")) then
        FS.checkAndCreateFolder(catalogue)
        util.writeToFile(res_data, filepath, true)
    end

    return relpath, filepath, catalogue
end

function M.process_link(book_cache_id, resources_src, base_url, is_proxy, opts, callback, css_state)
    if not (H.is_str(book_cache_id) and H.is_str(resources_src)) then return nil end

    local processed_src = util.trim(resources_src)
    if processed_src == "" then return nil end

    local first = processed_src:sub(1, 1)
    if processed_src:find("^data:") or processed_src:find("^res:") or processed_src:find("^tel:") or processed_src:find("^javascript:") or first == "#" or first == "?" then
        return nil
    end

    local function normalize_url(src, baseUrl, isProxy)
        if not H.is_str(baseUrl) then baseUrl = "" end
        if src:sub(1, 2) == "//" then
            return (baseUrl:match("^(https?:)") or "https:") .. src
        elseif src:sub(1, 1) == "/" or src:sub(1, 2) == "./" or src:sub(1, 3) == "../" then
            return socket_url.absolute(baseUrl, src)
        elseif isProxy == true and opts and opts.getProxyImageUrl then
            return opts.getProxyImageUrl(baseUrl, src)
        elseif not src:find("^%a+://") then
            return socket_url.absolute(baseUrl, src)
        end
        return src
    end

    processed_src = normalize_url(processed_src, base_url, is_proxy)
    if not (H.is_str(processed_src) and processed_src:find("^(https?:)")) then return nil end
    css_state = css_state or { active = {}, depth = 0 }
    if css_state.active[processed_src] then return nil end

    local resources_id = H.md5(processed_src)
    local ext = ImageUtil.get_url_extension(processed_src)
    if ext == "" and is_css_url(processed_src) then ext = "css" end

    if ext == "" then
        ext = ImageUtil.get_url_extension(resources_src:gsub("[#?].*", ""))
        if ext == "" then ext = ImageUtil.get_url_extension((resources_src:match("^(.-),") or resources_src)) end
    end

    local resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id
    local resources_relpath, resources_filepath = book_chapter_resources(book_cache_id, resources_filename)

    if ext ~= "" and resources_filepath and util.fileExists(resources_filepath) then
        return resources_relpath
    end
    if ext == "" then
        local css_relpath, css_path = book_chapter_resources(book_cache_id, resources_id .. ".css")
        if css_path and util.fileExists(css_path) then return css_relpath end
    end

    local status, err = httpReq({ url = processed_src, timeout = 60 }, true)
    if status and H.is_tbl(err) and err["data"] then
        ext = (not ext or ext == "") and err["ext"] or ext
        resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id

        if ext == "css" then
            if css_state.depth >= 2 then return nil end
            css_state.active[processed_src] = true
            css_state.depth = css_state.depth + 1
            err["data"] = M.replace_css_urls(err["data"], function(url)
                if url:sub(1, 1) == "#" then return nil end
                local absolute = socket_url.absolute(processed_src, url)
                if is_css_url(absolute) and (callback or css_state.active[absolute]) then
                    return absolute
                end
                local relpath = M.process_link(book_cache_id, url, processed_src, nil, opts, true, css_state)
                return relpath and relpath:match("^resources/(.+)$") or absolute
            end)
            css_state.depth = css_state.depth - 1
            css_state.active[processed_src] = nil
        end

        return book_chapter_resources(book_cache_id, resources_filename, err["data"])
    end
end

local DROPCAPS_SKIP = {
    ["“"]=true, ["”"]=true, ["‘"]=true, ["’"]=true, ["《"]=true, ["》"]=true,
    ["（"]=true, ["）"]=true, ["「"]=true, ["」"]=true, ["【"]=true, ["】"]=true,
    ["("]=true, [")"]=true, ['"']=true, ["'"]=true, ["<"]=true, [">"]=true,
    ["["]=true, ["]"]=true, ["—"]=true, ["…"]=true
}

local function get_dropcaps_info(line)
    if not line or line == "" then return nil, nil, nil end
    local leading_punc = {}
    local p_count = 0
    local target_char = nil
    local rest_line = nil

    local pos = 1
    local line_len = #line

    while pos <= line_len do
        local char = line:match(util.UTF8_CHAR_PATTERN, pos)
        if not char then break end

        if DROPCAPS_SKIP[char] then
            p_count = p_count + 1
            leading_punc[p_count] = char
            pos = pos + #char
        else
            target_char = char
            rest_line = line:sub(pos + #char)
            break
        end
    end

    if target_char then
        return table.concat(leading_punc), target_char, rest_line
    end
    return nil, nil, nil
end

local function append_text_html(lines, content, title, state, escape_text, blank_tag)
    content = content or ""
    title = title or ""
    state = state or { dropcaps = false }
    blank_tag = blank_tag or "<br>"

    local function format_text(text)
        if escape_text then return EpubHelper.escape_xml(text) end
        return text
    end

    for raw_line in util.gsplit(content, "\n", false, true) do
        local line = utf8proc.utf8_trim(raw_line)
        local el_tags
        local lower_line = line:lower()
        local allow_dropcaps = M.config and M.config.enable_dropcaps
        local is_title_line = false

        if allow_dropcaps and not state.dropcaps and line ~= ""
                and not lower_line:find("<img", 1, true)
                and not (state.preserve_inline and state.preserve_inline(line)) then
            if utf8proc.count(title) > 3 and string.find(line, title, 1, true) == 1 then
                line = utf8proc.utf8_trim(M.plain_text_replace(line, title, "", 1))
                if line == "" then
                    is_title_line = true
                end
            end

            if not is_title_line then
                local punc_prefix, rep_text, remaining_text = get_dropcaps_info(line)
                if rep_text and rep_text ~= "" then
                    punc_prefix = punc_prefix or ""
                    remaining_text = remaining_text or ""
                    el_tags = string.format(
                        '<p style="text-indent: 0em;">%s<span class="duokan-dropcaps-two">%s</span>%s</p>',
                        format_text(punc_prefix), format_text(rep_text), format_text(remaining_text)
                    )
                    state.dropcaps = true
                else
                    el_tags = string.format('<p>%s</p>', format_text(line))
                end
            end
        else
            el_tags = (line ~= "") and string.format('<p>%s</p>', format_text(line)) or blank_tag
        end

        if not is_title_line then
            lines[#lines + 1] = el_tags
        end
    end
end

function M.text_to_html(book_cache_id, content, title)
    local lines = {}
    content = content or ""
    title = title or ""
    append_text_html(lines, content, title, { dropcaps = false }, false, "<br>")

    return EpubHelper.addchapterT(title, table.concat(lines))
end

local function find_mixed_img_tag(content, from_pos)
    local search_pos = math.max(from_pos or 1, 1)
    local content_len = #content
    while search_pos <= content_len do
        local tag_start = content:find("<", search_pos, true)
        if not tag_start then
            return nil, nil
        end
        local tag_name = content:sub(tag_start + 1, tag_start + 3)
        local boundary = content:sub(tag_start + 4, tag_start + 4)
        if tag_name:lower() == "img"
            and (boundary == ""
                or boundary == "/"
                or boundary == ">"
                or boundary:match("%s"))
        then
            local quote
            local pos = tag_start + 4
            while pos <= content_len do
                local char = content:sub(pos, pos)
                if quote then
                    if char == quote then
                        quote = nil
                    end
                elseif char == "'" or char == '"' then
                    quote = char
                elseif char == ">" then
                    return tag_start, pos
                elseif char == "<" then
                    search_pos = pos
                    break
                end
                pos = pos + 1
            end
            if pos > content_len then
                search_pos = tag_start + 1
            end
        else
            search_pos = tag_start + 1
        end
    end
    return nil, nil
end

local function format_mixed_image_tag(tag, book_cache_id, base_url, opts, actions)
    local attrs = {}
    local ordered = {}
    for k, q, v in tag:gmatch('([%w_:%-]+)%s*=%s*(["\'])(.-)%2') do
        local lk = k:lower()
        if not attrs[lk] then
            ordered[#ordered + 1] = lk
            attrs[lk] = { val = v, quote = q }
        end
    end
    for k, v in tag:gmatch('([%w_:%-]+)%s*=%s*([^%s"\'=<>`]+)') do
        local lk = k:lower()
        if not attrs[lk] then
            ordered[#ordered + 1] = lk
            attrs[lk] = { val = v, quote = '"' }
        end
    end
    local image_action = actions and ContentActions.prepare_image(attrs, actions)
    local target = attrs.src and utf8proc.utf8_trim(attrs.src.val)
    if target and target ~= "" then
        local relpath = M.process_link(book_cache_id, target, base_url, true, opts)
        attrs.src.val = relpath or target
    end
    if attrs["class"] then
        local cls = attrs["class"].val or ""
        if cls == "" then
            attrs["class"].val = "picture-80"
        elseif not (" " .. cls .. " "):find(" picture-80 ", 1, true) then
            attrs["class"].val = cls .. " picture-80"
        end
    else
        ordered[#ordered + 1] = "class"
        attrs["class"] = { val = "picture-80", quote = '"' }
    end
    if not attrs.alt then
        ordered[#ordered + 1] = "alt"
        attrs.alt = { val = "", quote = '"' }
    end
    local buf = { "<img" }
    for _, k in ipairs(ordered) do
        local item = attrs[k]
        if item and item.val ~= nil then
            local q = item.quote or '"'
            local v = item.val
            local escaped_v = EpubHelper.escape_xml_attr(v, q)
            buf[#buf + 1] = string.format(
                ' %s=%s%s%s',
                k, q, escaped_v, q
            )
        end
    end
    buf[#buf + 1] = " />"
    local image = table.concat(buf)
    if image_action then image = ContentActions.wrap(image, image_action) end
    return '<div class="duokan-image-single">' .. image .. "</div>"
end

M._find_mixed_img_tag = find_mixed_img_tag
M._format_mixed_image_tag = format_mixed_image_tag

local function skip_one_line_break(content, pos)
    local first = content:sub(pos, pos)
    if first == "\r" then
        if content:sub(pos + 1, pos + 1) == "\n" then return pos + 2 end
        return pos + 1
    elseif first == "\n" then
        return pos + 1
    end
    return pos
end

function M.mixed_to_html(book_cache_id, content, title, base_url, opts, actions)
    content = content or ""
    title = title or ""
    opts = type(opts) == "table" and opts or {}
    if actions == nil then
        content, actions = ContentActions.begin(content, opts.review_context, opts.content_normalized)
    end

    local blocks = {}
    local text_state = { dropcaps = false, preserve_inline = actions and ContentActions.has_placeholder }
    local cursor = 1
    local previous_was_image = false

    while cursor <= #content do
        local img_start, img_end = find_mixed_img_tag(content, cursor)
        local text_fragment = img_start and content:sub(cursor, img_start - 1) or content:sub(cursor)
        local only_whitespace = text_fragment == "" or text_fragment:match("^%s*$") ~= nil

        if not (previous_was_image and only_whitespace) then
            append_text_html(blocks, text_fragment, title, text_state, true, "<br />")
        end
        if not img_start then break end

        blocks[#blocks + 1] = format_mixed_image_tag(
            content:sub(img_start, img_end), book_cache_id, base_url, opts, actions
        )
        previous_was_image = true
        cursor = skip_one_line_break(content, img_end + 1)
    end

    local html = EpubHelper.addchapterT(title, table.concat(blocks, "\n"))
    if actions then html = ContentActions.finish(html, actions) end
    return html, actions
end

local htmlparser
function M.analyzing(chapter, content, filePath, opts)
    opts = opts or {}
    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapter_title = chapter.title or ''
    content = H.is_str(content) and content or tostring(content)
    local actions
    content, actions = ContentActions.begin(content, chapter, opts.content_normalized)

    local first_line = string.match(content, "([^\n]*)\n?") or content
    local page_type = M.get_content_type(content, first_line)
    if actions and (actions.review_nodes or actions.review_actions) then page_type = 3 end

    if page_type == 2 then
        local img_sources = opts.getPorxyPicUrls(bookUrl, content)
        if H.is_tbl(img_sources) and #img_sources > 0 then
            if #img_sources == 1 then
                local res_url = img_sources[1]
                local data, ext = ImageUtil.download_image(res_url, { timeout = 60 })
                if not data then error('单图下载失败') end
                if not ext or ext == "" then ext = ImageUtil.get_url_extension(res_url) or "png" end
                return { kind = "file", chapter = chapter, filePath = string.format("%s.%s", filePath, ext), data = data }
            else
                filePath = filePath .. '.cbz'
                return { kind = "cbz", chapter = chapter, filePath = filePath, img_sources = img_sources }
            end
        else
            error('生成图片列表失败')
        end

    elseif page_type == 4 then
        local html_url = opts.getProxyEpubUrl(bookUrl, first_line)
        if not html_url or html_url == '' then error('转换失败') end

        local status, err = httpReq({ url = html_url, timeout = 60 }, true)
        if not status or not (H.is_tbl(err) and err["data"]) then error('XHTML 请求错误/数据为空') end

        local ext, original_name = ImageUtil.get_url_extension(first_line)
        ext = (not ext or ext == "") and err['ext'] or ext
        content = err['data']
        filePath = string.format("%s.%s", filePath, ext or "")

        if H.is_str(original_name) and original_name ~= "" and original_name:find("%.") then
            local dir_path = util.splitFilePathName(filePath)
            if H.is_str(dir_path) then filePath = FS.joinPath(dir_path, original_name) end
        end

        if not htmlparser then htmlparser = require("htmlparser") end
        local success, root = pcall(htmlparser.parse, content, 5000)

        if success and root and root("body")[1] then
            local body = root("body")[1]
            for _, el in ipairs(root("script")) do
                local el_text = el and el:gettext()
                if el_text then content = M.plain_text_replace(content, el_text, "") end
            end
            for _, el in ipairs(root("head > link[href]")) do
                if el and el.attributes and el.attributes["href"] then
                    local relpath = M.process_link(book_cache_id, el.attributes["href"], html_url, nil, opts)
                    local el_text = el:gettext()
                    if relpath and el_text then
                        local replace_text = M.plain_text_replace(el_text, el.attributes["href"], relpath)
                        content = M.plain_text_replace(content, el_text, replace_text)
                    end
                end
            end
            for _, el in ipairs(body:select("img[src]")) do
                if el and el.attributes and el.attributes["src"] then
                    local relpath = M.process_link(book_cache_id, el.attributes["src"], html_url, nil, opts)
                    local el_text = el:gettext()
                    if relpath and el_text then
                        local replace_text = M.plain_text_replace(el_text, el.attributes["src"], relpath)
                        content = M.plain_text_replace(content, el_text, replace_text)
                    end
                end
            end
            for _, el in ipairs(body:select("svg")) do
                local el_text = el and el:gettext()
                if el_text then
                    for open, r2, path, _ in el_text:gmatch(PATTERNS.IMAGE_XLINK) do
                        if open and open ~= "" then
                            open = open .. (r2 or "")
                            local relpath = M.process_link(book_cache_id, path, html_url, nil, opts)
                            if relpath then
                                local replace_text = M.plain_text_replace(el_text, open .. path, open .. relpath)
                                content = M.plain_text_replace(content, el_text, replace_text)
                            end
                        end
                    end
                end
            end

            content = content:gsub(PATTERNS.SCRIPT_TAG_1, ""):gsub(PATTERNS.SCRIPT_TAG_2, "")
            :gsub(PATTERNS.LINK_TAG, function(r1, r2, r3, r4)
                local open, path, close = r1, r3, r4
                if not (open and open ~= "" and path and path ~= "" and not path:find("^resources/")) then return end
                local relpath = M.process_link(book_cache_id, path, html_url, nil, opts)
                if relpath then return table.concat({open .. (r2 or ""), relpath, (r2 or "") .. (close or "")}) end
            end)
            :gsub(PATTERNS.IMAGE_XLINK, function(r1, r2, r3, r4)
                local open, path, close = r1, r3, r4
                if open and open ~= "" and path and not path:find("^resources/") then
                    local relpath = M.process_link(book_cache_id, path, html_url, nil, opts)
                    if relpath then return table.concat({open .. (r2 or ""), relpath, (r2 or "") .. (close or "")}) end
                end
            end)
            :gsub(PATTERNS.IMG_SRC, function(r1, r2, r3, r4)
                if r1 == "" or not r3 or r3:find("^resources/") then return end
                local relpath = M.process_link(book_cache_id, r3, html_url, nil, opts)
                if relpath then return table.concat({r1, r2, relpath, r2, r4}) end
            end)
        end
        return { kind = "file", chapter = chapter, filePath = filePath, data = content }

    elseif page_type == 3 then
        filePath = filePath .. '.html'
        return {
            kind = "file",
            chapter = chapter,
            filePath = filePath,
            data = M.mixed_to_html(book_cache_id, content, chapter_title, bookUrl, opts, actions or false),
        }

    else
        if opts.is_txt then
            filePath = filePath .. '.txt'
            local paragraphs = M.split_paragraphs(content)
            if #paragraphs == 0 then chapter.content_is_nil = true end

            content = table.concat(paragraphs, "\n")
            if not string.find(paragraphs[1] or "", chapter_title, 1, true) then
                content = table.concat({"\t\t", tostring(chapter_title), "\n\n", content})
            end
        else
            filePath = filePath .. '.html'
            content = M.text_to_html(book_cache_id, content, chapter_title)
        end
        return { kind = "file", chapter = chapter, filePath = filePath, data = content }
    end
end

return M
