local logger = require("logger")

--- Common timeout values
-- Large content 块超时 总超时
local LARGE_BLOCK_TIMEOUT = 10
local LARGE_TOTAL_TIMEOUT = 30
-- File downloads
local FILE_BLOCK_TIMEOUT = 15
local FILE_TOTAL_TIMEOUT = 60
-- Upstream defaults
local DEFAULT_BLOCK_TIMEOUT = 60
local DEFAULT_TOTAL_TIMEOUT = -1

local default_headers = {
    -- Use a modern UA to avoid CDN/WAF blocking outdated or niche devices
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
}

local function calc_block_timeout(total_timeout)
    if type(total_timeout) ~= "number" or total_timeout <= 0 then
        return DEFAULT_BLOCK_TIMEOUT
    end
    local block_timeout = total_timeout * 0.25
    block_timeout = math.max(3, block_timeout)
    block_timeout = math.min(15, block_timeout)
    block_timeout = math.min(block_timeout, total_timeout)
    return block_timeout
end

--[[
    return block_timeout, total_timeout.
    参数 options.timeout 两种写法：
      1. number : 总超时（total timeout），block timeout 由 calc_block_timeout 计算
      2. table: { block_timeout, total_timeout },  两项都必须是数字，缺值/非法回退默认值
    默认值: 文件下载 {FILE_BLOCK_TIMEOUT, FILE_TOTAL_TIMEOUT}，
                    普通请求 {DEFAULT_BLOCK_TIMEOUT, DEFAULT_TOTAL_TIMEOUT}。
]]
local function resolve_timeouts(options, is_file)
    options = options or {}
    local total_timeout
    local block_timeout
    local t = options.timeout
    if type(t) == "number" then
        total_timeout = t
        block_timeout = calc_block_timeout(t)
    elseif type(t) == "table" and type(t[1]) == "number" and type(t[2]) == "number" then
        block_timeout, total_timeout = t[1], t[2]
    else
        if is_file then
            block_timeout = FILE_BLOCK_TIMEOUT
            total_timeout = FILE_TOTAL_TIMEOUT
        else
            block_timeout = DEFAULT_BLOCK_TIMEOUT
            total_timeout = DEFAULT_TOTAL_TIMEOUT
        end
    end
    if type(total_timeout) == "number" and total_timeout > 0 and block_timeout > total_timeout then
        block_timeout = total_timeout
    end
    return block_timeout, total_timeout
end

local function get_extension_from_mimetype(content_type)
    if type(content_type) ~= "string" then return nil end
    local mime = content_type:match("^%s*([^;%s]+)")
    if not mime then return nil end
    mime = mime:lower()
    local extensions = {
        ["image/jpeg"] = "jpg",
        ["image/png"] = "png",
        ["image/gif"] = "gif",
        ["image/bmp"] = "bmp",
        ["image/webp"] = "webp",
        ["image/tiff"] = "tiff",
        ["image/svg+xml"] = "svg",
        ["application/xhtml+xml"] = "html",
        ["text/html"] = "html",
        ["text/javascript"] = "js",
        ["application/javascript"] = "js",
        ["text/css"] = "css",
        ["application/opentype"] = "otf",
        ["font/otf"] = "otf",
        ["application/truetype"] = "ttf",
        ["font/ttf"] = "ttf",
        ["application/font-woff"] = "woff",
        ["font/woff"] = "woff",
        ["application/font-woff2"] = "woff2",
        ["font/woff2"] = "woff2",
        ["application/epub+zip"] = "epub",
    }
    return extensions[mime]
end

local function get_image_format_head8(image_data)
    if type(image_data) ~= "string" or #image_data < 12 then return "bin" end
    local b1 = string.byte(image_data, 1)
    if b1 == 0xFF then
        if string.sub(image_data, 1, 3) == "\xFF\xD8\xFF" then return "jpg" end
    elseif b1 == 0x89 then
        if string.sub(image_data, 1, 8) == "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A" then return "png" end
    elseif b1 == 0x52 then
        if string.sub(image_data, 1, 4) == "RIFF" and string.sub(image_data, 9, 12) == "WEBP" then return "webp" end
    elseif b1 == 0x42 then
        if string.sub(image_data, 1, 2) == "BM" then return "bmp" end
    elseif b1 == 0x47 then
        if string.sub(image_data, 1, 4) == "GIF8" then return "gif" end
    elseif b1 == 0x49 then
        if string.sub(image_data, 1, 4) == "\x49\x49\x2A\x00" then return "tiff" end
    elseif b1 == 0x4D then
        if string.sub(image_data, 1, 4) == "\x4D\x4D\x00\x2A" then return "tiff" end
    end
    return "bin"
end

local function pGetUrlContent(options, is_create)
    options = options or {}
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local http = require("socket.http")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local url = options.url
    local file_fp = options.file
    local is_pic = options.is_pic
    local is_file = file_fp ~= nil

    local block_timeout, total_timeout = resolve_timeouts(options, is_file)

    local function close_file()
        if file_fp then pcall(function() file_fp:close() end) end
    end

    if type(url) ~= "string" or url == "" then
        close_file()
        return false, "Invalid URL"
    end

    local parsed = socket_url.parse(url)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        close_file()
        return false, "Unsupported protocol"
    end

    local sink = {}
    -- Only use the custom TCP creator for plain HTTP; leave HTTPS to default so TLS/SNI works properly
    local use_custom_create = is_create and parsed and parsed.scheme == "http"

    local req_headers = {}
    if type(options.headers) == "table" then
        for k, v in pairs(options.headers) do
            req_headers[k] = v
        end
    else
        for k, v in pairs(default_headers) do
            req_headers[k] = v
        end
    end

    if is_pic and not req_headers["Accept"] then
        -- Image requests prioritize
        req_headers["Accept"] = "image/png, image/jpeg, image/webp, image/bmp;q=0.9, image/tiff;q=0.8, image/*;q=0.7"
    end

    -- total_timeout > 0 时使用带总超时控制的 socketutil sink，否则普通 ltn12 sink
    local response_sink
    if not file_fp then
        if total_timeout and total_timeout > 0 then
            response_sink = socketutil.table_sink(sink)
        else
            response_sink = ltn12.sink.table(sink)
        end
    else
        if total_timeout and total_timeout > 0 then
            response_sink = socketutil.file_sink(file_fp)
        else
            response_sink = ltn12.sink.file(file_fp)
        end
    end

    local request = {
        url = url,
        method = options.method or "GET",
        headers = req_headers,
        sink = response_sink,
        source = options.source,
        redirect = options.redirect,
        -- Strictly customized TCP only for HTTP; HTTPS relies on underlying SSL stack for SNI/TLS
        create = use_custom_create and socketutil.tcp or nil,
    }
    logger.dbg("HTTP timeout:", "block=" .. tostring(block_timeout), "total=" .. tostring(total_timeout), "file=" .. tostring(is_file))
    socketutil:set_timeout(block_timeout, total_timeout)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        logger.err("request interrupted:", tostring(code), "block_timeout=" .. tostring(block_timeout), "total_timeout=" .. tostring(total_timeout))
        close_file()
        return false, "request interrupted:" .. tostring(code)
    end

    if headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        close_file()
        return false, "Network or remote server unavailable"
    end

    if type(code) ~= 'number' or code < 200 or code > 299 then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        logger.dbg("Response headers:", headers)
        close_file()
        return false, "Remote server error or unavailable"
    end

    local content
    if not file_fp then
        content = table.concat(sink)
        if headers and headers["content-length"] and options.method ~= "HEAD" then
            local content_length = tonumber(headers["content-length"])
            if content_length and #content ~= content_length then
                close_file()
                logger.warn("Incomplete content received:", "expected=" .. tostring(content_length), "actual=" .. tostring(#content))
                return false, "Incomplete content received"
            end
        end
    end

    local extension
    local contentType = headers["content-type"]
    if contentType then
        extension = get_extension_from_mimetype(contentType)
        if not extension and (contentType:match("^%s*image/") or is_pic) then
            extension = get_image_format_head8(content)
        end
    end
    
    close_file()

    return true, {
        data = content,
        ext = extension,
        headers = headers
    }
end

return pGetUrlContent
