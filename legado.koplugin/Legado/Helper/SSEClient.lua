local socket = require("socket")
local ssl = require("ssl")
local socket_url = require("socket.url")
local time = require("ui/time")
local UIManager = require("ui/uimanager")

local SSEClient = {}

local DEFAULT_HEADERS = {
    ["Accept"] = "text/event-stream",
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    ["Connection"] = "keep-alive",
}

-- ==================== chunked_decoder ====================
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

    -- 解析 size 行（hex + 可选 ;ext）；返回 true=终止块，false=进入 data，nil,err=失败
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
                -- size 行已见 \r，必须紧跟 \n（宽松兼容裸 \n 已在 size 状态处理）
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

-- sse_parser
local MAX_SSE_LINE = 256 * 1024
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
            return nil  -- SSE 注释行
        end        if line:sub(1, 6) == "event:" then
            local v = line:sub(7)
            if v:sub(1, 1) == " " then v = v:sub(2) end
            event = v
        elseif line:sub(1, 5) == "data:" then
            local v = line:sub(6)
            if v:sub(1, 1) == " " then v = v:sub(2) end
            data_lines[#data_lines + 1] = v
        end
        -- id: / retry: 忽略
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
            if #line > MAX_SSE_LINE then
                set_error("SSE 行过长")
                return {}, true
            end
            if crlf and crlf == idx then
                buf = buf:sub(idx + 2)
            else
                buf = buf:sub(idx + 1)
            end
            local evt, data = process_line(line)
            if evt then
                dispatched[#dispatched + 1] = { evt, data }
            end
        end
        return dispatched
    end

    return {
        push = push,
        get_error = function() return err_msg end,
    }
end

SSEClient._parsers = {
    chunked_decoder = chunked_decoder,
    sse_parser = sse_parser,
}

-- 批量读取：receive(n) 失败时第三返回值 partial 携带已读数据（零丢失）
local function receive_available(sock, max_bytes)
    local data, rerr, partial = sock:receive(max_bytes)
    if data then
        return data, rerr
    end
    if partial and partial ~= "" then
        return partial, rerr
    end
    return nil, rerr
end

-- 建立 TCP/TLS 连接；remaining() 为 open() 起的剩余秒数，各阶段超时取 min(阶段, remaining)
local function do_connect(url, connect_timeout, verify, remaining)
    local parsed = socket_url.parse(url)
    if not (parsed and parsed.host and parsed.scheme) then
        return nil, "无效 URL：" .. tostring(url)
    end
    local scheme = parsed.scheme
    local host = parsed.host
    local port = tonumber(parsed.port) or (scheme == "https" and 443 or 80)

    local sock = socket.tcp()
    -- 清除 socketutil 注入的 "t" 总超时，避免 SSE 长连接被强制掐断（实测被断开）
    pcall(function() sock:settimeout(-1, "t") end)
    local connect_to = connect_timeout or 8
    if remaining then connect_to = math.min(connect_to, remaining()) end
    if connect_to <= 0 then
        pcall(function() sock:close() end)
        return nil, "连接超时"
    end
    sock:settimeout(connect_to)
    local ok_c, err_c = sock:connect(host, port)
    if not ok_c then
        pcall(function() sock:close() end)
        return nil, "连接失败：" .. tostring(err_c)
    end
    if scheme == "https" then
        local ok_w, sock_w = pcall(function()
            local s = ssl.wrap(sock, {
                mode = "client",
                protocol = "any",
                -- 禁用旧协议：避免服务器因 TLS 版本不匹配直接断开（实测 send 即 closed）
                options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
                verify = verify and "required" or "none",
            })
            -- SNI：兼容 Envoy/CF 类服务器；不同 LuaSec 版本返回值不一致，失败不中止（非必需项）
            if s.sni then
                pcall(s.sni, s, host)
            end
            -- 握手必须用长超时（与 https.lua 一致）：实测短超时握手后 send 即被断开
            local hs_to = 60
            if remaining then hs_to = math.min(hs_to, remaining()) end
            if hs_to <= 0 then
                error("连接超时")
            end
            s:settimeout(hs_to)
            s:dohandshake()
            return s
        end)
        if not ok_w then
            pcall(function() sock:close() end)
            return nil, "TLS 握手失败：" .. tostring(sock_w)
        end
        sock = sock_w
    end
    return sock, nil, host, port, parsed
end

-- 发送 HTTP GET 请求（循环发送确保完整：大 URL 可能部分发送）
local function send_get_request(sock, headers, host, port, parsed)
    local merged = {}
    for k, v in pairs(DEFAULT_HEADERS) do merged[k] = v end
    if headers then
        for k, v in pairs(headers) do merged[k] = v end
    end

    local target = parsed.path or "/"
    if parsed.params and parsed.params ~= "" then
        target = target .. ";" .. parsed.params
    end
    if parsed.query and parsed.query ~= "" then
        target = target .. "?" .. parsed.query
    end

    local host_header
    if host:find(":") and not host:find("[") then
        host_header = "[" .. host .. "]"
    else
        host_header = host
    end
    local default_port = parsed.scheme == "https" and 443 or 80
    if port ~= default_port then
        host_header = host_header .. ":" .. port
    end

    local lines = {
        "GET " .. target .. " HTTP/1.1",
        "Host: " .. host_header,
    }
    for k, v in pairs(merged) do
        lines[#lines + 1] = k .. ": " .. v
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
    local req = table.concat(lines, "\r\n")

    local sent = 0
    while sent < #req do
        local n, err_s = sock:send(req:sub(sent + 1))
        if not n then
            return false, "请求发送失败：" .. tostring(err_s)
        end
        sent = sent + n
    end
    return true
end

function SSEClient.open(opts)
    opts = opts or {}
    local url = opts.url
    if not (type(url) == "string" and url ~= "") then
        error("SSEClient.open: url 必填")
    end

    local on_event = opts.on_event or function() end
    local on_close = opts.on_close or function() end
    local on_headers = opts.on_headers or function() end
    local total_timeout = opts.timeout or 120
    local read_timeout = opts.read_timeout or 0.2
    local connect_timeout = opts.connect_timeout or 8
    local require_event_stream = opts.require_event_stream ~= false
    -- 证书校验默认关闭（兼容自签名/局域网；严格校验需 opts.verify=true）
    local verify = opts.verify == true

    local decoder = chunked_decoder()
    local sse = sse_parser()
    local stream_state = "headers"
    local http_code = nil
    local response_headers = {}
    local sock = nil

    -- 总生命周期 deadline：connect/TLS/读取各阶段共用 remaining() 约束
    local deadline = time.now() + time.s(total_timeout)
    local function remaining()
        return math.max(0, deadline - time.now())
    end

    local task = {
        is_done = false,
        start_time = time.now(),
        timeout = total_timeout,
    }
    local zmq_ref = nil

    local function close_sock()
        if sock then
            pcall(function() sock:close() end)
            sock = nil
        end
    end

    -- 通知结束（幂等）：err=nil 表示正常流结束
    local function finish(err)
        if task.is_done then return end
        task.is_done = true
        if zmq_ref then UIManager:removeZMQ(zmq_ref) zmq_ref = nil end
        close_sock()
        pcall(on_close, err)
    end

    local function connect()
        local ok_d, err_d, host, port, parsed = do_connect(url, connect_timeout, verify, remaining)
        if not ok_d then
            finish(err_d)
            return false
        end
        sock = ok_d
        local ok_s, err_s = send_get_request(sock, opts.headers, host, port, parsed)
        if not ok_s then
            finish(err_s)
            return false
        end
        return true
    end

    -- 逐行读响应头；receive("*l") 失败时 partial 携带半行数据，必须跨轮拼接
    -- （服务器惰性发头/分片到达时头部可能被切断，实测丢失）
    local header_line_buf = ""
    local header_total = 0
    local MAX_HEADER_LINE = 16 * 1024
    local MAX_HEADER_TOTAL = 64 * 1024
    local function read_headers_step()
        while true do
            local line, err, partial = sock:receive("*l")
            if line then
                line = header_line_buf .. line
                header_line_buf = ""
                header_total = header_total + #line
                if header_total > MAX_HEADER_TOTAL then
                    return nil, "响应头过大"
                end
                if http_code == nil then
                    local code = line:match("^HTTP/%d%.%d%s+(%d%d%d)%s*.*$")
                    if not code then
                        return nil, "非法 HTTP 状态行"
                    end
                    http_code = code
                elseif line == "" then
                    if http_code ~= "200" then
                        return nil, "服务器返回 " .. tostring(http_code or "未知状态码")
                    end
                    -- 仅支持 chunked：避免把 Content-Length 定长响应误当 chunk 解码（实测）
                    local te = response_headers["transfer-encoding"] or ""
                    if not te:lower():find("chunked", 1, true) then
                        return nil, "服务器未使用 chunked Transfer-Encoding"
                    end
                    if response_headers["content-length"] then
                        return nil, "Transfer-Encoding 与 Content-Length 冲突"
                    end
                    if require_event_stream then
                        local content_type = response_headers["content-type"] or ""
                        if not content_type:find("text/event%-stream", 1) then
                            return nil, "服务器响应格式错误（非 event-stream）"
                        end
                    end
                    local ok_h, err_h = pcall(on_headers, http_code, response_headers)
                    if not ok_h then
                        return nil, "响应头回调异常：" .. tostring(err_h)
                    end

                    stream_state = "body"
                    return true
                else
                    if #line > MAX_HEADER_LINE then
                        return nil, "响应头行过长"
                    end
                    local k, v = line:match("^([^:]+):%s*(.*)$")
                    if k then response_headers[string.lower(k)] = v end
                end
            elseif err == "timeout" or err == "wantread" then
                if partial and partial ~= "" then
                    header_line_buf = header_line_buf .. partial
                    if #header_line_buf > MAX_HEADER_LINE then
                        return nil, "响应头行过长"
                    end
                end
                return false
            else
                return nil, "读取响应失败：" .. tostring(err)
            end
        end
    end

    local function on_data(raw)
        local done = decoder.decode(raw)
        local dec_err = decoder.get_error()
        if dec_err then
            finish("chunked 解码失败：" .. dec_err)
            return
        end
        local decoded = decoder.get_output()
        if decoded ~= "" then
            local events = sse.push(decoded)
            local sse_err = sse.get_error()
            if sse_err then
                finish("SSE 解析失败：" .. sse_err)
                return
            end
            for _, evt in ipairs(events) do
                -- 业务回调异常不吞掉：终止连接并报告
                local ok_ev, err_ev = pcall(on_event, evt[1], evt[2])
                if not ok_ev then
                    finish("事件回调异常：" .. tostring(err_ev))
                    return
                end
            end
        end
        if done then
            finish(nil)  -- 终止块（0）到达：正常流结束
        end
    end

    function task:waitEvent()
        if task.is_done then return nil end
        if remaining() <= 0 then
            finish("连接超时")
            return nil
        end
        if not sock then
            finish("连接未建立")
            return nil
        end
        local recvt = socket.select({ sock }, nil, 0)
        if #recvt > 0 then
            -- 阻塞模式短超时：行/字节读取超时后下轮 select 再读；受总 deadline 约束
            sock:settimeout(math.min(read_timeout, remaining()))
            if stream_state == "headers" then
                local ok_h, err_h = read_headers_step()
                if err_h then
                    finish(err_h)
                    return nil
                end
                if not ok_h then
                    return nil
                end
            end
            local data, rerr = receive_available(sock, 8192)
            if data and data ~= "" then
                local ok, perr = pcall(on_data, data)
                if not ok then
                    finish("数据解析出错：" .. tostring(perr))
                end
            end
            if rerr == "closed" then
                -- 服务器关闭连接：正常流结束（业务层用 finish_sent 区分是否已收 end 事件）；
                -- 注意 receive 可能同时返回 partial 数据 + closed（数据已在上方处理）
                if task.is_done then
                    return nil
                end
                finish(nil)
                return nil
            end
        end
        return nil
    end

    function task:stop()
        finish(nil)
    end

    if not connect() then
        return {
            is_done = function() return true end,
            cancel = function() end,
        }
    end

    zmq_ref = UIManager:insertZMQ(task)

    return {
        is_done = function() return task.is_done end,
        cancel = function()
            if not task.is_done then
                finish("已取消")
            end
        end,
    }
end

return SSEClient
