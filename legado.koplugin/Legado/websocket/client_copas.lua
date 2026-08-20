-- vendored lipp/lua-websockets client_copas;
-- verify 默认 none（KOReader luasec 无 CA，实测证书校验失败）；ws.verify 可覆盖
local socket = require'socket'
local sync = require'Legado/websocket.sync'
local logger = require"logger"

local dns_cache = {}
local function resolve_host(host)
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return host end
    if dns_cache[host] then return dns_cache[host] end
    local t0 = socket.gettime()
    local ok, ip = pcall(socket.dns.toip, host)
    local took = (socket.gettime() - t0) * 1000
    logger.warn(string.format("[client_copas] dns resolve %s -> %s (%.1fms)", host, tostring(ip), took))
    if ok and ip then
        dns_cache[host] = ip
        return ip
    end
    if ok and not ip then
        return host
    end
    return host
end

local new = function(ws)
  ws = ws or {}
  local copas = require'Legado.vendor.copas'

  local self = {}

  self.sock_connect = function(self,host,port)
    local sock = socket.tcp()
    self.sock = sock
    -- 清 total("t") 超时：否则长挂载 websocket 被强制掐断（实测断开）；block 由 copas.connect 覆盖为 0
    pcall(function() sock:settimeout(-1, "t") end)
    -- 规定connect/send 受 ws.timeout；receive 无限（空闲≠断线），总超时由外部 deadline 兜底
    if ws.timeout ~= nil then
      copas.settimeouts(sock, ws.timeout, ws.timeout, nil)
    end
    local _,err = copas.connect(sock, resolve_host(host), port)
    -- copas.connect 已内置 already connected 处理；此处任何 err 视为失败
    if err then
      pcall(function() sock:close() end)
      self.sock = nil
      return nil,err
    end
    return true
  end

  -- 握手必须用 copas.dohandshake；失败要清理 self.sock
  self.sock_handshake = function(self, host, ssl_params)
    local params = {
      mode = 'client',
      protocol = 'any',
      options = { 'all', 'no_sslv2', 'no_sslv3', 'no_tlsv1' },
      verify = 'none',
    }
    if ssl_params then
      for k, v in pairs(ssl_params) do params[k] = v end
    end
    if ws.verify ~= nil then
      params.verify = ws.verify
    end
    if params.sni == nil then
      params.sni = host
    end
    -- dohandshake 失败抛异常，必须 pcall 捕获并清 self.sock（防残留失败 socket）
    local ok_hs, hs_result = pcall(copas.dohandshake, self.sock, params)
    if not ok_hs or not hs_result then
      local sock = self.sock
      self.sock = nil
      if sock then pcall(function() sock:close() end) end
      return nil, tostring(hs_result or "TLS 握手失败")
    end
    return hs_result
  end

  self.sock_send = function(self,...)
    local sock = self.sock
    if not sock then return nil, "socket closed" end
    return copas.send(sock,...)
  end

  self.sock_receive = function(self,...)
    local sock = self.sock
    if not sock then return nil, "socket closed" end
    return copas.receive(sock,...)
  end

  self.sock_close = function(self)
    local sock = self.sock
    if not sock then return true end
    self.sock = nil
    local ok, err = pcall(function() sock:close() end)
    if not ok then return nil, err end
    return true
  end

  self = sync.extend(self)
  return self
end

local M = setmetatable({
    new = new,
}, {
    __call = function(self, ...)
        return new(...)
    end
})

M.open = function(opts)
    opts = opts or {}
    local url = opts.url
    if not url or url == "" then
        error("url 必填")
    end

    local JSON = require("json")
    local copas = require("Legado.vendor.copas")
    local frame = require("Legado.websocket.frame")

    local on_open = opts.on_open or function() end
    local on_message = opts.on_message or function() end
    local on_close = opts.on_close or function() end
    local on_error = opts.on_error or function() end
    local timeout = opts.timeout
    local connect_timeout = opts.connect_timeout or 8
    local send_on_open = opts.send_on_open

    local done = false
    local err_result = nil
    local ws_client = nil

    local function finish(clean, code, reason)
        if done then return end
        done = true
        if ws_client then
            pcall(function() ws_client:close(code, reason) end)
            ws_client = nil
        end
        if type(on_close) == "function" then
            pcall(on_close, clean, code, reason)
        end
    end

    local handle = {}
    function handle:is_done() return done end
    function handle:cancel(reason)
        if not done then
            err_result = reason or "cancelled"
            if ws_client then
                pcall(function() ws_client:close(1000, err_result) end)
            end
            finish(false, 1000, err_result)
        end
    end

    function handle:send(data, opcode)
        if done or not ws_client then return nil, "closed" end
        if type(data) == "table" then
            data = JSON.encode(data)
        end
        return ws_client:send(data, opcode or frame.TEXT)
    end

    function handle:close(code, reason)
        if done or not ws_client then return true end
        return ws_client:close(code or 1000, reason or "")
    end

    local deadline = (timeout and timeout > 0) and (socket.gettime() + timeout) or nil

    local function unwrap_err(err)
        if type(err) == "string" then return err end
        if type(err) == "table" then
            return err[1] or err.message or err.error or err.errorMsg or err.reason or err.err or tostring(err)
        end
        return tostring(err or "unknown error")
    end

    copas.addthread(function()
        local client = new({
            timeout = connect_timeout,
            verify = opts.verify or "none",
        })
        ws_client = client
        local ok, cerr = client:connect(url, opts.protocols)
        if not ok then
            local err_msg = "WebSocket 连接失败: " .. unwrap_err(cerr)
            pcall(on_error, err_msg)
            finish(false, 1006, err_msg)
            return
        end

        pcall(on_open)

        if send_on_open then
            local msg = type(send_on_open) == "table" and JSON.encode(send_on_open) or tostring(send_on_open)
            local sok, serr = client:send(msg)
            if not sok then
                local err_msg = "WebSocket 发送初始数据失败: " .. unwrap_err(serr)
                pcall(on_error, err_msg)
                finish(false, 1006, err_msg)
                return
            end
        end

        while not done do
            if deadline and socket.gettime() >= deadline then
                finish(false, 1000, "timeout")
                break
            end

            local msg, opcode_or_err, was_clean, close_code, close_reason = client:receive()
            if msg then
                pcall(on_message, msg, opcode_or_err)
            else
                local reason = close_reason or opcode_or_err or "closed"
                finish(was_clean == true, close_code or 1000, unwrap_err(reason))
                break
            end
        end
    end)
    
    if deadline then
        copas.addthread(function()
            while not done do
                local now = socket.gettime()
                if now >= deadline then
                    if not done then
                        finish(false, 1000, "timeout")
                    end
                    break
                end
                local remain = deadline - now
                local sleep_sec = remain > 0.5 and 0.2 or 0.05
                copas.sleep(sleep_sec)
            end
        end)
    end

    return handle
end

return M
