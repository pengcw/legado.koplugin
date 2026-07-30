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

local function get_extension_from_mimetype(content_type)
    local extensions = {
        ["image/jpeg"] = "jpg",
        ["image/png"] = "png",
        ["image/gif"] = "gif",
        ["image/bmp"] = "bmp",
        ["image/webp"] = "webp",
        ["image/tiff"] = "tiff",
        ["image/svg+xml"] = "svg",
        ["application/xhtml+xml"] = "html",
        ["text/javascript"] = "js",
        ["text/css"] = "css",
        ["application/opentype"] = "otf",
        ["application/truetype"] = "ttf",
        ["application/font-woff"] = "woff",
        ["application/epub+zip"] = "epub"
    }

    return extensions[content_type]
end

local function get_image_format_head8(image_data)
    if type(image_data) ~= "string" or #image_data < 12 then
        return "bin"
    end
    local b1 = string.byte(image_data, 1)
    if b1 == 0xFF then 
        if string.sub(image_data, 1, 3) == "\xFF\xD8\xFF" then 
            return "jpg" 
        end
    elseif b1 == 0x89 then 
        if string.sub(image_data, 1, 8) == "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A" then 
            return "png" 
        end
    elseif b1 == 0x52 then 
        if string.sub(image_data, 1, 4) == "RIFF" and string.sub(image_data, 9, 12) == "WEBP" then 
            return "webp" 
        end
    elseif b1 == 0x42 then 
        if string.sub(image_data, 1, 2) == "BM" then 
            return "bmp" 
        end
    elseif b1 == 0x47 then 
        if string.sub(image_data, 1, 4) == "GIF8" then 
            return "gif" 
        end
    elseif b1 == 0x49 then 
        if string.sub(image_data, 1, 4) == "\x49\x49\x2A\x00" then 
            return "tiff" 
        end
    elseif b1 == 0x4D then 
        if string.sub(image_data, 1, 4) == "\x4D\x4D\x00\x2A" then 
            return "tiff" 
        end
    end
    return "bin"
end

local function pGetUrlContent(options, is_create)

    local ltn12 = require("ltn12")
    local socket = require("socket")
    local http = require("socket.http")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")

    local url = options.url
    local timeout = options.timeout or 10
    local maxtime = options.maxtime or options.timeout + 20
    local file_fp = options.file
    local is_pic = options.is_pic

    local parsed = socket_url.parse(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return false, "Unsupported protocol"
    end

    local sink = {}
    -- Only use the custom TCP creator for plain HTTP; leave HTTPS to default so TLS/SNI works properly
    local use_custom_create = is_create and parsed and parsed.scheme == "http"

    local req_headers = {}
    if options.headers then
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
    local request = {
        url = url,
        method = options.method or "GET",
        headers = req_headers,
        sink = not file_fp and (maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink)) or
            (maxtime and socketutil.file_sink(file_fp) or ltn12.sink.file(file_fp)),
        source = options.source,
        redirect = options.redirect,
        -- Strictly customized TCP only for HTTP; HTTPS relies on underlying SSL stack for SNI/TLS
        create = use_custom_create and socketutil.tcp or nil,
    }

    socketutil:set_timeout(timeout, maxtime)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        logger.err("request interrupted:", code)
        return false, "request interrupted:" .. tostring(code)
    end

    if headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        return false, "Network or remote server unavailable"
    end

    if type(code) ~= 'number' or code < 200 or code > 299 then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        logger.dbg("Response headers:", headers)
        return false, "Remote server error or unavailable"
    end
    
    local content
    if not file_fp then 
      content = table.concat(sink)
      if headers and headers["content-length"] then
        local content_length = tonumber(headers["content-length"])
        if #content ~= content_length then
            return false, "Incomplete content received"
        end
      end
    end

    local extension
    local contentType = headers["content-type"]
    if contentType then
        extension = get_extension_from_mimetype(contentType)
        if not extension and (contentType:match("^image/") or is_pic) then
            extension = get_image_format_head8(content)
        end
    end

    return true, {
        data = content,
        ext = extension,
        headers = headers
    }
end

return pGetUrlContent
