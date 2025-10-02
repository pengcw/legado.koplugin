local time = require("ui/time")
local logger = require("logger")
local util = require("util")
local socket_url = require("socket.url")
local H = require("Legado/Helper")
local LegadoSpec = require("Legado/web_android_app")

local M = LegadoSpec:extend{
  name = "reader3",
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

function M:getProxyImageUrl(bookUrl, img_src)
    local res_img_src = img_src
    local server_address = self.settings.server_address
    
    local api_root_url = server_address:gsub("/reader3$", "")
    -- <img src='__API_ROOT__/book-assets/guest/剑来_/剑来.cbz/index/1.png' />
    res_img_src = custom_urlEncode(img_src):gsub("^__API_ROOT__", "")
    res_img_src = socket_url.absolute(api_root_url, res_img_src)
    return res_img_src
end

function M:getProxyEpubUrl(bookUrl, htmlUrl)
    if not H.is_str(htmlUrl) then
        return htmlUrl
    end
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
        timeouts = {15, 20},
    }, 'getBookSourcesList')
end

function M:getAvailableBookSource(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.book_url)) then
        return nil, '获取可用书源参数错误'
    end

    local bookUrl = options.book_url
    local name = options.name
    local author = options.author
    local last_index = options.last_index
    local search_size = options.search_size
    local is_more_call = options.last_index ~= nil
    if not is_more_call then
        local ret, err_msg = self:handleResponse(function()
            -- data=bookinfos
            return self.client:getAvailableBookSource({
                refresh = 0,
                url = bookUrl,
                v = os.time()
            })
        end, callback, {
            timeouts = {30, 50},
        }, 'getAvailableBookSource')
        if ret == nil then
            return ret, err_msg or "未知错误"
        else
            return {lastIndex = 0, list = ret}
        end
    end

    if not H.is_num(last_index) then
        last_index = -1
    end
    if not H.is_num(search_size) then
        search_size = 5
    end
    return self:handleResponse(function()
        -- data.list data.lastindex
        return self.client:searchBookSource({
            url = bookUrl,
            bookSourceGroup = '',
            lastIndex = last_index,
            searchSize = search_size,
            v = os.time()
        })

    end, callback, {
        timeouts = {70, 80},
    }, 'searchBookSource')
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

function M:searchBookMulti(options, callback)
     if not (H.is_tbl(options) and H.is_str(options.search_text) and options.search_text ~= '') then
        return nil, "输入参数错误"
    end

    local search_text = options.search_text
    local lastIndex = H.is_num(options.last_index) and options.last_index or -1
    local searchSize = H.is_num(options.search_size) and options.search_size or 20
    local concurrentCount = options.concurrent_count or 32
    
    return self:handleResponse(function()
        -- data.list data.lastindex
        return self.client:searchBookMulti({
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            lastIndex = lastIndex,
            searchSize = searchSize,
            v = os.time()
        })
    end, callback, {
        timeouts = {60, 80},
    }, 'searchBookMulti')
end

return M