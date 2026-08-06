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
        self.tokenManager = AuthToken:new(self.name)
        package.loaded["Spore.Middleware.Legado3Auth"] = require("Legado.spore.Middleware.Legado3Auth")
    end
    package.loaded["Spore.Middleware.FixJSON"] = require("Legado.spore.Middleware.FixJSON")
    package.loaded["Spore.Middleware.Format.UrlEncoded"] = require("Legado.spore.Middleware.Format.UrlEncoded")
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
    if not self._need_login then return true end

    local cache_token = self.tokenManager:get()
    if cache_token then
        return true, cache_token
    end
    return self:reader3Login()
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
    local server_address = self.settings.server_address
    logName = logName or 'handleResponse'
    opts = opts or {}
  
    local timeouts = opts.timeouts
    if not H.is_tbl(timeouts) or not H.is_num(timeouts[1]) or not H.is_num(timeouts[2]) then
        timeouts = {8, 12}
    end
  
    self:resetAndEnableMiddlewares(true)
  
    socketutil:set_timeout(timeouts[1], timeouts[2])
    local status, res = errHandler.pcall(requestFunc)
    socketutil:reset_timeout()
  
    if not (status and H.is_tbl(res) and H.is_tbl(res.body)) then
        logger.err(logName, "requestFunc err:", tostring(res))
        local err_msg = errHandler.map_message(res)
        return nil, string.format("Web 服务: %s", err_msg)
    end
  
    if isRetry ~= true and res.body.isSuccess == false and self:isNeedLogin(res.body) then
        if self.tokenManager then
            self.tokenManager:clear()
        end
        self:ensureLogin()
        logger.err("Need login, refreshed session and retrying")
        return self:handleResponse(requestFunc, callback, opts, logName, true)
    end

    if res.body.isSuccess == true then
          if not res.body.data then res.body.data = {} end
          if H.is_func(callback)  then
              return callback(res.body) 
           end
          return res.body.data
    else
        return nil, (res.body and res.body.errorMsg) and res.body.errorMsg or '出错'
    end
end

function M:unimplementedMethod(methodName)
    return nil, (methodName or "该方法") .. " 未在子类中实现"
end

function M:getBookshelf(callback)
    return self:unimplementedMethod("getBookshelf")
end

function M:saveBook(bookinfo, callback)
    return self:unimplementedMethod("saveBook")
end

function M:deleteBook(bookinfo)
    return self:unimplementedMethod("deleteBook")
end

function M:getChapterList(bookinfo, callback)
    return self:unimplementedMethod("getChapterList")
end

function M:getBookContent(chapter, callback)
    return self:unimplementedMethod("getBookContent")
end

function M:refreshBookContent(chapter, callback)
    return self:unimplementedMethod("refreshBookContent")
end

function M:saveBookProgress(chapter, callback)
    return self:unimplementedMethod("saveBookProgress")
end

function M:getProxyCoverUrl(coverUrl)
    return coverUrl
end

function M:getProxyImageUrl(bookUrl, img_src)
    return img_src
end

function M:getProxyEpubUrl(bookUrl, htmlUrl)
    return htmlUrl
end

function M:getAvailableBookSource(options, callback)
    return self:unimplementedMethod("getAvailableBookSource")
end

function M:changeBookSource(new_book_source, callback)
    return self:unimplementedMethod("changeBookSource")
end

function M:searchBookMulti(options, callback)
    return self:unimplementedMethod("searchBookMulti")
end

function M:searchBookSingle(options, callback)
    return self:unimplementedMethod("searchBookSingle")
end

function M:autoChangeBookSource(bookinfo, callback)
    return self:unimplementedMethod("autoChangeBookSource")
end

function M:getChaptersList(bookinfo)
    return self:unimplementedMethod("getChaptersList")
end

function M:getBookSourcesList(callback)
    return self:unimplementedMethod("getBookSourcesList")
end

function M:exploreBook(options, callback)
    return self:unimplementedMethod("exploreBook")
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    return self:unimplementedMethod("getBookSourcesExploreUrl")
end

return M