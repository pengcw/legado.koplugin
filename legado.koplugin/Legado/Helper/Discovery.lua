local bit = require("bit")
local socket = require("socket")
local logger = require("logger")
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

local function maskToPrefix(netmask)
    local mask_n = ip2num(netmask or "255.255.255.0")
    if not mask_n then return 24 end
    local prefix = 0
    for i = 31, 0, -1 do
        local p = 2 ^ i
        if mask_n >= p then
            prefix = prefix + 1
            mask_n = mask_n - p
        else
            break
        end
    end
    return prefix
end

local function prefixToMask(prefix)
    prefix = tonumber(prefix)
    if not prefix or prefix < 0 or prefix > 32 then return "255.255.255.0" end
    if prefix == 0 then return "0.0.0.0" end
    local n = 0
    for i = 31, 32 - prefix, -1 do
        n = n + 2 ^ i
    end
    return num2ip(n)
end

function M:getNetmask(ip)
    local f = io.open("/proc/net/route")
    if not f then
        logger.warn("Discovery: /proc/net/route 无法打开（权限受限）")
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
                logger.dbg("Discovery: route行 iface=", iface, "dest=", num2ip(dest_n), "mask=", num2ip(mask_n))
                if bit.band(bit.tobit(target), bit.tobit(mask_n)) % MAX_U32
                        == bit.band(bit.tobit(dest_n), bit.tobit(mask_n)) % MAX_U32 then
                    if not best or mask_n > best then best = mask_n end
                end
            end
        end
    end
    f:close()
    if not best then
        logger.warn("Discovery: /proc/net/route 未找到包含本机 ", ip, " 的网段路由")
        return nil
    end
    local mask = num2ip(best)
    return mask
end

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

function M:getScanRange(ip, netmask, max_hosts)
    local ip_n = ip2num(ip)
    local mask_n = ip2num(netmask or "255.255.255.0")
    if not ip_n or not mask_n then
        logger.warn("Discovery: 无效 IP/掩码", tostring(ip), tostring(netmask))
        return nil
    end
    local effective_mask_n = mask_n
    local network = bit.band(bit.tobit(ip_n), bit.tobit(effective_mask_n)) % MAX_U32
    local broadcast = (network + (MAX_U32 - 1 - effective_mask_n)) % MAX_U32
    local count = broadcast - network - 1
    max_hosts = max_hosts or 512
    if count > max_hosts then
        logger.warn("Discovery: 网段包含 ", count, " 主机超过上限 ", max_hosts, "，收缩至当前 IP /24 邻居段")
        effective_mask_n = ip2num("255.255.255.0")
        network = bit.band(bit.tobit(ip_n), bit.tobit(effective_mask_n)) % MAX_U32
        broadcast = (network + (MAX_U32 - 1 - effective_mask_n)) % MAX_U32
    end
    logger.dbg("Discovery: 网段", num2ip(network), "~", num2ip(broadcast), "(本机", ip .. ")")
    local first = network + 1
    local last = broadcast - 1
    if first > last then
        first = ip_n
        last = ip_n
    end
    return {
        first = first,
        last = last,
        network = network,
        broadcast = broadcast,
        netmask = num2ip(effective_mask_n),
    }
end

function M:getNetworks(options)
    options = options or {}
    local candidates = {}
    local seen_ips = {}
    local default_iface = getDefaultRouteIface()

    local function add_candidate(ip, netmask, iface, is_default)
        if not ip or type(ip) ~= "string" then return end
        local ip_match = ip:match("(%d+%.%d+%.%d+%.%d+)")
        if not ip_match then return end
        if ip_match:match("^127%.") or ip_match:match("^169%.254%.") or ip_match == "0.0.0.0" then
            return
        end
        if seen_ips[ip_match] then return end
        seen_ips[ip_match] = true

        local mask = netmask or self:getNetmask(ip_match) or "255.255.255.0"
        table.insert(candidates, {
            ip = ip_match,
            netmask = mask,
            iface = iface,
            is_default = is_default or (iface and default_iface and iface == default_iface) or false,
        })
    end

    if options.ip then
        add_candidate(options.ip, options.netmask, default_iface, true)
    else
        if net_info_ok and netinfo then
            local ok, ifaces = pcall(function()
                return netinfo:new():retrieve()
            end)
            if ok and type(ifaces) == "table" then
                for _, iface in ipairs(ifaces) do
                    if iface.name and not iface.name:match("^lo") and type(iface.ipv4) == "string" then
                        local prefix = iface.ipv4:match("/(%d+)$")
                        local mask = prefix and prefixToMask(prefix) or nil
                        local is_def = (default_iface and iface.name == default_iface)
                        add_candidate(iface.ipv4, mask, iface.name, is_def)
                    end
                end
            end
        end

        local f = io.open("/proc/net/route")
        if f then
            for line in f:lines() do
                local iface, dest, mask = line:match("^(%S+)%s+([%x]+)%s+[%x]+%s+[%x]+%s+%d+%s+%d+%s+%d+%s+([%x]+)")
                if iface and dest and mask and not iface:match("^lo") then
                    local dest_n = swap32(tonumber(dest, 16))
                    local mask_n = swap32(tonumber(mask, 16))
                    if dest_n ~= 0 and mask_n ~= 0 and mask_n ~= MAX_U32 - 1 then
                        local target_probe_ip = num2ip(dest_n + 1)
                        local ok_u, udp = pcall(function() return socket.udp() end)
                        if ok_u and udp then
                            local ok_peer = pcall(function() return udp:setpeername(target_probe_ip, 80) end)
                            local ip = ok_peer and udp:getsockname() or nil
                            pcall(function() udp:close() end)
                            if ip and ip:match("^(%d+%.%d+%.%d+%.%d+)$") then
                                local is_def = (default_iface and iface == default_iface)
                                add_candidate(ip, num2ip(mask_n), iface, is_def)
                            end
                        end
                    end
                end
            end
            f:close()
        end

        if #candidates == 0 then
            local ok_u, udp = pcall(function() return socket.udp() end)
            if ok_u and udp then
                local ok_peer = pcall(function() return udp:setpeername("8.8.8.8", 80) end)
                local ip = ok_peer and udp:getsockname() or nil
                pcall(function() udp:close() end)
                if ip and ip:match("^(%d+%.%d+%.%d+%.%d+)$") then
                    add_candidate(ip, nil, default_iface, true)
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.is_default and not b.is_default then return true end
        if not a.is_default and b.is_default then return false end
        return (a.iface or "") < (b.iface or "")
    end)

    local max_hosts = options.max_hosts or 512
    local results = {}
    local seen_networks = {}

    for _, cand in ipairs(candidates) do
        local range = self:getScanRange(cand.ip, cand.netmask, max_hosts)
        if range then
            local network_key = range.network
            if not seen_networks[network_key] then
                seen_networks[network_key] = true
                local effective_netmask = range.netmask or cand.netmask
                local prefix = maskToPrefix(effective_netmask)
                results[#results + 1] = {
                    ip = cand.ip,
                    netmask = effective_netmask,
                    first = range.first,
                    last = range.last,
                    cidr = string.format("%s/%d", num2ip(range.network), prefix),
                    iface = cand.iface,
                    is_default = cand.is_default,
                }
                logger.dbg("Discovery: 发现网段", results[#results].cidr, "接口=", cand.iface or "unknown", "本机IP=", cand.ip)
            end
        end
    end

    return results
end

function M:getNetwork(options)
    options = options or {}
    if options.ip then
        local ip = options.ip
        local netmask = options.netmask or self:getNetmask(ip) or "255.255.255.0"
        local range = self:getScanRange(ip, netmask, options.max_hosts)
        if not range then return nil, "无法确定本机网络" end
        local effective_netmask = range.netmask or netmask
        return {
            ip = ip,
            netmask = effective_netmask,
            first = range.first,
            last = range.last,
            cidr = string.format("%s/%d", num2ip(range.network), maskToPrefix(effective_netmask)),
        }
    end
    local nets = self:getNetworks(options)
    if nets and #nets > 0 then
        return nets[1]
    end
    return nil, "无法确定本机网络"
end

function M:getLocalIPv4()
    local net = self:getNetwork()
    return net and net.ip or nil
end

function M:getLocalIPv4List()
    local nets = self:getNetworks()
    local list = {}
    for _, n in ipairs(nets) do
        table.insert(list, n.ip)
    end
    return list
end

local function probeHosts(ips, ports, options)
    local results = {}
    local concurrency = options.concurrency or (math.min(64, math.max(32, math.floor(#ips / 8))))
    local wait = options.timeout or 0.3
    local total_timeout = options.total_timeout or 10
    local retry = options.retry or 2
    local callback = options.callback

    if type(ports) == "number" then ports = { ports } end
    logger.dbg("Discovery: 开始探测", #ips, "个IP x", #ports, "个端口, 并发", concurrency, "每轮", wait, "s, 总时限", total_timeout, "s")

    local queue = {}
    for _, ip in ipairs(ips) do
        for _, port in ipairs(ports) do
            queue[#queue + 1] = { ip = ip, port = port }
        end
    end
    local queue_head = 1
    local queue_tail = #queue

    local socks = {}
    local info_of = {}
    local in_flight = 0
    local rounds = 0
    local diag_conn_errs = 0
    local deadline = socket.gettime() + total_timeout

    local function record(ip, port)
        local entry = { ip = ip, port = port }
        results[#results + 1] = entry
        logger.dbg("Discovery: 命中", ip, port)
        if callback then pcall(callback, entry) end
    end

    local function start_next()
        while in_flight < concurrency and queue_head <= queue_tail do
            local item = queue[queue_head]
            queue[queue_head] = nil
            queue_head = queue_head + 1
            local sock = socket.tcp()
            sock:settimeout(0)
            local ok, err = sock:connect(item.ip, item.port)
            if ok then
                pcall(function() sock:close() end)
                record(item.ip, item.port)
            else
                if err and err ~= "timeout" and err ~= "in progress" and diag_conn_errs < 3 then
                    diag_conn_errs = diag_conn_errs + 1
                    logger.warn("Discovery: connect 立即失败", item.ip, item.port, tostring(err))
                end
                item.deadline = socket.gettime() + wait
                socks[#socks + 1] = sock
                info_of[sock] = item
                in_flight = in_flight + 1
            end
        end
    end

    start_next()
    while (in_flight > 0 or queue_head <= queue_tail) and socket.gettime() < deadline do
        rounds = rounds + 1
        local now = socket.gettime()
        local select_wait = wait
        for _, s in ipairs(socks) do
            local item = info_of[s]
            if item and item.deadline then
                local remain = item.deadline - now
                if remain > 0 and remain < select_wait then
                    select_wait = remain
                end
            end
        end
        if select_wait <= 0 then select_wait = 0.001 end

        local _, ready
        if #socks > 0 then
            _, ready = socket.select(nil, socks, select_wait)
        end
        ready = ready or {}
        local ready_set = {}
        for _, s in ipairs(ready) do ready_set[s] = true end

        now = socket.gettime()
        local remaining_socks = {}
        for _, s in ipairs(socks) do
            local item = info_of[s]
            if ready_set[s] then
                if s:getpeername() then record(item.ip, item.port) end
                pcall(function() s:close() end)
                info_of[s] = nil
                in_flight = in_flight - 1
            elseif now >= (item.deadline or 0) then
                if (item.retries or 0) < retry then
                    item.retries = (item.retries or 0) + 1
                    queue_tail = queue_tail + 1
                    queue[queue_tail] = item
                end
                pcall(function() s:close() end)
                info_of[s] = nil
                in_flight = in_flight - 1
            else
                remaining_socks[#remaining_socks + 1] = s
            end
        end
        socks = remaining_socks
        start_next()
    end
    for _, s in ipairs(socks) do
        pcall(function() s:close() end)
        info_of[s] = nil
    end
    socks = {}
    logger.dbg("Discovery: 探测完成", #results, "个命中, 共", rounds, "轮",
        (socket.gettime() >= deadline and "(已达总时限)" or ""))
    return results
end

local MAX_BODY = 4096
local function httpGet(ip, port, path, timeout, max_body)
    local sock = socket.tcp()
    sock:settimeout(timeout or 1)
    pcall(function() sock:settimeout(-1, "t") end)
    local ok = sock:connect(ip, port)
    if not ok then pcall(function() sock:close() end) return nil end
    local req = "GET " .. path .. " HTTP/1.1\r\n"
        .. "Host: " .. ip .. ":" .. port .. "\r\n"
        .. "Connection: close\r\n\r\n"
    local sent = sock:send(req)
    if not sent then pcall(function() sock:close() end) return nil end
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
    local limit = max_body or MAX_BODY
    local body
    if content_length and content_length >= 0 and content_length <= limit then
        body = sock:receive(content_length)
    else
        body = sock:receive(limit)
        if not body then body = sock:receive("*a") end
    end
    pcall(function() sock:close() end)
    return tonumber(code), body
end

function M:scan(port, options)
    options = options or {}
    local nets
    if options.ip then
        local net, err = self:getNetwork(options)
        if not net then return nil, err end
        nets = { net }
    else
        nets = self:getNetworks(options)
        if not nets or #nets == 0 then
            if options.include_loopback ~= false then
                return probeHosts({ "127.0.0.1" }, port or 80, options)
            end
            return nil, "无法确定本机网络"
        end
    end

    local ips = {}
    local seen = {}
    for _, net in ipairs(nets) do
        for n = net.first, net.last do
            local ip_str = num2ip(n)
            if not seen[ip_str] then
                seen[ip_str] = true
                ips[#ips + 1] = ip_str
            end
        end
    end
    if not options.ip and options.include_loopback ~= false and not seen["127.0.0.1"] then
        ips[#ips + 1] = "127.0.0.1"
    end

    if #ips == 0 then return nil, "无可用探测地址" end
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
    local timeout = options.timeout or 8
    local status, body = httpGet(ip, port, "/legado_test", timeout)
    if not status and options.retry ~= false then
        socket.sleep(0.3)
        status, body = httpGet(ip, port, "/legado_test", timeout)
    end
    return status == 200 and body ~= nil and body:find("web/legado_test", 1, true) ~= nil
end

function M:scanLegadoServices(opts)
    opts = opts or {}
    local ports = opts.ports or { 1122 }
    local scan_timeout = opts.timeout or 0.4
    local nets = self:getNetworks({ timeout = 0.4 })
    if not nets or #nets == 0 then
        nets = { { ip = "127.0.0.1", netmask = "255.255.255.255", cidr = "127.0.0.1/32" } }
    end
    local primary_net = nets[1]
    local cidrs = {}
    for _, n in ipairs(nets) do
        if n.cidr then table.insert(cidrs, n.cidr) end
    end
    local scope_cidr = #cidrs > 0 and table.concat(cidrs, ", ") or primary_net.cidr
    local display_net = {
        ip = primary_net.ip,
        netmask = primary_net.netmask,
        cidr = scope_cidr,
    }

    local scan_opts = {
        timeout = scan_timeout,
        total_timeout = opts.total_timeout or 10,
    }
    if opts.concurrency then
        scan_opts.concurrency = opts.concurrency
    end
    if opts.ip then
        scan_opts.ip = opts.ip
        scan_opts.netmask = opts.netmask
    end

    local hits = self:scan(ports, scan_opts)
    if type(hits) ~= "table" then
        return { list = {}, net = display_net, nets = nets }
    end
    local list = {}
    local loopback_items = {}
    for _, h in ipairs(hits) do
        if self:isLegado(h.ip, h.port, { timeout = opts.legado_timeout or 8 }) then
            local addr = string.format("%s:%d", h.ip, h.port)
            if h.ip:match("^127%.") then
                table.insert(loopback_items, addr)
            else
                table.insert(list, addr)
            end
        end
    end
    for _, addr in ipairs(loopback_items) do
        table.insert(list, addr)
    end
    return { list = list, net = display_net, nets = nets }
end

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
