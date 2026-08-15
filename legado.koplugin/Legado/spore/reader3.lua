local util = require("util")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local H = require("Legado/Helper")
local safe_pcall = require("Legado.Helper.Error").pcall
local BaseSpec = require("Legado.spore.base")

local M = BaseSpec:extend{
  name = "reader3",
  client = nil,
  settings = nil,
}

local function filter_search_book(book, search_text, is_exact_search, options)
    if not H.is_tbl(book) then return false end
    local has_name_filter = H.is_str(options and options.name) and options.name   ~= ""
    local has_author_filter = H.is_str(options and options.author) and options.author ~= ""
    local has_origin_filter = H.is_str(options and options.origin) and options.origin ~= ""
    if has_name_filter or has_author_filter or has_origin_filter then
        local match_name = has_name_filter and H.is_str(book.name) and book.name == options.name
        local match_author = has_author_filter and H.is_str(book.author) and book.author == options.author
        local match_origin = has_origin_filter and H.is_str(book.origin) and book.origin == options.origin

        if has_name_filter and not match_name then return false end
        if has_author_filter and not match_author then return false end
        if has_origin_filter and not match_origin then return false end

        return true
    end
    if is_exact_search then
        return (H.is_str(book.name) and book.name == search_text)
            or (H.is_str(book.author) and book.author == search_text)
    end
    return true
end

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
        return false,  res and tostring(res) or '获取用户信息出错'
    end
    
    if not (H.is_tbl(res) and H.is_tbl(res.body) ) then
        return false, "返回了无效数据"
    end
    if not (H.is_tbl(res.body.data) and H.is_str(res.body.data.accessToken)) then
        return false, '获取 Token 失败:' .. tostring(res.body.errorMsg or "")
    end
    
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
        -- logger.info("custom_urlEncode:",htmlUrl)
        -- logger.info("util.urlEncode",util.urlEncode(htmlUrl))
        -- logger.info("url.escape",socket_url.escape(htmlUrl))
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

function M:getAvailableBookSource(options, on_finish, on_chunk)
    if not (H.is_tbl(options) and H.is_str(options.book_url)
            and H.is_str(options.name) and options.name ~= "") then
        if H.is_func(on_finish) then on_finish(false, '获取可用书源参数错误') end
        return nil
    end
    on_finish = H.is_func(on_finish) and on_finish or function() end
    on_chunk = H.is_func(on_chunk) and on_chunk or function() end

    local book_url = options.book_url
    local name = options.name
    local author = options.author
    local last_index = options.last_index
    local is_more_call = last_index ~= nil and H.is_num(last_index)

    local finish_sent = false
    local all_results = {}
    local seen_origin = {}
    -- author 兜底：调用方未提供时用缓存快查结果的 author 众数补全，避免同名异作者混入
    local resolved_author = author
    local author_votes = {}
    local function note_author(a)
        if not H.is_str(a) or a == "" then return end
        author_votes[a] = (author_votes[a] or 0) + 1
    end
    local function resolve_author()
        if H.is_str(resolved_author) and resolved_author ~= "" then return end
        local best_a, best_n = nil, 0
        for a, n in pairs(author_votes) do
            if n > best_n then best_a, best_n = a, n end
        end
        resolved_author = best_a
    end

    local function add_results(list)
        if not H.is_tbl(list) then return end
        local new_chunk = {}
        for _, book in ipairs(list) do
            if H.is_tbl(book) and H.is_str(book.origin) and not seen_origin[book.origin] then
                seen_origin[book.origin] = true
                note_author(book.author)
                table.insert(all_results, book)
                table.insert(new_chunk, book)
            end
        end
        if #new_chunk > 0 then
            pcall(on_chunk, new_chunk)
        end
    end

    local function send_finish(success, data, msg, last_idx)
        if finish_sent then return end
        finish_sent = true
        pcall(on_finish, success, data, msg, last_idx)
    end

    local search_cancel = nil
    local function search_more(start_index)
        search_cancel = self:searchBookMulti({
            search_text = name,
            name = name,
            author = resolved_author,
            last_index = start_index,
        }, function(chunk)
            add_results(chunk)
        end, function(success, msg, server_last_index)
            if success then
                send_finish(true, { list = all_results }, nil, server_last_index)
            else
                send_finish(false, nil, msg or "搜索失败")
            end
        end)
    end

    if is_more_call then
        search_more(last_index)
    else
        local ok, ret = pcall(function()
            return self:handleResponse(function()
                return self.client:getAvailableBookSource({
                    refresh = 0,
                    url = book_url,
                    v = os.time()
                })
            end, nil, {
                timeouts = {30, 50},
            }, 'getAvailableBookSource')
        end)
        if ok and H.is_tbl(ret) then
            add_results(ret)
            resolve_author()
        end
        -- 缓存快查无论成败，均追加全量搜索
        search_more(-1)
    end

    return function()
        if search_cancel then search_cancel() end
        send_finish(false, nil, "已取消")
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
    if not (H.is_tbl(options) and H.is_str(options.search_text) and options.search_text ~= '') then
        if H.is_func(on_finish) then on_finish(false, "输入参数错误") end
        return nil
    end

    local is_exact_search = false
    local search_text = util.trim(options.search_text)
    if string.sub(search_text, 1, 1) == "=" then
        is_exact_search = true
        search_text = util.trim(string.sub(search_text, 2))
    end
    if search_text == '' then
        if H.is_func(on_finish) then on_finish(false, "输入参数错误") end
        return nil
    end

    local last_index = H.is_num(options.last_index) and options.last_index or -1
    -- 续搜：lastIndex >= 0（首搜 -1）
    local is_more_call = last_index >= 0

    -- 会话级去重（服务端去重仅单请求内）：新搜索重置，续搜沿用
    if not is_more_call then
        self._search_dedup = {}
    end
    local dedup = self._search_dedup or {}
    self._search_dedup = dedup

    local SSEClient = require("Legado/Helper/SSEClient")
    local JSON = require("json")

    local server_address = self.settings.server_address

    local finish_sent = false
    local function send_finish(success, msg, res_last_index)
        if finish_sent then return end
        finish_sent = true
        if H.is_func(on_finish) then
            pcall(on_finish, success, msg, res_last_index)
        end
    end

    -- 登录：无凭证（secure=false 免认证）时 token 为 nil，不附加 accessToken
    local login_ok, login_token = self:ensureLogin()
    if login_ok ~= true then
        if H.is_func(on_finish) then on_finish(false, tostring(login_token or "登录失败")) end
        return nil
    end
    local token = login_token or nil

    local function build_request()
        local q = {
            key = search_text,
            bookSourceGroup = '',
            lastIndex = last_index,
            searchSize = 50,
            concurrentCount = 32,
            v = os.time(),
        }
        local parts = {}
        for k, v in pairs(q) do
            parts[#parts + 1] = k .. "=" .. util.urlEncode(tostring(v))
        end
        if H.is_str(token) and token ~= "" then
            parts[#parts + 1] = "accessToken=" .. token
        end
        -- SSEClient 需完整 URL：server_address 去尾斜杠后拼 /searchBookMultiSSE
        local base = server_address:gsub("/+$", "")
        return base .. "/searchBookMultiSSE?" .. table.concat(parts, "&")
    end

    local client = nil
    local relogin_attempted = false
    local server_last_index = nil

    local function handle_error_event(error_msg)
        if error_msg == "请登录后使用" and not relogin_attempted then
            relogin_attempted = true
            if client then client:cancel() end
            -- 清 token 重新登录（罕见路径，阻塞可接受）
            if self.tokenManager then self.tokenManager:clear() end
            local ok_login2, msg2 = self:ensureLogin()
            if ok_login2 == true and H.is_str(msg2) and msg2 ~= "" then
                token = msg2
                open_stream()
                return
            end
            send_finish(false, tostring(msg2 or error_msg))
        else
            send_finish(false, error_msg)
        end
    end

    local function on_sse_event(evt_name, data_str)
        if evt_name == "message" then
            local ok, obj = pcall(JSON.decode, data_str)
            if ok and H.is_tbl(obj) then
                local chunk = {}
                if H.is_tbl(obj.data) then
                    for _, book in ipairs(obj.data) do
                        if H.is_tbl(book)
                                and filter_search_book(book, search_text, is_exact_search, options)
                                and H.is_str(book.name) and book.name ~= ""
                                and H.is_str(book.bookUrl) and book.bookUrl ~= ""
                                and not dedup[book.bookUrl] then
                            dedup[book.bookUrl] = true
                            table.insert(chunk, book)
                        end
                    end
                end
                if H.is_num(obj.lastIndex) then
                    server_last_index = obj.lastIndex
                end
                if #chunk > 0 and H.is_func(on_chunk) then
                    pcall(on_chunk, chunk)
                end
            end
        elseif evt_name == "error" then
            local ok, obj = pcall(JSON.decode, data_str)
            local error_msg = ok and H.is_tbl(obj) and H.is_str(obj.errorMsg) and obj.errorMsg or data_str
            handle_error_event(error_msg)
        elseif evt_name == "end" then
            local ok, obj = pcall(JSON.decode, data_str)
            if ok and H.is_tbl(obj) and H.is_num(obj.lastIndex) then
                server_last_index = obj.lastIndex
            end
            send_finish(true, nil, server_last_index)
            if client then client:cancel() end
        end
    end

    local function open_stream()
        client = SSEClient.open{
            url = build_request(),
            timeout = 120,
            on_event = on_sse_event,
            on_close = function(err)
                -- err=nil：服务器关闭/终止块（正常流结束）；否则为失败原因
                if not finish_sent then
                    send_finish(false, err or "连接中断")
                end
            end,
        }
    end

    open_stream()

    return function()
        if client then client:cancel() end
        -- 尚未结束时同步补发结束回调
        if not finish_sent then
            send_finish(false, "已取消")
        end
    end
end

-- 单元测试钩子（仅测试用）
M._parsers = require("Legado/Helper/SSEClient")._parsers

return M
