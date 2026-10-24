local JSON = require("json")
local url = require("socket.url")
local sha = require("ffi/sha2")
local M = {}

local function valid_action(value)
    return type(value) == "string" and not value:match("^%s*$") and #value <= 65536
end

M.EPUB_FALLBACK_ENABLED = false

function M.from_metadata(encoded)
    if type(encoded) ~= "string" then return end
    local ok, meta = pcall(function() return JSON.decode(sha.base64_to_bin(encoded)) end)
    if not ok or type(meta) ~= "table" then return end
    local action = valid_action(meta.click) and meta.click or meta.js
    if not valid_action(action) then return nil, meta end
    return {kind = "script", value = action, title = "评论"}, meta
end

function M.from_tag_metadata(encoded)
    local ok, meta = pcall(function() return JSON.decode(sha.base64_to_bin(encoded)) end)
    if not ok or type(meta) ~= "table" then return end
    local count = tostring(meta.count or ""):match("^%s*(.-)%s*$")
    local label = meta.tag == "note" and tostring(meta.text or "神评")
        or (count:match("^%d+%+?$") and #count <= 6 and ("[" .. count .. "]") or "[评]")
    local action
    if valid_action(meta.onpress) then
        action = {kind = "script", value = meta.onpress, title = "评论"}
    elseif M.http_url(meta.ident) then
        action = {kind = "url", value = meta.ident, title = "评论"}
    end
    return action, label, meta.tag == "note"
end

function M.href(context, id)
    if type(context) ~= "table" or type(context.book_cache_id) ~= "string"
            or not context.book_cache_id:match("^%w+$") then return end
    local chapter = tonumber(context.chapters_index)
    if not chapter or chapter < 0 or chapter % 1 ~= 0 or type(id) ~= "number" or id < 1 or id % 1 ~= 0 then return end
    return string.format("legado://r?c=%d&i=%d", chapter, id)
end

function M.from_href(href, context)
    if type(href) ~= "string" then return end
    local chapter, id = href:match("^legado://r%?c=(%d+)&i=(%d+)$")
    if chapter then
        local book = type(context) == "table" and context.book_cache_id
        if type(book) ~= "string" or not book:match("^%w+$") or tonumber(id) < 1 then return end
        return {book_cache_id = book, chapters_index = tonumber(chapter), id = tonumber(id)}
    end
    local book, chapter, id = href:match("^legado://review%?book=(%w+)&chapter=(%d+)&id=(%d+)$")
    if not book or tonumber(id) < 1 then return end
    return {book_cache_id = book, chapters_index = tonumber(chapter), id = tonumber(id)}
end

local MAX_ACTIONS = 10000
local MAX_ENCODED_BYTES = 8 * 1024 * 1024
local function valid_context(context)
    return type(context) == "table" and type(context.book_cache_id) == "string"
        and context.book_cache_id:match("^%w+$")
        and type(context.chapters_index) == "number" and context.chapters_index >= 0
        and context.chapters_index % 1 == 0
end

local function strip_markers(html)
    html = html:gsub("<!%-%-legado%-actions:.-%-%->", "")
    return html:gsub("<!%-%-legado%-review%-data:.-%-%->", "")
end

function M.embed(html, actions, context)
    html = strip_markers(html)
    if #actions == 0 then return html, false end
    if not valid_context(context) or #actions > MAX_ACTIONS then return html, false end
    local packed = {}
    for i, action in ipairs(actions) do
        packed[i] = {value = action.value}
        if action.kind ~= "script" then packed[i].kind = action.kind end
        if action.title ~= "评论" then packed[i].title = action.title end
    end
    local encoded = sha.bin_to_base64(JSON.encode({version = 3,
        context = {book = context.book_cache_id, chapter = context.chapters_index}, actions = packed}))
    if #encoded > MAX_ENCODED_BYTES then return html, false end
    local marker = "<!--legado-review-data:" .. encoded .. "-->"
    local pos = html:find("</body>", 1, true)
    if pos then return html:sub(1, pos - 1) .. marker .. html:sub(pos), true end
    return html .. marker, true
end

local mime_checked, mime_unb64 = false, nil
local function decode_action_base64(encoded)
    if not mime_checked then
        mime_checked = true
        local ok, mime = pcall(require, "mime")
        if ok and type(mime) == "table" and type(mime.unb64) == "function" then
            mime_unb64 = mime.unb64
        end
    end
    if mime_unb64 and #encoded % 4 == 0 and encoded:match("^[A-Za-z0-9+/]*=?=?$") then
        local decoded = mime_unb64(encoded)
        if type(decoded) == "string" then return decoded end
    end
    return sha.base64_to_bin(encoded)
end

local function decode_actions(html, context)
    if type(html) ~= "string" then return end
    local encoded, name, count
    count = 0
    for marker, payload in html:gmatch("<!%-%-(legado[%w%-]*):([^<>]-)%-%->") do
        if marker == "legado-actions" or marker == "legado-review-data" then
            count = count + 1
            name, encoded = marker, payload
        end
    end
    if count ~= 1 or #encoded > MAX_ENCODED_BYTES or not encoded:match("^[%w+/=]+$") then return end
    local ok, data = pcall(function() return JSON.decode(decode_action_base64(encoded)) end)
    if not ok or type(data) ~= "table" then return end
    local compact = data.version == 2 or data.version == 3
    if name == "legado-review-data" then
        if data.version ~= 3 or not valid_context(context) or type(data.context) ~= "table"
                or data.context.book ~= context.book_cache_id
                or data.context.chapter ~= context.chapters_index then return end
    elseif data.version ~= nil and data.version ~= 2 then return end
    local actions = compact and data.actions or data
    if type(actions) ~= "table" then return end
    local n = #actions
    if n > MAX_ACTIONS then return end
    for key in pairs(actions) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > n then return end
    end
    return actions, compact
end

local function select_action(actions, compact, id)
    if type(id) ~= "number" or id < 1 or id % 1 ~= 0 or id > MAX_ACTIONS
            or type(actions) ~= "table" or type(actions[id]) ~= "table" then return end
    local stored = actions[id]
    local action = {kind = stored.kind, value = stored.value, title = stored.title}
    if compact then
        if action.kind == nil then action.kind = "script" end
        if action.title == nil then action.title = "评论" end
    end
    if action.kind ~= "script" and action.kind ~= "url" then return end
    if type(action.value) ~= "string" or action.value:match("^%s*$") or #action.value > 65536 then return end
    if action.title ~= nil and (type(action.title) ~= "string" or #action.title > 4096) then return end
    if action.kind == "url" and not M.http_url(action.value) then return end
    return action
end

function M.read_action(html, id, context)
    if type(id) ~= "number" or id < 1 or id % 1 ~= 0 or id > MAX_ACTIONS then return end
    local actions, compact = decode_actions(html, context)
    return select_action(actions, compact, id)
end

function M.epub_links(html, context)
    local actions, compact = decode_actions(html, context)
    return html:gsub('<a href="([^"]+)"', function(href)
        local ref = M.from_href(href:gsub('&amp;', '&'), context)
        if not ref or ref.book_cache_id ~= context.book_cache_id
                or ref.chapters_index ~= context.chapters_index or not select_action(actions, compact, ref.id) then
            return '<a href="' .. href .. '"'
        end
        return string.format('<a id="lr%d-%d" class="legado-noteref" style="-cr-hint: noteref;" href="r.xhtml#c%d-%d"', ref.chapters_index, ref.id, ref.chapters_index, ref.id)
    end)
end

function M.fallback_page(previous, chapters)
    local entries = {}
    for chapter, id in (previous or ''):gmatch('id="c(%d+)%-(%d+)"') do
        entries[chapter .. '-' .. id] = {tonumber(chapter), tonumber(id)}
    end
    for chapter, html in pairs(chapters) do
        for key in pairs(entries) do
            if entries[key][1] == chapter then entries[key] = nil end
        end
        for c, id in html:gmatch('href="r%.xhtml#c(%d+)%-(%d+)"') do
            if tonumber(c) == chapter then entries[c .. '-' .. id] = {chapter, tonumber(id)} end
        end
    end
    local ordered = {}
    for _, entry in pairs(entries) do ordered[#ordered + 1] = entry end
    table.sort(ordered, function(a, b) return a[1] == b[1] and a[2] < b[2] or a[1] < b[1] end)
    local body = {'<p>关闭脚注或使用阅读器的返回功能继续阅读；也可通过阅读器目录导航。</p>'}
    for _, entry in ipairs(ordered) do
        body[#body + 1] = string.format('<div id="c%d-%d" class="legado-footnote" style="-cr-hint: footnote;"><p>此评论需要启用 Legado 插件才能查看。</p></div>', entry[1], entry[2])
    end
    return '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>评论说明</title></head><body>' .. table.concat(body) .. '</body></html>'
end

function M.from_epub_href(href, context)
    if type(href) ~= "string" or not valid_context(context) then return end
    local chapter, id = href:match('^r%.xhtml#c(%d+)%-(%d+)$')
    if not chapter then chapter, id = href:match('^OEBPS/Text/r%.xhtml#c(%d+)%-(%d+)$') end
    if not chapter or tonumber(id) < 1 or tonumber(id) > MAX_ACTIONS then return end
    return {book_cache_id = context.book_cache_id, chapters_index = tonumber(chapter), id = tonumber(id)}
end

function M.http_url(value)
    if type(value) ~= "string" or value:find("[%z\1-\32\127]") then return end
    local parsed = url.parse(value)
    if parsed and (parsed.scheme == "http" or parsed.scheme == "https")
            and parsed.host and parsed.host ~= "" and not parsed.userinfo then return value end
end

return M
