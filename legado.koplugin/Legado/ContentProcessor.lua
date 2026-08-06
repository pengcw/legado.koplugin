local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local logger = require("logger")
local dbg = require("dbg")
local ffiUtil = require("ffi/util")
local ImageUtil = require("Legado.Helper.ImageUtil")
local socket_url = require("socket.url")
local ffi = require("ffi")

local M = {
    config = {
        enable_dropcaps = true,      -- 控制是否启用首字下沉排版
        preserve_blank = true,       -- 控制是否保留空行
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

local libutf8proc
local libutf8proc_available = false

-- 在模块加载阶段预初始化 utf8proc，避免首次打开书籍延迟/卡顿
do
    pcall(function()
        if ffi.loadlib then
            libutf8proc = ffi.loadlib("utf8proc", "3")
        else
            if ffi.os == "Windows" then
                libutf8proc = ffi.load("libs/libutf8proc.dll")
            elseif ffi.os == "OSX" then
                libutf8proc = ffi.load("libs/libutf8proc.dylib")
            else
                libutf8proc = ffi.load("libs/libutf8proc.so.2")
            end
        end

        if libutf8proc then
            ffi.cdef [[
typedef int32_t utf8proc_int32_t;
typedef uint8_t utf8proc_uint8_t;
typedef ssize_t utf8proc_ssize_t;
utf8proc_ssize_t utf8proc_iterate(const utf8proc_uint8_t *, utf8proc_ssize_t, utf8proc_int32_t *);
]]
            libutf8proc_available = true
        end
    end)
end

-- 纯 Lua UTF-8 解码迭代器（无 C 库或加载失败时的后备方案）
local function native_utf8_chars(str, reverse)
    local str_len = #str
    local pos = reverse and (str_len + 1) or 0

    return function()
        while true do
            pos = reverse and (pos - 1) or (pos + 1)
            if (reverse and pos < 1) or (not reverse and pos > str_len) then
                return nil
            end

            local byte = str:byte(pos)
            if not byte then return nil end

            local bytes = 1
            local codepoint = byte

            if byte < 0x80 then
                bytes = 1
                codepoint = byte
            elseif byte >= 0xC0 and byte <= 0xDF then
                bytes = 2
                if pos + 1 <= str_len then
                    local b2 = str:byte(pos + 1)
                    if b2 and b2 >= 0x80 and b2 <= 0xBF then
                        codepoint = (byte - 0xC0) * 64 + (b2 - 0x80)
                    end
                end
            elseif byte >= 0xE0 and byte <= 0xEF then
                bytes = 3
                if pos + 2 <= str_len then
                    local b2, b3 = str:byte(pos + 1), str:byte(pos + 2)
                    if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                        codepoint = (byte - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
                    end
                end
            elseif byte >= 0xF0 and byte <= 0xF7 then
                bytes = 4
                if pos + 3 <= str_len then
                    local b2, b3, b4 = str:byte(pos + 1), str:byte(pos + 2), str:byte(pos + 3)
                    if b2 and b3 and b4 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
                        codepoint = (byte - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
                    end
                end
            end

            local start_pos = reverse and (pos - bytes + 1) or pos
            if start_pos >= 1 and start_pos + bytes - 1 <= str_len then
                local char = str:sub(start_pos, start_pos + bytes - 1)
                local ret_pos = start_pos
                pos = reverse and (start_pos - 1) or (start_pos + bytes - 1)
                return ret_pos, codepoint, char
            end
        end
    end
end

local function utf8_chars(str, reverse)
    if not libutf8proc_available then
        return native_utf8_chars(str, reverse)
    end

    local str_len = #str
    local pos = reverse and (str_len + 1) or 0
    local str_p = ffi.cast("const utf8proc_uint8_t*", str)
    local codepoint = ffi.new("utf8proc_int32_t[1]")

    return function()
        while true do
            pos = reverse and (pos - 1) or (pos + 1)
            if (reverse and pos < 1) or (not reverse and pos > str_len) then
                return nil
            end

            local remaining = reverse and pos or (str_len - pos + 1)
            local bytes = libutf8proc.utf8proc_iterate(str_p + pos - 1, remaining, codepoint)

            if bytes > 0 then
                local char = ffi.string(str_p + pos - 1, bytes)
                local ret_pos = tonumber(pos)
                pos = reverse and (pos - bytes + 1) or (pos + bytes - 1)
                return ret_pos, tonumber(codepoint[0]), char
            elseif bytes < 0 then
                if reverse then
                    pos = pos - 1
                end
            end
        end
    end
end

local UTF8_WHITESPACE_CODEPOINTS = {
    [0x00A0]=true, [0x1680]=true, [0x2000]=true, [0x2001]=true, [0x2002]=true, [0x2003]=true,
    [0x2004]=true, [0x2005]=true, [0x2006]=true, [0x2007]=true, [0x2008]=true, [0x2009]=true,
    [0x200A]=true, [0x200B]=true, [0x202F]=true, [0x205F]=true, [0x3000]=true, [0x0009]=true,
    [0x000A]=true, [0x000B]=true, [0x000C]=true, [0x000D]=true, [0x0020]=true
}

function M.utf8_trim(str)
    if type(str) ~= "string" or str == "" then return "" end

    local start
    for pos, cp, _ in utf8_chars(str) do
        if not UTF8_WHITESPACE_CODEPOINTS[cp] then
            start = pos
            break
        end
    end
    if not start then return "" end

    local finish
    for pos, cp, char in utf8_chars(str, true) do
        if not UTF8_WHITESPACE_CODEPOINTS[cp] then
            finish = pos + #char - 1
            break
        end
    end

    return (start and finish and start <= finish) and str:sub(start, finish) or ""
end

function M.plain_text_replace(text, pattern, replacement, count)
    text = tostring(text or "")
    pattern = tostring(pattern or "")
    replacement = tostring(replacement or "")

    if pattern == "" then return text end
    -- 转义 Lua 模式特殊字符
    local escaped_pattern = pattern:gsub("([%%().%+-*?[%]^$])", "%%%1")
    -- 转义替换字符串中的 %
    local safe_replacement = replacement:gsub("%%", "%%%%")
    return text:gsub(escaped_pattern, safe_replacement, count)
end

---去除多余换行、统一段落缩进、根据部分排版规则将不合理的换行合并成一个
---仅假设源文本格式混入了错误或多余换行和不标准的段落缩进
function M.splitParagraphsPreserveBlank(text)
    if type(text) ~= "string" or text == "" then return {} end

    text = text:gsub("\r\n?", "\n"):gsub("\n+", function(s)
        return (#s >= 2) and "\n\n" or s
    end)

    -- 兼容: 2半角+1全角,Koreader .txt auto add a indentEnglish
    local indentChinese = "\u{0020}\u{0020}\u{3000}"
    local indentEnglish = "\u{0020}\u{0020}"
    local paragraphs = {}
    local p_count = 0
    local allow_split = true
    local buffer = ""
    local prefix = nil
    local lines = {}
    local l_count = 0

    -- 保留空行，清理前后空白
    for line in util.gsplit(text, "\n", false, true) do
        l_count = l_count + 1
        lines[l_count] = M.utf8_trim(line)
    end

    -- 常见标点符号判断
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

            local line_len = #line
            local word_end = line:match(util.UTF8_CHAR_PATTERN .. "$")
            local next_word_start = (lines[i + 1] or ""):match(util.UTF8_CHAR_PATTERN)
            local word_end_isPunctuation = isPunctuation(word_end)

            -- 中文段末没有标点不允许换行, 避免触发koreader的章节标题渲染规则
            if prefix == indentChinese and (not word_end_isPunctuation or line_len < 7) then
                allow_split = false
            else
                allow_split = util.isSplittable and util.isSplittable(word_end, next_word_start, word_end) or true
            end

            if not allow_split and i < #lines then
                -- 非CJK两个单词间补充个空格
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

    -- 移除所有 <img> 标签后，检查是否仍有非空白字符
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

function M.getChapterContentType(txt, first_line)
    if type(txt) ~= "string" or txt == "" then return 1 end
    
    first_line = not first_line and (string.match(txt, "([^\n]*)\n?") or txt):lower() or first_line:lower()

    -- 优先检查 XHTML 特征
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

function M.processLink(book_cache_id, resources_src, base_url, is_proxy, context, callback)
    if not (H.is_str(book_cache_id) and H.is_str(resources_src)) then return nil end

    local processed_src = util.trim(resources_src)
    if processed_src == "" then return nil end

    local first = processed_src:sub(1, 1)
    -- protocols and anchors directly return nil
    if processed_src:find("^data:") or processed_src:find("^res:") or processed_src:find("^tel:") or processed_src:find("^javascript:") or first == "#" or first == "?" then
        return nil
    end

    local function normalize_url(src, baseUrl, isProxy)
        if not H.is_str(baseUrl) then baseUrl = "" end
        if src:sub(1, 2) == "//" then
            return (baseUrl:match("^(https?:)") or "https:") .. src
        elseif src:sub(1, 1) == "/" or src:sub(1, 2) == "./" or src:sub(1, 3) == "../" then
            return socket_url.absolute(baseUrl, src)
        elseif isProxy == true and context and context.getProxyImageUrl then
            return context.getProxyImageUrl(baseUrl, src)
        elseif not src:find("^%a+://") then
            -- not a complete URL, converted to an absolute path
            return socket_url.absolute(baseUrl, src)
        end
        return src
    end

    processed_src = normalize_url(processed_src, base_url, is_proxy)
    if not (H.is_str(processed_src) and processed_src:find("^(https?:)")) then return nil end

    local resources_id = H.md5(processed_src)
    local ext = ImageUtil.get_url_extension(processed_src)
    
    if ext == "" then
        ext = ImageUtil.get_url_extension(resources_src:gsub("[#?].*", ""))
        -- legado app 图片后带数据 v07ew.jpg,{'headers':{'referer':'https://m.weibo.cn'}}"
        if ext == "" then ext = ImageUtil.get_url_extension((resources_src:match("^(.-),") or resources_src)) end
    end

    local resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id
    local resources_relpath, resources_filepath = book_chapter_resources(book_cache_id, resources_filename)

    -- cache already exists
    if ext ~= "" and resources_filepath and util.fileExists(resources_filepath) then
        return resources_relpath
    end

    if not (context and context.pGetUrlContent) then return nil end

    local status, err = context.pGetUrlContent({ url = processed_src, timeout = 15, maxtime = 60 })
    if status and H.is_tbl(err) and err["data"] then
        ext = (not ext or ext == "") and err["ext"] or ext
        resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id

        -- 尝试处理css里面的级联
        if ext == "css_disable" and not callback then
            err["data"] = M.replace_css_urls(err["data"], function(url)
                -- 防止循环引用
                if url == resources_src then return url end
                return M.processLink(book_cache_id, url, processed_src, nil, context, true)
            end)
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

function M.txt2html(book_cache_id, content, title)
    local dropcaps = false
    local lines = {}
    local n = 0
    content = content or ""
    title = title or ""

    for line in util.gsplit(content, "\n", false, true) do
        line = M.utf8_trim(line)
        local el_tags

        local lower_line = line:lower()
        local allow_dropcaps = M.config and M.config.enable_dropcaps
        local is_title_line = false

        if allow_dropcaps and not dropcaps and line ~= "" and not lower_line:find("<img", 1, true) then
            -- 尝试清理重复标题 >9 避免单字误判
            if #title > 9 and string.find(line, title, 1, true) == 1 then
                line = M.utf8_trim(M.plain_text_replace(line, title, "", 1))
                if line == "" then
                    -- 抛弃仅重复标题行
                    is_title_line = true
                end
            end

            if not is_title_line then
                local punc_prefix, rep_text, remaining_text = get_dropcaps_info(line)
                -- 增加对 rep_text 的有效性检查
                if rep_text and rep_text ~= "" then
                    punc_prefix = punc_prefix or ""
                    remaining_text = remaining_text or ""
                    el_tags = string.format('<p style="text-indent: 0em;">%s<span class="duokan-dropcaps-two">%s</span>%s</p>', punc_prefix, rep_text, remaining_text)
                    dropcaps = true
                else
                    -- 如果没有有效的首字符，则作为普通段落处理
                    el_tags = string.format('<p>%s</p>', line)
                end
            end
        else
            el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
        end

        if not is_title_line then
            n = n + 1
            lines[n] = el_tags
        end
    end

    local epub = require("Legado/EpubHelper")
    epub.addCssRes(book_cache_id)
    return epub.addchapterT(title, table.concat(lines))
end

local htmlparser
function M.processChapter(chapter, content, filePath, context)
    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapter_title = chapter.title or ''
    content = H.is_str(content) and content or tostring(content)

    local first_line = string.match(content, "([^\n]*)\n?") or content
    local page_type = M.getChapterContentType(content, first_line)

    if page_type == 2 then -- IMAGE
        local img_sources = context.getPorxyPicUrls(bookUrl, content)
        if H.is_tbl(img_sources) and #img_sources > 0 then
            -- 一张图片就不打包cbz了
            if #img_sources == 1 then
                local res_url = img_sources[1]
                local status, err = context.pGetUrlContent({ url = res_url, timeout = 15, maxtime = 60, is_pic = true })
                if not status or not (H.is_tbl(err) and err["data"]) then error('单图下载失败') end

                local ext = ImageUtil.get_url_extension(res_url)
                if not ext or ext == "" then ext = err.ext or "png" end
                return context.chapter_writeToFile(chapter, string.format("%s.%s", filePath, ext), err['data'])
            else
                filePath = filePath .. '.cbz'
                local check_running = function() return context.isTaskRunning(chapter) end
                local status, err = pcall(ImageUtil.create_cbz_from_urls, filePath, img_sources, check_running)
                if not status then error('CreateCBZ err: ' .. tostring(err)) end
                if chapter.is_pre_loading then dbg.v('Cache task completed chapter.title:', chapter_title) end
                chapter.cacheFilePath = filePath
                return chapter
            end
        else
            error('生成图片列表失败')
        end

    elseif page_type == 4 then -- XHTML
        local html_url = context.getProxyEpubUrl(bookUrl, first_line)
        if not html_url or html_url == '' then error('转换失败') end
        
        local status, err = context.pGetUrlContent({ url = html_url, timeout = 15, maxtime = 60 })
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
            -- 清理 scripts
            for _, el in ipairs(root("script")) do
                local el_text = el and el:gettext()
                if el_text then content = M.plain_text_replace(content, el_text, "") end
            end
            -- 转换 link 与 img
            for _, el in ipairs(root("head > link[href]")) do
                if el and el.attributes and el.attributes["href"] then
                    local relpath = M.processLink(book_cache_id, el.attributes["href"], html_url, nil, context)
                    local el_text = el:gettext()
                    if relpath and el_text then 
                        local replace_text = M.plain_text_replace(el_text, el.attributes["href"], relpath)
                        content = M.plain_text_replace(content, el_text, replace_text) 
                    end
                end
            end
            for _, el in ipairs(body:select("img[src]")) do
                if el and el.attributes and el.attributes["src"] then
                    local relpath = M.processLink(book_cache_id, el.attributes["src"], html_url, nil, context)
                    local el_text = el:gettext()
                    if relpath and el_text then 
                        local replace_text = M.plain_text_replace(el_text, el.attributes["src"], relpath)
                        content = M.plain_text_replace(content, el_text, replace_text) 
                    end
                end
            end
            -- 处理 SVG xlink
            for _, el in ipairs(body:select("svg")) do
                local el_text = el and el:gettext()
                if el_text then
                    for open, r2, path, close in el_text:gmatch(PATTERNS.IMAGE_XLINK) do
                        if open and open ~= "" then
                            open = open .. (r2 or "")
                            local relpath = M.processLink(book_cache_id, path, html_url, nil, context)
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
                local relpath = M.processLink(book_cache_id, path, html_url, nil, context)
                if relpath then return table.concat({open .. (r2 or ""), relpath, (r2 or "") .. (close or "")}) end
            end)
            :gsub(PATTERNS.IMAGE_XLINK, function(r1, r2, r3, r4)
                local open, path, close = r1, r3, r4
                if open and open ~= "" and path and not path:find("^resources/") then
                    local relpath = M.processLink(book_cache_id, path, html_url, nil, context)
                    if relpath then return table.concat({open .. (r2 or ""), relpath, (r2 or "") .. (close or "")}) end
                end
            end)
            :gsub(PATTERNS.IMG_SRC, function(r1, r2, r3, r4)
                if r1 == "" or not r3 or r3:find("^resources/") then return end
                local relpath = M.processLink(book_cache_id, r3, html_url, nil, context)
                if relpath then return table.concat({r1, r2, relpath, r2, r4}) end
            end)
        end
        return context.chapter_writeToFile(chapter, filePath, content)

    elseif page_type == 3 then -- MIXED
        filePath = filePath .. '.html'
        if M.has_img_tag(content) then
            content = content:gsub(PATTERNS.IMG_SRC, function(r1, r2, r3, r4)
                if not (r1 and r1 ~= "" and r3 and r3 ~= "") then return end
                local relpath = M.processLink(book_cache_id, r3, bookUrl, true, context)
                if relpath then
                    -- 随文图
                    return string.format('<div class="duokan-image-single">%s</div>', table.concat({r1, r2, relpath, r2, ' class="picture-80" alt="" ', r4}))
                end
            end)
        end
        return context.chapter_writeToFile(chapter, filePath, M.txt2html(book_cache_id, content, chapter_title))
        
    else -- TEXT (1)
        if context.is_txt then
            filePath = filePath .. '.txt'
            local paragraphs = M.splitParagraphsPreserveBlank(content)
            if #paragraphs == 0 then chapter.content_is_nil = true end
            
            content = table.concat(paragraphs, "\n")
            if not string.find(paragraphs[1] or "", chapter_title, 1, true) then
                content = table.concat({"\t\t", tostring(chapter_title), "\n\n", content})
            end
        else
            filePath = filePath .. '.html'
            content = M.txt2html(book_cache_id, content, chapter_title)
        end
        return context.chapter_writeToFile(chapter, filePath, content)
    end
end

return M