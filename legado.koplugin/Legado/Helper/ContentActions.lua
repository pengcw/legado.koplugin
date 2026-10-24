local ReviewLink, EpubHelper, JSON, sha
local M = {}

local function load_dependencies()
    if ReviewLink then return end
    ReviewLink = require("Legado.Helper.ReviewLink")
    EpubHelper = require("Legado/EpubHelper")
    JSON = require("json")
    sha = require("ffi/sha2")
end

local function register(action, opts)
    if not action then return end
    load_dependencies()
    local id = opts.review_actions and (#opts.review_actions + 1) or 1
    local href = ReviewLink.href(opts.review_context, id)
    if href then
        opts.review_actions = opts.review_actions or {}
        opts.review_actions[id] = action
    end
    return href
end

function M.wrap(html, href)
    if not href then return html end
    load_dependencies()
    return '<a href="' .. EpubHelper.escape_xml_attr(href, '"') .. '">' .. html .. '</a>'
end

local REF_STYLE = ' class="legado-review-ref" style="font-size:0.5em;vertical-align:super;color:#0066cc;text-decoration:underline;white-space:nowrap"'
local function review_label(label, href)
    load_dependencies()
    local text = EpubHelper.escape_xml_attr(label, '"')
    if href then
        return '<sup' .. REF_STYLE .. '><a href="' .. EpubHelper.escape_xml_attr(href, '"') .. '" style="color:inherit;text-decoration:underline">' .. text .. '</a></sup>'
    end
    return '<sup' .. REF_STYLE .. '>' .. text .. '</sup>'
end

function M.take_image_action(attrs, opts)
    local metadata = attrs["data-legado-image-meta"]
    if not metadata then return end
    load_dependencies()
    local action, meta = ReviewLink.from_metadata(metadata.val)
    local queue = opts.review_image_hrefs and opts.review_image_hrefs[metadata.val]
    local href
    if queue and queue[queue.cursor] then
        href = queue[queue.cursor]
        queue.cursor = queue.cursor + 1
    else
        href = register(action, opts)
    end
    if not href then return end
    meta.click, meta.js = nil, nil
    if meta.style == "text" or meta.style == "TEXT" then meta.style = nil end
    if next(meta) then
        metadata.val = sha.bin_to_base64(JSON.encode(meta))
    else
        attrs["data-legado-image-meta"] = nil
    end
    return href
end

function M.has_markup(content)
    if content:find("<reader-review ", 1, true) then return true end
    if content:find('src="dp:', 1, true) then return true end
    if not content:find(" data-legado-image-meta=", 1, true) then return false end
    for encoded in content:gmatch('data%-legado%-image%-meta="([%w+/=]+)"') do
        load_dependencies()
        if ReviewLink.from_metadata(encoded) then return true end
    end
    return false
end

local function map_tags(content, transform)
    local result, cursor, search_pos = {}, 1, 1
    while true do
        local start = content:find("<", search_pos, true)
        if not start then break end
        local pos, quote = start + 1, nil
        while pos <= #content do
            local char = content:sub(pos, pos)
            if quote then
                if char == quote then quote = nil end
            elseif char == '"' or char == "'" then
                quote = char
            elseif char == ">" or char == "<" then
                break
            end
            pos = pos + 1
        end
        if pos > #content then break end
        if content:sub(pos, pos) ~= ">" then
            search_pos = start + 1
        else
            result[#result + 1] = content:sub(cursor, start - 1)
            result[#result + 1] = transform(content:sub(start, pos))
            cursor = pos + 1
            search_pos = cursor
        end
    end
    result[#result + 1] = content:sub(cursor)
    return table.concat(result)
end

local function each_attribute(tag, visit)
    local cursor = 1
    while true do
        local _, last, key = tag:find('([%w_:%-]+)%s*=%s*', cursor)
        if not last then return end
        local start = last + 1
        local quote = tag:sub(start, start)
        local finish
        if quote == '"' or quote == "'" then
            start = start + 1
            finish = tag:find(quote, start, true) or (#tag + 1)
        else
            finish = tag:find('[%s>]', start) or (#tag + 1)
        end
        if visit(key:lower(), tag:sub(start, finish - 1), start) then return end
        cursor = finish + 1
    end
end

local REVIEW_TYPES = {qtbzs = true, qmpl = true, ['qmpl-god'] = true}
local function known_review_image(src, style, kind, action, loading)
    if not action then return false end
    if REVIEW_TYPES[kind] then return true end
    if loading then return false end
    if style == 'text' or style == 'TEXT' then return true end
    return style == 'FULL' and src:find('^data:image/svg%+xml') ~= nil
end

function M.strip_reviews(content)
    return map_tags(content, function(tag)
        local lower = tag:lower()
        if lower:match('^</?comment[%s/>]') or lower:match('^</?note[%s/>]')
                or lower:match('^</?reader%-review[%s/>]') then return '' end
        if not lower:match('^<img[%s/>]') then return tag end
        local src, encoded, options
        each_attribute(tag, function(key, value)
            if key == 'data-legado-image-meta' then encoded = value end
            if not src and (key == 'src' or key == 'data-src' or key == 'data-original') then
                src = value
                options = value:match(',%s*({.*})%s*$')
            end
        end)
        src = src or ''
        if src:match('^dp:%d+$') or src:match('^dp:%d+,%s*{') then return '' end
        if encoded then
            load_dependencies()
            local action, meta = ReviewLink.from_metadata(encoded)
            if meta and known_review_image(src, meta.style, meta.type, action,
                    meta.headers or meta.imageDecode) then return '' end
        elseif options then
            local style = options:match('["\']style["\']%s*:%s*["\']([^"\']+)["\']')
            local kind = options:match('["\']type["\']%s*:%s*["\']([^"\']+)["\']')
            local action = options:find('["\']click["\']%s*:%s*["\']%s*[^%s"\']')
                or options:find('["\']js["\']%s*:%s*["\']%s*[^%s"\']')
            local loading = options:find('["\']headers["\']%s*:') or options:find('["\']imageDecode["\']%s*:')
            if known_review_image(src, style, kind, action, loading) then return '' end
        end
        return tag
    end)
end

local function has_raw_markup(content)
    if not (content:find('<[Cc][Oo][Mm][Mm][Ee][Nn][Tt][%s/>]')
            or content:find('<[Nn][Oo][Tt][Ee][%s/>]')
            or (content:find('<[Ii][Mm][Gg][%s/>]')
                and (content:find('[Oo][Nn][Pp][Rr][Ee][Ss][Ss]%s*=') or content:find(',%s*{')))) then
        return false
    end
    local found = false
    map_tags(content, function(tag)
        if found then return tag end
        local lower = tag:lower()
        if lower:match('^<comment[%s/>]') or lower:match('^<note[%s/>]') then
            found = true
        elseif lower:match('^<img[%s/>]') then
            each_attribute(tag, function(key, value)
                if key == 'onpress' or ((key == 'src' or key == 'data-src' or key == 'data-original')
                        and value:find(',%s*{')) then
                    found = true
                    return true
                end
            end)
        end
        return tag
    end)
    return found
end

function M.begin(content, context, already_normalized)
    if not content:find('<', 1, true) then return content end
    local raw = not already_normalized and has_raw_markup(content)
    if not raw and not M.has_markup(content) then return content end
    local state = {review_context = context}
    if not already_normalized then
        local ok, normalized = pcall(function()
            return require('Legado.spore.local.parser').normalize_reviews(raw and content or '')
        end)
        if ok and type(normalized) == 'string' then
            if raw then content = normalized end
        else
            state.review_normalization_unavailable = true
            return M.strip_reviews(content), state
        end
    end
    return M.prepare(content, state), state
end

function M.has_placeholder(text)
    return text:find('LEGADOREVIEWNODE%d+TOKEN') ~= nil
end

function M.prepare_image(attrs, state)
    if state.review_normalization_unavailable then
        if attrs.src then
            attrs.src.val = attrs.src.val:match('^(.-),%s*{') or attrs.src.val
        end
        attrs.onpress = nil
        return nil
    end
    return M.take_image_action(attrs, state)
end

function M.prepare(content, opts)
    opts.review_actions = nil
    opts.review_nodes = nil
    opts.review_image_hrefs = nil
    if not M.has_markup(content) then return content end
    load_dependencies()
    local function keep_image(tag, encoded, action)
        local href = register(action, opts)
        if href then
            opts.review_image_hrefs = opts.review_image_hrefs or {}
            local queue = opts.review_image_hrefs[encoded] or {cursor = 1}
            opts.review_image_hrefs[encoded] = queue
            queue[#queue + 1] = href
        end
        return tag
    end
    local full_nodes = {}
    local prepared = map_tags(content, function(tag)
        if tag == '</reader-review>' then return '' end
        local encoded = tag:match('^<reader%-review data%-legado%-review%-meta="([%w+/=]+)"')
        local action, label, style, is_note
        if encoded then
            action, label, is_note = ReviewLink.from_tag_metadata(encoded)
            if not label then return '' end
        elseif tag:match('^<img%s') then
            encoded = tag:match('data%-legado%-image%-meta="([%w+/=]+)"')
            local count = tag:match('src="dp:(%d+)"')
            if not encoded and not count then return tag end
            local meta = {}
            if encoded then action, meta = ReviewLink.from_metadata(encoded) end
            meta = meta or {}
            if not action and not count then return tag end
            style = meta.style
            if not count and (not action or (style ~= 'text' and style ~= 'TEXT')) then
                return keep_image(tag, encoded, action)
            end
            for key in pairs(meta) do
                if not count and key ~= 'click' and key ~= 'js' and key ~= 'style' and key ~= 'type' and key ~= 'count' then
                    return keep_image(tag, encoded, action)
                end
            end
            local value = tostring(count or meta.count or ""):match("^%s*(.-)%s*$")
            label = value:match("^%d+%+?$") and #value <= 6 and ('[' .. value .. ']') or '[评]'
        else
            return tag
        end
        local href = register(action, opts)
        if tag:match('^<img%s') and action and not href then return tag end
        opts.review_nodes = opts.review_nodes or {}
        opts.review_nodes[#opts.review_nodes + 1] = is_note
            and M.wrap(EpubHelper.escape_xml_attr(label, '"'), href) or review_label(label, href)
        local token = 'LEGADOREVIEWNODE' .. #opts.review_nodes .. 'TOKEN'
        if style == 'FULL' then full_nodes[#full_nodes + 1] = token end
        return style == 'FULL' and ('\n' .. token .. '\n') or token
    end)
    for _, token in ipairs(full_nodes) do
        prepared = prepared:gsub('[ \t\r\n]*' .. token .. '[ \t\r\n]*', '\n' .. token .. '\n')
    end
    return prepared
end

function M.finish(html, opts)
    if opts.review_nodes then
        html = html:gsub("<p>(LEGADOREVIEWNODE%d+TOKEN)</p>",
            '<p class="legado-review-entry" style="text-indent: 0; margin-top: 0; margin-bottom: 0;">%1</p>')
        html = html:gsub("LEGADOREVIEWNODE(%d+)TOKEN", function(id)
            return opts.review_nodes[tonumber(id)] or ""
        end)
    end
    if opts.review_actions then
        load_dependencies()
        local result, saved = ReviewLink.embed(html, opts.review_actions, opts.review_context)
        if saved then return result end
        local cleaned = result:gsub('<a%s[^>]-href="legado://r%?c=%d+&amp;i=%d+"[^>]*>(.-)</a>', '%1')
        return cleaned
    end
    return html
end

return M
