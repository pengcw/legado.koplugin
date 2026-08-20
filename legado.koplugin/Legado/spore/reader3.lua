local util = require("util")
local logger = require("logger")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local H = require("Legado/Helper")
local safe_pcall = require("Legado.Helper.Error").pcall
local BaseSpec = require("Legado.spore.base")
local bookutil = require("Legado.spore.bookutil")
local Probe = require("Legado.Helper.Probe")

local M = BaseSpec:extend{
  name = "reader3",
  client = nil,
  settings = nil,
}

function M:init()
    BaseSpec.init(self)
end

function M:reader3Login()
    local reader3_un = self.settings.reader3_un
    local reader3_pwd = self.settings.reader3_pwd

    if not (H.is_str(reader3_un) and H.is_str(reader3_pwd) and 
                    reader3_pwd ~= "" and reader3_un ~= "") then
        return false, '认证信息设置不全'
    end

    local server_address = self.settings and self.settings.server_address or ""
    local full_url = string.format("%s/login", tostring(server_address))
    local t_start = Probe.start("Spore", "login", full_url, "(timeout: 8s/10s)")

    self:resetAndEnableMiddlewares(false)
    socketutil:set_timeout(8, 10)

    local status, res = safe_pcall(function()
        return self.client:login({
            username = reader3_un,
            password = reader3_pwd,
            code = "",
            isLogin = true,
            v = os.time()
        })
    end)
    socketutil:reset_timeout()

    if not status then
        local err = res and tostring(res) or '获取用户信息出错'
        Probe.fail("Spore", "login", full_url, t_start, err)
        return false, err
    end
    
    if not (H.is_tbl(res) and H.is_tbl(res.body)) then
        Probe.fail("Spore", "login", full_url, t_start, "返回了无效数据")
        return false, "返回了无效数据"
    end
    if not (H.is_tbl(res.body.data) and H.is_str(res.body.data.accessToken)) then
        local err_msg = '获取 Token 失败:' .. tostring(res.body.errorMsg or "")
        Probe.fail("Spore", "login", full_url, t_start, res.body.errorMsg or "Token缺失")
        return false, err_msg
    end
    
    Probe.done("Spore", "login", full_url, t_start, "200 OK", "Token OK")
    self:ensureTokenManager():set(res.body.data.accessToken)
    return true, res.body.data.accessToken
end

function M:getBookshelf(callback)
    return self:handleResponse(function()
        return self.client:getBookshelf({
            refresh = 0,
            v = os.time()
        })
    end, callback, {
      timeouts = {8, 12}
    }, 'getBookshelf')
end

function M:saveBook(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl) and
        H.is_str(bookinfo.originName)) then
        return nil, "输入参数错误"
    end
  
    return self:handleResponse(function()
        -- data=bookinfo
        return self.client:saveBook({
  
            v = os.time(),
            name = bookinfo.name,
            author = bookinfo.author,
            bookUrl = bookinfo.bookUrl,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder or 0,
            durChapterIndex = bookinfo.durChapterIndex or 0,
            durChapterPos = bookinfo.durChapterPos or 0,
            durChapterTime = bookinfo.durChapterTime or 0,
            durChapterTitle = bookinfo.durChapterTitle or '',
            wordCount = bookinfo.wordCount or '',
            intro = bookinfo.intro or '',
            totalChapterNum = bookinfo.totalChapterNum or 0,
            kind = bookinfo.kind or '',
            type = bookinfo.type or 0
        })
  
    end, callback, {
        timeouts = {10, 12}
    }, 'saveBook')
  
  end
  
  function M:deleteBook(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl)) then
        return nil, "输入参数错误"
    end
  
    return self:handleResponse(function()
        return self.client:deleteBook({
  
            v = os.time(),
            name = bookinfo.name,
            author = bookinfo.author,
            bookUrl = bookinfo.bookUrl,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder or 0,
            durChapterIndex = bookinfo.durChapterIndex or 0,
            durChapterPos = bookinfo.durChapterPos or 0,
            durChapterTime = bookinfo.durChapterTime or 0,
            durChapterTitle = bookinfo.durChapterTitle or '',
            wordCount = bookinfo.wordCount or '',
            intro = bookinfo.intro or '',
            totalChapterNum = bookinfo.totalChapterNum or 0,
            kind = bookinfo.kind or '',
            type = bookinfo.type or 0
        })
    end, callback, {
        timeouts = {6, 8}
    }, 'deleteBook')
  end
  
  function M:getChapterList(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and bookinfo.bookUrl) then 
      return nil, "参数错误"
    end
  
    local bookUrl = bookinfo.bookUrl
    -- refresh=true：仅清除缓存场景强制绕过服务器目录缓存
    local refresh = bookinfo.refresh == true and 1 or 0
    return self:handleResponse(function()
          return self.client:getChapterList({
              url = bookUrl,
              refresh = refresh,
              v = os.time()
          })
    end, callback, {
      timeouts = {10, 18}
  }, 'getChapterList')
  end
  
  function M:getBookContent(chapter, callback)
    local bookUrl = chapter.bookUrl
    local down_chapters_index = chapter.chapters_index
  
    if not H.is_str(bookUrl) or not H.is_num(down_chapters_index) then
        return nil, 'getBookContent参数错误'
    end
  
    return self:handleResponse(function()
        -- data=string
        return self.client:getBookContent({
            url = bookUrl,
            index = down_chapters_index,
            v = os.time()
        })
    end, callback, {
        timeouts = {18, 25}
    }, 'getBookContent')
  end

function M:refreshBookContent(chapter, callback)
    local bookUrl = chapter.bookUrl
    local down_chapters_index = chapter.chapters_index
  
    if not H.is_str(bookUrl) or not H.is_num(down_chapters_index) then
        return nil, '刷新章节出错'
    end
    
    return self:handleResponse(function()
        return self.client:getBookContent({
            url = bookUrl,
            index = down_chapters_index,
            refresh = 1,
            v = os.time()
        })
    end, callback, {
        timeouts = {10, 20}
    }, 'refreshBookContent')
  end
  
  function M:saveBookProgress(chapter, callback)
    if not (H.is_str(chapter.name) and H.is_str(chapter.bookUrl)) then
        return nil, '参数错误'
    end
    local chapters_index = chapter.chapters_index
  
    return self:handleResponse(function()
        local timestamp = os.time()
        return self.client:saveBookProgress({
            name = chapter.name,
            author = chapter.author or '',
            durChapterPos = 0,
            durChapterIndex = chapters_index,
            durChapterTime = timestamp * 1000,
            durChapterTitle = chapter.title or '',
            index = chapters_index,
            url = chapter.bookUrl,
            v = timestamp,
        })
    end, callback, {
        timeouts = {3, 5}
    }, 'saveBookProgress')
  end

-- socket.url.escape util.urlEncode + / ? = @会被编码
-- 处理 reader3 服务器版含书名路径有空格等问题
local function custom_urlEncode(str)

    if str == nil then
        return ""
    end
    local segment_chars = {
        ['-'] = true,
        ['.'] = true,
        ['_'] = true,
        ['~'] = true,
        [','] = true,
        ['!'] = true,
        ['*'] = true,
        ['\''] = true,
        ['('] = true,
        [')'] = true,
        ['/'] = true,
        ['?'] = true,
        ['&'] = true,
        ['='] = true,
        [':'] = true,
        ['@'] = true
    }

    return string.gsub(str, "([^A-Za-z0-9_])", function(c)
        if segment_chars[c] then
            return c
        else
            return string.format("%%%02X", string.byte(c))
        end
    end)
    --[[
    -- socket_url.build_path(socket_url.parse_path(str))
    return str:gsub("([^%w%-%.%_%~%!%$%&%'%(%)%*%+%,%;%=%:%@%/%?])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    ]]
end

function M:getProxyCoverUrl(coverUrl)
    if not H.is_str(coverUrl) then return coverUrl end
    local server_address = self.settings.server_address
    
    local api_root_url = server_address:gsub("/reader3$", "")
    return socket_url.absolute(api_root_url, coverUrl)
end

function M:getProxyImageUrl(_, img_src)
    local res_img_src = H.is_str(img_src) and tostring(img_src) or ""
    local server_address = self.settings.server_address
    
    if res_img_src:find("^https?://") then return res_img_src end
    local api_root_url = server_address:gsub("/reader3$", "")
    -- <img src='__API_ROOT__/book-assets/guest/剑来_/剑来.cbz/index/1.png' />
    res_img_src = custom_urlEncode(img_src):gsub("^__API_ROOT__", "")
    res_img_src = socket_url.absolute(api_root_url, res_img_src)
    return res_img_src
end

function M:getProxyEpubUrl(_, htmlUrl)
    htmlUrl = H.is_str(htmlUrl) and tostring(htmlUrl) or ""
    local server_address = self.settings['server_address']
    if server_address:match("/reader3$") and htmlUrl:match("%.x?html$") then
        local api_root_url = server_address:gsub("/reader3$", "")
        -- 可能有空格 "data": "/book-assets/guest/紫川_老猪/紫川 作者：老猪.epub/index/OEBPS/Text/chapter_0.html"
        htmlUrl = custom_urlEncode(htmlUrl)
        return socket_url.absolute(api_root_url, htmlUrl)
    else
        return htmlUrl
    end
end

function M:getBookSourcesList(callback)
    return self:handleResponse(function()
        return self.client:getBookSources({
            simple = 1,
            v = os.time()
        })
    end, callback, {
        timeouts = {20, 30},
    }, 'getBookSourcesList')
end

function M:getReplaceRules(callback)
    return self:handleResponse(function()
        return self.client:getReplaceRules({
            v = os.time()
        })
    end, callback, {
        timeouts = {20, 30},
    }, 'getReplaceRules')
end

function M:getTxtTocRules(callback)
    return self:handleResponse(function()
        return self.client:getTxtTocRules({
            v = os.time()
        })
    end, callback, {
        timeouts = {20, 30},
    }, 'getTxtTocRules')
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    local ret, err_msg = self:_getBookSource({
        bookSourceUrl = bookSourceUrl,
    })
    if not (H.is_tbl(ret) and H.is_str(ret.exploreUrl)) then
        return nil, err_msg and tostring(err_msg) or "源探索未设置"
    end
    local explore_url = {
        exploreUrl = ret.exploreUrl,
        BookSourceUrl = bookSourceUrl,
    }
    if H.is_func(callback) then
        return callback(explore_url)
    end
    return explore_url
end

function M:_getBookSource(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.bookSourceUrl)) then
        return nil, '获取书源详情参数错误'
    end
    return self:handleResponse(function()
        return self.client:getBookSource({
            bookSourceUrl = options.bookSourceUrl,
            v = os.time()
        })
    end, callback, {
        timeouts = {10, 15},
    }, 'getBookSource')
end

function M:exploreBook(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.ruleFindUrl) and H.is_str(options.bookSourceUrl)) then
        return nil, "书源发现参数错误"
    end

    local page = options.page or 1

    return self:handleResponse(function()
        return self.client:exploreBook({
            ruleFindUrl = options.ruleFindUrl,
            page = page,
            bookSourceUrl = options.bookSourceUrl,
        })
    end, callback, {
        timeouts = {18, 30},
    }, 'exploreBook')
end

local function resolve_host_sync(host)
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return host end
    local socket = require("socket")
    local ok, ip = pcall(socket.dns.toip, host)
    if ok and ip and ip ~= "" then
        return ip
    end
    return host
end

local function fetch_sse_stream_sync(req_url, timeout_sec, ctx, on_event_sync)
    local socket = require("socket")
    local ssl = require("ssl")
    local socket_url = require("socket.url")
    local SSEClientCopas = require("Legado.Helper.SSEClientCopas")

    local max_time = timeout_sec or 120
    local t_start = Probe.start("Spore", "SSE_STREAM", req_url, string.format("(timeout: %ds)", max_time))

    local function probe_fail(reason)
        Probe.fail("Spore", "SSE_STREAM", req_url, t_start, reason)
    end

    local function probe_done()
        Probe.done("Spore", "SSE_STREAM", req_url, t_start, "200 OK", "stream finished")
    end

    local parsed = socket_url.parse(req_url)
    if not (parsed and parsed.host) then
        probe_fail("非法URL")
        return false, "非法URL"
    end
    local is_https = parsed.scheme == "https"
    local host = parsed.host
    local port = tonumber(parsed.port) or (is_https and 443 or 80)
    local req_path = (parsed.path or "/") .. (parsed.query and ("?" .. parsed.query) or "")

    local connect_ip = resolve_host_sync(host)

    local sock = socket.tcp()
    sock:settimeout(5)
    local ok_c, cerr = sock:connect(connect_ip, port)
    if not ok_c then
        sock:close()
        local msg = "连接服务器失败(" .. tostring(connect_ip) .. ":" .. tostring(port) .. "): " .. tostring(cerr)
        probe_fail(msg)
        return false, msg
    end

    if is_https then
        local ok_w, sock_w = pcall(function()
            local s = ssl.wrap(sock, {
                mode = "client",
                protocol = "any",
                options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
                verify = "none",
            })
            if s.sni then
                pcall(s.sni, s, host)
            end
            local hs_to = math.min(60, math.max(1, max_time - (socket.gettime() - start_time)))
            s:settimeout(hs_to)
            local ok_hs, err_hs = s:dohandshake()
            if not ok_hs then
                error(tostring(err_hs or "dohandshake failed"))
            end
            return s
        end)
        if not ok_w then
            pcall(function() sock:close() end)
            local msg = "TLS握手失败: " .. tostring(sock_w)
            probe_fail(msg)
            return false, msg
        end
        sock = sock_w
    end

    local req = string.format(
        "GET %s HTTP/1.1\r\nHost: %s\r\nAccept: text/event-stream\r\nConnection: close\r\nUser-Agent: KOReader-Legado\r\n\r\n",
        req_path, host
    )
    local ok_s, serr = sock:send(req)
    if not ok_s then
        sock:close()
        local msg = "发送请求失败: " .. tostring(serr)
        probe_fail(msg)
        return false, msg
    end

    sock:settimeout(0.5)
    local http_code = nil
    local is_chunked = false
    local start_time = socket.gettime()

    while socket.gettime() - start_time < max_time do
        if ctx and ctx.is_cancelled() then
            sock:close()
            probe_fail("已取消")
            return false, "已取消"
        end
        local line, rerr = sock:receive("*l")
        if line then
            if not http_code then
                http_code = line:match("^HTTP/%d%.%d%s+(%d%d%d)")
            end
            local lk, lv = line:match("^([^:]+):%s*(.*)$")
            if lk then
                lk = lk:lower()
                if lk == "transfer-encoding" and lv:lower():find("chunked", 1, true) then
                    is_chunked = true
                end
            end
            if line == "" then break end
        elseif rerr ~= "timeout" and rerr ~= "wantread" and rerr ~= "wantwrite" then
            sock:close()
            local msg = "读取响应头失败: " .. tostring(rerr)
            probe_fail(msg)
            return false, msg
        end
    end

    if not http_code then
        sock:close()
        probe_fail("读取响应头超时")
        return false, "读取响应头超时"
    end

    if http_code == "401" then
        sock:close()
        probe_fail("RETRY_LOGIN (401)")
        return false, "RETRY_LOGIN"
    elseif http_code ~= "200" then
        sock:close()
        local msg = "HTTP状态码异常: " .. tostring(http_code)
        probe_fail(msg)
        return false, msg
    end

    local decoder = is_chunked and SSEClientCopas._parsers.chunked_decoder() or nil
    local sse = SSEClientCopas._parsers.sse_parser()

    while socket.gettime() - start_time < max_time do
        if ctx and ctx.is_cancelled() then
            sock:close()
            probe_fail("已取消")
            return false, "已取消"
        end
        local raw, rerr, partial = sock:receive(8192)
        local chunk_data = raw or partial
        if chunk_data and #chunk_data > 0 then
            local decoded = chunk_data
            if decoder then
                decoder.decode(chunk_data)
                decoded = decoder.get_output()
            end
            if decoded ~= "" then
                local events = sse.push(decoded)
                for _, evt in ipairs(events) do
                    local res = on_event_sync(evt[1], evt[2])
                    if res == true then
                        sock:close()
                        probe_done()
                        return true
                    elseif res == "RETRY_LOGIN" then
                        sock:close()
                        probe_fail("RETRY_LOGIN")
                        return false, "RETRY_LOGIN"
                    elseif type(res) == "string" and res ~= "" then
                        sock:close()
                        probe_fail(res)
                        return false, res
                    end
                end
            end
        end
        if rerr == "closed" then break end
        if rerr ~= "timeout" and rerr ~= "wantread" and rerr ~= "wantwrite" and not raw and not partial then
            break
        end
    end
    sock:close()
    probe_done()
    return true
end

function M:getAvailableBookSource(options, on_finish, on_chunk)
    if not (H.is_tbl(options) and H.is_str(options.book_url) and options.book_url ~= "") then
        if H.is_func(on_finish) then on_finish(false, nil, '获取可用书源参数错误') end
        return function() end
    end

    local book_url = options.book_url
    local last_index = (H.is_num(options.last_index) and options.last_index >= 0) and options.last_index or -1

    local server_address = self.settings.server_address
    local initial_token = self:ensureTokenManager():get()

    local TaskQueue = require("Legado.task.v2")

    local task = TaskQueue.spawn(function(ctx)
        local token = initial_token
        if (not token or token == "") and self._need_login then
            local ok_lg, new_tok = self:reader3Login()
            if ok_lg and H.is_str(new_tok) then
                token = new_tok
            end
        end

        local function build_req_url(cur_tok)
            local parts = {
                "url=" .. util.urlEncode(book_url),
                "lastIndex=" .. tostring(last_index),
                "searchSize=30",
                "bookSourceGroup=",
                "refresh=0",
                "concurrentCount=32",
                "v=" .. tostring(os.time()),
            }
            if H.is_str(cur_tok) and cur_tok ~= "" then
                table.insert(parts, "accessToken=" .. cur_tok)
            end
            local parsed = socket_url.parse(server_address)
            parsed.path = (parsed.path or ""):gsub("/+$", "") .. "/searchBookSourceSSE"
            parsed.query = table.concat(parts, "&")
            return socket_url.build(parsed)
        end

        local all_results = {}
        local seen_origin = {}
        local server_last_index = nil
        local server_is_end = false
        local sse_err = nil

        local function do_fetch(cur_tok)
            local req_url = build_req_url(cur_tok)
            local JSON = require("json")

            return fetch_sse_stream_sync(req_url, 120, ctx, function(evt_name, data_str)
                if evt_name == "message" then
                    local ok_j, obj = pcall(JSON.decode, data_str)
                    if ok_j and H.is_tbl(obj) then
                        local chunk = {}
                        if H.is_tbl(obj.data) then
                            for _, book in ipairs(obj.data) do
                                if H.is_tbl(book) and H.is_str(book.origin) and not seen_origin[book.origin] then
                                    seen_origin[book.origin] = true
                                    table.insert(all_results, book)
                                    table.insert(chunk, book)
                                end
                            end
                        end
                        if tonumber(obj.lastIndex) then
                            server_last_index = tonumber(obj.lastIndex)
                        end
                        if #chunk > 0 then
                            ctx.emit("chunk", chunk)
                        end
                    end
                elseif evt_name == "end" then
                    local ok_e, obj_e = pcall(JSON.decode, data_str)
                    if ok_e and H.is_tbl(obj_e) then
                        if tonumber(obj_e.lastIndex) then
                            server_last_index = tonumber(obj_e.lastIndex)
                        end
                        if obj_e.isEnd == true then
                            server_is_end = true
                        end
                    end
                    return true
                elseif evt_name == "error" then
                    local ok_e, obj_e = pcall(JSON.decode, data_str)
                    local msg = ok_e and H.is_tbl(obj_e) and obj_e.errorMsg or data_str
                    if H.is_str(msg) and (msg:find("NEED_LOGIN", 1, true) or msg:find("登录", 1, true)) then
                        return "RETRY_LOGIN"
                    end
                    -- 返回消息让 fetch 以失败结束并透传到 UI（如"没有更多了"为正常结束信号）
                    return msg or "换源搜索失败"
                end
                return false
            end)
        end

        local ok_f, err_f = do_fetch(token)
        if (not ok_f and err_f and (err_f:find("401") or err_f == "RETRY_LOGIN")) or (err_f == "RETRY_LOGIN") then
            if self._need_login then
                local ok_lg2, new_tok2 = self:reader3Login()
                if ok_lg2 and H.is_str(new_tok2) then
                    ok_f, err_f = do_fetch(new_tok2)
                end
            end
        end

        if not ok_f and err_f ~= "RETRY_LOGIN" and err_f ~= "已取消" then
            error({ message = err_f or sse_err or "换源搜索失败" })
        end

        return {
            list = all_results,
            lastIndex = server_is_end and nil or server_last_index,
            isEnd = server_is_end,
        }
    end, { timeout = 125 })

    if H.is_func(on_chunk) then
        task:on("chunk", on_chunk)
    end

    if H.is_func(on_finish) then
        task:on("done", function(ok, res)
            if ok then
                local res_list = (type(res) == "table" and res.list) or {}
                local last_idx = (type(res) == "table" and res.lastIndex) or nil
                on_finish(true, { list = res_list }, nil, last_idx)
            else
                local Error = require("Legado.Helper.Error")
                on_finish(false, nil, Error.extract_message(res))
            end
        end)
    end

    return function()
        if not task:is_done() then
            task:cancel("已取消")
        end
    end
end

function M:changeBookSource(new_book_source, callback)
    -- origin = bookSourceUrl
    -- return bookinfo
    if not H.is_tbl(new_book_source) or not H.is_str(new_book_source.bookUrl) or not H.is_str(new_book_source.newUrl) or
        not H.is_str(new_book_source.bookSourceUrl) then
        return nil, '更换书源参数错误'
    end

    return self:handleResponse(function()
        -- data=bookinfo
        return self.client:setBookSource({
            bookUrl = new_book_source.bookUrl,
            bookSourceUrl = new_book_source.bookSourceUrl,
            newUrl = new_book_source.newUrl,
            v = os.time()
        })
    end, callback, {
        timeouts = {25, 30},
    }, 'changeBookSource')
end

function M:searchBookSingle(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.search_text) and 
            options.search_text ~= '' and H.is_str(options.book_source_url)) then
        return nil, "输入参数错误"
    end

    local search_text = options.search_text
    local bookSourceUrl = options.book_source_url
    local concurrentCount = options.concurrent_count or 32

    return self:handleResponse(function()
        -- data = bookinfolist
        return self.client:searchBook({
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            bookSourceUrl = bookSourceUrl,
            lastIndex = -1,
            page = 1,
            v = os.time()
        })
    end, callback, {
        timeouts = {20, 30},
    }, 'searchBookSingle')
end

function M:searchBookMulti(options, on_chunk, on_finish)
    local raw_text = (H.is_tbl(options) and (options.search_text or options.key)) or ""
    if not (H.is_str(raw_text) and raw_text ~= '') then
        if H.is_func(on_finish) then on_finish(false, "输入参数错误") end
        return function() end
    end

    local is_exact_search = false
    local search_text = util.trim(raw_text)
    if string.sub(search_text, 1, 1) == "=" then
        is_exact_search = true
        search_text = util.trim(string.sub(search_text, 2))
    end
    if search_text == '' then
        if H.is_func(on_finish) then on_finish(false, "输入参数错误") end
        return function() end
    end

    local last_index = (H.is_num(options.last_index) and options.last_index >= 0) and options.last_index or -1
    local is_more_call = last_index >= 0

    -- 会话级去重：首搜重置，续搜沿用
    if not is_more_call then
        self._search_dedup = {}
    end
    local dedup = self._search_dedup or {}
    self._search_dedup = dedup

    local filter_opts = {
        name = options.name,
        author = options.author,
    }

    local server_address = self.settings.server_address
    local initial_token = self:ensureTokenManager():get()

    local TaskQueue = require("Legado.task.v2")
    local task = TaskQueue.spawn(function(ctx)
        local token = initial_token
        if (not token or token == "") and self._need_login then
            local ok_lg, new_tok = self:reader3Login()
            if ok_lg and H.is_str(new_tok) then
                token = new_tok
            end
        end

        local function build_req_url(cur_tok)
            local parts = {
                "key=" .. util.urlEncode(search_text),
                "bookSourceGroup=",
                "lastIndex=" .. tostring(last_index),
                "searchSize=50",
                "concurrentCount=32",
                "v=" .. tostring(os.time()),
            }
            if H.is_str(cur_tok) and cur_tok ~= "" then
                table.insert(parts, "accessToken=" .. cur_tok)
            end
            local parsed = socket_url.parse(server_address)
            parsed.path = (parsed.path or ""):gsub("/+$", "") .. "/searchBookMultiSSE"
            parsed.query = table.concat(parts, "&")
            return socket_url.build(parsed)
        end

        local server_last_index = nil
        local server_is_end = false
        local sse_err = nil

        local function do_fetch(cur_tok)
            local req_url = build_req_url(cur_tok)
            local JSON = require("json")
            local bookutil = require("Legado.spore.bookutil")

            return fetch_sse_stream_sync(req_url, 120, ctx, function(evt_name, data_str)
                if evt_name == "message" then
                    local ok_j, obj = pcall(JSON.decode, data_str)
                    if ok_j and H.is_tbl(obj) then
                        local chunk = {}
                        if H.is_tbl(obj.data) then
                            for _, book in ipairs(obj.data) do
                                if H.is_tbl(book)
                                        and bookutil.filter_search(book, search_text, is_exact_search, filter_opts)
                                        and H.is_str(book.name) and book.name ~= ""
                                        and H.is_str(book.bookUrl) and book.bookUrl ~= "" then
                                    table.insert(chunk, book)
                                end
                            end
                        end
                        if tonumber(obj.lastIndex) then
                            server_last_index = tonumber(obj.lastIndex)
                        end
                        if #chunk > 0 then
                            ctx.emit("chunk", chunk)
                        end
                    end
                elseif evt_name == "end" then
                    local ok_e, obj_e = pcall(JSON.decode, data_str)
                    if ok_e and H.is_tbl(obj_e) then
                        if tonumber(obj_e.lastIndex) then
                            server_last_index = tonumber(obj_e.lastIndex)
                        end
                        if obj_e.isEnd == true then
                            server_is_end = true
                        end
                    end
                    return true
                elseif evt_name == "error" then
                    local ok_e, obj_e = pcall(JSON.decode, data_str)
                    local msg = ok_e and H.is_tbl(obj_e) and obj_e.errorMsg or data_str
                    if H.is_str(msg) and (msg:find("NEED_LOGIN", 1, true) or msg:find("登录", 1, true)) then
                        return "RETRY_LOGIN"
                    end
                    -- 返回消息让 fetch 以失败结束并透传到 UI（如"没有更多了"为正常结束信号）
                    return msg or "搜索失败"
                end
                return false
            end)
        end

        local ok_f, err_f = do_fetch(token)
        if (not ok_f and err_f and (err_f:find("401") or err_f == "RETRY_LOGIN")) or (err_f == "RETRY_LOGIN") then
            if self._need_login then
                local ok_lg2, new_tok2 = self:reader3Login()
                if ok_lg2 and H.is_str(new_tok2) then
                    ok_f, err_f = do_fetch(new_tok2)
                end
            end
        end

        if not ok_f and err_f ~= "RETRY_LOGIN" and err_f ~= "已取消" then
            error({ message = err_f or sse_err or "网络请求失败" })
        end

        return {
            lastIndex = server_is_end and nil or server_last_index,
            isEnd = server_is_end,
        }
    end, { timeout = 125 })

    if H.is_func(on_chunk) then
        task:on("chunk", function(chunk)
            local filtered_chunk = {}
            for _, b in ipairs(chunk) do
                if not dedup[b.bookUrl] then
                    dedup[b.bookUrl] = true
                    table.insert(filtered_chunk, b)
                end
            end
            if #filtered_chunk > 0 then
                on_chunk(filtered_chunk)
            end
        end)
    end

    if H.is_func(on_finish) then
        task:on("done", function(ok, res)
            if ok then
                local last_idx = (type(res) == "table" and res.lastIndex) or nil
                on_finish(true, nil, last_idx)
            else
                local Error = require("Legado.Helper.Error")
                on_finish(false, Error.extract_message(res))
            end
        end)
    end

    return function()
        if not task:is_done() then
            task:cancel("已取消")
        end
    end
end

-- 仅测试用
M._parsers = require("Legado.Helper.SSEClientCopas")._parsers

return M
