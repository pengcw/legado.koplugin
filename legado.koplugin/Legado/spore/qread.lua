local util = require("util")
local socket_url = require("socket.url")
local H = require("Legado/Helper")
local safe_pcall = require("Legado.Helper.Error").pcall
local LegadoSpec = require("Legado.spore.base")

local M = LegadoSpec:extend{
  name = "qread",
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

-- 打乱书源顺序，避免总是优先命中固定书源
local function source_list_shuffle(t)
    if type(t) ~= "table" or #t <= 1 then return t end
    local n = #t
    math.randomseed(os.time() + math.random(1000, 9999))
    for i = n, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function M:init()
    LegadoSpec.init(self)
end

function M:reader3Login()
    local socketutil = require("socketutil")
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
            model = "web"
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

function M:_getBookshelfPage()
    return self:handleResponse(function()
        return self.client:getBookshelfPage({
            oldmd5 = "e10adc3949ba59abbe56e057f20f883e"
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
    local total_pages = tonumber(ret.page) or 1
    if total_pages < 1 then total_pages = 1 end

    local all_books = {}
    local errors = {}

    for p = 1, total_pages do
        local page_data, page_err = self:handleResponse(function()
            return self.client:getBookshelfNew({
                md5 = md5,
                page = tostring(p),
            })
        end, nil, {
            timeouts = {8, 12}
        }, 'getBookshelf')

        if H.is_tbl(page_data) then
            for _, book in ipairs(page_data) do
                table.insert(all_books, book)
            end
        else
            table.insert(errors, page_err and tostring(page_err) or string.format("获取第%d页书架失败", p))
        end
    end

    if #errors > 0 and #all_books == 0 then
        return nil, table.concat(errors, "; ")
    end

    local response = {
        isSuccess = true,
        data = all_books,
    }

    if H.is_func(callback) then
        return callback(response)
    end
    return all_books
end


function M:getChapterListNew(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and bookinfo.bookUrl) then 
      return nil, "参数错误"
    end
  
    local bookUrl = bookinfo.bookUrl
    local bookSourceUrl = bookinfo.origin
    local bookname = H.is_str(bookinfo.name) and bookinfo.name or (H.is_str(bookinfo.bookname) and bookinfo.bookname or "")
    -- refresh=true：仅清除缓存场景绕过 24h 目录缓存
    local needRefresh = bookinfo.refresh == true and 1 or 0
    return self:handleResponse(function()
          return self.client:getChapterListNew({
              bookSourceUrl = bookSourceUrl,
              url = bookUrl,
              needRefresh = needRefresh,
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
  local down_chapters_index = chapter.chapters_index
  local bookSourceUrl = chapter.origin
  -- 书名统一用 name 字段
  local bookname = H.is_str(chapter.name) and chapter.name or ""

  local ret, err_msg = self:handleResponse(function()
      -- data={rules, text}
      return self.client:getBookContentNew({
          url = bookUrl,
          index = down_chapters_index,
          bookSourceUrl = bookSourceUrl,
          useReplaceRule = 1,
          bookname = bookname, -- 用于查找净化替换规则
          type = 0, --1表示强制不走缓存
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
            oldmd5 = "e10adc3949ba59abbe56e057f20f883e"
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
    local total_pages = tonumber(ret.page) or 1
    if total_pages < 1 then total_pages = 1 end

    local all_sources = {}
    local errors = {}

    for p = 1, total_pages do
        local page_data, page_err = self:handleResponse(function()
            return self.client:getBookSourcesNew({
                md5 = md5,
                page = tostring(p),
            })
        end, nil, {
            timeouts = {8, 18}
        }, 'getBookSourcesList')

        if H.is_tbl(page_data) then
            for _, source in ipairs(page_data) do
                table.insert(all_sources, source)
            end
        else
            table.insert(errors, page_err and tostring(page_err) or string.format("获取第%d页书源失败", p))
        end
    end

    if #errors > 0 and #all_sources == 0 then
        return nil, table.concat(errors, "; ")
    end

    local response = {
        isSuccess = true,
        data = all_sources,
    }

    if H.is_func(callback) then
        return callback(response)
    end
    return all_sources
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
    return self:getBookshelfNew(callback)
end

function M:getChapterList(bookinfo, callback)
    return self:getChapterListNew(bookinfo, callback)
end

function M:getBookContent(chapter, callback)
    return self:getBookContentNew(chapter, callback)
end

function M:saveBook(bookinfo, callback)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl) and
        H.is_str(bookinfo.originName)) then
        return nil, "saveBook参数错误"
    end
  
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
  
    end, callback, {
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
    return self:getBookSourcesListNew(callback)
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    local ret, err_msg = self:handleResponse(function()
        return self.client:getBookSourcesExploreUrl({
            bookSourceUrl = bookSourceUrl,
            need = nil,
        })
    end, nil, {
        timeouts = {12, 18},
    }, 'getBookSourcesExploreUrl')
    if not (H.is_tbl(ret) and H.is_str(ret.found)) then
        return nil, err_msg and tostring(err_msg) or "源探索未设置"
    end
    local explore_url = {
        exploreUrl = ret.found,
        bookSourceUrl = bookSourceUrl,
    }
    if H.is_func(callback) then
        return callback(explore_url)
    end
    return explore_url
end

function M:getAvailableBookSource2(options, _)
    if not (H.is_tbl(options) and H.is_str(options.book_url)) then
        return nil, '获取可用书源参数错误'
    end
    local bookUrl = options.book_url
    local ret, err_msg = self:handleResponse(function()
        return self.client:urlsaveBook({
            url = bookUrl,
        })
    end, nil, {
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

function M:getAvailableBookSource(options, on_finish, on_chunk)
    if not (H.is_tbl(options) and H.is_str(options.book_url) and 
            H.is_str(options.name) and options.name~= "" ) then
        if H.is_func(on_finish) then on_finish(false, '获取可用书源参数错误') end
        return nil
    end
    on_finish = H.is_func(on_finish) and on_finish or function() end
    on_chunk = H.is_func(on_chunk) and on_chunk or function() end

    local book_name = options.name
    local book_author = options.author

    -- 按 origin 去重（服务器模糊搜索返回同源重复；同名异作者靠 UI 区分）
    local cancel_func
    local finish_sent = false
    local all_results = {}
    local seen_origin = {}
    local function send_finish(success, data, msg, last_index)
        if finish_sent then return end
        finish_sent = true
        pcall(on_finish, success, data, msg, last_index)
    end

    cancel_func = self:searchBookMulti({
        search_text = book_name,
        name = book_name,
        author = book_author,
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

    return cancel_func
end

function M:searchBookSingle(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.search_text) and 
            options.search_text ~= '' and H.is_str(options.book_source_url)) then
        return nil, "searchBookSingle参数错误"
    end

    local search_text = options.search_text
    local bookSourceUrl = options.book_source_url

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
    -- {"isSuccess":true,"errorMsg":"success","data":",0,1,2,3,4,5,6,7,8,9"}
    -- {"isSuccess":true,"errorMsg":"success"}
    return self:handleResponse(function()
        return self.client:saveBookProgress({
            index = chapters_index,
            url = bookUrl,
            title = title,
            pos = 0, --pos 0.2
        })
    end, callback, {
        timeouts = {3, 5}
    }, 'saveBookProgress')
  end

function M:getReplaceRules(callback)
    return self:handleResponse(function()
        return self.client:getReplaceRulesPage({ v = os.time() })
    end, function(page_response)
        if not (type(page_response) == "table" and page_response.isSuccess == true
            and type(page_response.data) == "table") then
            if callback then callback({ type = "ERROR", message = "获取替换规则分页信息失败" }) end
            return nil, "获取替换规则分页信息失败"
        end
        local meta = page_response.data
        if not (type(meta.page) == "number" and type(meta.md5) == "string") then
            if callback then callback({ type = "ERROR", message = "替换规则分页数据格式异常" }) end
            return nil, "替换规则分页数据格式异常"
        end

        local all_rules = {}
        local errors = {}
        for p = 1, meta.page do
            local rules_data, rules_err = self:handleResponse(function()
                return self.client:getReplaceRulesNew({ md5 = meta.md5, page = tostring(p), v = os.time() })
            end)
            if rules_data and type(rules_data) == "table" then
                for _, rule in ipairs(rules_data) do
                    rule.order = rule.ruleorder or rule.order or 0
                    rule.group = rule.groupname or rule.group or ""
                    table.insert(all_rules, rule)
                end
            else
                table.insert(errors, tostring(rules_err))
            end
        end

        if #errors > 0 and #all_rules == 0 then
            if callback then callback({ type = "ERROR", message = "拉取替换规则失败: " .. table.concat(errors, "; ") }) end
            return nil, table.concat(errors, "; ")
        end

        if callback then callback({ type = "SUCCESS", body = all_rules }) end
        return all_rules
    end, { timeouts = {30, 60} }, 'getReplaceRules')
end

function M:getProxyCoverUrl(coverUrl)
    if not H.is_str(coverUrl) or coverUrl == "" then return coverUrl end
    local server_address = self.settings.server_address:gsub("/+$", "")
    if string.sub(coverUrl, 1, 1) == "/" then
        return socket_url.absolute(server_address, coverUrl)
    end
    if string.sub(coverUrl, 1, 8) == "baseurl/" then
        local url_path = string.sub(coverUrl, 8)
        if string.sub(url_path, 1, 1) ~= "/" then url_path = "/" .. url_path end
        return server_address .. url_path
    end
    if coverUrl:match("^%s*[hH][tT][tT][pP][sS]?://") then
        local proxy = server_address .. '/proxypng?url=' .. util.urlEncode(coverUrl)
        return { proxy, coverUrl }
    end
    return server_address .. '/proxypng?url=' .. util.urlEncode(coverUrl)
end

function M:getProxyImageUrl(_, img_src)
    if not H.is_str(img_src) or img_src == "" then return img_src end
    if string.sub(img_src, 1, 11) == "data:image/" then
        return img_src
    end
    -- 暂不支持段评
    if string.sub(img_src, 1, 3) == "dp:"  then
        return ""
    end
    local server_address = self.settings.server_address:gsub("/+$", "")
    if string.sub(img_src, 1, 1) == "/" then
        return socket_url.absolute(server_address, img_src)
    end
    if string.sub(img_src, 1, 8) == "baseurl/" then
        local url_path = string.sub(img_src, 8)
        if string.sub(url_path, 1, 1) ~= "/" then url_path = "/" .. url_path end
        return server_address .. url_path
    end
    return server_address .. '/proxypng?url=' .. util.urlEncode(img_src)
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

    local book_sources, err_msg = self:getBookSourcesList()
    if not (H.is_tbl(book_sources) and H.is_tbl(book_sources[1])) then
        if H.is_func(on_finish) then on_finish(false, err_msg or "获取书源列表失败") end
        return nil
    end

    local active_sources = {}
    for _, source in ipairs(book_sources) do
        if H.is_tbl(source) and source.enabled and H.is_str(source.bookSourceUrl) and
                source.bookSourceUrl ~= "" then
            table.insert(active_sources, source)
        end
    end
    if #active_sources == 0 then
        if H.is_func(on_finish) then on_finish(false, "没有启用的书源") end
        return nil
    end
    active_sources = source_list_shuffle(active_sources)

    local MAX_SOURCES = 500
    if #active_sources > MAX_SOURCES then
        for i = #active_sources, MAX_SOURCES + 1, -1 do
            active_sources[i] = nil
        end
    end

    local TaskQueue = require("Legado.task.Queue")

    local MAX_WORKERS = 4
    local SOURCE_TIMEOUT = 30

    local finish_sent = false
    local function send_finish(success, msg)
        if finish_sent then return end
        finish_sent = true
        if H.is_func(on_finish) then
            pcall(on_finish, success, msg)
        end
    end

    local channel_name = string.format("qread_search_%d_%d", os.time(), math.random(1000, 9999))
    local ch = TaskQueue:createChannel(channel_name, MAX_WORKERS, function(aborted)
        TaskQueue:destroyChannel(channel_name)
        if aborted then
            send_finish(false, "已取消")
        else
            send_finish(true, nil)
        end
    end)

    for _, source in ipairs(active_sources) do
        ch:pushTask(function(src)
            local status, ret = pcall(function()
                return self:handleResponse(function()
                    return self.client:searchBook({
                        key = search_text,
                        bookSourceUrl = src.bookSourceUrl,
                        page = 1,
                    })
                end, nil, {
                    timeouts = {10, 15},
                }, 'searchBookSingle')
            end)
            if not status or not H.is_tbl(ret) then return nil end

            local chunk = {}
            for _, book in ipairs(ret) do
                if H.is_tbl(book) and filter_search_book(book, search_text, is_exact_search, options)
                        and H.is_str(book.name) and book.name ~= ""
                        and H.is_str(book.bookUrl) and book.bookUrl ~= "" then
                    table.insert(chunk, book)
                end
            end
            return chunk
        end, function(ok, chunk)
            if ok and H.is_tbl(chunk) and #chunk > 0 and H.is_func(on_chunk) then
                pcall(on_chunk, chunk)
            end
        end, {
            args = {source},
            timeout = SOURCE_TIMEOUT,
        })
    end

    return function()
        -- 已 drain（全部完成）时 clearTasks 不触发 abort 回调，幂等补发"已取消"
        ch:clearTasks()
        send_finish(false, "已取消")
    end
end

function M:exploreBook(options, callback)
    if not (H.is_tbl(options) and H.is_str(options.ruleFindUrl) and H.is_str(options.bookSourceUrl)) then
        return nil, "发现书籍参数错误"
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

return M
