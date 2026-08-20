local socket = require("socket")
local socket_url = require("socket.url")
local logger = require("logger")
local copas = require("Legado.vendor.copas")

local M = {}

local DEFAULT_HEADERS = {
    ["Accept"] = "text/event-stream",
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    ["Connection"] = "keep-alive",
    ["Cache-Control"] = "no-cache",
}

local MAX_CHUNK_LINE = 4096
local MAX_CHUNK_SIZE = 16 * 1024 * 1024

local function chunked_decoder()
    local state = "size"
    local size = 0
    local size_buf = {}
    local out = {}
    local finished = false
    local err_msg = nil

    local function set_error(msg)
        if not err_msg then
            err_msg = msg
            finished = true
        end
        return true
    end

    local function parse_size_line()
        local size_line = table.concat(size_buf)
        size_buf = {}
        local size_str = size_line:match("^([0-9a-fA-F]+)")
        if not size_str then
            return set_error("非法 chunk size 行")
        end
        local rest = size_line:sub(#size_str + 1)
        if rest ~= "" and rest:sub(1, 1) ~= ";" then
            return set_error("非法 chunk size 行")
        end
        size = tonumber(size_str, 16)
        if not size then
            return set_error("chunk size 超出范围")
        end
        if size == 0 then
            finished = true
            return true
        end
        if size > MAX_CHUNK_SIZE then
            return set_error("chunk 数据块过大")
        end
        state = "data"
        return false
    end

    local function decode(input)
        if finished then return true end
        local i, n = 1, #input
        while i <= n do
            local c = input:sub(i, i)
            if state == "size" then
                if c == "\r" then
                    state = "size_cr"
                    i = i + 1
                elseif c == "\n" then
                    i = i + 1
                    if parse_size_line() then return true end
                else
                    size_buf[#size_buf + 1] = c
                    if #size_buf > MAX_CHUNK_LINE then
                        return set_error("chunk size 行过长")
                    end
                    i = i + 1
                end
            elseif state == "size_cr" then
                if c ~= "\n" then
                    return set_error("chunk size 行结尾非法")
                end
                i = i + 1
                if parse_size_line() then return true end
            elseif state == "data" then
                local take = math.min(size, n - i + 1)
                out[#out + 1] = input:sub(i, i + take - 1)
                size = size - take
                i = i + take
                if size == 0 then state = "crlf" end
            elseif state == "crlf" then
                if c == "\r" then
                    state = "crlf_lf"
                    i = i + 1
                elseif c == "\n" then
                    state = "size"
                    i = i + 1
                else
                    return set_error("chunk 数据块后缺少 CRLF")
                end
            elseif state == "crlf_lf" then
                if c ~= "\n" then
                    return set_error("chunk 数据块后的 CRLF 非法")
                end
                state = "size"
                i = i + 1
            end
        end
        return finished
    end

    local function get_output()
        local s = table.concat(out)
        out = {}
        return s
    end

    return {
        decode = decode,
        get_output = get_output,
        is_done = function() return finished end,
        get_error = function() return err_msg end,
    }
end

local MAX_SSE_LINE = 1 * 1024 * 1024
local MAX_SSE_EVENT = 8 * 1024 * 1024

local function sse_parser()
    local buf = ""
    local event = "message"
    local data_lines = {}
    local err_msg = nil

    local function set_error(msg)
        if not err_msg then err_msg = msg end
        return true
    end

    local function process_line(line)
        if line == "" then
            if #data_lines > 0 then
                local evt = event
                local data = table.concat(data_lines, "\n")
                event = "message"
                data_lines = {}
                return evt, data
            end
            return nil
        end
        if line:sub(1, 1) == ":" then
            return nil
        end
        if line:sub(1, 6) == "event:" then
            local v = line:sub(7)
            if v:sub(1, 1) == " " then v = v:sub(2) end
            event = v
        elseif line:sub(1, 5) == "data:" then
            local v = line:sub(6)
            if v:sub(1, 1) == " " then v = v:sub(2) end
            data_lines[#data_lines + 1] = v
        end
        return nil
    end

    local function push(chunk)
        buf = buf .. chunk
        if #buf > MAX_SSE_EVENT then
            set_error("SSE 事件过大")
            return {}, true
        end
        local dispatched = {}
        while true do
            local crlf = buf:find("\r\n", 1, true)
            local lf = buf:find("\n", 1, true)
            local idx
            if crlf and lf then idx = math.min(crlf, lf)
            elseif crlf then idx = crlf
            elseif lf then idx = lf
            else break end
            local line = buf:sub(1, idx - 1)
            local skip_line = false
            if #line > MAX_SSE_LINE then
                logger.warn(string.format("[SSEClientCopas] SSE 行过长: %d 字节，跳过该行（head: %s）",
                    #line, line:sub(1, 80)))
                skip_line = true
            end
            if crlf and crlf == idx then
                buf = buf:sub(idx + 2)
            else
                buf = buf:sub(idx + 1)
            end
            if not skip_line then
                local evt, data = process_line(line)
                if evt then
                    dispatched[#dispatched + 1] = { evt, data }
                end
            end
        end
        return dispatched
    end

    return {
        push = push,
        get_error = function() return err_msg end,
    }
end

M._parsers = {
    chunked_decoder = chunked_decoder,
    sse_parser = sse_parser,
}

function M.open(opts)
    opts = opts or {}
    local url = opts.url
    if not url or url == "" then
        error("url 必填")
    end

    local on_event = opts.on_event or function() end
    local on_close = opts.on_close or function() end
    local timeout = opts.timeout or 60
    local connect_timeout = opts.connect_timeout or 8
    local custom_headers = opts.headers or {}

    local parsed = socket_url.parse(url)
    if not (parsed and parsed.host and parsed.scheme) then
        error("无效 URL：" .. tostring(url))
    end

    local is_ssl = (parsed.scheme == "https")
    local host = parsed.host
    local port = tonumber(parsed.port) or (is_ssl and 443 or 80)
    local path = (parsed.path and parsed.path ~= "") and parsed.path or "/"
    if parsed.query and parsed.query ~= "" then
        path = path .. "?" .. parsed.query
    end

    local done = false
    local err_result = nil
    local raw_sock = nil
    local wrapped_sock = nil

    local function unwrap_err(err)
        if type(err) == "string" then return err end
        if type(err) == "table" then
            return err[1] or err.message or err.error or err.errorMsg or err.reason or err.err or tostring(err)
        end
        return err and tostring(err) or nil
    end

    local function finish(err)
        if done then return end
        done = true
        err_result = unwrap_err(err)
        if wrapped_sock then
            pcall(function() copas.close(wrapped_sock) end)
            raw_sock = nil
            wrapped_sock = nil
        elseif raw_sock then
            pcall(function() raw_sock:close() end)
            raw_sock = nil
        end
        if type(on_close) == "function" then
            pcall(on_close, err_result)
        end
    end

    local handle = {}
    function handle:is_done() return done end
    function handle:cancel()
        if not done then
            finish("已取消")
        end
    end

    local decoder = chunked_decoder()
    local sse = sse_parser()
    local deadline = (timeout and timeout > 0) and (socket.gettime() + timeout) or nil

    copas.addthread(function()
        local tcp = socket.tcp()
        raw_sock = tcp
        pcall(function() tcp:settimeout(-1, "t") end)
        tcp:settimeout(connect_timeout)

        local ok_c, cerr = tcp:connect(host, port)
        if not ok_c then
            finish("连接失败：" .. tostring(cerr))
            return
        end

        if is_ssl then
            local ok_ssl, luasec = pcall(require, "ssl")
            if not ok_ssl or not luasec then
                finish("未安装 LuaSec，无法建立 HTTPS SSE 连接")
                return
            end
            local ssl_params = {
                mode = "client",
                protocol = "any",
                verify = "none",
                options = "all",
            }
            local ok_w, sec_sock = pcall(luasec.wrap, tcp, ssl_params)
            if not ok_w or not sec_sock then
                finish("TLS 包装失败：" .. tostring(sec_sock))
                return
            end
            raw_sock = sec_sock
            local ok_h, herr = sec_sock:dohandshake()
            if not ok_h then
                finish("TLS 握手失败：" .. tostring(herr))
                return
            end
        end

        wrapped_sock = copas.wrap(raw_sock)

        local req_lines = { string.format("GET %s HTTP/1.1", path) }
        req_lines[#req_lines + 1] = string.format("Host: %s", (port == 80 or port == 443) and host or (host .. ":" .. port))
        for k, v in pairs(DEFAULT_HEADERS) do
            if custom_headers[k] == nil then
                req_lines[#req_lines + 1] = string.format("%s: %s", k, v)
            end
        end
        for k, v in pairs(custom_headers) do
            req_lines[#req_lines + 1] = string.format("%s: %s", k, v)
        end
        req_lines[#req_lines + 1] = "\r\n"

        local req_data = table.concat(req_lines, "\r\n")
        local ok_s, serr = wrapped_sock:send(req_data)
        if not ok_s then
            finish("发送请求失败：" .. tostring(serr))
            return
        end

        -- 5. 读取 HTTP 响应状态行与响应头
        local status_line, rerr = wrapped_sock:receive("*l")
        if not status_line then
            finish("读取响应状态行失败：" .. tostring(rerr))
            return
        end

        local status_code = tonumber(status_line:match("^HTTP/%d+%.%d+%s+(%d+)"))
        if not status_code or status_code < 200 or status_code >= 300 then
            finish("HTTP 响应状态码异常: " .. tostring(status_line))
            return
        end

        local is_chunked = false
        while not done do
            local header_line, herr = wrapped_sock:receive("*l")
            if not header_line then
                finish("读取响应头中断：" .. tostring(herr))
                return
            end
            if header_line == "" then
                break -- 响应头读取完毕，进入数据流阶段
            end
            local k, v = header_line:match("^([^:]+):%s*(.*)$")
            if k and string.lower(k) == "transfer-encoding" and string.lower(v):find("chunked") then
                is_chunked = true
            end
        end

        while not done do
            if deadline and socket.gettime() >= deadline then
                finish("连接超时")
                return
            end

            local line, derr = wrapped_sock:receive("*l")
            if line then
                local sse_data = line .. "\n"
                if is_chunked then
                    local chunk_done = decoder.decode(sse_data)
                    local dec_err = decoder.get_error()
                    if dec_err then
                        finish("Chunked 解码失败: " .. dec_err)
                        return
                    end
                    sse_data = decoder.get_output()
                    if chunk_done and sse_data == "" then
                        finish(nil)
                        return
                    end
                end

                if sse_data and #sse_data > 0 then
                    local events = sse.push(sse_data)
                    local sse_err = sse.get_error()
                    if sse_err then
                        finish("SSE 解析失败: " .. sse_err)
                        return
                    end
                    for _, evt in ipairs(events) do
                        local ok_ev, err_ev = pcall(on_event, evt[1], evt[2])
                        if not ok_ev then
                            logger.warn("[SSEClientCopas] on_event 回调异常: " .. tostring(err_ev))
                        end
                    end
                end
            end

            if derr == "closed" then
                finish(nil)
                return
            elseif derr and derr ~= "timeout" and derr ~= "wantread" then
                finish("网络连接异常: " .. tostring(derr))
                return
            end
        end
    end)

    return handle
end

return M
