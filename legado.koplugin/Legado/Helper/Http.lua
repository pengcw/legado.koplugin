local logger = require("logger")
local image_meta = require("Legado.Helper.image_meta")

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

-- =========================================================================
-- Transport 驱动分离：解耦同步 (LuaSocket) 与 协程异步 (Copas) 传输细节
-- =========================================================================
local SyncTransport = {}

function SyncTransport.request(opts)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")

    local response_sink
    if not opts.file_fp then
        if opts.total_timeout and opts.total_timeout > 0 then
            response_sink = socketutil.table_sink(opts.sink_table)
        else
            response_sink = ltn12.sink.table(opts.sink_table)
        end
    else
        if opts.total_timeout and opts.total_timeout > 0 then
            response_sink = socketutil.file_sink(opts.file_fp)
        else
            response_sink = ltn12.sink.file(opts.file_fp)
        end
    end

    local request = {
        url = opts.url,
        method = opts.method,
        headers = opts.headers,
        sink = response_sink,
        source = opts.source,
        redirect = opts.redirect,
        create = (opts.is_create and opts.is_http) and socketutil.tcp or nil,
    }

    socketutil:set_timeout(opts.block_timeout, opts.total_timeout)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        return nil, nil, "request interrupted:" .. tostring(code)
    end
    return code, headers, status
end

local CopasTransport = {}

function CopasTransport.request(opts)
    local copas_http = require("Legado.vendor.copas.http")
    local socket = require("socket")
    local ltn12 = require("ltn12")

    local response_sink = opts.file_fp and ltn12.sink.file(opts.file_fp) or ltn12.sink.table(opts.sink_table)

    local request = {
        url = opts.url,
        method = opts.method,
        headers = opts.headers,
        sink = response_sink,
        source = opts.source,
        redirect = opts.redirect,
        timeout = opts.block_timeout,
    }

    local pcall_ok, ok, code, headers, status = pcall(copas_http.request, request)
    if not pcall_ok then
        local err_str = type(ok) == "table" and tostring(ok[1] or ok) or tostring(ok)
        if err_str:find("timeout") then
            return nil, nil, "request interrupted:timeout"
        end
        return nil, nil, "request interrupted:" .. err_str
    end

    if not ok then
        local err_str = type(code) == "table" and tostring(code[1] or code) or tostring(code)
        if err_str:find("timeout") then
            return nil, nil, "request interrupted:timeout"
        end
        return nil, nil, "request interrupted:" .. err_str
    end
    return code, headers, status
end

local Probe = require("Legado.Helper.Probe")

local function pGetUrlContent(options, is_create)
    options = options or {}
    local socket_url = require("socket.url")

    local url = options.url
    local file_fp = options.file
    local is_pic = options.is_pic
    local is_file = file_fp ~= nil
    local method = (type(options.method) == "string" and options.method ~= "") and options.method:upper() or "GET"

    local block_timeout, total_timeout = resolve_timeouts(options, is_file)

    local function close_file()
        if file_fp then pcall(function() file_fp:close() end) end
    end

    local is_copas = Probe.is_copas()

    if type(url) ~= "string" or url == "" then
        close_file()
        Probe.fail("Http", method, '""', nil, "Invalid URL")
        return false, "Invalid URL"
    end

    local parsed = socket_url.parse(url)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        close_file()
        local reason = "Unsupported protocol: " .. tostring(parsed and parsed.scheme)
        Probe.fail("Http", method, tostring(url), nil, reason)
        return false, "Unsupported protocol"
    end

    local t_start = Probe.start("Http", method, tostring(url), string.format("(timeout: block=%ss, total=%ss)", block_timeout, total_timeout))

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
        req_headers["Accept"] = "image/png, image/jpeg, image/webp, image/bmp;q=0.9, image/tiff;q=0.8, image/*;q=0.7"
    end

    local sink = {}
    local transport = is_copas and CopasTransport or SyncTransport
    local code, headers, status = transport.request({
        url = url,
        method = method,
        headers = req_headers,
        source = options.source,
        redirect = options.redirect,
        file_fp = file_fp,
        sink_table = sink,
        block_timeout = block_timeout,
        total_timeout = total_timeout,
        is_create = is_create,
        is_http = parsed.scheme == "http",
    })

    if not code and status and status:find("^request interrupted") then
        close_file()
        Probe.fail("Http", method, tostring(url), t_start, status)
        return false, status
    end

    if headers == nil then
        close_file()
        Probe.fail("Http", method, tostring(url), t_start, "No HTTP headers")
        return false, "Network or remote server unavailable"
    end

    if type(code) ~= 'number' or code < 200 or code > 299 then
        close_file()
        Probe.fail("Http", method, tostring(url), t_start, "HTTP " .. tostring(code))
        return false, "Remote server error or unavailable"
    end

    -- 图片请求：Content-Type 明确非图片（text/*, application/json, xml）→ 提前失败
    if is_pic and headers and headers["content-type"] then
        local mime = headers["content-type"]:match("^%s*([^;%s]+)")
        if mime then
            mime = mime:lower()
            if mime:match("^text/") or mime == "application/json"
                    or mime == "application/xml"
                    or mime == "application/xhtml+xml" then
                close_file()
                Probe.fail("Http", method, tostring(url), t_start, "Invalid image MIME " .. mime)
                return false, "server error: Content-Type " .. mime
            end
        end
    end

    local content
    if not file_fp then
        content = table.concat(sink)
        if headers and headers["content-length"] and method ~= "HEAD" then
            local content_length = tonumber(headers["content-length"])
            if content_length and #content ~= content_length then
                close_file()
                Probe.fail("Http", method, tostring(url), t_start, "Incomplete content")
                return false, "Incomplete content received"
            end
        end
    end

    local extension
    local contentType = headers["content-type"]
    if contentType then
        extension = get_extension_from_mimetype(contentType)
        if not extension and (contentType:match("^%s*image/") or is_pic) then
            extension = image_meta.sniff_format(content)
        end
    end
    
    close_file()

    local size_str = is_file and "file" or Probe.format_bytes(content and #content or 0)
    Probe.done("Http", method, tostring(url), t_start, code, size_str, extension)

    return true, {
        data = content,
        ext = extension,
        headers = headers
    }
end

return pGetUrlContent
