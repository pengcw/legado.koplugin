
local SourceManager = require("Legado.spore.local.source_manager")
local Reader = require("Legado.spore.local.parser")
local logger = require("logger")
local Probe = require("Legado.Helper.Probe")
local base = require("Legado.spore.base")
local util = require("util")
local errHandler = require("Legado.Helper.Error")
local BookSourceLogin = require("Legado.Helper.BookSourceLogin")

local function is_str(v) return type(v) == "string" end
local function is_tbl(v) return type(v) == "table" end
local function is_func(v) return type(v) == "function" end

local MAX_AVAILABLE_SOURCE_SEARCH = 100

local function to_ipc_value(value, seen, omitted)
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return value end
    if kind == "number" then
        if value == value and value ~= math.huge and value ~= -math.huge then return value end
        omitted.count = omitted.count + 1
        return nil
    end
    if kind ~= "table" then
        omitted.count = omitted.count + 1
        return nil
    end

    seen = seen or {}
    if seen[value] then
        omitted.count = omitted.count + 1
        return nil
    end
    seen[value] = true
    local copy = {}
    for key, item in pairs(value) do
        local key_kind = type(key)
        if key_kind == "string" or key_kind == "number" then
            local safe_item = to_ipc_value(item, seen, omitted)
            if safe_item ~= nil then copy[key] = safe_item end
        else
            omitted.count = omitted.count + 1
        end
    end
    seen[value] = nil
    return copy
end

local function normalize_url(url)
    if not is_str(url) then return url end
    if url:sub(1, 8) == "https://" then
        url = "http://" .. url:sub(9)
    end
    url = url:gsub("#.*$", "")
    return url:gsub("/+$", "")
end

local M = base:extend({
    name = "local",
    client = nil,
    settings = nil,
    _need_login = false,
    tokenManager = nil,
})

local AuthToken = {}
function AuthToken:new(key)
    local o = { key = key or "local_server", _memory_token = nil }
    setmetatable(o, self)
    self.__index = self
    return o
end

function AuthToken:get()
    return self._memory_token
end

function AuthToken:set(token)
    self._memory_token = token
end

function AuthToken:clear()
    self._memory_token = nil
end

function M:init()
    self.settings = self.settings or {}
    self.single_source_loader = self.single_source_loader or self.settings.single_source_loader
    self.all_sources_loader = self.all_sources_loader or self.settings.all_sources_loader
    self.save_source_session = self.save_source_session or self.settings.save_source_session
    self.save_source_login_data = self.save_source_login_data or self.settings.save_source_login_data
    self._all_sources_loaded = false

    self._shelf = self.shelf or {}

    if not rawget(self, "source_manager") then
        self.source_manager = SourceManager.new({
            save_session = self.save_source_session,
            load_source = self.single_source_loader,
            save_login_data = self.save_source_login_data
        })
    end

    if is_tbl(self.settings.book_sources) and #self.settings.book_sources > 0 then
        self:load_book_sources(self.settings.book_sources)
    end

    self.tokenManager = AuthToken:new(self.name)
    self._need_login = false

    return self
end

function M:getLuaConfig()
    return nil
end

function M:isNeedLogin()
    return false
end

function M:reader3Login()
    return nil, "本地服务无需登录"
end

function M:ensureLogin()
    return true
end

function M:resetAndEnableMiddlewares()
    return nil
end

function M:handleResponse(requestFunc, callback, ...)
    local logName = select(2, ...) or 'handleResponse'
    local ok, res = errHandler.pcall(requestFunc)
    if not ok then
        local clean_err = errHandler.extract_message(res)
        if clean_err:find("^本地服务:") then
            return nil, clean_err
        end
        return nil, string.format("本地服务: %s", clean_err)
    end
    res = self:_normalize_output(logName, res)
    if is_func(callback) then
        local cb_ok, cb_ret, cb_err = errHandler.pcall(callback, { isSuccess = true, data = res })
        if not cb_ok then
            local clean_err = errHandler.extract_message(cb_ret)
            if clean_err:find("^本地服务:") then
                return nil, clean_err
            end
            return nil, string.format("本地服务: %s", clean_err)
        end
        return cb_ret, cb_err
    end
    return res
end

function M:unimplementedMethod(methodName)
    return nil, (methodName or "该方法") .. " 未在子类中实现"
end

function M:_find_in_shelf(bookUrl)
    for _, item in ipairs(self._shelf) do
        if item.bookUrl == bookUrl then return item end
    end
    return nil
end

function M:_upsert_shelf(item)
    local existed = self:_find_in_shelf(item.bookUrl)
    if existed then
        for k, v in pairs(item) do existed[k] = v end
        return existed
    end
    table.insert(self._shelf, item)
    return item
end

function M:_remove_from_shelf(bookUrl)
    for i, item in ipairs(self._shelf) do
        if item.bookUrl == bookUrl then
            table.remove(self._shelf, i)
            return true
        end
    end
    return false
end

function M:_get_shelf_list()
    return self._shelf
end

function M:load_book_sources(book_sources)
    local loaded = 0
    local function load_one(bs)
        if is_str(bs) then
            if bs:match("%.json$") then
                loaded = loaded + (self.source_manager:add_file(bs) and 1 or 0)
            else
                local ok = self.source_manager:add(bs)
                if ok then loaded = loaded + 1 end
            end
        elseif is_tbl(bs) then
            if bs.bookSourceUrl then
                local ok = self.source_manager:add(bs)
                if ok then loaded = loaded + 1 end
            else
                for _, s in ipairs(bs) do load_one(s) end
            end
        end
    end
    load_one(book_sources)
    return loaded
end

function M:_ensure_all_sources_loaded()
    if self._all_sources_loaded or not is_func(self.all_sources_loader) then return end

    local ok, sources = pcall(self.all_sources_loader)
    if not ok then error("加载本地书源失败: " .. tostring(sources)) end
    if not is_tbl(sources) then error("加载本地书源失败: 返回数据无效") end

    self:load_book_sources(sources)
    self._all_sources_loaded = true
end

local function find_exact_source(self, bookSourceUrl)
    if not is_str(bookSourceUrl) then return nil end
    for _, entry in ipairs(self.source_manager.sources) do
        if (entry.source.bookSourceUrl or "") == bookSourceUrl then
            return entry
        end
    end
end

function M:_find_by_source_url(bookSourceUrl)
    local entry = find_exact_source(self, bookSourceUrl)
    if entry then return entry end
    if not is_str(bookSourceUrl) then return nil end

    local norm = normalize_url(bookSourceUrl)
    for _, candidate in ipairs(self.source_manager.sources) do
        if normalize_url(candidate.source.bookSourceUrl or "") == norm then
            return candidate
        end
    end
end

function M:_get_source_entry(bookSourceUrl)
    local entry = find_exact_source(self, bookSourceUrl)
    if entry then return entry end

    if bookSourceUrl == "loc_book" then
        self:load_book_sources({{
            bookSourceUrl = "loc_book",
            bookSourceName = "本地书籍",
        }})
        return find_exact_source(self, bookSourceUrl)
    end

    if is_func(self.single_source_loader) and is_str(bookSourceUrl) and bookSourceUrl ~= "" then
        local ok, source_data = pcall(self.single_source_loader, bookSourceUrl)
        if ok and is_tbl(source_data) then
            self:load_book_sources({source_data})
            entry = find_exact_source(self, bookSourceUrl)
            if entry then return entry end
        end
    end

    return self:_find_by_source_url(bookSourceUrl)
end

function M:_locate_service(bookUrl, origin)
    local entry = self:_locate_service_raw(bookUrl, origin)
    if entry then return entry end

    if is_str(origin) and origin ~= "" then
        entry = self:_get_source_entry(origin)
        if entry then return entry end
    end

    if is_str(bookUrl) and (bookUrl:match("^content://") or bookUrl == "loc_book") then
        entry = self:_get_source_entry("loc_book")
        if entry then return entry end
    end

    logger.err(string.format("定位书源失败(单书源未命中或已被删): bookUrl=%s origin=%s 引擎当前已加载书源数=%d",
        tostring(bookUrl), tostring(origin), self.source_manager and #self.source_manager.sources or -1))
    return nil
end

function M:_locate_service_raw(bookUrl, origin)
    if is_str(origin) and origin ~= "" then
        return find_exact_source(self, origin)
    end
    local nbookUrl = normalize_url(bookUrl)
    for _, entry in ipairs(self.source_manager.sources) do
        local nbase = normalize_url(entry.source.bookSourceUrl or "")
        if nbase ~= "" and nbookUrl:sub(1, #nbase) == nbase then
            return entry
        end
    end
    return nil
end

function M:_normalize_book(b, source)
    local item = {}
    for k, v in pairs(b) do item[k] = v end
    if not item.origin or item.origin == "" then
        item.origin = source.bookSourceUrl
    end
    if not item.originName or item.originName == "" then
        item.originName = source.bookSourceName
    end
    return item
end

function M:_search_available_sources(bookUrl, name, _, on_candidate_chunk, shuffle_sources)
    local current = self:_locate_service(bookUrl)
    local current_base = current and current.source.bookSourceUrl or nil
    local list = {}
    if not is_str(name) or name == "" then return list, 0, 0 end

    local entries = {}
    for source_index, entry in ipairs(self.source_manager.sources) do
        local src = entry.source
        if src.bookSourceUrl ~= current_base and src:can_search() then
            entries[#entries + 1] = { source_index = source_index, entry = entry }
        end
    end
    if shuffle_sources then
        require("Legado.spore.bookutil").list_shuffle(entries)
    end

    local eligible_count = #entries
    local skipped_count = math.max(0, eligible_count - MAX_AVAILABLE_SOURCE_SEARCH)
    for i = eligible_count, MAX_AVAILABLE_SOURCE_SEARCH + 1, -1 do
        entries[i] = nil
    end
    Probe.event("Source", "本地换源书源范围",
        string.format("eligible=%d searching=%d skipped=%d", eligible_count, #entries, skipped_count))

    local bookutil = require("Legado.spore.bookutil")
    local name_filter = { name = name, normalize_name = true }
    for _, shuffled in ipairs(entries) do
        local source_index, entry = shuffled.source_index, shuffled.entry
        local src = entry.source
        local source_label = string.format("%d:%s", source_index, tostring(src.bookSourceName or "未命名书源"))
        local t_search_start = Probe.start("Source", "本地换源候选源", source_label,
            string.format("(book: %s)", tostring(name)))
        local ok, books, search_err = pcall(function() return entry.service:search(name, 1) end)
        local source_candidates, rejected_count = {}, 0
        if ok and is_tbl(books) then
            for _, b in ipairs(books) do
                if bookutil.filter_search(b, name, false, name_filter) and b.bookUrl ~= bookUrl then
                    local candidate = self:_normalize_book(b, src)
                    list[#list + 1] = candidate
                    source_candidates[#source_candidates + 1] = candidate
                else
                    rejected_count = rejected_count + 1
                end
            end
            Probe.done("Source", "本地换源候选源", source_label, t_search_start, "200 OK",
                string.format("candidates=%d rejected=%d", #source_candidates, rejected_count))
            if #source_candidates > 0 and is_func(on_candidate_chunk) then
                on_candidate_chunk(source_candidates)
            end
        else
            Probe.fail("Source", "本地换源候选源", source_label, t_search_start,
                tostring(ok and search_err or books or "搜索失败"))
        end
    end
    return list, #entries, skipped_count
end

function M:saveBook(bookinfo, callback)
    if not (is_tbl(bookinfo) and is_str(bookinfo.name) and is_str(bookinfo.origin) and is_str(bookinfo.bookUrl) and
        is_str(bookinfo.originName)) then
        return nil, "输入参数错误"
    end
    return self:handleResponse(function()
        local item = {}
        for k, v in pairs(bookinfo) do item[k] = v end
        item.originOrder = item.originOrder or 0
        item.durChapterIndex = item.durChapterIndex or 0
        item.durChapterPos = item.durChapterPos or 0
        item.durChapterTime = item.durChapterTime or 0
        item.durChapterTitle = item.durChapterTitle or ''
        item.wordCount = item.wordCount or ''
        item.intro = item.intro or ''
        item.totalChapterNum = item.totalChapterNum or 0
        item.kind = item.kind or ''
        item.type = item.type or 0
        return self:_upsert_shelf(item)
    end, callback, nil, 'saveBook')
end

function M:downloadBook(bookinfo, temp)
    if not (is_tbl(bookinfo) and is_str(bookinfo.bookUrl)) then return nil, "输入参数错误" end
    local entry = self:_locate_service(bookinfo.bookUrl, bookinfo.origin)
    if not entry or tonumber(entry.source.bookSourceType) ~= 3 then
        return nil, "未找到文件下载书源"
    end
    local info, err = entry.service:book_info(bookinfo.bookUrl, bookinfo)
    if not info then return nil, err end
    return require("Legado.spore.local.file_download").download(info, entry.source, bookinfo, temp)
end

function M:deleteBook(bookinfo, callback)
    if not (is_tbl(bookinfo) and is_str(bookinfo.name) and is_str(bookinfo.origin) and is_str(bookinfo.bookUrl)) then
        return nil, "输入参数错误"
    end
    return self:handleResponse(function()
        return self:_remove_from_shelf(bookinfo.bookUrl)
    end, callback, nil, 'deleteBook')
end

function M:getChapterList(bookinfo, callback)
    if not (is_tbl(bookinfo) and bookinfo.bookUrl) then
        logger.warn("getChapterList 参数错误 bookinfo=" .. tostring(bookinfo))
        return nil, "参数错误"
    end
    local bookUrl = bookinfo.bookUrl
    logger.info(string.format("getChapterList 开始 bookUrl=%s origin=%s",
        tostring(bookUrl), tostring(bookinfo.origin)))
    local book_variable
    local on_result = is_func(callback) and function(response)
        response.bookVariable = book_variable
        return callback(response)
    end or nil
    return self:handleResponse(function()
        local entry = self:_locate_service(bookUrl, bookinfo.origin)
        if not entry then
            logger.err("getChapterList 定位书源失败 bookUrl=" .. tostring(bookUrl))
            error("本地未加载书源，无法获取目录: " .. tostring(bookUrl))
        end
        logger.info("getChapterList 定位书源: " .. tostring(entry.source.bookSourceName)
            .. " (" .. tostring(entry.source.bookSourceUrl) .. ")")
        local toc, err = entry.service:fetch_toc(bookUrl, {
            name = bookinfo.name,
            variable = bookinfo.variable,
        }, {
            dialect = bookinfo.textTransformDialect,
            rules = bookinfo.textTransformRules,
        }, bookinfo.runPreUpdateJs == true)
        if not toc then
            logger.err("getChapterList 抓取目录失败 bookUrl=" .. tostring(bookUrl) .. " err=" .. tostring(err))
            error(err or "目录抓取失败")
        end
        book_variable = toc.variable
        local chapters = toc.chapters or {}
        logger.info(string.format("getChapterList 成功 章节数=%d 抓取页数=%d%s",
            #chapters, toc.pages or 0, toc.truncated and " [已达页数上限]" or ""))
        return chapters
    end, on_result, nil, 'getChapterList')
end

function M:getBookContent(chapter, callback)
    local bookUrl = chapter and chapter.bookUrl
    if not is_str(bookUrl) then
        logger.warn("getBookContent 参数错误 chapter=" .. tostring(chapter))
        return nil, 'getBookContent参数错误'
    end
    local chap_url = (is_str(chapter.url) and chapter.url ~= "") and chapter.url
        or ((is_str(chapter.chapterUrl) and chapter.chapterUrl ~= "") and chapter.chapterUrl or nil)
    local content_url = chap_url or bookUrl
    logger.info(string.format("getBookContent 开始 bookUrl=%s contentUrl=%s origin=%s index=%s",
        tostring(bookUrl), tostring(content_url), tostring(chapter.origin),
        tostring(chapter.chapters_index)))
    local content_state
    local on_result = is_func(callback) and function(response)
        response.bookVariable = content_state.bookVariable
        response.variable = content_state.variable
        return callback(response)
    end or nil
    return self:handleResponse(function()
        local entry = self:_locate_service(bookUrl, chapter.origin)
        if not entry then
            logger.err("getBookContent 定位书源失败 bookUrl=" .. tostring(bookUrl))
            error("本地未加载书源，无法获取正文: " .. tostring(bookUrl))
        end
        logger.info("getBookContent 定位书源: " .. tostring(entry.source.bookSourceName)
            .. " (" .. tostring(entry.source.bookSourceUrl) .. ")")
        local res, err = entry.service:fetch_content(content_url, {
            name = chapter.name,
            variable = chapter.bookVariable,
        }, {
            url = content_url,
            bookUrl = bookUrl,
            index = chapter.index or chapter.chapters_index,
            title = chapter.title,
            variable = chapter.variable,
            isVolume = chapter.isVolume,
            nextChapterUrl = chapter.nextChapterUrl,
        }, {
            dialect = chapter.textTransformDialect,
            rules = chapter.textTransformRules,
        })
        if not res then
            logger.err("getBookContent 抓取正文失败 contentUrl=" .. tostring(content_url) .. " err=" .. tostring(err))
            error(err or "正文抓取失败")
        end
        content_state = res
        logger.info(string.format("getBookContent 成功 正文长度=%d", #(res.content or "")))
        return res.content or ""
    end, on_result, nil, 'getBookContent')
end

function M:refreshBookContent(chapter, callback)
    return self:getBookContent(chapter, callback)
end

function M:getProxyCoverUrl(coverUrl)
    return coverUrl
end

function M:getProxyImageUrl(...)
    return select(2, ...)
end

function M:getProxyEpubUrl(...)
    return select(2, ...)
end

function M:getBookSourceLoginUi(bookSourceUrl, callback)
    if not is_str(bookSourceUrl) or bookSourceUrl == "" then
        return nil, "缺少书源 URL"
    end
    return self:handleResponse(function()
        local entry = self:_get_source_entry(bookSourceUrl)
        if not entry then error("本地未加载书源: " .. bookSourceUrl) end
        local fields
        local ok, f_or_err = pcall(function() return entry.service:login_ui() end)
        if ok and type(f_or_err) == "table" then
            fields = f_or_err
        else
            local raw_ui = entry.source.data and entry.source.data.loginUi or entry.source.loginUi
            if type(raw_ui) == "string" and raw_ui:match("^%s*%[") then
                local json = require("json")
                local parsed_ok, parsed = pcall(json.decode, raw_ui)
                if parsed_ok and type(parsed) == "table" then
                    fields = parsed
                end
            end
            if not fields then
                fields = {}
            end
        end
        local login_url = entry.source.data and entry.source.data.loginUrl or ""
        if type(login_url) == "string" and login_url ~= ""
                and not login_url:match("^%s*@js:") and not login_url:match("^%s*js:")
                and not login_url:match("^%s*<js>") then
            local clean_url = login_url:match("^%s*([^\r\n%s\"'<>{}\\]+)")
            if clean_url then
                clean_url = clean_url:gsub("[;,%.]+$", "")
                login_url = entry.source:absolute(clean_url)
                if not (type(login_url) == "string" and login_url:match("^https?://")) then
                    login_url = nil
                end
            else
                login_url = nil
            end
        else
            login_url = nil
        end
        return {
            fields = fields,
            values = entry.source.login_data or {},
            session = entry.source.session,
            loginUrl = login_url,
        }
    end, callback, nil, "getBookSourceLoginUi")
end

function M:loginBookSource(options, callback)
    if not (is_tbl(options) and is_str(options.bookSourceUrl) and options.bookSourceUrl ~= "") then
        return nil, "缺少书源 URL"
    end
    return self:handleResponse(function()
        local entry = self:_get_source_entry(options.bookSourceUrl)
        if not entry then error("本地未加载书源: " .. options.bookSourceUrl) end

        if options.action == "logout" or options.action == "clear_cache" then
            if type(self.clear_source_state) ~= "function" then error("书源清理不可用", 0) end
            local kind = options.action == "logout" and "cookie" or "cache"
            if kind == "cache" then
                local cleared = require("Legado.spore.local.providers.file_cache").new():clear(entry.source.bookSourceUrl)
                if cleared ~= true then error("书源文件缓存清除失败，请稍后重试", 0) end
            end
            local cleared, session = self.clear_source_state(entry.source.bookSourceUrl, kind)
            if cleared ~= true then error(session or "书源清理失败", 0) end
            entry.source.session = session
            entry.service.session_dirty = false
            if kind == "cookie" then
                entry.service.login_data, entry.source.login_data = nil, nil
            end
            return {message = kind == "cookie" and "已清除cookie及登录凭证" or "已清除cache"}
        end

        if options.action == "save_config" then
            error("当前不支持通用 Cookie/Token 配置")
        end

        local ok, result, err = pcall(entry.service.login, entry.service, options.values, options.action)
        if not ok then error(result) end
        if not result then error(err or "书源登录失败") end
        return result
    end, callback, nil, "loginBookSource")
end

function M:getBookSourcesList(callback)
    return self:handleResponse(function()
        local list = {}
        for _, entry in ipairs(self.source_manager.sources) do
            local src = entry.source
            table.insert(list, {
                bookSourceName = src.bookSourceName,
                bookSourceUrl = src.bookSourceUrl,
                bookSourceGroup = src.bookSourceGroup or '',
                exploreUrl = src.exploreUrl or '',
                enabled = true,
                hasLogin = BookSourceLogin.hasLogin({
                    bookSourceUrl = src.bookSourceUrl,
                    loginUi = src.loginUi,
                    loginUrl = src.data and src.data.loginUrl,
                    session = src.session,
                    loginData = src.login_data,
                }),
            })
        end
        return list
    end, callback, nil, 'getBookSourcesList')
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    local entry = self:_get_source_entry(bookSourceUrl)
    if not entry then
        return nil, "本地未加载书源: " .. tostring(bookSourceUrl)
    end
    local kinds, err = entry.service:explore_kinds()
    if not kinds then return nil, err end
    if #kinds == 0 then return nil, "源探索未设置" end
    local ret = {
        exploreUrl = require("json").encode(kinds),
        BookSourceUrl = bookSourceUrl,
    }
    if is_func(callback) then
        return callback(ret)
    end
    return ret
end

function M:exploreBook(options, callback)
    if not (is_tbl(options) and is_str(options.ruleFindUrl) and is_str(options.bookSourceUrl)) then
        return nil, "书源发现参数错误"
    end
    local page = options.page or 1
    return self:handleResponse(function()
        local entry = self:_get_source_entry(options.bookSourceUrl)
        if not entry then error("本地未加载书源: " .. options.bookSourceUrl) end
        local source, service = entry.source, entry.service
        local books, err = service:explore(options.ruleFindUrl, page)
        if not books then error(err or "发现页执行失败") end
        local list = {}
        for _, b in ipairs(books) do
            list[#list + 1] = self:_normalize_book(b, source)
        end
        return list
    end, callback, nil, 'exploreBook')
end

function M:getAvailableBookSource(options, on_finish, on_chunk)
    if not (is_tbl(options) and is_str(options.book_url)) then
        local err = '获取可用书源参数错误'
        if is_func(on_finish) then on_finish(false, nil, err, -1) end
        return nil, err
    end

    local search_label = options.name or "换源候选"
    local t_search_start = Probe.start("Source", "本地换源候选任务", search_label, "(TaskV2)")
    local TaskQueue = require("Legado.task.v2")
    local started, task = pcall(TaskQueue.spawn, function(ctx)
        self:_ensure_all_sources_loaded()
        local candidate_count = 0
        local searched_source_count, skipped_source_count = 0, 0
        if options.last_index == nil then
            local _, searched_count, skipped_count = self:_search_available_sources(options.book_url, options.name, options.author, function(chunk)
                local omitted = { count = 0 }
                local safe_chunk = to_ipc_value(chunk, nil, omitted)
                if omitted.count > 0 then
                    logger.warn("[LocalAvailableSources] dropped non-JSON fields:", omitted.count)
                end
                if #safe_chunk > 0 then
                    candidate_count = candidate_count + #safe_chunk
                    ctx.emit("chunk", safe_chunk)
                end
            end, true)
            searched_source_count, skipped_source_count = searched_count, skipped_count
        end
        return {
            lastIndex = -1,
            source_count = #self.source_manager.sources,
            searched_source_count = searched_source_count,
            skipped_source_count = skipped_source_count,
            candidate_count = candidate_count,
        }
    end, { timeout = 120 })

    if not started then
        local err = "启动本地换源搜索失败: " .. tostring(task)
        Probe.fail("Source", "本地换源候选任务", search_label, t_search_start, err)
        if is_func(on_finish) then on_finish(false, nil, err, -1) end
        return nil, err
    end

    local partial_results = {}
    task:on("chunk", function(chunk)
        for _, candidate in ipairs(chunk) do
            partial_results[#partial_results + 1] = candidate
        end
        if is_func(on_chunk) then on_chunk(chunk) end
    end)
    task:on("done", function(success, result, state)
        if success then
            local source_count = result.source_count or 0
            local searched_source_count = result.searched_source_count or 0
            local skipped_source_count = result.skipped_source_count or 0
            local partial_msg
            if skipped_source_count > 0 then
                result.partial = true
                partial_msg = string.format("仅搜索%d个书源，另有%d个未搜索", searched_source_count, skipped_source_count)
            end
            result.source_count = nil
            result.searched_source_count = nil
            result.skipped_source_count = nil
            result.candidate_count = nil
            result.list = partial_results
            Probe.done("Source", "本地换源候选任务", search_label, t_search_start,
                result.partial and "206 PARTIAL" or "200 OK",
                string.format("sources=%d searched=%d skipped=%d candidates=%d", source_count,
                    searched_source_count, skipped_source_count, #partial_results), "TaskV2")
            if is_func(on_finish) then
                on_finish(true, result, partial_msg, result.lastIndex)
            end
        else
            local Error = require("Legado.Helper.Error")
            local err = Error.extract_message(result)
            local cancelled = state == "cancelled" or err == "已取消" or err == "user_cancelled" or err == "cancelled"
            if #partial_results > 0 and not cancelled then
                local partial = { lastIndex = -1, list = partial_results, partial = true }
                Probe.done("Source", "本地换源候选任务", search_label, t_search_start, "206 PARTIAL",
                    string.format("candidates=%d interrupted=%s", #partial_results, err), "TaskV2")
                if is_func(on_finish) then on_finish(true, partial, err, -1) end
            else
                Probe.fail("Source", "本地换源候选任务", search_label, t_search_start, err)
                if is_func(on_finish) then on_finish(false, nil, err, -1) end
            end
        end
    end)

    return function()
        if not task:is_done() then task:cancel("已取消") end
    end
end

function M:changeBookSource(new_book_source, callback)
    local request = is_tbl(new_book_source) and new_book_source or {}
    local trace_target = request.name or request.bookUrl or "-"
    local t_change_start = Probe.start("Source", "本地换源应用", trace_target, "(local)")
    if not (is_tbl(new_book_source) and is_str(new_book_source.bookUrl) and is_str(new_book_source.newUrl) and
        is_str(new_book_source.bookSourceUrl)) then
        local err = '更换书源参数错误'
        Probe.fail("Source", "本地换源应用", trace_target, t_change_start, err)
        return nil, err
    end

    local result, err = self:handleResponse(function()
        local entry = self:_get_source_entry(new_book_source.bookSourceUrl)
        if not entry then error("本地未加载书源: " .. new_book_source.bookSourceUrl) end

        local item = self:_find_in_shelf(new_book_source.bookUrl)
        if not item then
            item = {}
            for key, value in pairs(new_book_source) do item[key] = value end
        end
        local new_url = new_book_source.newUrl
        if not new_url:match("^https?://") then
            new_url = entry.source:absolute(new_url)
        end
        item.bookUrl = new_url
        item.origin = new_book_source.bookSourceUrl
        item.originName = entry.source.bookSourceName
        item.newUrl = nil
        return item
    end, callback, nil, 'changeBookSource')

    if result ~= nil then
        Probe.done("Source", "本地换源应用", trace_target, t_change_start, "200 OK", nil, "local")
    else
        Probe.fail("Source", "本地换源应用", trace_target, t_change_start, tostring(err or "换源失败"))
    end
    return result, err
end

function M:searchBookSingle(options, callback)
    if not (is_tbl(options) and is_str(options.search_text) and options.search_text ~= '' and
        is_str(options.book_source_url)) then
        return nil, "输入参数错误"
    end
    return self:handleResponse(function()
        local entry = self:_get_source_entry(options.book_source_url)
        if not entry then error("本地未加载书源: " .. options.book_source_url) end
        local books, err = entry.service:search(options.search_text, 1)
        if not books then error(err or "搜索失败") end
        local list = {}
        for _, b in ipairs(books) do
            list[#list + 1] = self:_normalize_book(b, entry.source)
        end
        return list
    end, callback, nil, 'searchBookSingle')
end

function M:searchBookMulti(options, on_chunk, on_finish)
    local function fail(message)
        if is_func(on_finish) then
            on_finish(false, message)
            return nil
        end
        return nil, message
    end
    if not (is_tbl(options) and is_str(options.search_text) and options.search_text ~= '') then
        return fail("输入参数错误")
    end

    local loaded, load_err = pcall(self._ensure_all_sources_loaded, self)
    if not loaded then return fail("加载本地书源失败: " .. tostring(load_err)) end
    local entries = {}
    for i, entry in ipairs(self.source_manager.sources) do entries[i] = entry end
    if #entries == 0 then return fail("没有启用的书源") end

    local TaskQueue = require("Legado.task.v2")
    local Error = require("Legado.Helper.Error")
    local errors = {}
    local finished = false
    local function finish(success, message)
        if finished then return end
        finished = true
        if is_func(on_finish) then on_finish(success, message) end
    end
    local ok, batch = pcall(TaskQueue.batch, entries, function(entry, _, ctx)
        ctx.throw_if_cancelled()
        local books, source_errors, cancelled = self.source_manager.search(
            { sources = { entry } }, options.search_text, 1, nil, ctx.is_cancelled
        )
        if cancelled or ctx.is_cancelled() then ctx.throw_if_cancelled() end
        if #source_errors > 0 then
            return { error = tostring(source_errors[1].error) }
        end
        local omitted = { count = 0 }
        local safe_chunk = to_ipc_value(books, nil, omitted)
        if omitted.count > 0 then
            logger.warn("[LocalSearch] dropped non-JSON fields from source:", tostring(entry.source.bookSourceName), omitted.count)
        end
        return { books = safe_chunk }
    end, {
        engine = "process",
        concurrency = 3,
        timeout = 120,
        on_item = function(index, success, result)
            if finished then return end
            local source = entries[index].source
            if success and is_tbl(result) and is_tbl(result.books) then
                if #result.books > 0 and is_func(on_chunk) then on_chunk(result.books) end
            else
                local message = success and is_tbl(result) and result.error or Error.extract_message(result)
                errors[#errors + 1] = {
                    sourceName = tostring(source.bookSourceName),
                    error = tostring(message or "搜索结果无效"),
                }
                logger.warn(string.format("[LocalSearch] %s: %s", tostring(source.bookSourceName), errors[#errors].error))
            end
        end,
        on_finish = function(_, result)
            if finished then return end
            if not is_tbl(result) then
                return finish(false, Error.extract_message(result))
            end
            if #errors == #entries then
                local first = errors[1]
                return finish(false, string.format("所有书源搜索失败（%d 个），例如：%s: %s", #errors,
                    first.sourceName, first.error))
            end
            local message
            if #errors > 0 then
                local names = {}
                for i = 1, math.min(#errors, 3) do names[i] = errors[i].sourceName end
                if #errors > #names then names[#names + 1] = "等" end
                message = string.format("部分书源搜索失败（%d 个）：%s", #errors, table.concat(names, "、"))
            end
            finish(true, message)
        end,
    })
    if not ok then return fail("启动本地搜索失败: " .. tostring(batch)) end
    return function()
        if finished then return end
        finished = true
        batch.cancel("已取消")
        if is_func(on_finish) then on_finish(false, "已取消") end
    end
end

function M:autoChangeBookSource(bookinfo, callback)
    if not (is_tbl(bookinfo) and is_str(bookinfo.bookUrl)) then
        return nil, '自动换源参数错误'
    end
    return self:handleResponse(function()
        local candidates, searched_count, skipped_count =
            self:_search_available_sources(bookinfo.bookUrl, bookinfo.name, bookinfo.author, nil, true)
        if #candidates == 0 then
            if skipped_count > 0 then
                error(string.format("已搜索%d个书源未找到可用源，另有%d个未搜索", searched_count, skipped_count))
            end
            error("未找到可用书源")
        end
        local best = candidates[1]
        local item = self:_find_in_shelf(bookinfo.bookUrl)
        if item then
            item.bookUrl = best.bookUrl
            item.origin = best.origin
            item.originName = best.originName
            return item
        end
        return best
    end, callback, nil, 'autoChangeBookSource')
end

function M:getChaptersList(bookinfo)
    return self:getChapterList(bookinfo)
end

function M:reader3Token()
    return nil
end

return M
