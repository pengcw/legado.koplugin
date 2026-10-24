local time = require("ui/time")
local logger = require("logger")
local Screen = require("device").screen
local util = require("util")
local LuaSettings = require("luasettings")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local Spore = require("Spore")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local load_script = require("Legado.Helper.Loader").load_script
local errHandler = require("Legado.Helper.Error")
local Probe = require("Legado.Helper.Probe")

local M = {
    name = "base",
    client = nil,
    settings = nil,
    _need_login = false,
    tokenManager = nil,
}

local AuthToken = {}
function AuthToken:new(key)
    local o = { key = key or "r3k", _memory_token = nil }
    setmetatable(o, self)
    self.__index = self
    return o
end

function AuthToken:_getConfig()
    return LuaSettings:open(Env.getTempDirectory() .. '/cache.lua')
end

function AuthToken:get()
    if self._memory_token then return self._memory_token end
    local token = self:_getConfig():readSetting(self.key)
    if H.is_str(token) and token ~= "" then
        self._memory_token = token
    end
    return self._memory_token
end

function AuthToken:set(token)
    if not H.is_str(token) or token == "" then
        return self:clear()
    end
    self._memory_token = token
    self:_getConfig():saveSetting(self.key, token):flush()
end

function AuthToken:clear()
    self._memory_token = nil
    self:_getConfig():delSetting(self.key):flush()
end

function M:extend(subclass_prototype)
    local o = subclass_prototype or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function M:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

function M:init()
    local spec_name = tostring(self.name) .. "_spec"
    local _spec, err_msg = load_script("Legado.spore." .. spec_name)
    if not _spec then
        logger.err("LegadoSpec loading failed", err_msg)
        return
    end
    local is_debug = false
    if is_debug then
        Spore.debug = {
            write = function(def, ...)
                logger.info(table.concat({...}))
            end
        }
    end
    self.client = Spore.new_from_lua(_spec, { base_url = self.settings.server_address .. '/' })
    self._need_login = H.is_func(self.client.login) and (self.settings.reader3_un or "") ~= ""

    if self._need_login then
        self.tokenManager = AuthToken:new(self:getTokenKey())
        package.loaded["Spore.Middleware.Legado3Auth"] = require("Legado.spore.Middleware.Legado3Auth")
    end
    package.loaded["Spore.Middleware.FixJSON"] = require("Legado.spore.Middleware.FixJSON")
    package.loaded["Spore.Middleware.Format.UrlEncoded"] = require("Legado.spore.Middleware.Format.UrlEncoded")
end

function M:getTokenKey()
    local addr = H.is_str(self.settings.server_address) and self.settings.server_address or ""
    local user = H.is_str(self.settings.reader3_un) and self.settings.reader3_un or ""
    return string.format("%s_%s", self.name, H.md5(addr .. "|" .. user))
end

function M:ensureTokenManager()
    if not self.tokenManager then
        self.tokenManager = AuthToken:new(self:getTokenKey())
    end
    return self.tokenManager
end

function M:getLuaConfig(path)
    return LuaSettings:open(path)
end

function M:isNeedLogin(response)
    if not ( self._need_login == true and H.is_tbl(response)) then return false end
    local err_msg = response.data or response.errorMsg
    return H.is_str(err_msg) and string.find(err_msg, 'NEED_LOGIN', 1, true) ~= nil
end

function M:reader3Login()
    return nil, "reader3Login 函数未重写"
end

function M:ensureLogin()
    local cache_token = self:ensureTokenManager():get()
    if H.is_str(cache_token) and cache_token ~= "" then
        return true, cache_token
    end
    if self._need_login then
        return self:reader3Login()
    end
    return true, nil
end

function M:resetAndEnableMiddlewares(includeAuth)
    self.client:reset_middlewares()
    if includeAuth and self._need_login == true then
        self.client:enable("Legado3Auth", { app = self })
    end
    self.client:enable("Format.UrlEncoded")
    self.client:enable("Format.JSON")
    self.client:enable("FixJSON")
    self.client:enable("UserAgent", {
        useragent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    })
end

function M:handleResponse(requestFunc, callback, opts, logName, isRetry)
    local server_address = self.settings and self.settings.server_address or ""
    logName = logName or 'handleResponse'
    opts = opts or {}

    local timeouts = opts.timeouts
    if not H.is_tbl(timeouts) or not H.is_num(timeouts[1]) or not H.is_num(timeouts[2]) then
        timeouts = {8, 12}
    end

    local function full_url()
        return string.format("%s/%s", tostring(server_address), tostring(logName))
    end
    local t_start = Probe.start("Spore", logName, full_url, function()
        return string.format("(timeout: block=%ds, total=%ds)%s",
            timeouts[1], timeouts[2], isRetry and " (retry)" or "")
    end)

    self:resetAndEnableMiddlewares(true)

    socketutil:set_timeout(timeouts[1], timeouts[2])
    local spore_probe_token = Probe.spore_enter(logName)
    local status, res = errHandler.pcall(requestFunc)
    Probe.spore_leave(spore_probe_token, status and "return" or "error")
    socketutil:reset_timeout()

    if not (status and H.is_tbl(res) and H.is_tbl(res.body)) then
        local err_msg = errHandler.map_message(res)
        Probe.fail("Spore", logName, full_url, t_start, err_msg)
        return nil, string.format("Web 服务: %s", err_msg)
    end

    if isRetry ~= true and res.body.isSuccess == false and self:isNeedLogin(res.body) then
        if self.tokenManager then
            self.tokenManager:clear()
        end
        Probe.retry("Spore", logName, full_url, t_start, "NEED_LOGIN -> Re-authenticating")
        self:ensureLogin()
        return self:handleResponse(requestFunc, callback, opts, logName, true)
    end

    if res.body.isSuccess == true then
        if not res.body.data then res.body.data = {} end
        Probe.done("Spore", logName, full_url, t_start, "200 OK", function()
            return Probe.format_summary(res.body.data)
        end)
        if H.is_func(callback) then
            return callback(res.body)
        end
        return res.body.data
    else
        local err_reason = (res.body and res.body.errorMsg) and res.body.errorMsg or '出错'
        Probe.fail("Spore", logName, full_url, t_start, err_reason)
        return nil, err_reason
    end
end

function M:unimplementedMethod(methodName, callback, custom_msg)
    local msg = custom_msg or "当前服务端不支持此功能"
    local resp = {
        isSuccess = false,
        state = false,
        error = msg,
        message = msg,
        type = "ERROR",
        data = nil,
    }
    if type(callback) == "function" then
        callback(resp)
    end
    return nil, msg, resp
end

local BOOK_FIELD_ALIASES = {
    name            = { "name", "bookName", "book_name", "title" },
    bookUrl         = { "bookUrl", "bookURL", "book_url", "url", "bookUrlNew" },
    author          = { "author", "authors", "authorName", "author_name" },
    origin          = { "origin", "sourceUrl", "source_url", "bookSourceUrl", "from" },
    originName      = { "originName", "origin_name", "sourceName", "source_name", "bookSourceName" },
    intro           = { "intro", "description", "desc", "summary", "introText" },
    coverUrl        = { "coverUrl", "coverURL", "cover_url", "cover", "img", "picUrl", "thumbnail" },
    wordCount       = { "wordCount", "word_count", "words", "totalWords" },
    kind            = { "kind", "category", "typeName", "bookType", "class" },
    totalChapterNum = { "totalChapterNum", "total_chapter_num", "chapterCount", "totalChapters" },
    lastChapter     = { "lastChapter", "last_chapter", "latestChapter", "newChapter" },
    updateTime      = { "updateTime", "update_time", "updatedAt", "lastUpdateTime", "lastUpdate" },
    status          = { "status", "bookStatus", "serializeStatus" },
    btype           = { "btype", "bookTypeId", "type" },
}

function M:_norm_book_fields(book)
    if type(book) ~= "table" then return book end
    for target, aliases in pairs(BOOK_FIELD_ALIASES) do
        if book[target] == nil then
            for _, alias in ipairs(aliases) do
                if book[alias] ~= nil then
                    book[target] = book[alias]
                    break
                end
            end
        end
    end
    return book
end

function M:_norm_paged(raw)
    if type(raw) ~= "table" then return raw end
    if type(raw.list) == "table" then
        if not H.is_num(raw.lastIndex) then raw.lastIndex = -1 end
        for i, book in ipairs(raw.list) do
            raw.list[i] = self:_norm_book_fields(book)
        end
        return raw
    end
    for i, book in ipairs(raw) do
        raw[i] = self:_norm_book_fields(book)
    end
    return { list = raw, lastIndex = -1 }
end

function M:_norm_paged_raw(raw)
    if type(raw) ~= "table" then return raw end
    if type(raw.list) == "table" then
        if not H.is_num(raw.lastIndex) then raw.lastIndex = -1 end
        return raw
    end
    return { list = raw[1] ~= nil and raw or {}, lastIndex = -1 }
end

function M:_norm_explore(raw)
    if type(raw) ~= "table" then return raw end
    raw.bookSourceUrl = raw.bookSourceUrl or raw.BookSourceUrl or ""
    return raw
end

function M:_norm_content(raw)
    if type(raw) == "table" and type(raw.text) == "string" then
        return raw.text
    end
    return raw
end

function M:_norm_book_list(raw)
    if type(raw) ~= "table" then return raw end
    if type(raw.list) == "table" then
        for i, book in ipairs(raw.list) do
            raw.list[i] = self:_norm_book_fields(book)
        end
        return raw.list
    end
    for i, book in ipairs(raw) do
        raw[i] = self:_norm_book_fields(book)
    end
    return raw
end

function M:_norm_book(raw)
    if type(raw) ~= "table" then return raw end
    local book
    if type(raw.bookinfo) == "table" then
        book = raw.bookinfo[1] or raw.bookinfo
    elseif type(raw.data) == "table" then
        book = raw.data[1] or raw.data
    else
        book = raw
    end
    if type(book) ~= "table" or next(book) == nil then
        return nil
    end
    return self:_norm_book_fields(book)
end

local NORM_MAP = {
    searchBookMulti          = "_norm_paged",
    getAvailableBookSource   = "_norm_paged_raw",
    exploreBook              = "_norm_book_list",
    searchBookSingle         = "_norm_book_list",
    getBookshelf             = "_norm_book_list",
    getBookSourcesExploreUrl = "_norm_explore",
    getBookContent           = "_norm_content",
    refreshBookContent       = "_norm_content",
    autoChangeBookSource     = "_norm_book",
    changeBookSource         = "_norm_book",
    saveBook                 = "_norm_book",
}

function M:_normalize_output(logName, data)
    local norm = NORM_MAP[logName]
    if not norm then return data end
    local normalizer = self[norm]
    if type(normalizer) ~= "function" then
        logger.err("NORM_MAP 配置错误: " .. tostring(logName) .. " -> " .. tostring(norm))
        return data
    end
    return normalizer(self, data)
end

function M:supports(method)
    if type(self[method]) ~= "function" then return false end
    local base_impl = M[method]
    if type(base_impl) ~= "function" then return true end
    if self[method] == M.unimplementedMethod then return false end
    return self[method] ~= base_impl
end

function M:getBookshelf(callback)
    return self:unimplementedMethod("getBookshelf", callback)
end

function M:saveBook(bookinfo, callback)
    return self:unimplementedMethod("saveBook", callback)
end

function M:deleteBook(bookinfo, callback)
    return self:unimplementedMethod("deleteBook", callback)
end

function M:getChapterList(bookinfo, callback)
    return self:unimplementedMethod("getChapterList", callback)
end

function M:getBookContent(chapter, callback)
    return self:unimplementedMethod("getBookContent", callback)
end

function M:refreshBookContent(chapter, callback)
    return self:unimplementedMethod("refreshBookContent", callback)
end

function M:saveBookProgress(chapter, callback)
    return self:unimplementedMethod("saveBookProgress", callback)
end

function M:getProxyCoverUrl(coverUrl)
    return coverUrl
end

function M:getProxyImageUrl(...)
    return select(2, ...)
end

function M:getProxyEpubUrl(bookUrl, htmlUrl)
    return htmlUrl
end

function M:getAvailableBookSource(options, on_finish, on_chunk)
    local msg = "当前服务端不支持此功能"
    if type(on_finish) == "function" then
        on_finish(false, nil, msg, -1)
    end
    return nil, msg
end

function M:changeBookSource(new_book_source, callback)
    return self:unimplementedMethod("changeBookSource", callback)
end

function M:searchBookMulti(options, callback)
    return self:unimplementedMethod("searchBookMulti", callback)
end

function M:searchBookSingle(options, callback)
    return self:unimplementedMethod("searchBookSingle", callback)
end

function M:autoChangeBookSource(bookinfo, callback)
    return self:unimplementedMethod("autoChangeBookSource", callback)
end

function M:getChaptersList(bookinfo, callback)
    return self:unimplementedMethod("getChaptersList", callback)
end

function M:getBookSourcesList(callback)
    return self:unimplementedMethod("getBookSourcesList", callback)
end

function M:getReplaceRules(callback)
    return self:unimplementedMethod("getReplaceRules", callback)
end

function M:getTxtTocRules(callback)
    return self:unimplementedMethod("getTxtTocRules", callback)
end

function M:exploreBook(options, callback)
    return self:unimplementedMethod("exploreBook", callback)
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    return self:unimplementedMethod("getBookSourcesExploreUrl", callback)
end

return M
