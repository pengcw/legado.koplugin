local time = require("ui/time")
local logger = require("logger")
local Screen = require("device").screen
local util = require("util")
local socket_url = require("socket.url")
  local JSON = require("json")
local H = require("Legado/Helper")
local BaseSpec = require("Legado.spore.base")
local bookutil = require("Legado.spore.bookutil")
local errHandler = require("Legado.Helper.Error")
local Probe = require("Legado.Helper.Probe")

local M = BaseSpec:extend{
    name = "android_app",
    client = nil,
    settings = nil,
}

function M:init()
    BaseSpec.init(self)
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
          return self.client:refreshToc({
              url = bookUrl,
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
      timeouts = {5, 8}
  }, 'saveBookProgress')
end

function M:getProxyCoverUrl(coverUrl)
    if not H.is_str(coverUrl) then return coverUrl end
    local server_address = self.settings.server_address
    local proxy_cover = table.concat({server_address, '/cover?path=', util.urlEncode(coverUrl)})
    local is_http = coverUrl:match("^%s*[hH][tT][tT][pP][sS]?://") ~= nil
    if is_http then
        return { coverUrl, proxy_cover }
    end
    return proxy_cover
end

function M:getProxyImageUrl(bookUrl, img_src)
    bookUrl = H.is_str(bookUrl) and bookUrl or ""
    img_src = H.is_str(img_src) and img_src or ""
    local width = Screen:getWidth() or 800
    local server_address = self.settings.server_address

    local res_img_src = table.concat({server_address, '/image?url=', util.urlEncode(bookUrl), '&path=',
    util.urlEncode(img_src), '&width=', width})

    return res_img_src
end

function M:getProxyEpubUrl(_bookUrl, htmlUrl)
    return htmlUrl
end

function M:getAvailableBookSource(options, on_finish, on_chunk)
    if not (H.is_tbl(options) and H.is_str(options.book_url) and
        options.name) then
        if H.is_func(on_finish) then on_finish(false, '获取可用书源参数错误') end
        return nil
    end
    on_finish = H.is_func(on_finish) and on_finish or function() end
    on_chunk = H.is_func(on_chunk) and on_chunk or function() end

    local name = options.name
    local author = options.author

    -- 按 origin 去重（与 qread 一致，避免同源重复）
    local finish_sent = false
    local all_results = {}
    local seen_origin = {}
    local function send_finish(success, data, msg, last_index)
        if finish_sent then return end
        finish_sent = true
        pcall(on_finish, success, data, msg, last_index)
    end

    return self:searchBookMulti({
        search_text = name,
        name = name,
        author = author,
    }, function(chunk)
        local new_chunk = {}
        if H.is_tbl(chunk) then
            for _, book in ipairs(chunk) do
                local origin = book.origin
                if H.is_str(origin) and not seen_origin[origin] then
                    seen_origin[origin] = true
                    table.insert(all_results, book)
                    table.insert(new_chunk, book)
                end
            end
        end
        if #new_chunk > 0 then
            pcall(on_chunk, new_chunk)
        end
    end, function(success, msg, server_last_index)
        if success then
            send_finish(true, { list = all_results }, nil, server_last_index)
        else
            send_finish(false, nil, msg or "搜索失败")
        end
    end)
end

function M:changeBookSource(new_book_source, callback)
    return self:saveBook(new_book_source, callback)
end

function M:getBookSourcesList(callback)
    return self:handleResponse(function()
        return self.client:getBookSources({
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
    end, function(response)
        if response and response.isSuccess == true and type(response.data) == "string" then
            local JSON = require("json")
            local parsed, err = pcall(JSON.decode, response.data)
            if parsed and type(err) == "table" then
                if callback then callback({type="SUCCESS", body=err}) end
                return err
            else
                if callback then callback({type="ERROR", message="Invalid JSON in getReplaceRules"}) end
                return nil, "Invalid JSON in getReplaceRules"
            end
        end
        if callback then callback(response) end
        return response
    end, {
        timeouts = {20, 30},
    }, 'getReplaceRules')
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    return self:handleResponse(function()
        return self.client:getBookSource({
            url = bookSourceUrl,
            v = os.time()
        })
    end, function(response)
        if response and response.isSuccess == true and type(response.data) == "table" then
            local exploreUrl = response.data.exploreUrl
            local result = { exploreUrl = exploreUrl, bookSourceUrl = bookSourceUrl }
            if callback then callback({type = "SUCCESS", body = result}) end
            return result
        end
        if callback then callback(response) end
        return response
    end, {
        timeouts = {10, 15},
    }, 'getBookSourcesExploreUrl')
end

function M:searchBookMulti(options, on_chunk, on_finish)
    if type(options) == "string" then
        options = { search_text = options }
    end
    if not (H.is_tbl(options) and H.is_str(options.search_text) and options.search_text ~= '') then
        if H.is_func(on_finish) then on_finish(false, "输入参数错误") end
        return nil
    end
    local search_text = options.search_text
    local timeout = options.timeout or 60
    local is_exact_search = false
    if string.sub(search_text, 1, 1) == '=' then
        search_text = string.sub(search_text, 2)
        is_exact_search = true
    end
    if search_text == '' then
        if H.is_func(on_finish) then on_finish(false, "输入参数错误") end
        return nil
    end

    local Task = require("Legado.task.v2")
    local parsed = socket_url.parse(self.settings.server_address)
    local ws_scheme = (parsed.scheme == 'http') and 'ws' or 'wss'
    local default_port = (ws_scheme == 'ws') and 80 or 443
    parsed.port = (parsed.port or default_port) + 1
    local ws_server_address = string.format("%s://%s:%s%s", ws_scheme, parsed.host, parsed.port, "/searchBook")

    local timeout = options and options.timeout or 60

    local task = Task.spawn(function(ctx)
        local WS = require("Legado.websocket.client_copas")
        local JSON = require("json")
        local bookutil = require("Legado.spore.bookutil")

        local deduplication = {}
        local ws_finished = false
        local ws_error = nil

        local ws = WS.open({
            url = ws_server_address,
            send_on_open = { key = search_text },
            timeout = timeout,
            connect_timeout = 8,
            on_message = function(response_body)
                if ctx.is_cancelled() then return end
                local ok_decode, parsed_body = pcall(JSON.decode, response_body)
                if ok_decode and type(parsed_body) == 'table' and #parsed_body > 0 then
                    local chunk = {}
                    for _, v in ipairs(parsed_body) do
                        if type(v) == "table" and type(v.name) == "string" and v.name ~= "" and type(v.bookUrl) == "string" and v.bookUrl ~= "" then
                            local deduplication_key = table.concat({v.origin or v.bookSourceUrl or "", v.name, v.author or ""}, "|||")
                            if not deduplication[deduplication_key] and bookutil.filter_search(v, search_text, is_exact_search, options) then
                                table.insert(chunk, v)
                                deduplication[deduplication_key] = true
                            end
                        end
                    end
                    if #chunk > 0 then
                        ctx.emit("chunk", chunk) -- 离散帧实时推流回主进程
                    end
                end
            end,
            on_close = function(clean, code, reason)
                ws_finished = true
            end,
            on_error = function(err)
                ws_finished = true
                ws_error = err
            end,
        })

        -- 协作等待，直到 WebSocket 关闭或收到取消信号
        while not ws_finished and not ws:is_done() do
            if ctx.is_cancelled() then
                ws:cancel("task_cancelled")
                break
            end
            ctx.sleep(0.05)
        end

        if ws_error then
            error(tostring(ws_error))
        end
        return true
    end, {
        timeout = timeout + 5,
    })

    if H.is_func(on_chunk) then
        task:on("chunk", on_chunk)
    end

    if H.is_func(on_finish) then
        task:on("done", function(ok, res, state)
            if ok then
                on_finish(true, nil)
            else
                local Error = require("Legado.Helper.Error")
                local err_msg = Error.extract_message(res)
                on_finish(false, err_msg)
            end
        end)
    end

    return function()
        if not task:is_done() then
            task:cancel("已取消")
        end
    end
end

M.searchBook = M.searchBookMulti

function M:_searchBookSocket(search_text, filter, timeout)
  if not (H.is_str(search_text) and search_text ~= '') then
      return nil, "输入参数错误"
  end

  timeout = timeout or 60

  local is_exact_search = false
  if string.sub(search_text, 1, 1) == '=' then
      search_text = string.sub(search_text, 2)
      is_exact_search = true
  end

  local websocket = require('Legado/websocket')
  local errHandler = require("Legado.Helper.Error")

  local key_json = JSON.encode({
      key = search_text
  })

  local client = websocket.client.sync({
      timeout = 3
  })

  local parsed = socket_url.parse(self.settings.server_address)
  local ws_scheme = (parsed.scheme == 'http') and 'ws' or 'wss'
  local default_port = (ws_scheme == 'ws') and 80 or 443
  parsed.port = (parsed.port or default_port) + 1
  local ws_server_address = string.format("%s://%s:%s%s", ws_scheme, parsed.host, parsed.port, "/searchBook")
  local t_start = Probe.start("Spore", "WS_SEARCH", ws_server_address, string.format("(timeout: %ds)", timeout))

  local ok, err = client:connect(ws_server_address)
  if not ok then
      err = errHandler.map_message(err)
      Probe.fail("Spore", "WS_SEARCH", ws_server_address, t_start, "连接失败: " .. tostring(err))
      return nil, "请求失败：" .. tostring(err)
  end

  if client.sock and client.sock.settimeout then
      client.sock:settimeout(timeout)
  end

    local function filter_even(book)
        return bookutil.filter_search(book, search_text, is_exact_search, filter)
    end

  client:send(key_json)
  local result
  ok, result = errHandler.pcall(function()
      local response = {}
      local start_time = time.now()
      local deduplication = {}

      while true do
          local response_body = client:receive()
          if not response_body then break end

          if time.since(start_time) > time.s(timeout) then
              break
          end

          local ok_decode, parsed_body = pcall(JSON.decode, response_body)
          if ok_decode and type(parsed_body) == 'table' and #parsed_body > 0 then
              for _, v in ipairs(parsed_body) do
                if H.is_tbl(v) and H.is_str(v.name) and v.name ~= "" and H.is_str(v.bookUrl) and v.bookUrl ~= "" then
                    local deduplication_key = table.concat({v.origin or v.bookSourceUrl or "", v.name, v.author or ""}, "|||")
                    if not deduplication[deduplication_key] and filter_even(v) then
                        table.insert(response, v)
                        deduplication[deduplication_key] = true
                    end
                 end
              end
          end
      end
      deduplication = nil
      return response
  end)

  pcall(function()
      client:close()
  end)

  if not ok then
      Probe.fail("Spore", "WS_SEARCH", ws_server_address, t_start, result)
      return nil, 'ws返回数据出错：' .. tostring(result)
  end

  local count_str = (H.is_tbl(result) and #result > 0) and string.format("%d books", #result) or "0 books"
  Probe.done("Spore", "WS_SEARCH", ws_server_address, t_start, "200 OK", count_str)

  return result
end

-- ⚠️ 后端仅对 index==0 的第一本书打印详细字段日志
-- ⚠️ Lua 模式是字节级的：多字节符号（┌└…）必须 plain find，不能进 [字符集]
local BOOK_SOURCE_DEBUG_SYMBOLS = { "┌", "└", "︽", "⇒", "◇", "≡", "︾" }
local BOOK_SOURCE_DEBUG_FIELD_MAP = {
    ["书名"] = "name",
    ["作者"] = "author",
    ["分类"] = "kind",
    ["字数"] = "wordCount",
    ["最新章节"] = "durChapterTitle",
    ["简介"] = "intro",
    ["封面"] = "coverUrl",
    ["目录链接"] = "tocUrl",
}

local function splitBookSourceDebugLine(line)
    if type(line) ~= "string" then return nil end
    local body = line:match("^%[%d+:%d+%.%d+%]%s*(.*)$")
    if not body then return nil end
    for _, sym in ipairs(BOOK_SOURCE_DEBUG_SYMBOLS) do
        if body:find(sym, 1, true) == 1 then
            return sym, body:sub(#sym + 1)
        end
    end
    return nil
end

function M:_bookSourceDebugNewState()
    return {
        books = {},
        current_book = nil,
        current_field = nil,
        saw_activity = false, -- 是否收到过搜索日志（区分书源无响应）
    }
end

function M:_bookSourceDebugCommit(state)
    local book = state.current_book
    state.current_book = nil
    state.current_field = nil
    if not (book and H.is_str(book.name) and book.name ~= ""
            and H.is_str(book.bookUrl) and book.bookUrl ~= "") then
        return
    end
    table.insert(state.books, book)
end

function M:_bookSourceDebugConsume(line, state)
    state = state or self:_bookSourceDebugNewState()
    local sym, content = splitBookSourceDebugLine(line)
    if not sym then return false end
    state.saw_activity = true

    if sym == "┌" then
        local field = content:match("^%s*获取(.+)%s*$")
        if field == "书籍列表" then
            self:_bookSourceDebugCommit(state)
            state.current_field = nil
        elseif field == "书名" then
            self:_bookSourceDebugCommit(state)
            state.current_book = {}
            state.current_field = "书名"
        elseif field then
            state.current_field = field
        end
    elseif sym == "└" then
        local key = state.current_field and BOOK_SOURCE_DEBUG_FIELD_MAP[state.current_field]
        if key and state.current_book then
            state.current_book[key] = content
        end
    elseif sym == "◇" or sym == "︽" then
        self:_bookSourceDebugCommit(state)
        return true
    end
    return false
end

function M:searchBookSingle(options)
    if not (H.is_tbl(options) and H.is_str(options.search_text) and options.search_text ~= ''
            and H.is_str(options.book_source_url) and options.book_source_url ~= '') then
        return nil, "searchBookSingle参数错误"
    end

    local search_text = options.search_text
    local bookSourceUrl = options.book_source_url
    local timeout = H.is_num(options.timeout) and options.timeout or 30
    local idle_timeout = H.is_num(options.idle_timeout) and options.idle_timeout or 8

    local websocket = require('Legado/websocket')
    local socket = require("socket")

    local parsed = socket_url.parse(self.settings.server_address)
    local ws_scheme = (parsed.scheme == 'http') and 'ws' or 'wss'
    local default_port = (ws_scheme == 'ws') and 80 or 443
    parsed.port = (parsed.port or default_port) + 1
    local ws_addr = string.format("%s://%s:%s%s", ws_scheme, parsed.host, parsed.port, "/bookSourceDebug")
    local t_start = Probe.start("Spore", "WS_DEBUG", ws_addr, string.format("(timeout: %ds)", timeout))

    local client = websocket.client.sync({ timeout = 3 })
    local ok, err = client:connect(ws_addr)
    if not ok then
        Probe.fail("Spore", "WS_DEBUG", ws_addr, t_start, "连接失败: " .. tostring(err))
        return nil, "连接失败：" .. tostring(err)
    end

    client:send(JSON.encode({ tag = bookSourceUrl, key = search_text }))

    local state = self:_bookSourceDebugNewState()
    local start = socket.gettime()
    local idle_start = socket.gettime()
    local finished = false

    while socket.gettime() - start < timeout do
        local recvt = socket.select({ client.sock }, nil, 0.5)
        if #recvt > 0 then
            local body = client:receive()
            if not body then
                break
            end
            if body ~= "ping" and body ~= "" then
                if self:_bookSourceDebugConsume(body, state) then
                    finished = true
                    break
                end
                if state.saw_activity then
                    idle_start = socket.gettime()
                end
            end
        elseif socket.gettime() - idle_start > idle_timeout then
            -- 请求发出后长时间无搜索日志：书源不存在/不可用（服务端仅 ping 保活）
            break
        end
    end
    pcall(function() client:close() end)

    if not state.saw_activity then
        Probe.fail("Spore", "WS_DEBUG", ws_addr, t_start, "书源无响应")
        return nil, "书源无响应（可能不存在或不可用）"
    end

    local count_str = #state.books > 0 and string.format("%d books", #state.books) or "0 books"
    Probe.done("Spore", "WS_DEBUG", ws_addr, t_start, "200 OK", count_str)

    if finished and #state.books == 0 then
        return {}
    end
    return state.books
end

return M
