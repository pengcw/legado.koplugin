local bit = require("bit")
local socket = require("socket")
local logger = require("logger")
-- ffi/netinfo 仅 KOReader > 2025.8有
local netinfo
local net_info_ok = pcall(function()
    netinfo = require("ffi/netinfo")
end)

local M = {}

local MAX_U32 = 4294967296
local function ip2num(ip)
    if type(ip) ~= "string" then return nil end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function num2ip(n)
    return string.format("%d.%d.%d.%d",
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

local function swap32(n)
    n = n % MAX_U32
    return ((n % 256) * 16777216)
        + (math.floor(n / 256) % 256) * 65536
        + (math.floor(n / 65536) % 256) * 256
        + (math.floor(n / 16777216) % 256)
end

function M:getNetmask(ip)
    local f = io.open("/proc/net/route")
    if not f then
        logger.warn("NetProbe: /proc/net/route 无法打开（权限受限）")
        return nil
    end
    local target = ip2num(ip)
    local best = nil
    for line in f:lines() do
        local iface, dest, mask = line:match("^(%S+)%s+([%x]+)%s+[%x]+%s+[%x]+%s+%d+%s+%d+%s+%d+%s+([%x]+)")
        if iface and dest and mask then
            local dest_n = swap32(tonumber(dest, 16))
            local mask_n = swap32(tonumber(mask, 16))
            if mask_n ~= 0 and mask_n ~= MAX_U32 - 1 then
                logger.dbg("NetProbe: route行 iface=", iface, "dest=", num2ip(dest_n), "mask=", num2ip(mask_n))
                if bit.band(bit.tobit(target), bit.tobit(mask_n)) % MAX_U32
                        == bit.band(bit.tobit(dest_n), bit.tobit(mask_n)) % MAX_U32 then
                    if not best or mask_n > best then best = mask_n end
                end
            end
        end
    end
    f:close()
    if not best then
        logger.warn("NetProbe: /proc/net/route 未找到包含本机 ", ip, " 的网段路由")
        return nil
    end
    local mask = num2ip(best)
    return mask
end

-- 多网卡时取实际上网接口
local function getDefaultRouteIface()
    local f = io.open("/proc/net/route")
    if not f then return nil end
    for line in f:lines() do
        local iface, dest = line:match("^(%S+)%s+([%x]+)%s")
        if iface and dest == "00000000" then
            f:close()
            return iface
        end
    end
    f:close()
    return nil
end

function M:getLocalIPv4()
    if net_info_ok and netinfo then
        local ok, ifaces = pcall(function()
            return netinfo:new():retrieve()
        end)
        if ok and type(ifaces) == "table" then
            local default_iface = getDefaultRouteIface()
            if default_iface then
                for _, iface in ipairs(ifaces) do
                    if iface.name == default_iface and type(iface.ipv4) == "string" then
                        local ip = iface.ipv4:match("(%d+%.%d+%.%d+%.%d+)")
                        if ip then
                            logger.dbg("NetProbe: 本机IP(netinfo)", iface.name, ip)
                            return ip
                        end
                    end
                end
                logger.warn("NetProbe: 默认路由接口 ", default_iface, " 未匹配到 IPv4，回退遍历")
            end
            for _, iface in ipairs(ifaces) do
                if iface.name ~= "lo" and type(iface.ipv4) == "string" then
                    local ip = iface.ipv4:match("(%d+%.%d+%.%d+%.%d+)")
                    if ip then
                        logger.dbg("NetProbe: 本机IP(netinfo)", iface.name, ip)
                        return ip
                    end
                end
            end
            logger.warn("NetProbe: netinfo 未返回 IPv4 接口，尝试 UDP 兜底")
        else
            logger.warn("NetProbe: netinfo 获取接口失败，尝试 UDP 兜底", tostring(ifaces))
        end
    end
    -- UDP 兜底
    local ok_u, udp = pcall(function() return socket.udp() end)
    if ok_u and udp then
        local ok_peer = pcall(function() return udp:setpeername("8.8.8.8", 80) end)
        local ip = ok_peer and udp:getsockname() or nil
        pcall(function() udp:close() end)
        if ip and ip:match("^(%d+%.%d+%.%d+%.%d+)$") then
            logger.dbg("NetProbe: 本机IP(UDP兜底)", ip)
            return ip
        end
        logger.warn("NetProbe: UDP 兜底也失败", tostring(ip))
    end
    return nil
end

function M:getScanRange(ip, netmask)
    local ip_n = ip2num(ip)
    local mask_n = ip2num(netmask or "255.255.255.0")
    if not ip_n or not mask_n then
        logger.warn("NetProbe: 无效 IP/掩码", tostring(ip), tostring(netmask))
        return nil
    end
    local network = bit.band(bit.tobit(ip_n), bit.tobit(mask_n)) % MAX_U32
    local broadcast = (network + (MAX_U32 - 1 - mask_n)) % MAX_U32
    logger.dbg("NetProbe: 网段", num2ip(network), "~", num2ip(broadcast), "(本机", ip .. ")")
    return { first = network + 1, last = broadcast - 1 }
end

local function probeHosts(ips, ports, options)
    local results = {}      -- { ip = ip, port = port } 列表
    local concurrency = options.concurrency or 32
    local wait = options.timeout or 0.3
    local total_timeout = options.total_timeout or 10
    local retry = options.retry or 2
    local callback = options.callback

    if type(ports) == "number" then ports = { ports } end
    logger.dbg("NetProbe: 开始探测", #ips, "个IP x", #ports, "个端口, 并发", concurrency, "每轮", wait, "s, 总时限", total_timeout, "s")

    local queue = {}
    for i = #ips, 1, -1 do
        for _, port in ipairs(ports) do
            queue[#queue + 1] = { ip = ips[i], port = port }
        end
    end

    local socks = {}       -- 在途 socket
    local info_of = {}     -- sock -> { ip, port }
    local in_flight = 0
    local rounds = 0
    local diag_conn_errs = 0
    local deadline = socket.gettime() + total_timeout

    local function record(ip, port)
        local entry = { ip = ip, port = port }
        results[#results + 1] = entry
        logger.dbg("NetProbe: 命中", ip, port)
        if callback then pcall(callback, entry) end
    end

    local function start_next()
        while in_flight < concurrency and #queue > 0 do
            local item = table.remove(queue)
            local sock = socket.tcp()
            sock:settimeout(0) -- 非阻塞
            local ok, err = sock:connect(item.ip, item.port)
            if ok then
                pcall(function() sock:close() end)
                record(item.ip, item.port)
            else
                -- 非阻塞 connect 的正常返回是 timeout（EINPROGRESS 等 select）；其他错误抽样记录
                if err and err ~= "timeout" and err ~= "in progress" and diag_conn_errs < 3 then
                    diag_conn_errs = diag_conn_errs + 1
                    logger.warn("NetProbe: connect 立即失败", item.ip, item.port, tostring(err))
                end
                socks[#socks + 1] = sock
                info_of[sock] = item
                in_flight = in_flight + 1
            end
        end
    end
    -- 未就绪的连接重新入队重试；就绪（连通或被拒）的不重试
    start_next()
    while (in_flight > 0 or #queue > 0) and socket.gettime() < deadline do
        rounds = rounds + 1
        local _, ready
        if #socks > 0 then
            _, ready = socket.select(nil, socks, wait)
        end
        ready = ready or {}
        local ready_set = {}
        for _, s in ipairs(ready) do ready_set[s] = true end
        for _, s in ipairs(socks) do
            local item = info_of[s]
            if ready_set[s] then
                if s:getpeername() then record(item.ip, item.port) end
            elseif (item.retries or 0) < retry then
                item.retries = (item.retries or 0) + 1
                queue[#queue + 1] = item
            end
            pcall(function() s:close() end)
            info_of[s] = nil
            in_flight = in_flight - 1
        end
        socks = {}
        start_next()
    end
    logger.dbg("NetProbe: 探测完成", #results, "个命中, 共", rounds, "轮",
        (socket.gettime() >= deadline and "(已达总时限)" or ""))
    return results
end

local MAX_BODY = 4096
local function httpGet(ip, port, path, timeout, max_body)
    local sock = socket.tcp()
    sock:settimeout(timeout or 1)
    -- 清除 socketutil 注入的 total timeout（插件其他模块会留正值），避免慢响应被掐断
    pcall(function() sock:settimeout(-1, "t") end)
    local ok = sock:connect(ip, port)
    if not ok then pcall(function() sock:close() end) return nil end
    -- Host 带端口（HTTP/1.1 规范，非默认端口时）
    local req = "GET " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. ip .. ":" .. port .. "\r\n"
        .. "Connection: close\r\n\r\n"
    local sent = sock:send(req)
    if not sent then pcall(function() sock:close() end) return nil end
    -- 校验 status line：非 HTTP 服务（如 SSH banner）不误判为 HTTP
    local status_line = sock:receive("*l")
    if not status_line then pcall(function() sock:close() end) return nil end
    local code = status_line:match("^HTTP/%d+%.%d+%s+(%d%d%d)")
    if not code then pcall(function() sock:close() end) return nil end
    local content_length = nil
    while true do
        local line = sock:receive("*l")
        if not line then pcall(function() sock:close() end) return nil end
        if line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k and k:lower() == "content-length" then content_length = tonumber(v) end
    end
    -- body 限长读取：探测场景只需响应前缀（如 isLegado 的 web/legado_test），
    -- 避免 keep-alive/chunked/大 body 造成长时间读取
    local limit = max_body or MAX_BODY
    local body
    if content_length and content_length <= limit then
        body = sock:receive(content_length)
    else
        body = sock:receive(limit) -- 读满 limit 或连接关闭/超时即返回已读部分
        if not body then body = sock:receive("*a") end
    end
    pcall(function() sock:close() end)
    return tonumber(code), body
end

function M:getNetwork(options)
    options = options or {}
    local ip = options.ip or self:getLocalIPv4()
    if not ip then return nil, "无法确定本机网络" end
    local netmask = options.netmask or self:getNetmask(ip) or "255.255.255.0"
    local range = self:getScanRange(ip, netmask)
    if not range then return nil, "无法确定本机网络" end
    logger.dbg("NetProbe: 网络 ip=", ip, "netmask=", netmask)
    return {
        ip = ip,
        netmask = netmask,
        first = range.first,
        last = range.last,
    }
end

function M:scan(port, options)
    options = options or {}
    local net, err = self:getNetwork(options)
    if not net then return nil, err end
    local max_hosts = options.max_hosts or 512
    local host_count = net.last - net.first + 1
    if host_count > max_hosts then
        logger.warn("NetProbe: 网段过大（", host_count, " 主机）超过上限 ", max_hosts)
        return nil, "network too large"
    end
    local ips = {}
    for n = net.first, net.last do
        ips[#ips + 1] = num2ip(n)
    end
    return probeHosts(ips, port or 80, options)
end

function M:scanHTTP(port, path, options)
    options = options or {}
    local hits = self:scan(port, options)
    if not hits then return nil end
    local results = {}
    for _, hit in ipairs(hits) do
        local status, body = httpGet(hit.ip, hit.port, path or "/", options.timeout or 1)
        if status then
            local entry = { ip = hit.ip, port = hit.port, status = status, body = body }
            results[#results + 1] = entry
            if options.callback then pcall(options.callback, entry) end
        end
    end
    return results
end

function M:isLegado(ip, port, options)
    options = options or {}
    local status, body = httpGet(ip, port, "/legado_test", options.timeout or 2)
    return status == 200 and body ~= nil and body:find("web/legado_test", 1, true) ~= nil
end

-- 通断检测：任意 http/https URL，收到 HTTP 响应（任意状态码）即在线。
-- 走 socket.http（自动 TLS/SNI，支持重定向），区别于局域网 httpGet 的裸 TCP。
-- 用 HEAD 请求：socket.http 对 HEAD 不读 body（http.lua shouldreceivebody），
-- 避免 body 慢/不完整导致的误判；总时限由 socketutil.table_sink 强制
-- （socket 级 total 超时基本不触发，socketutil里面有注释）
function M:check(url, options)
    options = options or {}
    local socketutil = require("socketutil")
    local http = require("socket.http")
    local timeout = options.timeout or 3
    socketutil:set_timeout(timeout, options.total_timeout or timeout * 2)
    local code = socket.skip(1, http.request{
        url = url,
        method = "HEAD",
        sink = socketutil.table_sink({}),
    })
    -- 部分服务拒绝 HEAD（直接断开连接）→ GET 兜底重试一次（table_sink 有总时限兜底）
    if type(code) ~= "number" then
        code = socket.skip(1, http.request{
            url = url,
            sink = socketutil.table_sink({}),
        })
    end
    socketutil:reset_timeout()
    return type(code) == "number"
end

return M
