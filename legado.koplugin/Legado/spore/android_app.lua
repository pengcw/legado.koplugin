local time = require("ui/time")
local logger = require("logger")
local Screen = require("device").screen
local util = require("util")
local socket_url = require("socket.url")
local H = require("Legado/Helper")
local BaseSpec = require("Legado.spore.base")

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
  return self:handleResponse(function()
        return self.client:getChapterList({
            url = bookUrl,
            v = os.time()
        })
  end, callback, {
    timeouts = {10, 18}
}, 'getChapterList')
end

function M:getBookContent(chapter, callback)
  local bookUrl = chapter.bookUrl
  local chapters_index = chapter.chapters_index
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
  local chapters_index = chapter.chapters_index
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
    return table.concat({server_address, '/cover?path=', util.urlEncode(coverUrl)})
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

function M:getProxyEpubUrl(bookUrl, htmlUrl)
    return htmlUrl
end

function M:getAvailableBookSource(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.book_url) and 
        options.name) then
        return nil, '获取可用书源参数错误'
    end

    local bookUrl = options.book_url
    local name = options.name
    local author = options.author

    local ret, err_msg = self:_searchBookSocket(name, {
        name = name,
        author = author
    })
    if ret == nil then
        return ret, err_msg or "未知错误"
    else
        return {list = ret}
    end
end

function M:changeBookSource(new_book_source, callback)
    return self:saveBook(new_book_source, callback)
end

function M:searchBookMulti(options, callback)
    local search_text = options.search_text
    local ret, err_msg = self:_searchBookSocket(search_text)
    if ret == nil then
        return ret, err_msg or "未知错误"
    else
        return { list = ret, lastIndex = -1 }
    end
end

function M:searchBookMultiAsync(options, on_chunk, on_finish)
    local search_text = options.search_text or ""
    local timeout = 60
    local is_exact_search = false
    if string.sub(search_text, 1, 1) == '=' then
        search_text = string.sub(search_text, 2)
        is_exact_search = true
    end

    local JSON = require("json")
    local websocket = require('Legado/websocket')
    local UIManager = require("ui/uimanager")
    local socket = require("socket")
    
    local key_json = JSON.encode({ key = search_text })
    local client = websocket.client.sync({ timeout = 3 })
    local parsed = socket_url.parse(self.settings.server_address)
    local ws_scheme = parsed.scheme == 'http' and 'ws' or 'wss'
    parsed.port = (parsed.port or (ws_scheme == 'ws' and 80 or 443)) + 1
    local ws_server_address = string.format("%s://%s:%s%s", ws_scheme, parsed.host, parsed.port, "/searchBook")
    
    local ok, err = client:connect(ws_server_address)
    if not ok then return on_finish(false, "连接失败：" .. tostring(err)) end
    
    client:send(key_json)
    
    local function filter_even(book)
        if not H.is_tbl(book) then return false end
        if is_exact_search then
            return (book.name == search_text) or (book.author == search_text)
        end
        return true
    end

    local SearchTask = {}
    function SearchTask:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        o.is_done = false
        return o
    end

    function SearchTask:start(client, timeout, on_chunk, on_finish, filter_even)
        self.client = client
        self.start_time = time.now()
        self.timeout = timeout
        self.on_chunk = on_chunk
        self.on_finish = on_finish
        self.filter_even = filter_even
        self.deduplication = {}
        
        self.JSON = require("json")
        self.UIManager = require("ui/uimanager")
        self.socket = require("socket")
        self.zmq_ref = self.UIManager:insertZMQ(self)
    end

    function SearchTask:stop()
        if self.is_done then return end
        self.is_done = true
        pcall(function() self.client:close() end)
        if self.zmq_ref then self.UIManager:removeZMQ(self.zmq_ref) end
    end

    function SearchTask:waitEvent()
        if self.is_done then return nil end
        if time.since(self.start_time) > time.s(self.timeout) then
            self:stop()
            self.on_finish(false, "搜索超时")
            return nil
        end
        
        local recvt = self.socket.select({self.client.sock}, nil, 0)
        if #recvt > 0 then
            self.client.sock:settimeout(60) 
            local response_body, recv_err = self.client:receive()
            if not response_body then
                if recv_err == "timeout" then return nil end
                self:stop()
                self.on_finish(true, nil)
                return nil
            end
            
            local ok_decode, parsed_body = pcall(self.JSON.decode, response_body)
            if ok_decode and type(parsed_body) == 'table' and #parsed_body > 0 then
                local chunk = {}
                for i, v in ipairs(parsed_body) do
                    if type(v) == "table" and type(v.name) == "string" and v.name ~= "" and type(v.bookUrl) == "string" and v.bookUrl ~= "" then
                        local deduplication_key = table.concat({v.name, v.author or "", tostring(v.originOrder or 1)}, "|||")
                        if not self.deduplication[deduplication_key] and self.filter_even(v) then
                            table.insert(chunk, v)
                            self.deduplication[deduplication_key] = true
                        end
                    end
                end
                if #chunk > 0 then
                    self.on_chunk(chunk)
                end
            end
        end
        return nil
    end
    
    local task = SearchTask:new()
    task:start(client, timeout, on_chunk, on_finish, filter_even)
    
    return function()
        if not task.is_done then
            task:stop()
            on_finish(false, "已取消")
        end
    end
end

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

  local JSON = require("json")
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

  local ok, err = client:connect(ws_server_address)
  if not ok then
      logger.err('ws连接出错', err)
      err = errHandler.map_message(err)
      return nil, "请求失败：" .. tostring(err)
  end

  if client.sock and client.sock.settimeout then
      client.sock:settimeout(timeout)
  end

    local function filter_even(book)
        if not H.is_tbl(book) then return false end

        local has_name_filter = H.is_str(filter and filter.name) and filter.name   ~= ""
        local has_author_filter = H.is_str(filter and filter.author) and filter.author ~= ""
        local has_origin_filter = H.is_str(filter and filter.origin) and filter.origin ~= ""

        if has_name_filter or has_author_filter or has_origin_filter then
            local match_name = has_name_filter and H.is_str(book.name) and book.name == filter.name
            local match_author = has_author_filter and H.is_str(book.author) and book.author == filter.author
            local match_origin = has_origin_filter and H.is_str(book.origin) and book.origin == filter.origin

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
              logger.err("ws receive 超时")
              break
          end

          local ok_decode, parsed_body = pcall(JSON.decode, response_body)
          if ok_decode and type(parsed_body) == 'table' and #parsed_body > 0 then
              for i, v in ipairs(parsed_body) do
                if H.is_tbl(v) and H.is_str(v.name) and v.name ~= "" and H.is_str(v.bookUrl) and v.bookUrl ~= "" then
                    local deduplication_key = table.concat({v.name, v.author or "", tostring(v.originOrder or 1)}, "|||")
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
      logger.err('ws返回数据出错：', result)
      return nil, 'ws返回数据出错：' .. tostring(result)
  end

  return result
end

return M
