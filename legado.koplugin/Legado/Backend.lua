local logger = require("logger")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local ffiUtil = require("ffi/util")
local md5 = require("ffi/sha2").md5
local dbg = require("dbg")
local LuaSettings = require("luasettings")
local socket_url = require("socket.url")
local util = require("util")
local time = require("ui/time")

local UIManager = require("ui/uimanager")
local H = require("Legado/Helper")

-- 太旧版本缺少这个函数
if not dbg.log then
    dbg.log = logger.dbg
end

local M = {
    dbManager = {},
    settings_data = nil,
    task_pid_file = nil,
    apiClient = nil
}

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

local function get_extension_from_mimetype(content_type)
    local extensions = {
        ["image/jpeg"] = "jpg",
        ["image/png"] = "png",
        ["image/gif"] = "gif",
        ["image/bmp"] = "bmp",
        ["image/webp"] = "webp",
        ["image/tiff"] = "tiff",
        ["image/svg+xml"] = "svg",
        ["application/xhtml+xml"] = "html",
        ["text/javascript"] = "js",
        ["text/css"] = "css",
        ["application/opentype"] = "otf",
        ["application/truetype"] = "ttf",
        ["application/font-woff"] = "woff",
        ["application/epub+zip"] = "epub"
    }

    return extensions[content_type] or ""
end

local function get_image_format_head8(image_data)
    if type(image_data) ~= "string" then
        return "bin"
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
        return "bin"
    end
end

local function get_url_extension(url)
    if type(url) ~= "string" or url == "" then
        return ""
    end
    local parsed = socket_url.parse(url)
    local path = parsed and parsed.path
    if not path or path == "" then
        return ""
    end
    path = socket_url.unescape(path):gsub("/+$", "")

    local filename = path:match("([^/]+)$") or ""
    local ext = filename:match("%.([%w]+)$")
    -- logger.info(path, filename, ext)
    return ext and ext:lower() or "", filename
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

local function convertToGrayscale(image_data)
    local Png = require("Legado/Png")
    return Png.processImage(Png.toGrayscale, image_data, 1)

end

local function pGetUrlContent(url, timeout, maxtime)

    local ltn12 = require("ltn12")
    local socket = require("socket")
    local http = require("socket.http")
    local socketutil = require("socketutil")

    timeout = timeout or 600
    maxtime = maxtime or 700

    local parsed = socket_url.parse(url)
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        error("Unsupported protocol")
    end

    local sink = {}
    local request = {
        url = url,
        method = "GET",
        headers = {
            ["user-agent"] = "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/533.2+ Kindle/3.0+"
        },
        sink = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
        create = socketutil.tcp
    }

    socketutil:set_timeout(timeout, maxtime)
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

    local content = table.concat(sink)
    if headers and headers["content-length"] then
        local content_length = tonumber(headers["content-length"])
        if #content ~= content_length then
            error("Incomplete content received")
        end
    end

    local extension = ""
    local contentType = headers["content-type"]
    if contentType then
        extension = get_extension_from_mimetype(contentType)
        if not extension or extension == "" and contentType:match("^image/") then
            extension = get_image_format_head8(content)
        end
    end

    return {
        data = content,
        ext = extension,
        headers = headers
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
        local status, err = pcall(pGetUrlContent, img_src)

        if status and H.is_tbl(err) and err['data'] then

            local imgdata = err['data']
            local img_extension = err['ext']
            if not img_extension or img_extension == "" then
                img_extension = get_url_extension(img_src)
            end

            local img_name = string.format("%d.%s", i, img_extension or "")
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
    local legadoSpec = require("Legado/LegadoSpec")
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
    if not self.settings_data.data.setting_url and not self.settings_data.data.reader3_un and
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

    local BookInfoDB = require("Legado/BookInfoDB")
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
        return false, '获取 Token 失败'
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
        return wrap_response(nil, "仅支持服务器版本\r\n其它请在 app 操作后刷新")
    end

    self.apiClient:reset_middlewares()
    self.apiClient:enable("Legado3Auth")
    self.apiClient:enable("Format.JSON")
    self.apiClient:enable("ForceJSON")

    -- 单次轮询 timeout,总 timeout
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
        return wrap_response(nil, 'NEED_LOGIN，刷新并继续')
    end

    if H.is_tbl(res.body) and res.body.isSuccess == true and res.body.data then
        if H.is_func(callback) then
            return callback(res.body)
        else
            return wrap_response(res.body.data)
        end
    else
        return wrap_response(nil, (res.body and res.body.errorMsg) and res.body.errorMsg or '出错')
    end
end

function M:refreshChaptersList(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl)) then
        return wrap_response(nil, "获取目录参数错误")
    end
    local bookUrl = bookinfo.bookUrl
    return self:legadoSporeApi(function()
        return self.apiClient:getChapterList({
            url = bookUrl,
            bookSource = bookinfo.origin,
            bookSourceUrl = bookinfo.origin,
            refresh = 0,
            v = os.time()
        })
    end, nil, {
        timeouts = {6, 10}
    }, 'refreshChaptersList')

end

function M:refreshChaptersCache(bookinfo, last_refresh_time)

    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
    end
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl) and H.is_str(bookinfo.cache_id)) then
        return wrap_response(nil, "获取目录参数错误")
    end
    local book_cache_id = bookinfo.cache_id
    local bookUrl = bookinfo.bookUrl
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
            return wrap_response(nil, '数据写入出错，请重试')
        end
        return wrap_response(true)
    end, {
        timeouts = {10, 12}
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
            return wrap_response(nil, '写入数据出错，请重试')
        end

        return wrap_response(true)
    end, {
        timeouts = {8, 12}
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
        timeouts = {3, 5}
    }, 'saveBookProgress')

end

function M:getAvailableBookSource(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl)) then
        return wrap_response(nil, '获取可用书源参数错误')
    end

    local bookUrl = bookinfo.bookUrl
    local name = bookinfo.name
    local author = bookinfo.author
    if self.settings_data.data.server_type == 1 then
        return self:searchBookSocket(name, {
            name = name,
            author = author
        })
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
                return wrap_response(nil, '数据写入出错，请重试')
            end
            return wrap_response(true)
        else
            return wrap_response(nil, '接口返回数据格式错误')
        end
    end, {
        timeouts = {25, 30},
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
        timeouts = {70, 80},
        isServerOnly = true
    }, 'searchBook')

end

function M:searchBookSocket(search_text, filter, timeout)
    if not (H.is_str(search_text) and search_text ~= '') then
        return wrap_response(nil, "输入参数错误")
    end

    if self.settings_data.data.server_type ~= 1 then
        return wrap_response(nil, "仅支持阅读 APP")
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

    local parsed = socket_url.parse(self.settings_data.data.server_address)
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
        return wrap_response(nil, "连接出错：" .. tostring(err))
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
        return wrap_response(nil, 'ws返回数据出错：' .. H.errorHandler(err))
    end

    return wrap_response(err)
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
        -- isServerOnly = true
        if H.is_str(response.data.name) and H.is_str(response.data.bookUrl) and H.is_str(response.data.origin) then
            local bookShelfId = self:getServerPathCode()
            local db_save = {response.data}
            local status, err = pcall(function()
                return self.dbManager:upsertBooks(bookShelfId, db_save, true)
            end)

            if not status then
                dbg.log('addBookToLibrary数据写入', tostring(err))
                return wrap_response(nil, '数据写入出错，请重试')
            end
        end
        return wrap_response(true)
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

local ffi = require("ffi")
local libutf8proc

local function utf8_chars(str, reverse)
    if libutf8proc == nil then
        -- 兼容旧版
        if ffi.loadlib then
            libutf8proc = ffi.loadlib("utf8proc", "3")
        else
            if ffi.os == "Windows" then
                libutf8proc = ffi.load("libs/libutf8proc.dll")
            elseif ffi.os == "OSX" then
                libutf8proc = ffi.load("libs/libutf8proc.dylib")
            else
                libutf8proc = ffi.load("libs/libutf8proc.so.2")
            end
        end

        ffi.cdef [[
typedef int32_t utf8proc_int32_t;
typedef uint8_t utf8proc_uint8_t;
typedef ssize_t utf8proc_ssize_t;
utf8proc_ssize_t utf8proc_iterate(const utf8proc_uint8_t *, utf8proc_ssize_t, utf8proc_int32_t *);
]]
    end
    local str_len = #str
    local pos = reverse and (str_len + 1) or 0
    local str_p = ffi.cast("const utf8proc_uint8_t*", str)
    local codepoint = ffi.new("utf8proc_int32_t[1]")

    return function()
        while true do
            pos = reverse and (pos - 1) or (pos + 1)
            if (reverse and pos < 1) or (not reverse and pos > str_len) then
                return nil
            end

            local remaining = reverse and pos or (str_len - pos + 1)
            -- 指针偏移调整为 str_p + pos - 1
            local bytes = libutf8proc.utf8proc_iterate(str_p + pos - 1, remaining, codepoint)

            if bytes > 0 then
                -- 计算起始指针，转换为Lua字符串
                local char = ffi.string(str_p + pos - 1, bytes)
                local ret_pos = tonumber(pos)
                pos = reverse and (pos - bytes) or (pos + bytes - 1)
                return ret_pos, tonumber(codepoint[0]), char
            elseif bytes < 0 then
                pos = reverse and (pos - 1) or (pos + 1)
            end
        end
    end
end

function M:utf8_trim(str)
    if type(str) ~= "string" or str == "" then
        return ""
    end

    local utf8_whitespace_codepoints = {
        [0x00A0] = true,
        [0x1680] = true,
        [0x2000] = true,
        [0x2001] = true,
        [0x2002] = true,
        [0x2003] = true,
        [0x2004] = true,
        [0x2005] = true,
        [0x2006] = true,
        [0x2007] = true,
        [0x2008] = true,
        [0x2009] = true,
        [0x200A] = true,
        [0x200B] = true,
        [0x202F] = true,
        [0x205F] = true,
        [0x3000] = true,
        [0x0009] = true,
        [0x000A] = true,
        [0x000B] = true,
        [0x000C] = true,
        [0x000D] = true,
        [0x0020] = true
    }

    local start
    for pos, cp, char in utf8_chars(str) do
        if not utf8_whitespace_codepoints[cp] then
            start = pos
            break
        end
    end
    if not start then
        return ""
    end

    local finish
    for pos, cp, char in utf8_chars(str, true) do
        if not utf8_whitespace_codepoints[cp] then
            finish = pos + #char - 1
            break
        end
    end

    return (start and finish and start <= finish) and str:sub(start, finish) or ""
end

---去除多余换行、统一段落缩进、根据部分排版规则将不合理的换行合并成一个
---仅假设源文本格式混入了错误或多余换行和不标准的段落缩进
---@param text any
local function splitParagraphsPreserveBlank(text)
    if not text or text == "" then
        return {}
    end

    text = text:gsub("\r\n?", "\n"):gsub("\n+", function(s)
        return (#s >= 2) and "\n\n" or s
    end)

    -- 兼容: 2半角+1全角,Koreader .txt auto add a indentEnglish
    local indentChinese = "\u{0020}\u{0020}\u{3000}"
    local indentEnglish = "\u{0020}\u{0020}"
    local paragraphs = {}
    local allow_split = true
    local buffer = ""
    local prefix = nil
    local lines = {}

    -- 保留空行，清理前后空白
    for line in util.gsplit(text, "\n", false, true) do
        line = M:utf8_trim(line)
        table.insert(lines, line)
    end

    -- 常见标点符号判断
    local function isPunctuation(char)
        if not char then
            return false
        end

        local punctuationSet = {
            ["\u{0021}"] = true,
            ["\u{002C}"] = true,
            ["\u{002E}"] = true,
            ["\u{003A}"] = true,
            ["\u{003B}"] = true,
            ["\u{003F}"] = true,
            ["\u{3001}"] = true,
            ["\u{3002}"] = true,
            ["\u{FF0C}"] = true,
            ["\u{FF0E}"] = true,
            ["\u{FF1A}"] = true,
            ["\u{FF1B}"] = true,
            ["\u{FF1F}"] = true,
            ["\u{2026}"] = true,
            ["\u{00B7}"] = true,
            ["\u{2022}"] = true,
            ["\u{FF5E}"] = true
        }

        if punctuationSet[char] then
            return true
        end

        local code = ffiUtil.utf8charcode(char)
        if not code then
            return false
        end

        return (code >= 0x2000 and code <= 0x206F) or (code >= 0x3000 and code <= 0x303F) or
                   (code >= 0xFF00 and code <= 0xFFEF)
    end

    for i, line in ipairs(lines) do

        if buffer and buffer ~= "" then
            line = table.concat({buffer, line or ""})
            buffer = ""
        end

        if line == "" then
            table.insert(paragraphs, line)
        else
            if not prefix then
                prefix = util.hasCJKChar(line:sub(1, 9)) and indentChinese or indentEnglish
                -- logger.dbg('isChinese:', prefix == indentChinese)
            end

            local line_len = #line
            local word_end = line:match(util.UTF8_CHAR_PATTERN .. "$")
            local next_word_start = (lines[i + 1] or ""):match(util.UTF8_CHAR_PATTERN)
            local word_end_isPunctuation = isPunctuation(word_end)

            -- 中文段末没有标点不允许换行, 避免触发koreader的章节标题渲染规则
            if prefix == indentChinese and (not word_end_isPunctuation or line_len < 7) then
                allow_split = false
            else
                allow_split = util.isSplittable and util.isSplittable(word_end, next_word_start, word_end) or true
            end

            -- logger.dbg(i,line_len,word_end,next_word_start, word_end_isPunctuation, allow_split)

            if not allow_split and i < #lines then

                if prefix == indentEnglish and not word_end_isPunctuation and not isPunctuation(next_word_start) then
                    -- 非CJK两个单词间补充个空格
                    line = line .. "\u{0020}"
                end
                buffer = table.concat({buffer, line})
            else
                table.insert(paragraphs, prefix .. line)
            end
        end
    end

    lines = nil

    return paragraphs
end

local function has_img_tag(text)
    if type(text) ~= "string" then
        return false
    end
    return text:find("<[iI][mM][gG][^>]*>") ~= nil
end

local function has_other_content(text)
    if type(text) ~= "string" then
        return false
    end
    local without_img = text:gsub("<[iI][mM][gG][^>]+>", ""):gsub("\u{3000}", "")
    return without_img:find("%S") ~= nil
end

local function get_chapter_ontent_type(txt, first_line)
    if type(txt) ~= "string" then
        return 1
    end
    local page_type

    if not first_line or type(first_line) ~= 'string' then
        first_line = (string.match(txt, "([^\n]*)\n?") or txt):lower()
    else
        first_line = first_line:lower()
    end

    -- logger.info("优先检查 XHTML 特征",get_url_extension("/test.epub/index/OPS/Text/Chapter79.xhtml"))
    if string.match(first_line, "%.x?html$") then
        page_type = 4
    else

        local has_img_in_first_line = string.find(first_line, "<img", 1, true)
        if has_img_in_first_line then
            local is_other_content = has_other_content(txt)
            page_type = is_other_content and 3 or 2
        elseif has_img_tag(txt) then
            local is_other_content = has_other_content(txt)
            page_type = is_other_content and 3 or 2
        else
            page_type = 1
        end
    end
    return page_type
end

local book_chapter_resources = function(book_cache_id, filename, res_data, overwrite)

    if not book_cache_id then
        return
    end

    local catalogue, relpath, filepath

    catalogue = string.format("%s/resources", H.getBookCachePath(book_cache_id))
    if H.is_str(filename) then
        relpath = string.format("resources/%s", filename)
        filepath = string.format("%s/%s", catalogue, filename)
    end

    if res_data and (overwrite or not util.fileExists(filepath or "")) then
        H.checkAndCreateFolder(catalogue)
        util.writeToFile(res_data, filepath, true)
    end

    return relpath, filepath, catalogue
end

local chapter_writeToFile = function(chapter, filePath, resources)
    if util.fileExists(filePath) then
        if chapter.is_pre_loading == true then
            error('存在目标任务，本次任务取消')
        else
            chapter.cacheFilePath = filePath
            return chapter
        end
    end

    if util.writeToFile(resources, filePath, true) then

        if chapter.is_pre_loading == true then
            dbg.v('Cache task completed chapter.title', chapter.title or '')
        end

        chapter.cacheFilePath = filePath
        return chapter
    else
        error('下载 content 写入失败')
    end
end

local replace_css_urls = function(css_text, replace_fn)
    css_text = tostring(css_text or "")
    return (css_text:gsub("url%s*%((%s*['\"]?)(.-)(['\"]?%s*)%)", function(prefix, old_path, suffix)
        if type(old_path) ~= "string" or old_path == "" or old_path:lower():find("^data:") then
            return
        end
        local ok, new_path = pcall(replace_fn, old_path)
        if not ok or type(new_path) ~= "string" or new_path == "" then
            return "url(" .. prefix .. old_path .. suffix .. ")"
        end
        return
    end))
end

local processLink
processLink = function(book_cache_id, resources_src, base_url, is_porxy, callback)
    if not (H.is_str(book_cache_id) and H.is_str(resources_src) and resources_src ~= "") then
        logger.dbg("invalid params in processLink", book_cache_id, resources_src)
        return nil
    end

    local processed_src
    if is_porxy == true then
        local bookUrl = base_url
        processed_src = M:getProxyImageUrl(bookUrl, resources_src)
    else
        processed_src = util.trim(resources_src)

        local lower_src = processed_src:lower()
        if lower_src:find("^data:") then
            logger.dbg("skipping data URI", processed_src)
            return nil
        elseif lower_src:find("^res:") then
            logger.dbg("fonts css URI", processed_src)
            return nil
        elseif lower_src:sub(1, 1) == "#" then
            return nil
        elseif lower_src:sub(1, 2) == "//" then
            processed_src = "https:" .. processed_src
        elseif lower_src:sub(1, 1) == "/" then
            processed_src = socket_url.absolute(base_url, processed_src)
        elseif not lower_src:find("^http") then
            processed_src = socket_url.absolute(base_url, processed_src)
        end
    end

    local ext = get_url_extension(processed_src)
    if ext == "" then
        local clean_url = resources_src:gsub("[#?].*", "")
        ext = get_url_extension(clean_url)
        if ext == "" then
            -- legado app 图片后带数据 v07ew.jpg,{'headers':{'referer':'https://m.weibo.cn'}}"
            clean_url = resources_src:match("^(.-),") or resources_src
            ext = get_url_extension(clean_url)
        end
    end

    -- logger.info("src_ext", ext, "resources_src", resources_src)
    local resources_id = md5(processed_src)
    local resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id

    local resources_relpath, resources_filepath, resources_catalogue =
        book_chapter_resources(book_cache_id, resources_filename)
    -- logger.info(resources_relpath, resources_filepath, resources_catalogue)

    -- 已有缓存
    if ext ~= "" and resources_filepath and util.fileExists(resources_filepath) then
        return resources_relpath
    end

    local status, err = pcall(pGetUrlContent, processed_src)
    if status and H.is_tbl(err) and err["data"] then
        if not ext or ext == "" then
            ext = err["ext"] or ""
            resources_filename = ext ~= "" and string.format("%s.%s", resources_id, ext) or resources_id
        end

        -- 尝试处理css里面的级联
        if ext == "css_disable" and not callback then
            err["data"] = replace_css_urls(err["data"], function(url)
                -- 防止循环引用
                if url == resources_src then
                    return url
                end
                return processLink(book_cache_id, url, processed_src, nil, true)
            end)

        end

        return book_chapter_resources(book_cache_id, resources_filename, err["data"])
    end

end

local function plain_text_replace(text, pattern, replacement, count)
    text = tostring(text or "")
    pattern = tostring(pattern or "")
    replacement = tostring(replacement or "")

    if pattern == "" then
        return text
    end
    -- 转义 Lua 模式特殊字符
    local escaped_pattern = pattern:gsub("([%%().%+-*?[%]^$])", "%%%1")
    -- 转义替换字符串中的 %
    local safe_replacement = replacement:gsub("%%", "%%%%")
    return text:gsub(escaped_pattern, safe_replacement, count)
end

local txt2html = function(book_cache_id, content, title)
    local dropcaps
    local lines = {}
    content = content or ""
    title = title or ""

    for line in util.gsplit(content, "\n", false, true) do
        line = M:utf8_trim(line)
        local el_tags

        if dropcaps ~= true and line ~= "" and not string.find(line, "<img", 1, true) then
            -- 尝试清理重复标题 >9 避免单字误判
            if #title > 9 and string.find(line, title, 1, true) == 1 then
                line = plain_text_replace(line, title, "", 1)
            end
            local rep_text = line:match(util.UTF8_CHAR_PATTERN)
            line = plain_text_replace(line, rep_text, "", 1)
            el_tags = string.format('<p style="text-indent: 0em;"><span class="duokan-dropcaps-two">%s</span>%s</p>',
                rep_text, line)
            dropcaps = true
        else
            el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
        end
        table.insert(lines, el_tags)
    end

    if #lines > 0 then
        content = table.concat(lines)
    end

    local epub = require("Legado/EpubHelper")
    epub.addCssRes(book_cache_id)
    return epub.addchapterT(title, content)
end

local htmlparser
function M:_AnalyzingChapters(chapter, content)

    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    local chapter_title = chapter.title or ''
    local down_chapters_index = chapter.chapters_index

    if type(content) ~= "string" then
        content = tostring(content)
    end

    local filePath = H.getChapterCacheFilePath(book_cache_id, chapters_index, chapter.name)

    local first_line = string.match(content, "([^\n]*)\n?") or content
    local PAGE_TYPES = {
        TEXT = 1, -- 纯文本
        IMAGE = 2, -- 纯图片
        MIXED = 3, -- 图文混合
        XHTML = 4, -- XHTML/EPUB
        MEDIA = 5 -- 音频/视频（??）
    }

    local page_type = get_chapter_ontent_type(content, first_line)
    -- logger.dbg("get_chapter_ontent_type:",page_type)

    if page_type == PAGE_TYPES['IMAGE'] then
        local img_sources = self:getPorxyPicUrls(bookUrl, content)
        if H.is_tbl(img_sources) and #img_sources > 0 then

            -- 一张图片就不打包cbz了
            if #img_sources == 1 then
                local res_url = img_sources[1]
                local status, err = pcall(pGetUrlContent, res_url)
                if not status then
                    error('请求错误，' .. H.errorHandler(err))
                end
                if not (H.is_tbl(err) and err["data"]) then
                    error('下载失败，数据为空')
                end

                local ext = get_url_extension(res_url)
                if (not ext or ext == "") and not not err.ext then
                    ext = err['ext']
                end

                filePath = string.format("%s.%s", filePath, ext or "")
                return chapter_writeToFile(chapter, filePath, err['data'])
            else
                filePath = filePath .. '.cbz'
                local status, err = pcall(pDownload_CreateCBZ, filePath, img_sources)

                if not status then
                    error('CreateCBZ err:' .. H.errorHandler(err))
                end

                if chapter.is_pre_loading == true then
                    dbg.v('Cache task completed chapter.title:', chapter_title)
                end
            end
            chapter.cacheFilePath = filePath
            return chapter
        else
            error('生成图片列表失败')
        end

    elseif page_type == PAGE_TYPES['XHTML'] then

        local html_url = self:getProxyEpubUrl(bookUrl, first_line)
        -- logger.info("bookurl",bookUrl)
        -- logger.info("first_line",first_line)
        -- logger.info("html_url",html_url)
        if html_url == nil or html_url == '' then
            error('转换失败')
        end
        local status, err = pcall(pGetUrlContent, html_url)
        if not status then
            error('请求错误，' .. H.errorHandler(err))
        end
        if not (H.is_tbl(err) and err["data"]) then
            error('下载失败，数据为空')
        end
        -- TODO 写入原始文件名，用于导出
        local ext, original_name = get_url_extension(first_line)
        if (not ext or ext == "") and not not err.ext then
            ext = err['ext']
        end

        content = err['data'] or '下载失败'
        filePath = string.format("%s.%s", filePath, ext or "")

        if not htmlparser then
            htmlparser = require("htmlparser")
        end
        local success, root = pcall(htmlparser.parse, content, 5000)
        if success and root then

            local body = root("body")
            if body[1] then
                local img_pattern = "(<[Ii][Mm][Gg].-[Ss][Rr][Cc]%s*=%s*)(['\"])(.-)%2([^>]*>)"
                local image_xlink_pattern = '(<image.-href%s*=%s*)(["\'])(.-)%2([^>]*>)'
                local link_pattern = '(<link.-href%s*=%s*)(["\'])(.-)%2([^>]*>)'
                for _, el in ipairs(root("script")) do
                    if el then
                        local el_text = el:gettext()
                        if el_text then
                            content = plain_text_replace(content, el_text, "")
                        end
                    end
                end
                for _, el in ipairs(root("head > link[href]")) do
                    if el and el.attributes and el.attributes["href"] then
                        local relpath = processLink(book_cache_id, el.attributes["href"], html_url)
                        local el_text = el:gettext()
                        if H.is_str(relpath) and el_text then
                            local replace_text = plain_text_replace(el_text, el.attributes["href"], relpath)
                            content = plain_text_replace(content, el_text, replace_text)
                        end
                    end
                end
                for _, el in ipairs(body[1]:select("img[src]")) do
                    if el and el.attributes and el.attributes["src"] then
                        local relpath = processLink(book_cache_id, el.attributes["src"], html_url)
                        local el_text = el:gettext()
                        if relpath and el_text then
                            local replace_text = plain_text_replace(el_text, el.attributes["src"], relpath)
                            content = plain_text_replace(content, el_text, replace_text)
                        end
                    end
                end
                for _, el in ipairs(body[1]:select("svg")) do
                    if el then
                        local el_text = el:gettext()
                        for r1, r2, r3, r4 in el_text:gmatch(image_xlink_pattern) do
                            local open, path, close = r1, r3, r4
                            if not open or open == "" then
                                return
                            end
                            open = open .. r2 or ""
                            local relpath = processLink(book_cache_id, path, html_url)
                            if H.is_str(relpath) then
                                local replace_text = plain_text_replace(el_text, open .. path, open .. relpath)
                                content = plain_text_replace(content, el_text, replace_text)
                            end
                        end
                    end
                end

                -- 补充处理
                content = content:gsub("<script[^>]*>(.-\n?)</script>", ""):gsub("<script[^>]*>[\x00-\xFF]-</script>",
                    ""):gsub(link_pattern, function(r1, r2, r3, r4)
                    local open, path, close = r1, r3, r4
                    if not (open and open ~= "" and path and path ~= "" and string.find(path, "^resources/") == nil) then
                        return
                    end
                    local relpath = processLink(book_cache_id, path, html_url)
                    if H.is_str(relpath) then
                        r2 = r2 or ""
                        close = close or ""
                        return table.concat({open .. r2, relpath, r2 .. close})
                    end
                    return
                end):gsub(image_xlink_pattern, function(r1, r2, r3, r4)
                    local open, path, close = r1, r3, r4
                    -- 前面处理过了这里就跳过
                    if open and open ~= "" and path and string.find(path, "^resources/") == nil then
                        local relpath = processLink(book_cache_id, path, html_url)
                        if H.is_str(relpath) then
                            r2 = r2 or ""
                            close = close or ""
                            return table.concat({open .. r2, relpath, r2 .. close})
                        end
                    end
                    return
                end):gsub(img_pattern, function(r1, r2, r3, r4)
                    if r1 == "" or not r3 or string.find(r3, "^resources/") ~= nil then
                        return
                    end
                    local path = r3
                    local relpath = processLink(book_cache_id, path, html_url)
                    if H.is_str(relpath) then
                        return table.concat({r1, r2, relpath, r2, r4})
                    end
                    return
                end)
            end
        end

        return chapter_writeToFile(chapter, filePath, content)

    elseif page_type == PAGE_TYPES['MIXED'] then
        -- 混合 img 标签和文本
        filePath = filePath .. '.html'
        local img_pattern = "(<[Ii][Mm][Gg].-[Ss][Rr][Cc]%s*=%s*)(['\"])(.-)%2([^>]*>)"
        if has_img_tag(content) then

            content = content:gsub(img_pattern, function(r1, r2, r3, r4)
                if not (r1 and r1 ~= "" and r3 and r3 ~= "") then
                    return
                end
                local path = r3
                local relpath = processLink(book_cache_id, path, bookUrl, true)
                if H.is_str(relpath) then
                    -- 随文图
                    return string.format('<div class="duokan-image-single">%s</div>',
                        table.concat({r1, r2, relpath, r2, ' class="picture-80" alt="" ', r4}))
                end
                return
            end)
        end

        content = txt2html(book_cache_id, content, chapter_title)
        return chapter_writeToFile(chapter, filePath, content)
    else
        -- TEXT
        if self.settings_data.data.istxt == true then
            filePath = filePath .. '.txt'
            local paragraphs = splitParagraphsPreserveBlank(content)
            if #paragraphs == 0 then
                chapter.content_is_nil = true
            end
            first_line = paragraphs[1] or ""
            content = table.concat(paragraphs, "\n")
            paragraphs = nil

            if not string.find(first_line, chapter_title, 1, true) then
                content = table.concat({"\t\t", tostring(chapter_title), "\n\n", content})
            end
        else
            filePath = filePath .. '.html'
            content = txt2html(book_cache_id, content, chapter_title)
        end

        return chapter_writeToFile(chapter, filePath, content)
    end

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

    return self:_AnalyzingChapters(chapter, response.body)
end

function M:getCacheChapterFilePath(chapter)

    if not H.is_tbl(chapter) or chapter.book_cache_id == nil or chapter.chapters_index == nil then
        dbg.log('getCacheChapterFilePath parameters err:', chapter)
        return chapter
    end

    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    local book_name = chapter.name or ""
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

    local filePath = H.getChapterCacheFilePath(book_cache_id, chapters_index, book_name)

    local extensions = {'html', 'cbz', 'xhtml', 'txt', 'png', 'jpg'}

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
    local server_type = self.settings_data.data.server_type
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

function M:getProxyImageUrl(bookUrl, img_src)
    local res_img_src = img_src
    local width = Device.screen:getWidth() or 800
    local server_address = self.settings_data.data.server_address
    local server_type = self.settings_data.data.server_type
    if server_type == 1 then
        res_img_src = table.concat({server_address, '/image?url=', util.urlEncode(bookUrl), '&path=',
                                    util.urlEncode(img_src), '&width=', width})
    elseif server_type == 2 then
        local api_root_url = server_address:gsub("/reader3$", "")
        -- <img src='__API_ROOT__/book-assets/guest/剑来_/剑来.cbz/index/1.png' />
        res_img_src = custom_urlEncode(img_src):gsub("^__API_ROOT__", "")
        res_img_src = socket_url.absolute(api_root_url, res_img_src)
    end
    return res_img_src
end

function M:getPorxyPicUrls(bookUrl, content)
    local picUrls = get_img_src(content)
    if not H.is_tbl(picUrls) or #picUrls < 1 then
        return {}
    end

    local new_porxy_picurls = {}
    for i, img_src in ipairs(picUrls) do
        local new_url = self:getProxyImageUrl(bookUrl, img_src)
        table.insert(new_porxy_picurls, new_url)
    end
    return new_porxy_picurls
end

function M:pDownload_Image(img_src, timeout)
    local status, err = pcall(pGetUrlContent, img_src, timeout)
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
            local img_sources = self:getPorxyPicUrls(bookUrl, data)
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
        return wrap_response(nil, '有后台任务进行中，请等待结束或者重启 KOReader')
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
        return wrap_response(nil, '有后台任务进行中，请等待结束或者重启 KOReader')
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
            return wrap_response(nil, '下载任务添加失败：' .. H.errorHandler(err))
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
    local status, err = pcall(pGetUrlContent, img_src)

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

    local status, err = pcall(function()

        local update_state = {}

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

    if cache_file_path ~= nil then

        local cache_name = select(2, util.splitFilePathName(cache_file_path)) or ''
        local _, extension = util.splitFileNameSuffix(cache_name)

        if extension and chapter.cacheExt ~= extension then
            local status, err = pcall(function()

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
    end

    if chapter.isRead ~= true and NetworkMgr:isConnected() then
        local complete_count = self:getcompleteReadAheadChapters(chapter)
        if complete_count < 40 then
            local preDownloadNum = 5
            if chapter.cacheExt and chapter.cacheExt == 'cbz' then
                preDownloadNum = 3
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
        logger.err('下载章节失败：', err)
        return wrap_response(nil, "下载章节失败：" .. H.errorHandler(err))
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
    if parsed.user and parsed.user ~= "" then
        self.settings_data.data.reader3_un = util.urlDecode(parsed.user)
        self.settings_data.data.reader3_pwd = util.urlDecode(parsed.password)
    end

    local clean_url = socket_url.build(parsed)

    -- dbg.log("server_address:", clean_url)
    self.settings_data.data.server_address = clean_url
    self.settings_data.data.setting_url = new_setting_url
    self.settings_data.data.server_address_md5 = md5(parsed.host)
    if not H.is_tbl(self.settings_data.data.servers_history) or not self.settings_data.data.servers_history[1] then
        self.settings_data.data.servers_history = {}
    end

    local function updateHistoryItem(history_table, item, max_size)
        local removed_old = false
        for i = #history_table, 1, -1 do
            if history_table[i] == item then
                table.remove(history_table, i)
                removed_old = true
                break
            end
        end
        table.insert(history_table, item)
        if max_size and max_size > 0 then
            while #history_table > max_size do
                table.remove(history_table, 1)
            end
        end
    end
    
    --添加历史记录
    updateHistoryItem(self.settings_data.data.servers_history, new_setting_url, 10)

    if string.find(string.lower(parsed.path or ""), "/reader3$") then
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

    if util.fileExists(self.task_pid_file) then
        util.removeFile(self.task_pid_file)
    end

    self:closeDbManager()
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

