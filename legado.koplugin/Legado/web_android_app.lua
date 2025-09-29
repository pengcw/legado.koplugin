local time = require("ui/time")
local logger = require("logger")
local Screen = require("device").screen
local util = require("util")
local socket_url = require("socket.url")
local H = require("Legado/Helper")

local M = {
  name = "legado_app",
  client = nil,
  settings = nil,
}

function M:new(o)
    o = o or {}
    setmetatable(o, {
        __index = function(_, k)
            local v = self[k]
            if v ~= nil then return v end
            return function() return nil, "后端暂不支持此功能" end
        end
    })
    if o.init then
        o:init()
    end
    return o
end

function M:init()
  local Spore = require("Spore")
  local legadoSpec = require("Legado/LegadoSpec").legado_app
  package.loaded["Legado/LegadoSpec"] = nil

  self.client = Spore.new_from_lua(legadoSpec, {
      base_url = self.settings.server_address .. '/'
      -- base_url = 'http://eu.httpbin.org/'
  })
  -- fix koreader ver 2024.05
  package.loaded["Spore.Middleware.ForceJSON"] = {}
  require("Spore.Middleware.ForceJSON").call = function(args, req)
      -- req.env.HTTP_USER_AGENT = ""
      req.headers = req.headers or {}
      req.headers["user-agent"] =
          "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+"
      return function(res)
          res.headers = res.headers or {}
          res.headers["content-type"] = 'application/json'
          return res
      end
  end
end

function M:handleResponse(requestFunc, callback, opts, logName)
  local socketutil = require("socketutil")

  local server_address = self.settings.server_address
  logName = logName or 'handleResponse'
  opts = opts or {}

  local timeouts = opts.timeouts
  if not H.is_tbl(timeouts) or not H.is_num(timeouts[1]) or not H.is_num(timeouts[2]) then
      timeouts = {8, 12}
  end

  self.client:reset_middlewares()
  self.client:enable("Format.JSON")
  self.client:enable("ForceJSON")

  -- 单次轮询 timeout,总 timeout
  socketutil:set_timeout(timeouts[1], timeouts[2])
  local status, res = pcall(requestFunc)
  socketutil:reset_timeout()

  if not (status and H.is_tbl(res) and H.is_tbl(res.body)) then

      local err_msg = H.errorHandler(res)
      logger.err(logName, "requestFunc err:", tostring(res))
      err_msg = H.map_error_message(err_msg)
      return nil, string.format("Web 服务: %s", err_msg)
  end

  if H.is_tbl(res.body) and res.body.isSuccess == true and res.body.data then
        return H.is_func(callback) and callback(res.body) or res.body.data
  else
      return nil, (res.body and res.body.errorMsg) and res.body.errorMsg or '出错'
  end
end

function M:getBookshelf(callback)
  return self:handleResponse(function()
      -- data=bookinfos
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

  local nowTime = time.now()
  bookinfo.time = time.to_ms(nowTime)

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

function M:deleteBook(bookinfo)
  if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl)) then
      return wrap_response(nil, "输入参数错误")
  end

  return self:handleResponse(function()
      -- {"isSuccess":true,"errorMsg":"","data":"删除书籍成功"}
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
  end, nil, {
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
      return self.client:saveBookProgress({
          name = chapter.name,
          author = chapter.author or '',
          durChapterPos = 0,
          durChapterIndex = chapters_index,
          durChapterTime = time.to_ms(time.now()),
          durChapterTitle = chapter.title or '',
          index = chapters_index,
          url = chapter.bookUrl,
          v = os.time()
      })
  end, callback, {
      timeouts = {3, 5}
  }, 'saveBookProgress')
end

function M:getProxyCoverUrl(coverUrl)
    if not H.is_str(coverUrl) then return coverUrl end
    local server_address = self.settings.server_address
    return table.concat({server_address, '/cover?path=', util.urlEncode(coverUrl)})
end
function M:getProxyImageUrl(bookUrl, img_src)
    local res_img_src = img_src
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

function M:searchBookSingle(options, callback)
    return nil, "后端不支持此功能"
end

-- { errmsg = "", list = err, lastIndex = 1}
function M:searchBookMulti(options, callback)
    local search_text = options.search_text
    local ret, err_msg = self:_searchBookSocket(search_text)
    if ret == nil then
        return ret, err_msg or "未知错误"
    else
        return {list = ret}
    end
end

function M:autoChangeBookSource_(bookinfo, callbak)
    self:_autoChangeSourceSocket(bookinfo, callbak)
end

function M:_searchBookSocket(search_text, filter, timeout)
  if not (H.is_str(search_text) and search_text ~= '') then
      return nil, "输入参数错误"
  end

  timeout = timeout or 60

  local is_precise = false
  if string.sub(search_text, 1, 1) == '=' then
      search_text = string.sub(search_text, 2)
      is_precise = true
  end

  local JSON = require("json")
  local websocket = require('Legado/websocket')

  local key_json = JSON.encode({
      key = search_text
  })

  local client = websocket.client.sync({
      timeout = 3
  })

  local parsed = socket_url.parse(self.settings.server_address)
  local ws_scheme
  if parsed.scheme == 'http' then
      ws_scheme = 'ws'
      if not parsed.port then
          parsed.port = 80
      end
  else
      ws_scheme = 'wss'
      if not parsed.port then
          parsed.port = 443
      end
  end

  parsed.port = parsed.port + 1

  local ws_server_address = string.format("%s://%s:%s%s", ws_scheme, parsed.host, parsed.port, "/searchBook")

  local ok, err = client:connect(ws_server_address)
  if not ok then
      logger.err('ws连接出错', err)
      err = H.map_error_message(err)
      return nil, "请求失败：" .. tostring(err)
  end

  local filterEven
  if H.is_tbl(filter) and filter.name then
      filterEven = function(line)
          if H.is_tbl(line) and (filter.name == nil or line.name == filter.name) and
              (filter.author == nil or line.author == filter.author) and
              (filter.origin == nil or line.origin == filter.origin) then
              return line
          end
      end
  elseif is_precise == true then
      filterEven = function(line)
          if H.is_tbl(line) and line.name and (line.name == search_text or line.author == search_text) then
              return line
          end
      end
  else
      filterEven = function(line)
          if H.is_tbl(line) then
              return line
          end
      end
  end

  client:send(key_json)
  ok, err = pcall(function()
      local response = {}
      local start_time = os.time()
      local deduplication = {}

      while true do
          local response_body = client:receive()
          if not response_body then
              break
          end

          if os.time() - start_time > timeout then
              logger.err("ws receive 超时")
              break
          end

          local _, parsed_body = pcall(JSON.decode, response_body)
          if type(parsed_body) ~= 'table' or #parsed_body == 0 then
              -- pong
              goto continue
          end

          local start_idx = #response + 1
          for i, v in ipairs(parsed_body) do

              local deduplication_key = table.concat({v.name, v.author or "", v.originOrder or 1})
              if not deduplication[deduplication_key] and filterEven(v) then
                  response[start_idx] = v
                  start_idx = start_idx + 1
                  deduplication[deduplication_key] = true
              end
          end

          ::continue::
      end
      deduplication = nil
      collectgarbage()
      collectgarbage()
      return response
  end)

  pcall(function()
      client:close()
  end)

  if not ok then
      logger.err('ws返回数据出错：', err)
      return nil, 'ws返回数据出错：' .. H.errorHandler(err)
  end

  return err
end

return M
