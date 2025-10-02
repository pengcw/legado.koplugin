local time = require("ui/time")
local logger = require("logger")
local util = require("util")
local socket_url = require("socket.url")
local H = require("Legado/Helper")
local LegadoSpec = require("Legado/web_android_app")

local M = LegadoSpec:extend{
  name = "qread",
  client = nil,
  settings = nil,
}

function M:init()
    LegadoSpec.init(self)
end

function M:reader3Login()
    local socketutil = require("socketutil")
    local server_address = self.settings['server_address']
    local reader3_un = self.settings.reader3_un
    local reader3_pwd = self.settings.reader3_pwd

    if not (H.is_str(reader3_un) and H.is_str(reader3_pwd) and 
                    reader3_pwd ~= "" and reader3_un ~= "") then
        return false, '认证信息设置不全'
    end

    self.client:reset_middlewares()
    self.client:enable("Format.JSON")
    self.client:enable("ForceJSON")
    socketutil:set_timeout(8, 10)

    local status, res = H.pcall(function()
        return self.client:login({
            username = reader3_un,
            password = reader3_pwd,
            model = "web"
        })
    end)
    socketutil:reset_timeout()

    if not status then
        return false,  res and tostring(res) or '获取用户信息出错'
    end
    if not (H.is_tbl(res) and H.is_tbl(res.body) ) then
        return false,
            (res.body and res.body.errorMsg) and res.body.errorMsg or "服务器返回了无效的数据结构"
    end
    if not (H.is_tbl(res.body.data) and H.is_str(res.body.data.accessToken)) then
        return false, '获取 Token 失败'
    end
    logger.dbg('get legado3token:', res.body.data.accessToken)

    self:reader3Token(res.body.data.accessToken)
    return true, res.body.data.accessToken
end

function M:_getBookshelfPage()
    return self:handleResponse(function()
        return self.client:getBookshelfPage({
            oldmd5 = "2025-09-28 08:50:11.020Z"
        })
    end, nil, {
      timeouts = {6, 10}
    }, 'getBookshelfPage')
end

function M:getBookshelfNew(callback)
    local ret, err_msg = self:_getBookshelfPage()
    if not (H.is_tbl(ret) and ret.md5) then
        return nil, err_msg and tostring(err_msg) or "未知错误"
    end
    local md5 = ret.md5
    local page = ret.page or 1

    return self:handleResponse(function()
        return self.client:getBookshelfNew({
            md5 = md5,
            page = page,
        })
    end, callback, {
      timeouts = {8, 12}
    }, 'getBookshelf')
end

function M:getChapterListNew(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and bookinfo.bookUrl) then 
      return nil, "参数错误"
    end
  
    local bookUrl = bookinfo.bookUrl
    local bookSourceUrl = bookinfo.origin
    local bookname = bookinfo.name
    return self:handleResponse(function()
          return self.client:getChapterListNew({
              bookSourceUrl = bookSourceUrl,
              url = bookUrl,
              needRefresh = 0,
              useReplaceRule = 1,
              bookname = bookname,
          })
    end, callback, {
      timeouts = {10, 18}
  }, 'getChapterList')
end

function M:getBookContentNew(chapter, callback)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookUrl) and H.is_num(chapter.chapters_index)) then
        return nil, 'getBookContent参数错误'
    end

  local bookUrl = chapter.bookUrl
  local chapters_index = chapter.chapters_index
  local down_chapters_index = chapter.chapters_index
  local bookSourceUrl = chapter.origin

  local ret, err_msg = self:handleResponse(function()
      -- data={rules, text}
      return self.client:getBookContentNew({
          url = bookUrl,
          index = down_chapters_index,
          bookSourceUrl = bookSourceUrl,
          useReplaceRule = 1,
          bookname = "",
          type = 0,
      })
  end, callback, {
      timeouts = {18, 25}
  }, 'getBookContent')
  
  if not H.is_tbl(ret) then
        return nil, err_msg and tostring(err_msg) or "未知错误"
  end
  return ret.text or "null"
end
function M:_getBookSourcesPage()
    return self:handleResponse(function()
        return self.client:getBookSourcesPage({
            oldmd5 = "2025-09-28 08:50:11.020Z"
        })
    end, nil, {
      timeouts = {6, 10}
    }, 'getBookSourcesPage')
end

function M:getBookSourcesListNew(callback)
    local ret, err_msg = self:_getBookSourcesPage()
    if not (H.is_tbl(ret) and ret.md5) then
        return nil, err_msg and tostring(err_msg) or "未知错误"
    end
    local md5 = ret.md5
    local page = ret.page or 1

    return self:handleResponse(function()
        return self.client:getBookSourcesNew({
            md5 = md5,
            page = page,
        })
    end, callback, {
      timeouts = {8, 12}
    }, 'getBookSourcesList')
end

function M:refreshBook(chapter, callback)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookUrl)) then
        return nil, '刷新书籍出错'
    end
    local bookUrl = chapter.bookUrl
    return self:handleResponse(function()
        return self.client:refreshBook({
            bookurl = bookUrl,
        })
    end, callback, {
        timeouts = {10, 20}
    }, 'refreshBook')
end

function M:getBookshelf(callback)
    return self:handleResponse(function()
        return self.client:getBookshelf({
            version = '3.2.1'
        })
    end, callback, {
      timeouts = {8, 12}
    }, 'getBookshelf')
end

function M:getChapterList(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and bookinfo.bookUrl) then 
      return nil, "参数错误"
    end
  
    local bookUrl = bookinfo.bookUrl
    local bookSourceUrl = bookinfo.origin
    local bookname = bookinfo.name
    return self:handleResponse(function()
          return self.client:getChapterList({
              bookSourceUrl = bookSourceUrl,
              url = bookUrl,
          })
    end, callback, {
      timeouts = {10, 18}
  }, 'getChapterList')
end

function M:getBookContent(chapter, callback)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookUrl) and  H.is_str(chapter.origin) and H.is_num(chapter.chapters_index)) then
        return nil, 'getBookContent参数错误'
    end

  local bookUrl = chapter.bookUrl
  local chapters_index = chapter.chapters_index
  local down_chapters_index = chapter.chapters_index
  local bookSourceUrl = chapter.origin

  return self:handleResponse(function()
      -- data={rules, text}
      return self.client:getBookContent({
          url = bookUrl,
          index = down_chapters_index,
          bookSourceUrl = bookSourceUrl,
          type = 0,
      })
  end, callback, {
      timeouts = {18, 25}
  }, 'getBookContent')
end

function M:saveBook(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl) and
        H.is_str(bookinfo.originName)) then
        return nil, "saveBook参数错误"
    end
  
    local nowTime = time.now()
    bookinfo.time = time.to_ms(nowTime)
  
    return self:handleResponse(function()
        -- data=bookinfo
        return self.client:saveBook({
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
        timeouts = {10, 12}
    }, 'saveBook')
  end
  
  function M:deleteBook(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl)) then
        return nil, "deleteBook参数错误"
    end
  
    return self:handleResponse(function()
        return self.client:deleteBook({
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

function M:getBookSourcesList(callback)
    return self:handleResponse(function()
        return self.client:getBookSources({
            isall = 0,
        })
    end, callback, {
        timeouts = {15, 20},
    }, 'getBookSourcesList')
end

function M:getAvailableBookSource(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.book_url)) then
        return nil, '获取可用书源参数错误'
    end
    local bookUrl = options.book_url
    local ret, err_msg = self:handleResponse(function()
        return self.client:urlsaveBook({
            url = bookUrl,
        })
    end, callback, {
        timeouts = {15, 20},
    }, 'getAvailableBookSource')

    if ret == nil then
        return nil, err_msg or "未知错误"
    else
        -- 只返回了一个源数据?
        if H.is_tbl(ret) and not H.is_tbl(ret[1]) then
            return {list = {ret}}
        end
        return {list = ret}
    end
end

function M:searchBookSingle(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.search_text) and 
            options.search_text ~= '' and H.is_str(options.book_source_url)) then
        return nil, "searchBookSingle参数错误"
    end

    local search_text = options.search_text
    local bookSourceUrl = options.book_source_url
    local concurrentCount = options.concurrent_count or 32

    return self:handleResponse(function()
        -- data = bookinfolist
        return self.client:searchBook({
            key = search_text,
            bookSourceUrl = bookSourceUrl,
            page = 1,
        })
    end, callback, {
        timeouts = {20, 30},
    }, 'searchBookSingle')
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
        })
    end, callback, {
        timeouts = {25, 30},
    }, 'changeBookSource')
end

function M:refreshBookContent(chapter, callback)
    if not (H.is_tbl(chapter) and H.is_str(chapter.bookUrl)) then
        return nil, '刷新章节出错'
    end
    local bookUrl = chapter.bookUrl
    local chapters_index = chapter.chapters_index
    return self:handleResponse(function()
        return self.client:fetchBookContent({
            url = bookUrl,
            index = chapters_index,
        })
    end, callback, {
        timeouts = {10, 20}
    }, 'refreshBookContent')
end

function M:saveBookProgress(chapter, callback)
    if not (H.is_tbl(chapter) and H.is_str(chapter.title) and H.is_str(chapter.bookUrl)) then
        return nil, '参数错误'
    end
    local chapters_index = chapter.chapters_index
    local bookUrl = chapter.bookUrl
    local title = chapter.title

    return self:handleResponse(function()
        return self.client:saveBookProgress({
            index = chapters_index,
            url = bookUrl,
            title = title,
            pos = 0.1,
        })
    end, callback, {
        timeouts = {3, 5}
    }, 'saveBookProgress')
  end

function M:getProxyCoverUrl(coverUrl)
    if not H.is_str(coverUrl) then return coverUrl end
    local res_cover_src = coverUrl
    local server_address = self.settings.server_address
    local res_cover_src = table.concat({server_address, '/proxypng?url=', util.urlEncode(res_cover_src)})
    return res_cover_src
end
function M:getProxyImageUrl(bookUrl, img_src)
    local res_img_src = img_src
    local server_address = self.settings.server_address
    local res_img_src = table.concat({server_address, '/proxypng?url=', util.urlEncode(res_img_src)})
    return res_img_src
end

function M:searchBookMulti(callback)
    return self:unsupportedMethod()
end

return M
