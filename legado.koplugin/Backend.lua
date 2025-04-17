local logger = require("logger")
local Device = require("device")
local ffiUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5
local dbg = require("dbg")
local LuaSettings = require("luasettings")
local socket_url = require("socket.url")
local util = require("util")
local time = require("ui/time")

local UIManager = require("ui/uimanager")
local H = require("libs/Helper")

local function wrap_response(data, err_message)
    return data ~= nil and {
        type = 'SUCCESS',
        body = data
    } or {
        type = 'ERROR',
        message = err_message or "Unknown error"
    }
end

local function get_img_src(html)
    if type(html) ~= "string" then
        return {}
    end

    local img_sources = {}
    -- local img_pattern = "<img[^>]*src%s*=%s*([\"']?)([^%s\"'>]+)%1[^>]*>"
    local img_pattern = '<img[^>]-src%s*=%s*["\']?([^"\'>%s]+)["\']?[^>]*>'

    for src in html:gmatch(img_pattern) do
        if src and src ~= "" then
            table.insert(img_sources, src)
        end
    end

    return img_sources
end

local function get_extension_from_content_type(content_type)
    local extensions = {
        ["image/jpeg"] = "jpg",
        ["image/png"] = "png",
        ["image/gif"] = "gif",
        ["image/bmp"] = "bmp",
        ["image/webp"] = "webp",
        ["image/tiff"] = "tiff",
        ["image/svg+xml"] = "svg"
    }

    return extensions[content_type]
end

local function get_image_format_head8(image_data)
    if type(image_data) ~= "string" then
        return
    end

    local header = image_data:sub(1, 8)

    if header:sub(1, 3) == "\xFF\xD8\xFF" then
        return "jpg"
    elseif header:sub(1, 8) == "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A" then
        return "png"
    elseif header:sub(1, 4) == "\x47\x49\x46\x38" then
        return "gif"
    elseif header:sub(1, 2) == "\x42\x4D" then
        return "bmp"
    elseif header:sub(1, 4) == "\x52\x49\x46\x46" then
        return "webp"
    else

        return
    end
end

local function pDownload_Image(img_src, timeout, maxtime)

    local ltn12 = require("ltn12")
    local socket = require("socket")
    local http = require("socket.http")
    local socketutil = require("socketutil")

    timeout = timeout or 600

    local parsed = socket_url.parse(img_src)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        error("Unsupported protocol")
    end

    local imageData = {}
    local request = {
        url = img_src,
        method = "GET",
        sink = maxtime and socketutil.table_sink(imageData) or ltn12.sink.table(imageData),
        create = socketutil.tcp
    }

    socketutil:set_timeout(timeout, maxtime or 700)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE or code == socketutil.SSL_HANDSHAKE_CODE or code == socketutil.SINK_TIMEOUT_CODE then
        logger.err("request interrupted:", code)
        error("request interrupted:" .. tostring(code))
    end

    if headers == nil then
        logger.warn("No HTTP headers:", status or code or "network unreachable")
        error("Network or remote server unavailable")
    end
    if type(code) ~= 'number' or code < 200 or code > 299 then
        logger.warn("HTTP status not okay:", status or code or "network unreachable")
        logger.dbg("Response headers:", headers)
        error("Remote server error or unavailable")
    end

    local merge_image_data = table.concat(imageData)
    if headers and headers["content-length"] then
        local content_length = tonumber(headers["content-length"])
        if #merge_image_data ~= content_length then
            error("Incomplete content received")
        end
    end

    local extension = 'bin'

    local contentType = headers["content-type"]

    if contentType and contentType:match("^image/") then
        extension = get_extension_from_content_type(contentType) or 'bin'
    else
        extension = get_image_format_head8(merge_image_data) or 'bin'
    end

    return {
        data = merge_image_data,
        ext = extension
    }
end

local function pDownload_CreateCBZ(filePath, img_sources)

    dbg.v('CreateCBZ strat:')

    if not filePath or not H.is_tbl(img_sources) then
        error("Cbz param error:")
    end

    local is_convertToGrayscale = false

    local cbz_path_tmp = filePath .. '.downloading'

    if util.fileExists(cbz_path_tmp) then
        if M:isExtractingInBackground() == true then
            error("Other threads downloading, cancelled")
        else
            util.removeFile(cbz_path_tmp)
        end
    end

    local ZipWriter = require("ffi/zipwriter")

    local cbz = ZipWriter:new{}
    if not cbz:open(cbz_path_tmp) then
        error('CreateCBZ cbz:open err')
    end
    cbz:add("mimetype", "application/vnd.comicbook+zip", true)

    local no_compression = true

    for i, img_src in ipairs(img_sources) do

        dbg.v('Download_Image start', i, img_src)
        local status, err = pcall(pDownload_Image, img_src)

        if status and H.is_tbl(err) and err['data'] then

            local imgdata = err['data']
            local img_extension = err['ext'] or "jpg"

            local img_name = string.format("%d.%s", i, img_extension)
            if is_convertToGrayscale == true and img_extension == 'png' then
                local success, imgdata_new = convertToGrayscale(imgdata)
                if success ~= true then

                    goto continue
                end
                imgdata = imgdata_new.data
            end

            cbz:add(img_name, imgdata, no_compression)

        else
            dbg.v('Download_Image err', tostring(err))
        end
        ::continue::
    end

    cbz:close()
    dbg.v('CreateCBZ cbz:close')

    if util.fileExists(filePath) ~= true then
        os.rename(cbz_path_tmp, filePath)
    else
        if util.fileExists(cbz_path_tmp) == true then
            util.removeFile(cbz_path_tmp)
        end
        error('exist target file, cancelled')
    end

    return filePath
end

local function convertToGrayscale(image_data)
    local Png = require("lib/Png")
    return Png.processImage(Png.toGrayscale, image_data, 1)

end

local M = {
    dbManager = {},
    settings_data = nil,
    task_pid_file = nil,
    apiClient = nil
}

function M:HandleResponse(response, on_success, on_error)
    if not response then
        return on_error and on_error("Response is nil")
    end

    local rtype = response.type
    if rtype == "SUCCESS" then
        return on_success and on_success(response.body)
    elseif rtype == "ERROR" then
        return on_error and on_error(response.message or "")
    end
    return on_error and on_error("Unknown response type: " .. tostring(rtype))
end

function M:loadSpore()
    local Spore = require("Spore")
    local legadoSpec = require("libs/LegadoSpec")
    self.apiClient = Spore.new_from_lua(legadoSpec, {
        base_url = self.settings_data.data.server_address .. '/'
        -- base_url = 'http://eu.httpbin.org/'
    })
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
    package.loaded["Spore.Middleware.Legado3Auth"] = {}
    require("Spore.Middleware.Legado3Auth").call = function(args, req)
        local spore = req.env.spore

        if self.settings_data.data.reader3_un ~= '' then

            local loginSuccess, token = self:_reader3Login()
            if loginSuccess == true and type(token) == 'string' and token ~= '' then

                local accessToken = string.format("accessToken=%s", token)
                if type(req.env.QUERY_STRING) == 'string' and #req.env.QUERY_STRING > 0 then
                    req.env.QUERY_STRING = req.env.QUERY_STRING .. '&' .. accessToken
                else
                    req.env.QUERY_STRING = accessToken
                end
            else
                logger.warn('Legado3Auth', '登录失败', token or 'nil')
            end
        end

        return function(res)
            if type(res.body) == 'table' and res.body.data == "NEED_LOGIN" and res.body.isSuccess == false then
                self:resetReader3Token()
            end
            return res
        end
    end
end

function M:initialize()
    self.settings_data = LuaSettings:open(H.getUserSettingsPath())
    self.task_pid_file = H.getTempDirectory() .. '/task.pid.lua'

    -- 兼容历史版本 <1.038
    if H.is_nil(self.settings_data.data.setting_url) and H.is_nil(self.settings_data.data.reader3_un) and
        H.is_str(self.settings_data.data.legado_server) then
        self.settings_data.data.setting_url = self.settings_data.data.legado_server
    end
    -- <1.049
    if not self.settings_data.data.server_address and H.is_str(self.settings_data.data.legado_server) then
        self.settings_data.data.server_address = self.settings_data.data.legado_server
        if string.find(string.lower(self.settings_data.data.server_address), "/reader3$") then
            self.settings_data.data.server_type = 2
        else
            self.settings_data.data.server_type = 1
        end
        self.settings_data.data.legado_server = nil
        self.settings_data:flush()
    end

    if self.settings_data and not self.settings_data.data['server_address'] then
        self.settings_data.data = {
            chapter_sorting_mode = "chapter_descending",
            server_address = 'http://127.0.0.1:1122',
            server_address_md5 = 'f528764d624db129b32c21fbca0cb8d6',
            server_type = 1,
            setting_url = 'http://127.0.0.1:1122',
            reader3_un = '',
            reader3_pwd = '',
            servers_history = {},
            stream_image_view = false
        }
        self.settings_data:flush()
    end

    self:loadSpore()

    local BookInfoDB = require("BookInfoDB")
    self.dbManager = BookInfoDB:new({
        dbPath = H.getTempDirectory() .. "/bookinfo.db"
    })
end

function M:show_notice(msg, timeout)
    local Notification = require("ui/widget/notification")
    Notification:notify(msg or '', Notification.SOURCE_ALWAYS_SHOW)
end

function M:backgroundCacheConfig()
    return LuaSettings:open(H.getTempDirectory() .. '/cache.lua')
end
function M:resetReader3Token()
    self:backgroundCacheConfig():delSetting('r3k'):flush()
end

function M:_reader3Login()
    local cache_config = self:backgroundCacheConfig()
    if H.is_str(cache_config.data.r3k) then
        return true, cache_config.data.r3k
    end

    local socketutil = require("socketutil")
    local server_address = self.settings_data.data['server_address']
    local reader3_un = self.settings_data.data.reader3_un
    local reader3_pwd = self.settings_data.data.reader3_pwd

    if not H.is_str(reader3_un) or not H.is_str(reader3_pwd) or reader3_pwd == '' or reader3_un == '' then
        return false, '认证信息设置不全'
    end

    self.apiClient:reset_middlewares()
    self.apiClient:enable("Format.JSON")
    self.apiClient:enable("ForceJSON")
    socketutil:set_timeout(8, 10)

    local status, res = pcall(function()
        return self.apiClient:reader3Login({
            username = reader3_un,
            password = reader3_pwd,
            code = "",
            isLogin = true,
            v = os.time()
        })
    end)
    socketutil:reset_timeout()

    if not status then
        return false, H.errorHandler(res) or '获取用户信息出错'
    end

    if not H.is_tbl(res.body) or not H.is_tbl(res.body.data) then
        return false,
            (res.body and res.body.errorMsg) and res.body.errorMsg or "服务器返回了无效的数据结构"
    end

    if not H.is_str(res.body.data.accessToken) then
        return false, '获取Token失败'
    end

    logger.dbg('get legado3token:', res.body.data.accessToken)

    cache_config:saveSetting("r3k", res.body.data.accessToken):flush()

    return true, res.body.data.accessToken
end

function M:legadoSporeApi(requestFunc, callback, opts, logName)
    local socketutil = require("socketutil")

    local server_address = self.settings_data.data['server_address']
    logName = logName or 'legadoSporeApi'
    opts = opts or {}

    local isServerOnly = opts.isServerOnly
    local timeouts = opts.timeouts
    if not H.is_tbl(timeouts) or not H.is_num(timeouts[1]) or not H.is_num(timeouts[2]) then
        timeouts = {8, 12}
    end

    if isServerOnly == true and self.settings_data.data.server_type ~= 2 then
        return wrap_response(nil, "仅支持服务器版本\r\n其它请在app操作后刷新")
    end

    self.apiClient:reset_middlewares()
    self.apiClient:enable("Legado3Auth")
    self.apiClient:enable("Format.JSON")
    self.apiClient:enable("ForceJSON")

    socketutil:set_timeout(timeouts[1], timeouts[2])
    local status, res = pcall(requestFunc)
    socketutil:reset_timeout()

    if not status or not H.is_tbl(res.body) then

        local err_msg = H.errorHandler(res)
        if err_msg == "wantread" then
            err_msg = '连接超时'
        end
        logger.err(logName, 'requestFunc err:', tostring(res))
        return wrap_response(nil, 'requestFunc: ' .. err_msg)
    end

    if H.is_tbl(res.body) and res.body.data == "NEED_LOGIN" and res.body.isSuccess == false then
        self:resetReader3Token()
        self:_reader3Login()
        return wrap_response(nil, 'NEED_LOGIN,刷新并继续')
    end

    if H.is_tbl(res.body) and res.body.isSuccess == true and not H.is_nil(res.body.data) then
        if H.is_func(callback) then
            return callback(res.body)
        else
            return wrap_response(res.body.data)
        end
    else
        return wrap_response(nil, (res.body and res.body.errorMsg) and res.body.errorMsg or '出错')
    end
end

function M:refreshChaptersCache(bookinfo, last_refresh_time)

    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
    end

    local book_cache_id = bookinfo.cache_id
    local bookUrl = bookinfo.bookUrl

    if not bookUrl or not H.is_str(book_cache_id) then
        return wrap_response(nil, "获取目录参数错误")
    end
    return self:legadoSporeApi(function()
        return self.apiClient:getChapterList({
            url = bookUrl,
            v = os.time()
        })
    end, function(response)

        local status, err = pcall(function()
            return self.dbManager:upsertChapters(book_cache_id, response.data)
        end)

        if not status then
            dbg.log('refreshChaptersCache数据写入', tostring(err))
            return wrap_response(nil, '数据写入出错,请重试')
        end
        return wrap_response(true)
    end, {
        timeouts = {12, 12}
    }, 'refreshChaptersCache')
end

function M:refreshLibraryCache(last_refresh_time)

    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
    end

    return self:legadoSporeApi(function()
        -- data=bookinfos
        return self.apiClient:getBookshelf({
            refresh = 0,

            v = os.time()
        })
    end, function(response)
        local bookShelfId = self:getServerPathCode()
        local status, err = pcall(function()
            return self.dbManager:upsertBooks(bookShelfId, response.data)
        end)

        if not status then
            dbg.log('refreshLibraryCache数据写入', H.errorHandler(err))
            return wrap_response(nil, '写入数据出错,请重试')
        end

        return wrap_response(true)
    end, {
        timeouts = {6, 10}
    }, 'refreshLibraryCache')
end

function M:pGetChapterContent(chapter)
    local bookUrl = chapter.bookUrl
    local chapters_index = chapter.chapters_index
    local down_chapters_index = chapter.chapters_index

    if not H.is_str(bookUrl) or not H.is_num(down_chapters_index) then
        return wrap_response(nil, 'GetChapterContent参数错误')
    end

    return self:legadoSporeApi(function()
        -- data=string
        return self.apiClient:getBookContent({

            url = bookUrl,
            index = down_chapters_index,
            v = os.time()
        })
    end, nil, {
        timeouts = {18, 25}
    }, 'GetChapterContent')
end

function M:saveBookProgress(chapter)

    if not (H.is_str(chapter.name) and H.is_str(chapter.bookUrl)) then
        return wrap_response(nil, '参数错误')
    end
    local chapters_index = chapter.chapters_index

    return self:legadoSporeApi(function()
        return self.apiClient:saveBookProgress({
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
    end, nil, {
        timeouts = {3, 3}
    }, 'saveBookProgress')

end

function M:getAvailableBookSource(bookUrl)
    if not H.is_str(bookUrl) then
        return wrap_response(nil, '获取可用书源参数错误')
    end

    return self:legadoSporeApi(function()
        -- data=bookinfos
        return self.apiClient:getAvailableBookSource({
            refresh = 0,
            url = bookUrl,
            v = os.time()
        })
    end, nil, {
        timeouts = {30, 50},
        isServerOnly = true
    }, 'getAvailableBookSource')

end

function M:getBookSourcesList()
    return self:legadoSporeApi(function()
        return self.apiClient:getBookSources({
            simple = 1,
            v = os.time()
        })
    end, nil, {
        timeouts = {15, 20},
        isServerOnly = true
    }, 'getBookSourcesList')
end

function M:setBookSource(newBookSource)
    -- origin = bookSourceUrl
    -- return bookinfo
    if not H.is_tbl(newBookSource) or not H.is_str(newBookSource.bookUrl) or not H.is_str(newBookSource.newUrl) or
        not H.is_str(newBookSource.bookSourceUrl) then
        return wrap_response(nil, '更换书源参数错误')
    end

    return self:legadoSporeApi(function()
        -- data=bookinfo
        return self.apiClient:setBookSource({
            bookUrl = newBookSource.bookUrl,
            bookSourceUrl = newBookSource.bookSourceUrl,
            newUrl = newBookSource.newUrl,
            v = os.time()
        })
    end, function(response)
        if H.is_str(response.data.name) and H.is_str(response.data.bookUrl) and H.is_str(response.data.origin) then
            local bookShelfId = self:getServerPathCode()
            local response = {response.data}
            local status, err = pcall(function()
                return self.dbManager:upsertBooks(bookShelfId, response, true)
            end)

            if not status then
                dbg.log('setBookSource数据写入', tostring(err))
                return wrap_response(nil, '数据写入出错,请重试')
            end
            return wrap_response(true)
        else
            return wrap_response(nil, '接口返回数据格式错误')
        end
    end, {
        timeouts = {10, 18},
        isServerOnly = true
    }, 'setBookSource')

end

function M:searchBookSource(bookUrl, lastIndex, searchSize)
    if not H.is_str(bookUrl) then
        return wrap_response(nil, '获取更多书源参数错误')
    end
    if not H.is_num(lastIndex) then
        lastIndex = -1
    end
    if not H.is_num(lastIndex) then
        searchSize = 5
    end
    return self:legadoSporeApi(function()
        -- data.list data.lastindex
        return self.apiClient:searchBookSource({
            url = bookUrl,
            bookSourceGroup = '',
            lastIndex = lastIndex,
            searchSize = searchSize,
            v = os.time()
        })

    end, nil, {
        timeouts = {100, 120},
        isServerOnly = true
    }, 'searchBook')

end
function M:searchBook(search_text, bookSourceUrl, concurrentCount)
    if not (H.is_str(search_text) and search_text ~= '' and H.is_str(bookSourceUrl)) then
        return wrap_response(nil, "输入参数错误")
    end
    concurrentCount = concurrentCount or 32
    return self:legadoSporeApi(function()
        -- data = bookinfolist
        return self.apiClient:searchBook({
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            bookSourceUrl = bookSourceUrl,
            lastIndex = -1,
            page = 1,
            v = os.time()
        })
    end, nil, {
        timeouts = {20, 30},
        isServerOnly = true
    }, 'searchBook')
end

function M:searchBookMulti(search_text, lastIndex, searchSize, concurrentCount)

    if not H.is_str(search_text) or search_text == '' then
        return wrap_response(nil, "输入参数错误")
    end

    lastIndex = lastIndex or -1
    searchSize = searchSize or 20
    concurrentCount = concurrentCount or 32
    return self:legadoSporeApi(function()
        -- data.list data.lastindex
        return self.apiClient:searchBookMulti({
            key = search_text,
            bookSourceGroup = '',
            concurrentCount = concurrentCount,
            lastIndex = lastIndex,
            searchSize = searchSize,
            v = os.time()
        })
    end, nil, {
        timeouts = {60, 80},
        isServerOnly = true
    }, 'searchBook')
end

function M:addBookToLibrary(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl) and
        H.is_str(bookinfo.originName)) then
        return wrap_response(nil, "输入参数错误")
    end

    local nowTime = time.now()
    bookinfo.time = time.to_ms(nowTime)

    return self:legadoSporeApi(function()
        -- data=bookinfo
        return self.apiClient:saveBook({

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

    end, function(response)
        if H.is_str(response.data.name) and H.is_str(response.data.bookUrl) and H.is_str(response.data.origin) then
            local bookShelfId = self:getServerPathCode()
            local db_save = {response.data}
            local status, err = pcall(function()
                return self.dbManager:upsertBooks(bookShelfId, db_save, true)
            end)

            if not status then
                dbg.log('addBookToLibrary数据写入', tostring(err))
                return wrap_response(nil, '数据写入出错,请重试')
            end
            return wrap_response(true)
        else
            return wrap_response(nil, '接口返回数据格式错误')
        end
    end, {
        timeouts = {10, 12}
    }, 'addBookToLibrary')

end

function M:deleteBook(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and H.is_str(bookinfo.origin) and H.is_str(bookinfo.bookUrl)) then
        return wrap_response(nil, "输入参数错误")
    end

    return self:legadoSporeApi(function()
        -- {"isSuccess":true,"errorMsg":"","data":"删除书籍成功"}
        return self.apiClient:deleteBook({

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

local function splitParagraphsPreserveBlank(text)
    if not text or text == "" then
        return ""
    end

    local paragraphs = {}
    -- Koreader .txt auto add a indentEnglish
    -- 兼容: 2半角+1全角
    local indentChinese = "  　"
    -- local indentChinese = "__"
    local indentEnglish = "  "

    -- 标准化换行符号，合并连续换行符为最多两个
    text = text:gsub("\r\n?", "\n"):gsub("\n+", function(s)
        return (#s >= 2) and "\n\n" or s
    end)

    local lineCount = select(2, text:gsub("\n", "")) + 1
    paragraphs = table.create and table.create(lineCount) or paragraphs

    local lines = {}
    for line in text:gmatch("([^\n]*)\n?") do
        table.insert(lines, line)
    end
    text = nil

    for _, line in ipairs(lines) do
        -- %s 全角 特殊空格:\u{00A0}
        local trimmed = line:gsub("^[%s　 ]+", "")
        -- :gsub("[%s　 ]+$", "") 

        if trimmed ~= "" then
            -- 非ASCII按中文处理 ffiUtil.utf8charcode
            local first_byte = trimmed:sub(1, 1):byte()
            local prefix = (first_byte and first_byte < 128) and indentEnglish or indentChinese
            table.insert(paragraphs, prefix .. trimmed)
        end
    end
    lines = nil
    -- return table.concat(paragraphs, "§\n")
    return table.concat(paragraphs, "\n")
end

function M:pDownloadChapter(chapter, message_dialog, is_recursive)

    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    local chapter_title = chapter.title or ''
    local down_chapters_index = chapter.chapters_index

    local function message_show(msg)
        if message_dialog then
            message_dialog.text = msg
            UIManager:setDirty(message_dialog, "ui")
            UIManager:forceRePaint()
        end
    end

    if bookUrl == nil or not book_cache_id then
        error('pDownloadChapter input parameters err' .. tostring(bookUrl) .. tostring(book_cache_id))
    end

    local cache_chapter = self:getCacheChapterFilePath(chapter)
    if cache_chapter and cache_chapter.cacheFilePath then
        return cache_chapter
    end

    local response = self:pGetChapterContent(chapter)

    if is_recursive ~= true and H.is_tbl(response) and response.type == 'ERROR' and
        string.find(tostring(response.message), 'NEED_LOGIN', 1, true) then
        self:resetReader3Token()
        self:pDownloadChapter(chapter, message_dialog, true)
    end

    if not H.is_tbl(response) or response.type ~= 'SUCCESS' then
        error(response.message or '章节下载失败')
    end

    local content = response.body

    if type(content) ~= "string" then
        content = tostring(content)
    end

    local filePath = H.getChapterCacheFilePath(book_cache_id, chapters_index)

    local first_line = string.match(content, "([^\n]*)\n?") or content

    if string.find(first_line, "<img", 1, true) then

        local img_sources = self:getProxyImageUrl(bookUrl, content)
        if H.is_tbl(img_sources) and #img_sources > 0 then

            filePath = filePath .. '.cbz'
            local status, err = pcall(function()
                pDownload_CreateCBZ(filePath, img_sources)
            end)

            if not status then
                error('CreateCBZ err:' .. tostring(err))
            end

            if chapter.is_pre_loading == true then
                dbg.v('Cache task completed chapter.title:', chapter_title)
            end

            chapter.cacheFilePath = filePath
            return chapter

        else
            error('生成图片列表失败')
        end

    else

        if string.match((first_line or ''):lower(), "%.x?html$") then
            -- epub
            local html_url = self:getProxyEpubUrl(bookUrl, first_line)
            if html_url == nil or html_url == '' then
                error('转换失败')
            end
            local status, err = pcall(pDownload_Image, html_url)
            if not status then
                error('下载失败:' .. tostring(err))
            end
            local ext = first_line:match("[^%.]+$") or "html"
            content = err['data'] or '下载失败'
            filePath = filePath .. '.' .. ext

        else

            filePath = filePath .. '.txt'
            content = splitParagraphsPreserveBlank(content)

            if content == "" then
                chapter.content_is_nil = true
            end

            if not string.find(first_line, chapter_title, 1, true) then
                content = table.concat({"\t\t", tostring(chapter_title), "\n\n", content})
            end

        end

        if util.fileExists(filePath) then
            if chapter.is_pre_loading == true then

                error('存在目标任务,本次任务取消')
            else

                chapter.cacheFilePath = filePath
                return chapter
            end
        end

        if util.writeToFile(content, filePath, true) then

            if chapter.is_pre_loading == true then
                dbg.v('Cache task completed chapter.title', chapter_title)
            end

            chapter.cacheFilePath = filePath
            return chapter
        else

            error('下载content写入失败')
        end
    end

end

function M:getCacheChapterFilePath(chapter)

    if not H.is_tbl(chapter) or chapter.book_cache_id == nil or chapter.chapters_index == nil then
        dbg.log('getCacheChapterFilePath parameters err:', chapter)
        return chapter
    end

    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index

    local cache_file_path = chapter.cacheFilePath
    local cacheExt = chapter.cacheExt

    if H.is_str(cache_file_path) then
        if util.fileExists(cache_file_path) then
            chapter.cacheFilePath = cache_file_path
            return chapter
        else
            dbg.v('Files are deleted, clear database record flag', cache_file_path)
            pcall(function()
                self.dbManager:updateCacheFilePath(chapter, false)
            end)
            chapter.cacheFilePath = nil
        end
    end

    local filePath = H.getChapterCacheFilePath(book_cache_id, chapters_index)

    local extensions = {'txt', 'cbz', 'html', 'xhtml', 'jpg', 'png'}

    if H.is_str(cacheExt) then

        table.insert(extensions, 1, chapter.cacheExt)
    end

    for _, ext in ipairs(extensions) do
        local fullPath = filePath .. '.' .. ext
        if util.fileExists(fullPath) then
            chapter.cacheFilePath = fullPath
            return chapter
        end
    end

    return chapter
end

function M:findNextChaptersNotDownLoad(current_chapter, count)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log('findNextChaptersNotDownLoad: bad params', current_chapter)
        return {}
    end

    if current_chapter.call_event == nil then
        current_chapter.call_event = 'next'
    end

    local next_chapters = self.dbManager:findChapterNotDownLoadLittle(current_chapter, count)

    if not H.is_tbl(next_chapters[1]) or next_chapters[1].chapters_index == nil then
        dbg.log('not found', current_chapter.chapters_index)
        return {}
    end

    return next_chapters
end

function M:findNextChapter(current_chapter, is_downloaded)

    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log("findNextChapter: bad params", current_chapter)
        return
    end

    local book_cache_id = current_chapter.book_cache_id
    local totalChapterNum = current_chapter.totalChapterNum
    local current_chapters_index = current_chapter.chapters_index

    if current_chapter.call_event == nil then
        current_chapter.call_event = 'next'
    end

    local next_chapter = self.dbManager:findNextChapterInfo(current_chapter, is_downloaded)

    if not H.is_tbl(next_chapter) or next_chapter.chapters_index == nil then
        dbg.log('not found', current_chapter.chapters_index)
        return
    end

    next_chapter.call_event = current_chapter.call_event
    next_chapter.is_pre_loading = current_chapter.is_pre_loading

    return next_chapter

end

function M:getProxyCoverUrl(coverUrl)
    if not H.is_str(coverUrl) then
        return coverUrl
    end
    local server_address = self.settings_data.data['server_address']
    return table.concat({server_address, '/cover?path=', util.urlEncode(coverUrl)})
end

function M:getProxyEpubUrl(bookUrl, htmlUrl)
    if not H.is_str(htmlUrl) then
        return htmlUrl
    end
    local server_address = self.settings_data.data['server_address']
    if server_address:match("/reader3$") and htmlUrl:match("%.x?html$") then
        local api_root_url = server_address:gsub("/reader3$", "")
        htmlUrl = htmlUrl:gsub("([^%w%-%.%_%~%/])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        return api_root_url .. htmlUrl

    else
        return htmlUrl
    end
end

function M:getProxyImageUrl(bookUrl, content)

    local picUrls = get_img_src(content)
    if not H.is_tbl(picUrls) or #picUrls < 1 then
        return {}
    end

    local new_porxy_picurls = {}

    local server_address = self.settings_data.data['server_address']

    if server_address:match("/reader3$") then
        local api_root_url = server_address:gsub("/reader3$", "")

        for i, img_src in ipairs(picUrls) do
            img_src = img_src:gsub("([^%w%-%.%_%~%/])", function(c)
                return string.format("%%%02X", string.byte(c))
            end)

            local new_url = img_src:gsub("^__API_ROOT__", api_root_url)

            table.insert(new_porxy_picurls, new_url)
        end
    else
        local width = Device.screen:getWidth() or 800
        for i, img_src in ipairs(picUrls) do
            local new_url = server_address .. '/image?url=' .. util.urlEncode(bookUrl) .. '&path=' ..
                                util.urlEncode(img_src) .. '&width=' .. width
            table.insert(new_porxy_picurls, new_url)
        end
    end

    return new_porxy_picurls
end

function M:pDownload_Image(img_src, timeout)
    local status, err = pcall(pDownload_Image, img_src, timeout)
    if status and H.is_tbl(err) and err['data'] then
        return wrap_response(err)
    else
        return wrap_response(nil, H.errorHandler(err))
    end
end

function M:getChapterImgList(chapter)
    local chapters_index = chapter.chapters_index
    local bookUrl = chapter.bookUrl
    local down_chapters_index = chapters_index

    if not H.is_str(bookUrl) and not H.is_str(chapter.book_cache_id) then
        return
    end

    return self:HandleResponse(self:pGetChapterContent({
        bookUrl = bookUrl,
        chapters_index = down_chapters_index
    }), function(data)
        if H.is_str(data) then
            local img_sources = self:getProxyImageUrl(bookUrl, data)
            if H.is_tbl(img_sources) and #img_sources > 0 then
                if chapter.isRead ~= true then
                    self.dbManager:updateIsRead(chapter, true, true)
                end
                return img_sources
            else
                logger.dbg('获取图片列表失败 ')
                return
            end
        else
            logger.dbg('返回数据格式出错')
            return
        end
    end, function(err_msg)
        return
    end)
end

function M:DownAllChapter(chapters)
    local begin_chapter = chapters[1]

    begin_chapter.call_event = 'next'

    local status, err = self:preLoadingChapters(begin_chapter, #chapters)
    if not status then
        return wrap_response(nil, tostring(err))
    else
        return wrap_response(err)
    end
end

function M:preLoadingChapters(chapter, download_chapter_count)

    if not H.is_tbl(chapter) then
        return false, 'preLoadingChaptersIncorrect call parameters'
    end

    if self:isExtractingInBackground() == true then
        dbg.log('"Background tasks incomplete. Cannot create new tasks:"')
        return false, "Background tasks incomplete. Cannot create new tasks:"
    end

    if not H.is_num(download_chapter_count) or download_chapter_count < 1 then
        download_chapter_count = 1
    end

    local chapter_down_tasks = {}

    if chapter[1] and chapter[1].chapters_index ~= nil and chapter[1].book_cache_id ~= nil then

        chapter_down_tasks = chapter
    else

        chapter_down_tasks = self:findNextChaptersNotDownLoad(chapter, download_chapter_count)
    end

    if not H.is_tbl(chapter_down_tasks) or #chapter_down_tasks < 1 then
        return false, 'No chapter to be downloaded'
    end

    pcall(function()
        Device:enableCPUCores(2)
        UIManager:preventStandby()
    end)

    self:closeDbManager()

    local task_pid, err = ffiUtil.runInSubProcess(function()

        pcall(function()

            util.writeToFile('', self.task_pid_file, true)
        end)

        local task_return_db_add = self.dbManager:transaction(
            function(book_cache_id, chapters_index, cache_file_path)
                return self.dbManager:dynamicUpdateChapters({
                    chapters_index = chapters_index,
                    book_cache_id = book_cache_id
                }, {
                    content = 'downloaded',
                    cacheFilePath = cache_file_path
                })
            end)

        local task_return_db_clear = self.dbManager:transaction(
            function(chapter_down_tasks, task_return_ok_list)

                for i = 1, #chapter_down_tasks do
                    local nextChapter = chapter_down_tasks[i]
                    if H.is_tbl(nextChapter) and nextChapter.chapters_index ~= nil and nextChapter.book_cache_id ~= nil then

                        local chapters_index = tonumber(nextChapter.chapters_index)
                        local book_cache_id = nextChapter.book_cache_id

                        if task_return_ok_list['ok_' .. chapters_index] == nil then

                            local status, err = pcall(function()
                                self.dbManager:updateDownloadState({
                                    chapters_index = chapters_index,
                                    book_cache_id = book_cache_id
                                }, false)
                            end)

                            if not status then
                                dbg.log("Error cleaning download task for database write:", H.errorHandler(err))
                            end
                        end
                    end
                end
            end)

        local task_return_ok_list = {}

        ffiUtil.usleep(50)

        for i = 1, #chapter_down_tasks do

            ffiUtil.usleep(50)

            local nextChapter = chapter_down_tasks[i]

            if H.is_tbl(nextChapter) and nextChapter.chapters_index ~= nil and nextChapter.book_cache_id ~= nil then

                nextChapter.is_pre_loading = true
                dbg.v('Threaded tasks running:runInSubProcess_start_title:', nextChapter.title)

                local status, err = pcall(function()
                    return self:pDownloadChapter(nextChapter)
                end)

                if not status then
                    logger.err("Chapter download failed: ", tostring(err))
                else

                    if H.is_tbl(err) and err.cacheFilePath then

                        local cache_file_path = err.cacheFilePath
                        local chapters_index = tonumber(nextChapter.chapters_index)
                        local book_cache_id = nextChapter.book_cache_id

                        task_return_ok_list['ok_' .. chapters_index] = true

                        dbg.v('Download chapter successfully:', book_cache_id, chapters_index, cache_file_path)

                        status, err = pcall(function()
                            return task_return_db_add(book_cache_id, chapters_index, cache_file_path)
                        end)
                        if not status then
                            logger.err('Error saving download to database:', tostring(err))
                        end
                    end

                end
            else
                dbg.log("Cache error: next chapter data source")

            end

            if not util.fileExists(self.task_pid_file) then
                dbg.v("Downloader received stop signal")
                break
            end

        end

        dbg.v("Clean up unfinished downloads")
        local status, err = pcall(function()
            return task_return_db_clear(chapter_down_tasks, task_return_ok_list)
        end)
        if not status and err then
            dbg.v("Incomplete chapter cleanup after load", tostring(err))
        end

        self:closeDbManager()

        chapter_down_tasks = nil
        task_return_ok_list = nil

        status, err = pcall(function()
            util.removeFile(self.task_pid_file)
            ffiUtil.usleep(50)
            util.removeFile(self.task_pid_file)
        end)

        status, err = pcall(function()

            Device:enableCPUCores(1)

            UIManager:allowStandby()
        end)
        if not status and err then
            dbg.v('allowStandby err', tostring(err))
        end

        return true

    end, nil, true)

    if not task_pid then
        dbg.log("Multithreaded task creation failed:" .. tostring(err))
        pcall(function()
            Device:enableCPUCores(1)
            UIManager:allowStandby()
        end)
        return false, "Background download task failed" .. tostring(err)
    else

        dbg.v("Task started. PID:" .. tostring(task_pid))

        local task_return_db_func = self.dbManager:transaction(
            function(task_return_chapter, content)

                self.dbManager:cleanDownloading()

                for i = 1, #task_return_chapter do
                    local task_chapter = task_return_chapter[i]
                    if H.is_tbl(task_chapter) and task_chapter.chapters_index ~= nil and task_chapter.book_cache_id ~=
                        nil then
                        self.dbManager:updateDownloadState(task_chapter, content)
                    end
                end
            end)

        local status, err = pcall(function()

            task_return_db_func(chapter_down_tasks, 'downloading_')
        end)
        if not status and err then
            dbg.v("Download flag write error:", tostring(err))
        end

        return true, chapter_down_tasks
    end

end

function M:getChapterInfoCache(bookCacheId, chapterIndex)
    local chapter_data = self.dbManager:getChapterInfo(bookCacheId, chapterIndex)
    return chapter_data
end

function M:getChapterCount(bookCacheId)
    return self.dbManager:getChapterCount(bookCacheId)
end

function M:getBookInfoCache(bookCacheId)
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:getBookinfo(bookShelfId, bookCacheId)
end

function M:getcompleteReadAheadChapters(current_chapter)
    return self.dbManager:getcompleteReadAheadChapters(current_chapter)
end

function M:setBooksTopUp(bookCacheId, sortOrder)
    local bookShelfId = self:getServerPathCode()
    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        return wrap_response(nil, '参数错误')
    end

    local set_sortorder = 0
    local where_sortorder = {
        _where = ' > 0'
    }
    if sortOrder == 0 then
        set_sortorder = {
            _set = "= strftime('%s', 'now')"
        }
        where_sortorder = 0
    end

    self.dbManager:dynamicUpdate('books', {
        sortOrder = set_sortorder
    }, {
        bookCacheId = bookCacheId,
        bookShelfId = bookShelfId,
        sortOrder = where_sortorder
    })
    return wrap_response(true)
end

function M:getBookShelfCache()
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:getAllBooksByUI(bookShelfId)
end

function M:onBookOpening(bookCacheId)
    if not H.is_str(bookCacheId) then
        return
    end
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:dynamicUpdate('books', {
        sortOrder = {
            _set = "= strftime('%s', 'now')"
        }
    }, {
        bookCacheId = bookCacheId,
        bookShelfId = bookShelfId,
        sortOrder = {
            _where = " > 0"
        }
    })
end

function M:getLastReadChapter(bookCacheId)
    return self.dbManager:getLastReadChapter(bookCacheId)
end

function M:getChapterLastUpdateTime(bookCacheId)
    return self.dbManager:getChapterLastUpdateTime(bookCacheId)
end

function M:getBookChapterCache(bookCacheId)
    local bookShelfId = self:getServerPathCode()

    local is_desc_sort = true
    if self.settings_data.data['chapter_sorting_mode'] == 'chapter_ascending' then
        is_desc_sort = false
    end
    local chapter_data = self.dbManager:getAllChaptersByUI(bookCacheId, is_desc_sort)
    return chapter_data
end

function M:getBookChapterPlusCache(bookCacheId)
    local bookShelfId = self:getServerPathCode()
    local chapter_data = self.dbManager:getAllChapters(bookCacheId)
    return chapter_data
end

function M:closeDbManager()
    self.dbManager:closeDB()
end

function M:cleanBookCache(book_cache_id)
    if self:isExtractingInBackground() == true then
        return wrap_response(nil, '有后台任务进行中,请等待结束或者重启koreader')
    end
    local bookShelfId = self:getServerPathCode()

    self.dbManager:clearBook(bookShelfId, book_cache_id)

    local book_cache_path = H.getBookCachePath(book_cache_id)
    if book_cache_path and util.pathExists(book_cache_path) then

        ffiUtil.purgeDir(book_cache_path)

        return wrap_response(true)
    else
        return wrap_response(nil, '没有缓存')
    end
end

function M:cleanAllBookCaches()
    if self:isExtractingInBackground() == true then
        return wrap_response(nil, '有后台任务进行中,请等待结束或者重启koreader')
    end

    local bookShelfId = self:getServerPathCode()
    self.dbManager:clearBooks(bookShelfId)
    self:closeDbManager()
    local books_cache_dir = H.getTempDirectory()
    ffiUtil.purgeDir(books_cache_dir)
    H.getTempDirectory()
    self.settings_data.data.servers_history = {}
    self:saveSettings()
    return wrap_response(true)
end

function M:MarkReadChapter(chapter, is_update_timestamp)
    local chapters_index = chapter.chapters_index
    chapter.isRead = not chapter.isRead
    self.dbManager:updateIsRead(chapter, chapter.isRead, is_update_timestamp)
    return wrap_response(true)
end

function M:ChangeChapterCache(chapter)
    local chapters_index = chapter.chapters_index
    local cacheFilePath = chapter.cacheFilePath
    local book_cache_id = chapter.book_cache_id
    local isDownLoaded = chapter.isDownLoaded

    if isDownLoaded ~= true then

        local status, err = self:preLoadingChapters({chapter}, 1)
        if status == true then
            return wrap_response(true)
        else
            return wrap_response(nil, '下载任务添加失败:' .. H.errorHandler(err))
        end
    else

        if util.fileExists(cacheFilePath) then
            util.removeFile(cacheFilePath)
        end

        self.dbManager:transaction(function()
            self.dbManager:dynamicUpdateChapters(chapter, {
                content = '_NULL',
                cacheFilePath = '_NULL'
            })
        end)()

        return wrap_response(true)
    end
end

function M:runTaskWithRetry(taskFunc, timeoutMs, intervalMs)

    if not H.is_func(taskFunc) then
        dbg.log("taskFunc must be a function")
        return
    end

    if not H.is_num(timeoutMs) or timeoutMs <= 10 then
        dbg.log("timeoutMs must be > 10")
        return
    end

    if not H.is_num(intervalMs) or intervalMs <= 10 then
        dbg.log("intervalMs must be > 0")
        return
    end

    local startTime = os.time()

    local isTaskCompleted = false

    dbg.v("Task started at: %d", startTime)

    local function checkTask()

        local currentTime = os.time()
        if currentTime - startTime >= timeoutMs / 1000 then
            dbg.log("Task timed out!")
            return
        end

        if isTaskCompleted then
            dbg.v("Task completed!")
            return
        end

        local status, result = pcall(taskFunc)
        if not status then

            dbg.log("Task function error:", result)
            isTaskCompleted = false
        else

            isTaskCompleted = result
        end

        if isTaskCompleted then

            dbg.v("Task completed!")
        else

            dbg.v("Retrying in %d ms...", currentTime)

            UIManager:scheduleIn(intervalMs / 1000, checkTask)
        end
    end

    checkTask()
end

function M:download_cover_img(book_cache_id, coverUrl)
    local img_src = self:getProxyCoverUrl(coverUrl)
    local status, err = pcall(pDownload_Image, img_src)

    if status and err and err['data'] then
        local cover_img_data = err['data']
        local cover_img_path = H.getCoverCacheFilePath(book_cache_id) .. '.' .. ext
        util.writeToFile(cover_img_data, cover_img_path)
    end
end

function M:quit_the_background_download_job()

    if util.fileExists(self.task_pid_file) then
        util.removeFile(self.task_pid_file)
    end
    return true
end

function M:check_the_background_download_job(chapter_down_tasks)

    if not H.is_tbl(chapter_down_tasks) or #chapter_down_tasks == 0 then
        return wrap_response(true)
    end

    if not self:isExtractingInBackground() then
        dbg.v("Inspector stopping...")
        if #chapter_down_tasks ~= 1 then
            return wrap_response(true)
        else
            return {
                type = 'SUCCESS',
                body = {
                    message = '下载任务已经切换到后台'
                }
            }
        end
    end

    local total_num = #chapter_down_tasks
    local downloaded_num = 0

    local target_ages = {}
    local book_cache_id = chapter_down_tasks[1].book_cache_id

    for i = 1, total_num do
        local task_chapter = chapter_down_tasks[i]
        if task_chapter and task_chapter.chapters_index ~= nil then
            table.insert(target_ages, task_chapter.chapters_index)
        end
    end

    local status, err = pcall(function()
        return self.dbManager:getDownloadProgress(book_cache_id, target_ages)
    end)

    if status then
        downloaded_num = tonumber(err)
    end

    dbg.v('Download progress num:', downloaded_num)
    if downloaded_num == 0 then

        return {
            type = 'PENDING',
            body = {
                type = 'INITIALIZING',
                total = total_num,
                downloaded = downloaded_num
            }
        }
    elseif downloaded_num < total_num then
        return {
            type = 'PENDING',
            body = {
                total = total_num,
                downloaded = downloaded_num
            }
        }
    else

        return wrap_response(true)
    end

end

function M:isExtractingInBackground(task_pid)
    -- ffiUtil.isSubProcessDone(task_pid)
    local pid_file = self.task_pid_file
    if not util.fileExists(pid_file) then
        return false
    end
    if H.isFileOlderThan(pid_file, 24 * 60 * 60) then
        util.removeFile(pid_file)
        return false
    end

    return true
end

function M:after_reader_chapter_show(chapter)

    local chapters_index = chapter.chapters_index
    local cache_file_path = chapter.cacheFilePath
    local book_cache_id = chapter.book_cache_id
    local update_state = {}

    local status, err = pcall(function()
        if chapter.isDownLoaded ~= true then
            update_state.content = 'downloaded'
            update_state.cacheFilePath = cache_file_path
        end

        if chapter.isRead ~= true then
            update_state.isRead = true
            update_state.lastUpdated = {
                _set = "= strftime('%s', 'now')"
            }
        end
        self.dbManager:transaction(function()
            self.dbManager:dynamicUpdateChapters(chapter, update_state)
        end)()
    end)

    if not status then
        dbg.log('updating the read download flag err:', tostring(err))
    end

    if cache_file_path ~= nil and chapter.cacheExt == nil then

        local status, err = pcall(function()
            local cache_name = select(2, util.splitFilePathName(cache_file_path))
            local _, extension = util.splitFileNameSuffix(cache_name)
            local bookShelfId = self:getServerPathCode()
            self.dbManager:transaction(function()
                return self.dbManager:dynamicUpdateBooks({
                    book_cache_id = book_cache_id,
                    bookShelfId = bookShelfId
                }, {
                    cacheExt = extension
                })
            end)()
        end)
        if not status then
            dbg.log('updating cache ext err:', tostring(err))
        end
    end

    if chapter.isRead ~= true then
        local complete_count = self:getcompleteReadAheadChapters(chapter)
        if complete_count < 40 then
            local preDownloadNum = 3
            if chapter.cacheExt and chapter.cacheExt == 'txt' then
                preDownloadNum = 5
            end
            self:preLoadingChapters(chapter, preDownloadNum)
        end
    end

    chapter.isRead = true
    chapter.isDownLoaded = true
end

function M:downloadChapter(chapter, message_dialog)

    local bookCacheId = chapter.book_cache_id
    local chapterIndex = chapter.chapters_index

    if self.dbManager:isDownloading(bookCacheId, chapterIndex) == true and self:isExtractingInBackground() == true then
        return wrap_response(nil, "此章节后台下载中, 请等待...")
    end

    local status, err = pcall(function()
        return self:pDownloadChapter(chapter, message_dialog)
    end)
    if not status then
        logger.err('下载章节失败:', err)
        return wrap_response(nil, "下载章节失败:" .. H.errorHandler(err))
    end
    return wrap_response(err)

end

function M:getServerPathCode()
    if self.settings_data.data['server_address_md5'] == nil then
        local server_address_md5 = socket_url.parse(self.settings_data.data['server_address']).host
        self.settings_data.data['server_address_md5'] = md5(server_address_md5)
        self.saveSettings()
    end
    return tostring(self.settings_data.data['server_address_md5'])
end

function M:getSettings()
    return self.settings_data.data
end

function M:saveSettings(settings)
    if H.is_tbl(settings) and H.is_str(self.settings_data.data.server_address) then
        if not H.is_str(settings.server_address) or not H.is_str(settings.chapter_sorting_mode) then
            return wrap_response(nil, '参数校检错误，保存失败')
        end
        self.settings_data.data = settings
    end
    self.settings_data:flush()
    self.settings_data = LuaSettings:open(H.getUserSettingsPath())
    return wrap_response(true)
end

function M:setEndpointUrl(new_setting_url)

    if not H.is_str(new_setting_url) or new_setting_url == '' then
        return wrap_response(nil, '参数校检错误，保存失败')
    end

    local parsed = socket_url.parse(new_setting_url)
    if not parsed then
        return wrap_response(nil, '地址不合规则，请检查')
    end

    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return wrap_response(nil, '不支持的协议，请检查')
    end

    if not parsed.host or parsed.host == "" then
        return wrap_response(nil, "没有主机名")
    end

    if parsed.port then
        local port_num = tonumber(parsed.port)
        if not port_num or port_num < 1 or port_num > 65535 then
            return wrap_response(nil, "端口号不正确")
        end
    end

    local settings = self.settings_data.data

    local username = ''
    local password = ''
    if parsed.userinfo then

        local decoded_userinfo = socket_url.unescape(parsed.userinfo)
        username, password = decoded_userinfo:match("^([^:]+):?(.*)$")
        password = (password ~= "") and password or nil
        if not H.is_str(username) or not H.is_str(password) then
            return wrap_response(nil, "username,passwor格式有误")
        end
    end

    local clean_url = string.format("%s://%s%s%s%s%s%s", parsed.scheme, parsed.host,
        parsed.port and (":" .. parsed.port) or "", parsed.path or "", parsed.query and ("?" .. parsed.query) or "",
        parsed.params and (";" .. parsed.params) or "", parsed.fragment and ("#" .. parsed.fragment) or "")

    dbg.log("server_address:", clean_url)

    self.settings_data.data.reader3_un = username
    self.settings_data.data.reader3_pwd = password
    self.settings_data.data.server_address = clean_url
    self.settings_data.data.setting_url = new_setting_url
    self.settings_data.data.server_address_md5 = md5(parsed.host)
    if not H.is_tbl(self.settings_data.data.servers_history) then
        self.settings_data.data.servers_history = {}
    end
    self.settings_data.data.servers_history[new_setting_url] = 1
    if string.find(string.lower(self.settings_data.data.server_address), "/reader3$") then
        self.settings_data.data.server_type = 2
    else
        self.settings_data.data.server_type = 1
    end
    self:saveSettings()

    self:loadSpore()

    return wrap_response(self.settings_data.data)
end

function M:onExitClean()
    dbg.v('Backend call onExitClean')

    self:closeDbManager()

    if util.fileExists(self.task_pid_file) then
        util.removeFile(self.task_pid_file)
    end

    collectgarbage()
    collectgarbage()
    return true
end

require("ffi/__gc")(M, {
    __gc = function(t)
        M:onExitClean()
    end
})

return M
