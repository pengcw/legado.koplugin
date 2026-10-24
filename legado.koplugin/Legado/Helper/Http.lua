local logger = require("logger")
local image_meta = require("Legado.Helper.image_meta")
local Error = require("Legado.Helper.Error")

local LARGE_BLOCK_TIMEOUT = 10
local LARGE_TOTAL_TIMEOUT = 30
local FILE_BLOCK_TIMEOUT = 15
local FILE_TOTAL_TIMEOUT = 60
local DEFAULT_BLOCK_TIMEOUT = 60
local DEFAULT_TOTAL_TIMEOUT = -1

local default_headers = {
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

local function bounded_sink(sink, opts)
    local progress=opts.progress
    if not progress then return sink end
    return function(chunk, err)
        if chunk then progress.bytes_received=progress.bytes_received+#chunk end
        if opts.deadline and opts.clock() >= opts.deadline then
            progress.kind="limit_exceeded"
            return nil,"resource deadline exceeded"
        end
        if opts.max_bytes and progress.bytes_received > opts.max_bytes then
            progress.kind="limit_exceeded"
            return nil,"resource byte limit exceeded"
        end
        return sink(chunk,err)
    end
end

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
        sink = bounded_sink(response_sink, opts),
        source = opts.source,
        redirect = opts.redirect,
        proxy = opts.proxy,
        create = (opts.is_create and opts.is_http) and socketutil.tcp or nil,
    }

    socketutil:set_timeout(opts.block_timeout, opts.total_timeout)
    local ok, result, code, headers, status = pcall(http.request, request)
    socketutil:reset_timeout()
    if not ok then return nil, nil, "request interrupted:" .. Error.extract_message(result) end

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
        sink = bounded_sink(response_sink, opts),
        source = opts.source,
        redirect = opts.redirect,
        proxy = opts.proxy,
        timeout = opts.block_timeout,
    }

    local pcall_ok, ok, code, headers, status = pcall(copas_http.request, request)
    if not pcall_ok then
        local err_str = Error.extract_message(ok)
        if err_str:find("timeout") then
            return nil, nil, "request interrupted:timeout"
        end
        return nil, nil, "request interrupted:" .. err_str
    end

    if not ok then
        local err_str = Error.extract_message(code)
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
    local probe_url = options.probe_url or url
    local file_fp = options.file
    local is_pic = options.is_pic
    local is_file = file_fp ~= nil
    local method = (type(options.method) == "string" and options.method ~= "") and options.method:upper() or "GET"

    local block_timeout, total_timeout = resolve_timeouts(options, is_file)
    local clock=options.clock or os.time
    local progress=(options.max_bytes or options.deadline) and {bytes_received=0}
    local function failed(message, kind, known)
        return false,message,progress and {bytes_received=known and progress.bytes_received or nil,
            kind=kind or progress.kind or "download_failed"}
    end

    local function close_file()
        if file_fp then pcall(function() file_fp:close() end) end
    end

    if options.deadline then
        local remaining=options.deadline-clock()
        if remaining <= 0 then
            close_file()
            return failed("request interrupted:deadline","limit_exceeded",true)
        end
        block_timeout=math.min(block_timeout,remaining)
        total_timeout=total_timeout > 0 and math.min(total_timeout,remaining) or remaining
    end
    local is_copas = Probe.is_copas()

    if type(url) ~= "string" or url == "" then
        close_file()
        Probe.fail("Http", method, '""', nil, "Invalid URL")
        return failed("Invalid URL")
    end

    local parsed = socket_url.parse(url)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        close_file()
        local reason = "Unsupported protocol: " .. tostring(parsed and parsed.scheme)
        Probe.fail("Http", method, probe_url, nil, options.probe_url and "Unsupported protocol" or reason)
        return failed("Unsupported protocol")
    end

    local t_start = Probe.start("Http", method, probe_url, function()
        return string.format("(timeout: block=%ss, total=%ss)", block_timeout, total_timeout)
    end)

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
        proxy = options.proxy,
        progress = progress,
        max_bytes = options.max_bytes,
        deadline = options.deadline,
        clock = clock,
        file_fp = file_fp,
        sink_table = sink,
        block_timeout = block_timeout,
        total_timeout = total_timeout,
        is_create = is_create,
        is_http = parsed.scheme == "http",
    })

    if progress and (progress.kind or (options.deadline and clock() >= options.deadline)) then
        close_file()
        Probe.fail("Http", method, probe_url, t_start, "Resource receive limit exceeded")
        return failed("Resource receive limit exceeded","limit_exceeded",progress.kind~=nil or type(code)=="number")
    end
    if not code and status and status:find("^request interrupted") then
        close_file()
        Probe.fail("Http", method, probe_url, t_start, options.probe_url and "Request interrupted" or status)
        return failed(status)
    end

    if headers == nil then
        close_file()
        Probe.fail("Http", method, probe_url, t_start, "No HTTP headers")
        return failed("Network or remote server unavailable")
    end

    if type(code) ~= 'number' or (not options.raw_response and (code < 200 or code > 299)) then
        close_file()
        Probe.fail("Http", method, probe_url, t_start, "HTTP " .. tostring(code))
        return failed("Remote server error or unavailable")
    end

    if is_pic and headers and headers["content-type"] then
        local mime = headers["content-type"]:match("^%s*([^;%s]+)")
        if mime then
            mime = mime:lower()
            if mime:match("^text/") or mime == "application/json"
                    or mime == "application/xml"
                    or mime == "application/xhtml+xml" then
                close_file()
                Probe.fail("Http", method, probe_url, t_start, options.probe_url and "Invalid image MIME" or ("Invalid image MIME " .. mime))
                return failed("server error: Content-Type " .. mime)
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
                Probe.fail("Http", method, probe_url, t_start, "Incomplete content")
                return failed("Incomplete content received")
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

    Probe.done("Http", method, probe_url, t_start, code, function()
        return is_file and "file" or Probe.format_bytes(content and #content or 0)
    end, extension)

    return true, {
        data = content,
        ext = extension,
        headers = headers,
        code = code,
        bytes_received = progress and progress.bytes_received,
    }
end

return pGetUrlContent
