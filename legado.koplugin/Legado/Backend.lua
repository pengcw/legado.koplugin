local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local ffiUtil = require("ffi/util")
local dbg = require("dbg")
local LuaSettings = require("luasettings")
local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local time = require("ui/time")
local bit = require("bit")

local UIManager = require("ui/uimanager")
local TaskQueue = require("Legado.task.Queue")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local errHandler = require("Legado.Helper.Error")
local safe_call = pcall
local load_script = require("Legado.Helper.Loader").load_script
local TaskLock = require("Legado.task.Lock")
local ImageUtil = require("Legado.Helper.ImageUtil")
local ConfigValidator = require("Legado.ConfigValidator")
local base = require("Legado.spore.base")
local Probe = require("Legado.Helper.Probe")
local PreloadReadAhead = require("Legado/PreloadReadAhead")
local PlgState = require("Legado/PlgState")
local BookSourceLogin = require("Legado.Helper.BookSourceLogin")
local TextTransformRules = require("Legado.Helper.TextTransformRules")
local LocalExtension = require("Legado.LocalExtension")

if not dbg.log then
    dbg.log = logger.dbg
end

local M = {
    dbManager = {},
    settings_data = nil,
    task_pid_file = nil,
    apiClient = nil,
    preload_read_ahead = nil,
}

local BOOK_SOURCES_SYNC_INTERVAL = 60 * 60

function M:normalizeDownloadThreads(value)
    local n = tonumber(value)
    if not n or n ~= n then n = 2 end
    return math.max(1, math.min(6, math.floor(n)))
end

local SERVICE_UNREACHABLE_PATTERNS = {
    "connection refused", "连接被拒绝",
    "no route to host", "无法连接到服务",
    "network unreachable", "网络不可用",
    "host not found", "域名解析失败",
    "wantread", "连接超时", "请求超时",
    "ssl handshake failed", "安全连接失败",
    "closed", "连接已关闭",
    "eof", "连接意外终止",
}

local function isServiceUnreachable(err_msg)
    if type(err_msg) ~= "string" or err_msg == "" then return false end
    local lower = err_msg:lower()
    for _, pattern in ipairs(SERVICE_UNREACHABLE_PATTERNS) do
        if lower:find(pattern, 1, true) then return true end
    end
    return false
end

local function extract_err_msg(v)
    if type(v) == "string" then return v end
    if type(v) == "table" then
        return v[1] or v.message or v.errorMsg or v.error or v.reason or v.err or v[2] or "unknown error"
    end
    return v and tostring(v) or nil
end

local function wrap_response(data, err_message)
    local response = {
        type = data ~= nil and 'SUCCESS' or 'ERROR'
    }
    if data ~= nil then
        response.body = data
    else
        local clean_err = err_message and errHandler.extract_message(err_message) or nil
        response.message = clean_err or "Unknown error"
    end
    return response
end

local function unsupported_response(message)
    return wrap_response(nil, message or "当前服务端不支持此功能")
end

local function extract_list(value)
    if type(value) == "string" then
        local ok_json, JSON = pcall(require, "json")
        if not ok_json then return nil end
        local ok_decode, decoded = pcall(JSON.decode, value)
        if not ok_decode then return nil end
        value = decoded
    end
    if type(value) ~= "table" then return nil end
    if value.type == "SUCCESS" then return extract_list(value.body) end
    if value.type == "ERROR" then return nil end
    if value.isSuccess ~= nil then
        if value.isSuccess ~= true then return nil end
        return extract_list(value.data)
    end
    if value.list ~= nil then return extract_list(value.list) end
    if value.data ~= nil then return extract_list(value.data) end
    return value
end

local function normalize_list_response(raw, err_message, fallback_message)
    local list = extract_list(raw)
    if list then return wrap_response(list) end
    local response_error = type(raw) == "table" and (raw.message or raw.errorMsg or raw.error)
    return wrap_response(nil, err_message or response_error or fallback_message)
end

local function summarize_book_sources(sources, trust_provider_flag)
    local summaries = {}
    for _, source in ipairs(sources or {}) do
        if type(source) == "table" then
            local has_login = (trust_provider_flag and source.hasLogin == true)
                or BookSourceLogin.hasLogin(source)
            summaries[#summaries + 1] = {
                bookSourceName = source.bookSourceName,
                bookSourceUrl = source.bookSourceUrl,
                bookSourceGroup = source.bookSourceGroup,
                exploreUrl = source.exploreUrl,
                enabled = source.enabled,
                enabledExplore = source.enabledExplore,
                loginUrl = source.loginUrl,
                hasLogin = has_login and true or false,
            }
        end
    end
    return summaries
end

function M:HandleResponse(response, on_success, on_error)
    on_success = H.is_func(on_success) and on_success or function(...) end
    on_error   = H.is_func(on_error)   and on_error   or function(...) end
    if not H.is_tbl(response) then
        return on_error("Response is nil")
    end
    local rtype = response.type
    if rtype == "SUCCESS" then
        return on_success(response.body)
    elseif rtype == "ERROR" then
        local msg = H.is_str(response.message) and response.message or "Unknown error"
        return on_error(msg)
    end
    return on_error("Unknown response type: " .. tostring(rtype))
end

function M:supportsProviderMethod(method)
    local client = self.apiClient
    if not client then return false end

    if type(client.supports) == "function" then
        local ok, supported = pcall(client.supports, client, method)
        return ok and supported == true
    end
    return type(client[method]) == "function"
end

local function is_response_table(val)
    return type(val) == "table" and (val.type == "SUCCESS" or val.type == "ERROR" or val.isSuccess ~= nil)
end

local function call_provider(client, method, callback, ...)
    if not client then
        local resp = unsupported_response("未初始化服务端")
        if H.is_func(callback) then callback(resp) end
        return resp
    end
    local fn = client[method]
    if type(fn) == "function" then
        local res, err = fn(client, ...)
        if is_response_table(res) then
            local resp = res
            if res.isSuccess ~= nil and res.type == nil then
                if res.isSuccess == true then
                    resp = wrap_response(res.data)
                else
                    resp = wrap_response(nil, res.errorMsg or res.error or "操作失败")
                end
            end
            if H.is_func(callback) then callback(resp) end
            return resp
        end
        local resp = (res == nil and err ~= nil) and wrap_response(nil, err) or wrap_response(res)
        if H.is_func(callback) then callback(resp) end
        return resp
    end
    local resp = unsupported_response("当前服务端不支持此功能")
    if H.is_func(callback) then callback(resp) end
    return resp
end

function M:guardUnsupported(supported, message)
    if supported == true then return nil end
    return unsupported_response(message)
end

function M:clearAuthState()
    local client = self.apiClient
    local token_manager = client and client.tokenManager
    if not token_manager or type(token_manager.clear) ~= "function" then
        return false
    end
    local ok = pcall(token_manager.clear, token_manager)
    return ok
end

function M:onServiceError(err_msg)
    if not self:_isLegadoApp() then return end
    local msg = extract_err_msg(err_msg)
    if not isServiceUnreachable(msg) then return end
    if not NetworkMgr:isConnected() then return end
    local PlgState = require("Legado/PlgState")
    if PlgState.service_guard_cooldown_until
            and PlgState.service_guard_cooldown_until > time.now() then return end
    PlgState.service_guard_cooldown_until = time.now() + time.s(30)
    self:promptServiceUnreachable(msg)
end

function M:promptServiceUnreachable()
    local ButtonDialog = require("ui/widget/buttondialog")
    local Discovery = require("Legado.Helper.Discovery")
    local TaskProg = require("Legado.task.Progress")
    local dialog
    local function startScan()
        TaskProg.loading("正在扫描局域网服务", function()
            return Discovery:scanLegadoServices({ timeout = 0.4 })
        end, function(ok, result)
            if dialog and dialog.close then dialog:close() end
            if not ok or type(result) ~= "table" or not result.list or #result.list == 0 then
                require("Legado/PlgState").service_guard_cooldown_until = time.now() + time.s(10)
                local scope = type(result) == "table" and result.net and result.net.cidr or nil
                return self:_show_notice(string.format("未在 %s 网段发现开源阅读服务",
                    scope and tostring(scope) or "局域网"))
            end
            local result_dialog
            local buttons = {}
            for _, addr in ipairs(result.list) do
                table.insert(buttons, {{ text = addr, callback = function()
                    UIManager:close(result_dialog)
                    self:HandleResponse(self:updateActiveServerAddress(addr), function()
                        self:_show_notice("已切换至 " .. addr)
                        local LibraryView = require("Legado/LibraryView")
                        if LibraryView.instance then LibraryView.instance:onRefreshLibrary() end
                    end, function(switch_err)
                        self:_show_notice("切换失败：" .. tostring(switch_err))
                    end)
                end }})
            end
            table.insert(buttons, {{ text = "取消", callback = function()
                UIManager:close(result_dialog)
                require("Legado/PlgState").service_guard_cooldown_until = time.now() + time.s(30)
            end }})
            result_dialog = ButtonDialog:new{
                title = "扫描结果 - 发现服务端",
                title_align = "center",
                buttons = buttons,
            }
            UIManager:show(result_dialog)
        end, { timeout = 20 })
    end
    local action_buttons = {}
    if PlgState.LOCAL_MODE_ENTRY_ENABLED and not self:_isLocal() and self:_isLegadoApp() then
        table.insert(action_buttons, {
            text = "本地解析",
            callback = function()
                UIManager:close(dialog)
                require("Legado/LibraryView"):getInstance():enableLocalMode()
            end,
        })
    end
    table.insert(action_buttons, {
        text = "扫描并重连",
        callback = function()
            UIManager:close(dialog)
            startScan()
        end,
    })
    table.insert(action_buttons, {
        text = "忽略",
        callback = function()
            UIManager:close(dialog)
        end,
    })
    dialog = ButtonDialog:new{
        title = "请检查阅读 Web 服务是否开启，\n或扫描局域网重连",
        title_align = "center",
        buttons = { action_buttons },
    }
    UIManager:show(dialog)
end

function M:updateActiveServerAddress(new_url)
    if not (H.is_str(new_url) and new_url ~= "") then
        return wrap_response(nil, "地址无效")
    end
    if not new_url:match("^%s*[hH][tT][tT][pP][sS]?://") then
        new_url = "http://" .. new_url
    end
    new_url = new_url:gsub("/+$", "")
    local settings = self:getSettings()
    local conf_name = settings.current_conf_name
    local web_configs = settings.web_configs
    if H.is_tbl(web_configs) and H.is_str(conf_name)
            and H.is_tbl(web_configs[conf_name]) then
        web_configs[conf_name].url = new_url
        settings.web_configs = web_configs
    end
    settings.server_address = new_url
    self:saveSettings(settings)
    self:loadApiProvider()
    logger.info("服务地址已切换至", new_url)
    return wrap_response(true)
end

function M:_isLocal()
    local data = self.settings_data and self.settings_data.data or {}
    local conf_name = data.current_conf_name
    return PlgState:isLocalMode(conf_name) or tonumber(data.server_type) == 4
end

function M:canUseBookDiscovery()
    return not self:_isLocal()
end

function M:_isQingread()
    return tonumber(self.settings_data.data.server_type) == 3
end

function M:_isReader3()
    return tonumber(self.settings_data.data.server_type) == 2
end

function M:_isLegadoApp()
    return tonumber(self.settings_data.data.server_type) == 1
end

function M:_getTextTransformDialect()
    if self:_isReader3() then return "reader3" end
    if self:_isQingread() then return "qread" end
    return "legado"
end

function M:_getMatchedTextTransformRules(book, target)
    if type(book) ~= "table" then return {} end
    local db = self.dbManager
    if not db or type(db.getEnabledTextTransformRules) ~= "function" then return {} end

    local shelf_id = book.book_self_id or book.bookShelfId or self:getCurrentBookShelfId()
    if not (H.is_str(shelf_id) and shelf_id ~= "") then return {} end

    local ok, rules = pcall(db.getEnabledTextTransformRules, db, shelf_id)
    if not ok or type(rules) ~= "table" then
        logger.warn("读取文本转换规则失败:", tostring(rules))
        return {}
    end

    local matched_ok, matched = pcall(
        TextTransformRules.filter,
        rules,
        self:_getTextTransformDialect(),
        book,
        target
    )
    if not matched_ok then
        logger.warn("筛选文本转换规则失败:", tostring(matched))
        return {}
    end
    return matched
end

function M:_withLocalTextTransformRequest(value, target)
    if not self:_isLocal() or type(value) ~= "table" then return value end

    local rules = self:_getMatchedTextTransformRules(value, target)
    if #rules == 0 then return value end

    local request = {}
    for key, item in pairs(value) do request[key] = item end
    request.textTransformDialect = self:_getTextTransformDialect()
    request.textTransformRules = rules
    return request
end

function M:_applyRemoteReader3TextTransform(values, book, target)
    if self:_isLocal() or not self:_isReader3() or type(values) ~= "table" or #values == 0 then
        return values
    end

    local rules = self:_getMatchedTextTransformRules(book, target)
    if #rules == 0 then return values end

    local transformed, err = LocalExtension.applyReader3TextTransform(values, rules)
    if type(transformed) ~= "table" then
        logger.warn("Reader3 文本替换失败，使用原始内容:", tostring(err))
        return values
    end
    return transformed
end

function M:_applyRemoteReader3ChapterTitles(chapters, book)
    if self:_isLocal() or not self:_isReader3() or type(chapters) ~= "table" then
        return chapters
    end

    local indexes, titles = {}, {}
    for index, chapter in ipairs(chapters) do
        if type(chapter) == "table" and H.is_str(chapter.title) then
            indexes[#indexes + 1] = index
            titles[#titles + 1] = chapter.title
        end
    end
    if #titles == 0 then return chapters end

    local transformed = self:_applyRemoteReader3TextTransform(titles, book, "title")
    for i, chapter_index in ipairs(indexes) do
        chapters[chapter_index].title = transformed[i] or chapters[chapter_index].title
    end
    return chapters
end

function M:isEnhancedMode()
    local data = self.settings_data and self.settings_data.data or {}
    return data.enhanced_mode == true
end

function M:toggleEnhancedMode(enable)
    if enable == true then
        local ok, err = LocalExtension.available()
        if not ok then return false, err end
    elseif self:_isLocal() then
        self:toggleLocalMode(false)
    end

    if self.settings_data and self.settings_data.data then
        self.settings_data.data.enhanced_mode = enable == true
        if type(self.settings_data.flush) == "function" then
            self.settings_data:flush()
        end
    end
    return true
end

function M:syncLocalModeData(shelf_id)
    shelf_id = shelf_id or self:getCurrentBookShelfId() or "default"
    local engine_ok, engine_err = LocalExtension.available()
    if not engine_ok then
        return false, engine_err, false
    end

    local source_response = self:getBookSourcesList()
    local supports_rules = self:supportsProviderMethod("getReplaceRules")
    local rule_response, rule_err
    if supports_rules then rule_response, rule_err = self:getReplaceRules() end
    local sources = extract_list(source_response)
    if type(sources) ~= "table" or (#sources == 0 and next(sources) == nil) then
        return true, (source_response and source_response.message) or "未知错误", false
    end

    local rules = extract_list(rule_response)
    if supports_rules and type(rules) ~= "table" then
        return false, "同步替换规则失败: " .. tostring(rule_err or (type(rule_response) == "table" and rule_response.message) or "未知错误"), false
    end

    local ok, err = pcall(function()
        if supports_rules then
            local valid, validation_err = require("Legado.Helper.TextTransformRules").validateSnapshot(rules)
            if not valid then error(validation_err) end
        end
        local committed, commit_err = self.dbManager:transaction(function()
            self.dbManager:syncBookSources(shelf_id, sources)
            if supports_rules then
                self.dbManager:syncTextTransformRules(shelf_id, rules, self:_getTextTransformDialect())
            end
            return true
        end)()
        if not committed then error(commit_err) end
    end)
    if not ok then
        return false, "同步本地模式数据失败: " .. tostring(err), false
    end
    return true, nil, true
end

function M:applyLocalModeState(enable)
    local data = self.settings_data and self.settings_data.data or {}
    PlgState:isLocalMode(data.current_conf_name, enable == true)
    self:loadApiProvider()
    return true
end

function M:toggleLocalMode(enable)
    if enable then
        local shelf_id = self:getCurrentBookShelfId() or "default"
        local ok, err, synced = self:syncLocalModeData(shelf_id)
        if not ok then return false, err end

        local local_sources = {}
        if self.dbManager and type(self.dbManager.getEnabledBookSources) == "function" then
            local_sources = self.dbManager:getEnabledBookSources(shelf_id) or {}
        end
        if not synced and #local_sources == 0 then
            return false, "同步书源失败且本地无离线书源: " .. tostring(err or "未知错误")
        end
        self:applyLocalModeState(true)
        return true, synced and nil or "OFFLINE_CACHE"
    end

    self:applyLocalModeState(false)
    return true
end

function M:loadApiProvider()
    local client
    local opts = { settings = self:getSettings() }
    if self:_isLocal() then
        local local_client = LocalExtension.createProvider({
            db = self.dbManager,
            shelf_id = self:getCurrentBookShelfId() or "default",
            settings = opts.settings,
        })
        if local_client then
            self.apiClient = local_client
            return
        end

        local data = self.settings_data and self.settings_data.data or {}
        if tonumber(data.server_type) == 4 then
            self.apiClient = nil
            return
        end
        PlgState:isLocalMode(data.current_conf_name, false)
    end

    if self:_isReader3() then
        client = require("Legado.spore.reader3")
    elseif self:_isQingread() then
        client = require("Legado.spore.qread")
        opts.source_summary_loader = function()
            local db, shelf_id = self.dbManager, self:getCurrentBookShelfId()
            if not db or not H.is_str(shelf_id) or shelf_id == "" then return nil end
            local sources = db:getEnabledBookSourceSummaries(shelf_id)
            if #sources > 0 then return sources end
            local known = db:execute([[
                SELECT 1 FROM book_sources WHERE bookShelfId = ?
                UNION ALL
                SELECT 1 FROM sync_records WHERE scopeType = 'bookshelf' AND scopeId = ?
                    AND resourceType = 'book_sources' AND resourceKey = '' AND lastSuccessAt > 0
                LIMIT 1
            ]], { shelf_id, shelf_id })
            if #known > 0 then return sources end
            return nil
        end
    else
        client = require("Legado.spore.android_app")
    end
    self.apiClient = client:new(opts)
end

local preload_callbacks = {}

local function make_preload_host(backend)
    return {
        is_connected = function()
            return NetworkMgr:isConnected()
        end,
        get_settings = function()
            return backend:getSettings()
        end,
        normalize_download_threads = function(value)
            return backend:normalizeDownloadThreads(value)
        end,
        is_comic = function(book_cache_id)
            return backend:isBookTypeComic(book_cache_id)
        end,
        get_usable_cache_path = function(chapter)
            local cache = backend:getCacheChapterFilePath(chapter, true)
            if cache and cache.cacheFilePath and util.fileExists(cache.cacheFilePath) then
                return cache.cacheFilePath
            end
        end,
        get_cached_ahead = function(chapter)
            return backend:getcompleteReadAheadChapters(chapter)
        end,
        get_readable_ahead_indexes = function(chapter, count)
            if backend.dbManager and type(backend.dbManager.getReadableAheadIndexes) == "function" then
                return backend.dbManager:getReadableAheadIndexes(chapter, count)
            end
            local current_index = tonumber(chapter and chapter.chapters_index)
            local indexes = {}
            if current_index then
                for i = 1, math.max(0, math.floor(tonumber(count) or 0)) do
                    indexes[i] = current_index + i
                end
            end
            return indexes
        end,
        find_missing_chapters = function(chapter, count)
            return backend:findNextChaptersNotDownLoad(chapter, count, true)
        end,
        get_book_info = function(book_cache_id)
            return backend:getBookInfoCache(book_cache_id)
        end,
        download_chapter = function(chapter, options)
            return backend:_pDownloadChapter(chapter, options)
        end,
        commit_cache_path = function(chapter, path)
            return backend.dbManager:updateCacheFilePath(chapter, path)
        end,
        set_task_lock = function(targets, is_locked, ttl, owner_id)
            return TaskLock.setLock(backend.dbManager, targets, is_locked, ttl, owner_id)
        end,
        inject_one = function(book_cache_id, chapter_index, raw, book_name)
            if preload_callbacks.inject_one then
                return preload_callbacks.inject_one(book_cache_id, chapter_index, raw, book_name)
            end
        end,
        inject_many = function(book_cache_id, chapters_map, book_name)
            if preload_callbacks.inject_many then
                return preload_callbacks.inject_many(book_cache_id, chapters_map, book_name)
            end
        end,
        reading_chapter = function()
            return PlgState:readingChapter()
        end,
        request_refresh = function(priority, context)
            if preload_callbacks.request_refresh then return preload_callbacks.request_refresh(priority, context) end
        end,
        show_notice = function(message)
            return backend:_show_notice(message)
        end,
        show_chapter_loading = function(chapter)
            if preload_callbacks.show_chapter_loading then return preload_callbacks.show_chapter_loading(chapter) end
        end,
        hide_chapter_loading = function(chapter, error_msg)
            if preload_callbacks.hide_chapter_loading then return preload_callbacks.hide_chapter_loading(chapter, error_msg) end
        end,
    }
end

function M:_newPreloadReadAhead(callbacks)
    if callbacks then preload_callbacks = callbacks end
    return PreloadReadAhead:new(make_preload_host(self), PlgState)
end

function M:initialize(callbacks)
    if callbacks then preload_callbacks = callbacks end
    local BookInfoDB = require("Legado/BookInfoDB")
    self.dbManager = BookInfoDB:new({
        dbPath = Env.getTempDirectory() .. "/bookinfo.db"
    })
    local ok, err_msg = pcall(function()
        local fn, file_path = load_script("Legado/_r3l_once")
        return fn and fn() == true and util.removeFile(file_path)
    end)
    if not ok then
        logger.err("run_once_task loading loading failed:", err_msg)
    end
    require("Legado/EpubHelper").prepareCacheResources()

    self.settings_data = self:getLuaConfig(Env.getUserSettingsPath())

    if H.is_tbl(self.settings_data) and not (H.is_tbl(self.settings_data.data) and
                self.settings_data.data['current_conf_name']) then
        self.settings_data.data = {
                server_address = "http://127.0.0.1:1122",
                current_conf_name = "default",
                web_configs ={
                    ["default"] = {
                        url = "http://127.0.0.1:1122",
                        ["type"] = 1,
                        desc = "",
                    },
                },
                server_type = 1,
                reader3_un = '',
                reader3_pwd = '',
                disable_browser = nil,
                sync_reading = nil,
                open_at_last_read = nil,
        }
        self.settings_data:flush()
    end
    pcall(function() TaskLock.cleanAll(self.dbManager) end)
    self.preload_read_ahead = self:_newPreloadReadAhead()
    self:loadApiProvider()
end

function M:checkOta(is_compel)
    local check_interval = 518400
    local setting_data = self:getSettings()
    local last_check = tonumber(setting_data.last_check_ota) or 0
    local need_check = is_compel == true or (os.time() - last_check > check_interval)

    if need_check and NetworkMgr:isConnected() then
        local legado_update = require("Legado/Update")
        setting_data.last_check_ota = (os.time() - check_interval + 259200)
        self:saveSettings(setting_data)

        legado_update:ota(function()
            setting_data = self:getSettings()
            setting_data.last_check_ota = os.time()
            self:saveSettings(setting_data)
        end)
    end
end

function M:_show_notice(msg)
    local Notification = require("ui/widget/notification")
    Notification:notify(msg or '', Notification.SOURCE_ALWAYS_SHOW)
end
function M:getLuaConfig(path)
    return LuaSettings:open(path)
end
function M:backgroundCacheConfig()
    return self:getLuaConfig(Env.getTempDirectory() .. '/cache.lua')
end

function M:sharedChapterMetadata(book_cache_dir)
    if not (H.is_str(book_cache_dir) and util.pathExists(book_cache_dir)) then return {} end
    local book_defaults_path = FS.joinPath(book_cache_dir, "book_defaults.lua")
    return self:getLuaConfig(book_defaults_path)
end
function M:bookContentType(book)
    if H.is_str(book) then book = self:getBookInfoCache(book) end
    if not H.is_tbl(book) then return "unknown" end
    local value = tonumber(book.btype or book.type)
    if not value then
        if book.cacheExt == "cbz" then return "comic" end
        return "unknown"
    end
    if value == 2 or bit.band(value, 64) ~= 0 then return "comic" end
    if value == 0 or value == 8 or bit.band(value, 8) ~= 0 then return "reader" end
    if book.cacheExt == "cbz" then return "comic" end
    return "unknown"
end

function M:isBookTypeComic(book_cache_id)
    if not H.is_str(book_cache_id) then return false end
    local route = self:bookReaderRoute(book_cache_id)
    if route == "comic" then return true end
    if route == "reader" then return false end
    return self:bookContentType(book_cache_id) == "comic"
end

function M:refreshLibraryCache(last_refresh_time)
    if self:enforceRateLimit(last_refresh_time, 2000) then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
    end
    if self:_isLocal() then
        return wrap_response(true)
    end
    local ret, err_msg = self.apiClient:getBookshelf(function(response)
        local bookShelfId = self:getCurrentBookShelfId()
        local status, err = pcall(function()
            return self.dbManager:upsertBooks(bookShelfId, response.data)
        end)
        if not status then
            dbg.log('refreshLibraryCache数据写入', err)
            return nil, '写入数据出错，请重试'
        end
        return true
    end)
    return wrap_response(ret, err_msg)
end

function M:syncAndResortBooks()
    if not self:supportsProviderMethod("getBookshelf") then
        return unsupported_response("当前服务端不支持拉取远端书架排序")
    end

    local wrapped_response = self:refreshLibraryCache()
    return self:HandleResponse(wrapped_response, function(_)
        local bookShelfId = self:getCurrentBookShelfId()
        local status, err = pcall(function()
            return self.dbManager:resortBooksByLastRead(bookShelfId)
        end)
        if not status then
            return wrap_response(nil, "排序失败: " .. tostring(err))
        end
        return wrap_response(true)
    end, function(err_msg)
        return wrap_response(nil, err_msg)
    end)
end

function M:addBookToLibrary(bookinfo)
    return wrap_response(self.apiClient:saveBook(bookinfo, function(response)
        if H.is_tbl(response) and H.is_tbl(response.data) and H.is_str(response.data.name) and H.is_str(response.data.bookUrl) and H.is_str(response.data.origin) then
            local bookShelfId = self:getCurrentBookShelfId()
            local db_save = {response.data}
            local status, err = pcall(function()
                return self.dbManager:upsertBooks(bookShelfId, db_save, true)
            end)

            if not status then
                dbg.log('addBookToLibrary数据写入', tostring(err))
                return nil, '数据写入出错，请重试'
            end
        end
        return true
    end))
end
function M:isDownloadBook(bookinfo)
    return self:_isLocal() and H.is_tbl(bookinfo)
        and tonumber(bookinfo.btype or bookinfo.type) == 3
end

function M:downloadBook(bookinfo, temp)
    if not self:isDownloadBook(bookinfo) then
        return unsupported_response("当前模式不支持文件书源下载")
    end
    return wrap_response(self.apiClient:downloadBook(bookinfo, temp))
end

function M:deleteBook(bookinfo)
    if self:_isLocal() then
        return unsupported_response("本地解析模式不支持删除")
    end
    return wrap_response(self.apiClient:deleteBook(bookinfo))
end
function M:getChaptersList(bookinfo)
    return wrap_response(self.apiClient:getChapterList(
        self:_withLocalTextTransformRequest(bookinfo, "title")
    ))
end
function M:refreshChaptersCache(bookinfo, last_refresh_time)
    if self:enforceRateLimit(last_refresh_time, 2000) then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
    end
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl) and H.is_str(bookinfo.cache_id)) then
        return wrap_response(nil, "获取目录参数错误")
    end
    local book_cache_id = bookinfo.cache_id
    local book_shelf_id = bookinfo.book_self_id or self:getCurrentBookShelfId()

    local request_book = self:_withLocalTextTransformRequest(bookinfo, "title")
    return wrap_response(self.apiClient:getChapterList(request_book, function(response)
        if not self:_isLocal() and self:_isReader3() and H.is_tbl(response.data) then
            self:_applyRemoteReader3ChapterTitles(response.data, bookinfo)
        end

        local write_ok, valid_count = false, 0
        local status, err = safe_call(function()
            if self:_isLocal() and H.is_str(response.bookVariable) then
                self.dbManager:transaction(function()
                    write_ok, valid_count = self.dbManager:upsertChapters(book_cache_id, response.data)
                    if write_ok and valid_count > 0 then
                        self.dbManager:dynamicUpdate('books', { variable = response.bookVariable }, {
                            bookCacheId = book_cache_id, bookShelfId = book_shelf_id,
                            bookUrl = bookinfo.bookUrl, origin = bookinfo.origin,
                        })
                    end
                end)()
            else
                write_ok, valid_count = self.dbManager:upsertChapters(book_cache_id, response.data)
            end
            if write_ok and valid_count > 0 then
                if preload_callbacks.sync_new_chapters then
                    pcall(preload_callbacks.sync_new_chapters, book_cache_id, bookinfo.name or bookinfo.title)
                end
            end
        end)
        if not status or not write_ok then
            dbg.log('refreshChaptersCache数据写入', tostring(err))
            return nil, '数据写入出错，请重试'
        end
        if valid_count <= 0 then
            return nil, '目录为空或格式异常'
        end
        return true
    end))
end

function M:pGetChapterContent(chapter)
    if not self:_isLocal() and self:_isReader3() then
        return wrap_response(self.apiClient:getBookContent(chapter, function(response)
            local content = response.data
            if not H.is_str(content) then return content end
            local transformed = self:_applyRemoteReader3TextTransform({ content }, chapter, "content")
            return transformed[1] or content
        end))
    end

    if not self:_isLocal() then
        return wrap_response(self.apiClient:getBookContent(chapter))
    end

    local request_chapter = self:_withLocalTextTransformRequest(chapter, "content")
    if not H.is_str(chapter.book_cache_id) or not H.is_num(chapter.chapters_index) then
        return wrap_response(self.apiClient:getBookContent(request_chapter))
    end
    local next_chapter = self.dbManager:findNextChapterInfo({
        book_cache_id = chapter.book_cache_id,
        chapters_index = chapter.chapters_index,
        call_event = "next",
    })
    if H.is_tbl(next_chapter) and H.is_str(next_chapter.chapterUrl)
            and next_chapter.chapterUrl ~= "" then
        if request_chapter == chapter then
            request_chapter = {}
            for key, value in pairs(chapter) do request_chapter[key] = value end
        end
        request_chapter.nextChapterUrl = next_chapter.chapterUrl
    end
    local shelf_id = chapter.book_self_id or self:getCurrentBookShelfId()
    return wrap_response(self.apiClient:getBookContent(request_chapter, function(response)
        local book_changed = H.is_str(response.bookVariable) and response.bookVariable ~= chapter.bookVariable
        local chapter_changed = H.is_str(response.variable) and response.variable ~= chapter.variable
        if book_changed or chapter_changed then
            local saved, err = self.dbManager:transaction(function()
                if book_changed then
                    self.dbManager:dynamicUpdate('books', { variable = response.bookVariable }, {
                        bookCacheId = chapter.book_cache_id, bookShelfId = shelf_id,
                        bookUrl = chapter.bookUrl, origin = chapter.origin,
                        variable = chapter.bookVariable or '_NULL',
                    })
                end
                if chapter_changed then
                    self.dbManager:dynamicUpdate('chapters', { variable = response.variable }, {
                        bookCacheId = chapter.book_cache_id, chapterIndex = chapter.chapters_index,
                        variable = chapter.variable or '_NULL',
                    })
                end
                return true
            end)()
            if not saved then error(err or '正文变量保存失败') end
        end
        return response.data
    end))
end
function M:refreshBookContent(chapter)
    if self:_isLocal() then return self:pGetChapterContent(chapter) end
    return wrap_response(self.apiClient:refreshBookContent(chapter))
end
function M:saveBookProgress(chapter)
    return call_provider(self.apiClient, "saveBookProgress", nil, chapter)
end
function M:getProxyCoverUrl(coverUrl)
    return self.apiClient:getProxyCoverUrl(coverUrl)
end
function M:getProxyEpubUrl(bookUrl, htmlUrl)
    return self.apiClient:getProxyEpubUrl(bookUrl, htmlUrl)
end
function M:getProxyImageUrl(bookUrl, img_src)
    if self.apiClient and self.apiClient.getProxyImageUrl then
        return self.apiClient:getProxyImageUrl(bookUrl, img_src)
    end
    return img_src
end
function M:getBookSourcesList(callback)
    local raw, err_msg = self.apiClient:getBookSourcesList()
    local response = normalize_list_response(raw, err_msg, "获取书源列表失败")
    if H.is_func(callback) then callback(response) end
    return response
end

function M:getBookSourcesListCached(callback)
    local shelf_id = self:getCurrentBookShelfId()
    local summary_reader = self:_isLocal() and self.dbManager
        and self.dbManager.getEnabledBookSourceSummaries
    if H.is_str(shelf_id) and shelf_id ~= ""
            and self.dbManager and type(self.dbManager.getEnabledBookSources) == "function" then
        local local_ok, local_sources = pcall(function()
            if summary_reader then return summary_reader(self.dbManager, shelf_id) end
            return self.dbManager:getEnabledBookSources(shelf_id)
        end)
        if local_ok and H.is_tbl(local_sources) and #local_sources > 0 then
            local response = wrap_response(summarize_book_sources(local_sources, summary_reader ~= nil))
            if H.is_func(callback) then callback(response) end
            return response
        end
        if not local_ok then
            logger.warn("getBookSourcesListCached: local read failed:", tostring(local_sources))
        end
    end

    local response = self:getBookSourcesList()
    local sources = extract_list(response)
    if not sources then
        if H.is_func(callback) then callback(response) end
        return response
    end

    local local_mode = self:_isLocal()
    local response_sources = local_mode and summarize_book_sources(sources, true) or sources
    if local_mode then
        response = wrap_response(response_sources)
        if H.is_func(callback) then callback(response) end
        return response
    end

    if H.is_str(shelf_id) and shelf_id ~= ""
            and self.dbManager and type(self.dbManager.syncBookSources) == "function" then
        local sync_ok, sync_err = pcall(function()
            return self.dbManager:syncBookSources(shelf_id, sources)
        end)
        if not sync_ok then
            response = wrap_response(nil, "缓存书源失败: " .. tostring(sync_err))
        else
            response = wrap_response(response_sources)
        end
    else
        response = wrap_response(response_sources)
    end
    if H.is_func(callback) then callback(response) end
    return response
end

function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    return call_provider(self.apiClient, "getBookSourcesExploreUrl", callback, bookSourceUrl, callback)
end

function M:getBookSourceLoginUi(bookSourceUrl, callback)
    return call_provider(self.apiClient, "getBookSourceLoginUi", callback, bookSourceUrl, callback)
end

function M:loginBookSource(options, callback)
    return call_provider(self.apiClient, "loginBookSource", callback, options, callback)
end

function M:getAvailableBookSource(options, on_finish, on_chunk)
    local client = self.apiClient
    if not client or type(client.getAvailableBookSource) ~= "function" then
        local msg = "当前服务端不支持此功能"
        if H.is_func(on_finish) then on_finish(false, nil, msg, -1) end
        return nil, msg
    end
    if self:_isLocal() then self:closeDbManager() end
    return client:getAvailableBookSource(options, on_finish, on_chunk)
end

function M:exploreBook(options, callback)
    return call_provider(self.apiClient, "exploreBook", callback, options, callback)
end

function M:autoChangeBookSource(bookinfo, callback)
    return call_provider(self.apiClient, "autoChangeBookSource", callback, bookinfo, callback)
end

function M:searchBookSingle(options, callback)
    return call_provider(self.apiClient, "searchBookSingle", callback, options, callback)
end

function M:searchBookMulti(...)
    local client = self.apiClient
    if not client or type(client.searchBookMulti) ~= "function" then
        return wrap_response(nil, "当前服务端不支持此功能")
    end

    if self:_isLocal() then self:closeDbManager() end
    local result, err_msg = client:searchBookMulti(...)
    if result == nil and err_msg ~= nil then
        return wrap_response(nil, err_msg)
    end
    return result
end

function M:getReplaceRules(callback)
    local client = self.apiClient
    if not client or type(client.getReplaceRules) ~= "function" then
        local resp = unsupported_response("当前服务端不支持替换规则")
        if H.is_func(callback) then callback(resp) end
        return resp
    end
    local raw, err_msg = client:getReplaceRules()
    local response = normalize_list_response(raw, err_msg, "获取替换规则失败")
    if H.is_func(callback) then callback(response) end
    return response
end

function M:getTxtTocRules(callback)
    local client = self.apiClient
    if not client or type(client.getTxtTocRules) ~= "function" then
        local resp = unsupported_response("当前客户端不支持获取文本目录规则")
        if H.is_func(callback) then callback(resp) end
        return resp
    end
    local raw, err_msg = client:getTxtTocRules()
    local response = normalize_list_response(raw, err_msg, "获取文本目录规则失败")
    if H.is_func(callback) then callback(response) end
    return response
end

function M:updateBookSources(shelf_id, skip_reload)
    if self:_isLocal() then
        return nil, "本地模式不支持同步远端书源"
    end

    if not (self.dbManager and type(self.dbManager.syncBookSources) == "function") then
        return nil, "本地数据库不可用"
    end

    local response = self:getBookSourcesList()
    local sources = extract_list(response)
    if not sources then
        return nil, (response and response.message) or "获取书源列表失败"
    end

    shelf_id = shelf_id or self:getCurrentBookShelfId()
    if not (H.is_str(shelf_id) and shelf_id ~= "") then
        return nil, "书架标识无效"
    end

    local ok, count = pcall(function()
        return self.dbManager:syncBookSources(shelf_id, sources)
    end)
    if not ok then
        return nil, "同步书源失败: " .. tostring(count)
    end

    if not skip_reload then
        self:loadApiProvider()
    end
    return tonumber(count) or 0
end

function M:updateReplaceRules(shelf_id, skip_reload)
    if self:_isLocal() then
        return nil, "本地模式不支持同步远端替换规则"
    end

    if type(self.apiClient.getReplaceRules) ~= "function" then
        return nil, "当前客户端不支持获取替换规则"
    end
    if not (self.dbManager and type(self.dbManager.syncTextTransformRules) == "function") then
        return nil, "本地数据库不可用"
    end

    local response = self:getReplaceRules()
    local rules = extract_list(response)
    if not rules then
        return nil, (response and response.message) or "获取替换规则失败"
    end

    shelf_id = shelf_id or self:getCurrentBookShelfId()
    if not (H.is_str(shelf_id) and shelf_id ~= "") then
        return nil, "书架标识无效"
    end

    local ok, count = pcall(function()
        return self.dbManager:syncTextTransformRules(shelf_id, rules, self:_getTextTransformDialect())
    end)
    if not ok then
        return nil, "同步替换规则失败: " .. tostring(count)
    end

    if not skip_reload then
        self:loadApiProvider()
    end
    return tonumber(count) or 0
end

function M:BookSourcesAndRulesAsync(force)
    if self:_isLocal() then
        if force == true then return false, "本地模式不支持同步远端书源和替换规则" end
        return false
    end

    local shelf_id = self:getCurrentBookShelfId()
    local probe_target = "book_sources_and_rules@" .. tostring(shelf_id or "-")
    if not (H.is_str(shelf_id) and shelf_id ~= "") then
        logger.warn("BookSourcesAndRulesAsync: invalid bookshelf id")
        return
    end

    local channel = TaskQueue:getChannel("BookSourcesAndRules")
    if channel:hasTasks() then
        logger.dbg("BookSourcesAndRulesAsync: task already running")
        return
    end

    if not (self.dbManager and type(self.dbManager.tryStartSync) == "function") then
        logger.warn("BookSourcesAndRulesAsync: sync state is unavailable")
        return
    end
    local sync_interval = force == true and 0 or BOOK_SOURCES_SYNC_INTERVAL
    local gate_ok, should_start = pcall(function()
        return self.dbManager:tryStartSync(shelf_id, "book_sources", sync_interval)
    end)
    if not gate_ok then
        logger.warn("BookSourcesAndRulesAsync: sync frequency check failed:", tostring(should_start))
        return
    end
    Probe.eventf("Source", "后台同步限频", nil,
        "shelf_id=%s allowed=%s interval=%ds",
        shelf_id, tostring(should_start == true), sync_interval)
    if should_start ~= true then
        logger.dbg("BookSourcesAndRulesAsync: sync interval not reached")
        return
    end

    local t_sync_start = Probe.start("Source", "书源后台更新", probe_target, function()
        return string.format("(force=%s interval=%ds)", tostring(force == true), sync_interval)
    end)

    self:closeDbManager()
    channel:pushTask(function(target_shelf_id)
        local errors = {}
        local source_ok, source_count, source_err = pcall(function()
            return self:updateBookSources(target_shelf_id, true)
        end)
        if not source_ok then
            logger.err("BookSourcesAndRulesAsync: book sources sync failed:", tostring(source_count))
        elseif not source_count then
            logger.warn("BookSourcesAndRulesAsync: book sources sync failed:", tostring(source_err))
        end

        local rule_ok, rule_count, rule_err = pcall(function()
            return self:updateReplaceRules(target_shelf_id, true)
        end)
        if not rule_ok then
            logger.err("BookSourcesAndRulesAsync: replace rules sync failed:", tostring(rule_count))
        elseif not rule_count then
            logger.warn("BookSourcesAndRulesAsync: replace rules sync failed:", tostring(rule_err))
        end

        if not source_ok or source_count == nil then
            errors[#errors + 1] = "书源: " .. tostring(source_ok and source_err or source_count)
        end
        if not rule_ok or rule_count == nil then
            errors[#errors + 1] = "规则: " .. tostring(rule_ok and rule_err or rule_count)
        end
        if #errors > 0 then return false, table.concat(errors, "; ") end
        return true
    end, function(ok, err)
        if ok then
            Probe.done("Source", "书源后台更新", probe_target, t_sync_start, "200 OK")
            if self:_isLocal() then
                self:loadApiProvider()
            end
        else
            Probe.fail("Source", "书源后台更新", probe_target, t_sync_start, tostring(err))
            logger.err("BookSourcesAndRulesAsync: process failed:", tostring(err))
        end
    end, {
        args = { shelf_id },
        timeout = 120,
    })
end

function M:changeBookSource(newBookSource)
    local client = self.apiClient
    if not client or type(client.changeBookSource) ~= "function" then
        return unsupported_response("当前服务端不支持换源")
    end
    PlgState:cancelPreload("change_book_source")
    return wrap_response(self.apiClient:changeBookSource(newBookSource, function(response)
        local target_book
        if H.is_tbl(response) and H.is_tbl(response.data) then
            target_book = base:_norm_book_fields(response.data)
            if not target_book.bookUrl and newBookSource.newUrl then
                target_book.bookUrl = newBookSource.newUrl
            end
            if not target_book.origin and newBookSource.bookSourceUrl then
                target_book.origin = newBookSource.bookSourceUrl
            end
            if not target_book.originName and newBookSource.originName then
                target_book.originName = newBookSource.originName
            end
        elseif H.is_tbl(newBookSource) then
            target_book = {}
            for key, value in pairs(newBookSource) do
                target_book[key] = value
            end
            if target_book.newUrl then
                target_book.bookUrl = target_book.newUrl
            end
            if target_book.bookSourceUrl then
                target_book.origin = target_book.bookSourceUrl
            end
            if target_book.originName then
                target_book.originName = target_book.originName
            end
            target_book = base:_norm_book_fields(target_book)
        end

        if not target_book then
            return nil, '服务端返回空数据'
        end
        if not (H.is_str(target_book.name) and H.is_str(target_book.bookUrl)
                and H.is_str(target_book.origin)) then
            return nil, '接口返回数据格式错误'
        end

        local bookShelfId = self:getCurrentBookShelfId()
        local status, err = pcall(function()
            return self.dbManager:upsertBooks(bookShelfId, { target_book }, true)
        end)
        if not status then
            dbg.log('changeBookSource数据写入', tostring(err))
            return nil, '数据写入出错，请重试'
        end
        return true
    end))
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
local function format_chapter_desc(ch)
    if not ch then return "未知章节" end
    local idx = ch.chapters_index or ch.index or "?"
    local title = ch.title or ch.name or ""
    if title ~= "" then
        return string.format("第%s章: %s", tostring(idx), tostring(title))
    end
    return string.format("第%s章", tostring(idx))
end

function M:_pDownloadChapter(chapter, download_opts)
    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index

    if bookUrl == nil or not book_cache_id then
        error('_pDownloadChapter input parameters err' .. tostring(bookUrl) .. tostring(book_cache_id))
    end

    local cache_chapter = self:getCacheChapterFilePath(chapter, true)
    if cache_chapter and cache_chapter.cacheFilePath then
        local cache_size = FS.getFileSize(cache_chapter.cacheFilePath)
        Probe.done("Chapter", "命中本地缓存", format_chapter_desc(chapter), chapter._t_probe_start, "CACHE_HIT", Probe.format_bytes(cache_size))
        return cache_chapter
    end

    local t_dl_start = Probe.start("Chapter", "下载章节内容", format_chapter_desc(chapter), tostring(bookUrl))
    if download_opts and download_opts.acquire_request
            and not download_opts.acquire_request() then
        error("cancelled")
    end
    local response = self:pGetChapterContent(chapter)

    if not H.is_tbl(response) or response.type ~= 'SUCCESS' then
        local err_msg = (response and response.message) or '章节下载失败'
        Probe.fail("Chapter", "章节下载失败", format_chapter_desc(chapter), t_dl_start, tostring(err_msg))
        error(err_msg)
    end

    local raw_body = response.body
    local is_empty = true
    if H.is_str(raw_body) then
        local trimmed = raw_body:gsub("^%s+", ""):gsub("%s+$", "")
        if #trimmed > 0 then is_empty = false end
    elseif H.is_tbl(raw_body) then
        if #raw_body > 0 then is_empty = false end
    end

    if is_empty then
        local err_msg = "源站返回正文内容为空"
        Probe.fail("Chapter", "章节内容为空", format_chapter_desc(chapter), t_dl_start, err_msg)
        error(err_msg)
    end

    local filePath = Env.getChapterCacheFilePath(book_cache_id, chapters_index, chapter.name)
    local opts = {
        content_normalized = self:_isLocal(),
        getPorxyPicUrls = function(url, txt) return self:getPorxyPicUrls(url, txt) end,
        getProxyEpubUrl = function(url, line) return self:getProxyEpubUrl(url, line) end,
        getProxyImageUrl = function(url, src) return self:getProxyImageUrl(url, src) end,
        is_txt = self.settings_data.data.istxt == true,
    }
    local result = require("Legado.ContentParser").analyzing(chapter, response.body, filePath, opts)
    if result.kind == "cbz" then
        if download_opts and download_opts.auto_pack_cbz then
            Probe.done("Chapter", "漫画图片解析完成", format_chapter_desc(chapter), t_dl_start, "200 OK", Probe.format_bytes(#(response.body or "")), string.format("(%d P)", #(result.img_sources or {})))
            local max_threads = self:normalizeDownloadThreads(self.settings_data.data.download_threads)
            local QueueCbz = require("Legado.task.QueueCbz")
            local cbz_path = QueueCbz.from_urls(result.filePath, result.img_sources, download_opts and download_opts.check_running, {
                max_workers = max_threads,
                comic_info = { name = chapter.title or chapter.name or "" },
                chapter_desc = format_chapter_desc(chapter),
            })
            result.chapter.cacheFilePath = cbz_path
            return result.chapter
        else
            Probe.done("Chapter", "漫画图片解析完成", format_chapter_desc(chapter), t_dl_start, "CBZ_PENDING", string.format("(%d P)", #(result.img_sources or {})))
            return result
        end
    end
    if result.kind ~= "file" then
        error(string.format("未知章节解析类型: %s", tostring(result.kind)))
    end
    local written = chapter_writeToFile(result.chapter, result.filePath, result.data)
    local cache_size = FS.getFileSize(result.filePath)
    Probe.done("Chapter", "章节下载完成", format_chapter_desc(chapter), t_dl_start, "200 OK", Probe.format_bytes(cache_size))
    return written
end

function M:getCacheChapterFilePath(chapter, not_write_db)

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
            local tmp_file = cache_file_path .. ".tmp"
            if util.fileExists(tmp_file) then
                util.removeFile(tmp_file)
            end
            if not not_write_db then
                pcall(function()
                    self.dbManager:updateCacheFilePath(chapter, false)
                end)
            end
            chapter.cacheFilePath = nil
        end
    end

    local filePath = Env.getChapterCacheFilePath(book_cache_id, chapters_index, book_name)

    if H.is_str(cacheExt) and cacheExt ~= "" then
        local fullPath = filePath .. '.' .. cacheExt
        if util.fileExists(fullPath) then
            chapter.cacheFilePath = fullPath
            return chapter
        end
    end

    for _, ext in ipairs(Env.CHAPTER_CACHE_EXTENSIONS_LIST) do
        if ext ~= cacheExt then
            local fullPath = filePath .. '.' .. ext
            if util.fileExists(fullPath) then
                chapter.cacheFilePath = fullPath
                return chapter
            end
        end
    end

    return chapter
end

function M:clearChapterCache(book_cache_id, chapters_index)
    if not book_cache_id or chapters_index == nil then return false end
    local chapter = { book_cache_id = book_cache_id, chapters_index = chapters_index }
    local ch_cache = self:getCacheChapterFilePath(chapter, true)
    local cacheFilePath = ch_cache and ch_cache.cacheFilePath
    if cacheFilePath and util.fileExists(cacheFilePath) then
        pcall(function() DocSettings:open(cacheFilePath):purge() end)
        util.removeFile(cacheFilePath)
    end
    self.dbManager:updateCacheFilePath(chapter, false)
    return true
end

function M:findNextChaptersNotDownLoad(current_chapter, count, include_read)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log('findNextChaptersNotDownLoad: bad params', current_chapter)
        return {}
    end

    if current_chapter.call_event == nil then
        current_chapter.call_event = 'next'
    end

    local next_chapters = self.dbManager:findChapterNotDownLoadLittle(current_chapter, count, include_read)

    if not H.is_tbl(next_chapters[1]) or next_chapters[1].chapters_index == nil then
        dbg.log('not found', current_chapter.chapters_index)
        return {}
    end

    return next_chapters
end

function M:findPreviousChapter(current_chapter)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil
            or tonumber(current_chapter.chapters_index) == nil then
        return nil
    end
    return self:findNextChapter({
        book_cache_id = current_chapter.book_cache_id,
        chapters_index = tonumber(current_chapter.chapters_index),
        call_event = 'prev',
    })
end

function M:findNextChapter(current_chapter, is_downloaded)

    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log("findNextChapter: bad params", current_chapter)
        return
    end

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

function M:getPorxyPicUrls(bookUrl, content)
    return ImageUtil.extract_urls_from_html(content, function(src)
        return self:getProxyImageUrl(bookUrl, src)
    end)
end

function M:getChapterImgList(chapter)
    local chapters_index = chapter.chapters_index
    local bookUrl = chapter.bookUrl
    local origin = chapter.origin
    local down_chapters_index = chapters_index

    local ZipUtil = require("Legado.Helper.ZipUtil")
    if ZipUtil.isArchiverAvailable() then
        local cache_chapter = self:getCacheChapterFilePath(chapter, true)
        local cbz_path = cache_chapter and cache_chapter.cacheFilePath
        if cbz_path and cbz_path:match("%.cbz$") and util.fileExists(cbz_path) then
            local reader = ZipUtil.Reader:new()
            if reader and reader.open and reader:open(cbz_path) then
                local image_meta = require("Legado.Helper.image_meta")
                local img_entries = {}
                reader:iterate(function(entry)
                    if entry.mode ~= "directory" and image_meta.get_image_ext(entry.path) then
                        table.insert(img_entries, entry.path)
                    end
                end)
                if #img_entries > 0 then
                    table.sort(img_entries, function(a, b)
                        local a_index = tonumber(a:match("^(%d+)%."))
                        local b_index = tonumber(b:match("^(%d+)%."))
                        if a_index and b_index and a_index ~= b_index then
                            return a_index < b_index
                        end
                        return a < b
                    end)
                    local img_sources = {}
                    for _, entry_name in ipairs(img_entries) do
                        table.insert(img_sources, string.format("cbz://%s#%s", cbz_path, entry_name))
                    end
                    if chapter.isRead ~= true then
                        self.dbManager:updateIsRead(chapter, true, true)
                    end
                    return img_sources
                end
            end
        end
    end

    local req_chapter = {
        bookUrl = bookUrl,
        chapters_index = down_chapters_index,
        origin = origin,
        url = chapter.url or chapter.chapterUrl,
        chapterUrl = chapter.chapterUrl or chapter.url,
        book_cache_id = chapter.book_cache_id,
        title = chapter.title,
    }
    if not (H.is_str(req_chapter.url) and req_chapter.url ~= "") and chapter.book_cache_id then
        local ch = self:getChapterInfoCache(chapter.book_cache_id, tonumber(down_chapters_index))
        if H.is_tbl(ch) then
            req_chapter.url = ch.url or ch.chapterUrl
            req_chapter.chapterUrl = req_chapter.url
        end
    end

    return self:HandleResponse(self:pGetChapterContent(req_chapter), function(data)
        local err_msg
        if H.is_str(data) then
            local img_sources = self:getPorxyPicUrls(bookUrl, data)
            if H.is_tbl(img_sources) and #img_sources > 0 then
                if chapter.isRead ~= true then
                    self.dbManager:updateIsRead(chapter, true, true)
                end
                return img_sources
            else
                err_msg = "获取图片列表失败"
            end
        else
            err_msg = "获取图片列表失败"
        end
        logger.dbg("getChapterImgList err:", err_msg)
        return nil, err_msg
    end, function(err_msg)
        logger.err("getChapterImgList err:", err_msg)
        return nil, err_msg
    end)
end

function M:preLoadingChapters(chapters, download_chapter_count, result_progress_callback, temp_disable_multithread)
    local has_result_progress_callback = H.is_func(result_progress_callback)

    local return_error_handle = function(error_msg)
        error_msg = error_msg or "未知错误"
        logger.dbg("Legado.preLoadingChapters - ", error_msg)
        if has_result_progress_callback then result_progress_callback(false, error_msg) end
        return false, error_msg
    end

    if not H.is_tbl(chapters) then return return_error_handle('Incorrect call parameters') end
    pcall(function() TaskLock.cleanExpired(self.dbManager) end)

    local chapter_down_tasks
    local is_read_ahead = true
    if H.is_tbl(chapters[1]) and chapters[1].chapters_index ~= nil and chapters[1].book_cache_id ~= nil then
        chapter_down_tasks = chapters
        is_read_ahead = false
    else
        local down_count = tonumber(download_chapter_count)
        down_count = (down_count and down_count > 1) and down_count or 1
        chapter_down_tasks = self:findNextChaptersNotDownLoad(chapters, down_count)
    end

    if not H.is_tbl(chapter_down_tasks) or #chapter_down_tasks < 1 then
        logger.dbg("Legado.preLoadingChapters - All chapters already cached")
        Probe.done("Preload", "所有章节已缓存", tostring(chapters[1] and chapters[1].book_cache_id or "-"), nil, "CACHE_HIT", "0 chapters")
        if has_result_progress_callback then result_progress_callback(true, "所有章节已缓存") end
        return true, "所有章节已缓存"
    end

    local settings = self:getSettings()
    local max_threads = self:normalizeDownloadThreads(settings.download_threads)
    if temp_disable_multithread then
        max_threads = 1
        logger.info("Multi-threading temporarily disabled for this session")
    end

    local first_ch = chapter_down_tasks[1]
    local last_ch = chapter_down_tasks[#chapter_down_tasks]
    local book_cache_id = first_ch.book_cache_id
    local is_comic = self:isBookTypeComic(book_cache_id)
    local chapter_timeout = is_comic and 120 or 20

    local mode_name = is_read_ahead and "翻页预读" or "批量下载"
    local book_title = first_ch.book_name or first_ch.name or tostring(book_cache_id)
    local range_str = string.format("第%s..%s章", tostring(first_ch.chapters_index or 1), tostring(last_ch.chapters_index or #chapter_down_tasks))
    local batch_desc = string.format("%s[%s] 共%d章 (%s)", mode_name, book_title, #chapter_down_tasks, range_str)
    local t_batch_start = Probe.start("Preload", batch_desc, string.format("(threads=%d, type=%s, timeout=%ds)", max_threads, is_comic and "comic" or "text", chapter_timeout))

    logger.dbg("Legado.preLoadingChapters - START with", max_threads, "threads, type:", is_comic and "comic" or "text", "timeout:", chapter_timeout .. "s")

    local batch_id = "preload_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    local channel_prefix = is_read_ahead and "Preload_" or "PreloadBulk_"
    local channel_name = channel_prefix .. tostring(book_cache_id)
    local ch = TaskQueue:createChannel(channel_name, max_threads, nil, true)
    local completed_count = 0
    local has_error = false
    local failed_count = 0
    local failed_chapters = {}
    local first_error = nil

    local is_finalizing = false
    local pending_cbz_count = 0
    local check_completion = function(progress, err_msg, failed_chapter)
        if progress == false then
            Probe.fail("Preload", "预加载失败", batch_desc, t_batch_start, tostring(err_msg or "下载中断"))
            if not is_read_ahead then
                has_error = true
                failed_count = failed_count + 1
                first_error = first_error or err_msg or "下载中断"
                if failed_chapter then table.insert(failed_chapters, failed_chapter) end
                if has_result_progress_callback then
                    result_progress_callback(completed_count + failed_count)
                end
            elseif has_result_progress_callback then
                result_progress_callback(false, err_msg)
            end
        elseif has_result_progress_callback and type(progress) == "number" then
            if not is_read_ahead then
                result_progress_callback(completed_count + failed_count, err_msg)
            elseif not has_error then
                result_progress_callback(progress, err_msg)
            end
        end

        if is_finalizing then return end
        UIManager:nextTick(function()
            if ch and not ch:hasTasks() and pending_cbz_count <= 0 then
                if is_finalizing then return end
                is_finalizing = true
                if not is_read_ahead then
                    TaskQueue:destroyChannel(channel_name)
                end
                if has_error and not is_read_ahead then
                    local summary = string.format("缓存结束：成功%d章，失败%d章。首个错误：%s", completed_count, failed_count, tostring(first_error or "下载中断"))
                    Probe.done("Preload", "预加载批处理完成", batch_desc, t_batch_start, "PARTIAL_FAILURE", string.format("completed=%d/%d, failed=%d", completed_count + failed_count, #chapter_down_tasks, failed_count))
                    if has_result_progress_callback then
                        result_progress_callback(false, summary, failed_chapters)
                    end
                else
                    Probe.done("Preload", "预加载批处理完成", batch_desc, t_batch_start, "SUCCESS", string.format("%d/%d loaded", completed_count, #chapter_down_tasks))
                    if has_result_progress_callback and not has_error then
                        result_progress_callback(true, "任务结束")
                    end
                end
            end
        end)
    end

    if is_read_ahead and ch.queue and #ch.queue > 0 then
        local max_queue_size = math.max(10, (tonumber(download_chapter_count) or 3) * 2)
        if #ch.queue > max_queue_size then
            local tasks_to_drop = {}
            for i = #ch.queue, max_queue_size + 1, -1 do
                local removed_task = table.remove(ch.queue, i)
                if removed_task and removed_task.args and removed_task.args[1] then
                    local removed_chapter = removed_task.args[1]
                    removed_chapter.is_pre_loading = nil
                    table.insert(tasks_to_drop, removed_chapter)
                    logger.dbg('Legado.preLoadingChapters - Dropped old queued task:', removed_chapter.chapters_index)
                end
            end
            if #tasks_to_drop > 0 then
                pcall(function() TaskLock.setLock(self.dbManager, tasks_to_drop, false, nil, batch_id) end)
            end
        end
    end

    local tasks_to_insert = {}
    local db_update_success = self.dbManager:transaction(function(chapter_info, cache_file_path)
        self.dbManager:updateCacheFilePath(chapter_info, cache_file_path)
    end, {enable_savepoint = true})

    for i = #chapter_down_tasks, 1, -1 do
        local dlChapter = chapter_down_tasks[i]

        if dlChapter.isDownLoaded ~= true and not self:isTaskRunning(dlChapter) then
            dlChapter.is_pre_loading = true
            table.insert(tasks_to_insert, dlChapter)

            ch:pushTask(
                function(chapter_info)
                    return self:_pDownloadChapter(chapter_info)
                end,
                function(success, downloaded_chapter)
                    local current_chapter = dlChapter
                    current_chapter.is_pre_loading = nil
                    if success and H.is_tbl(downloaded_chapter) and downloaded_chapter.kind == "cbz" then
                        local pending = downloaded_chapter
                        pending_cbz_count = pending_cbz_count + 1
                        local t_cbz_start = Probe.start("Chapter", "CBZ打包", format_chapter_desc(current_chapter), string.format("(%d P图片)", #pending.img_sources))
                        local cbz_writer = require("Legado.task.QueueCbz"):new()
                        local started, start_err = cbz_writer:from_urls_async({
                            output = pending.filePath,
                            images = pending.img_sources,
                            opts = {
                                comic_info = { name = current_chapter.title or "" },
                                max_workers = max_threads,
                            },
                            on_finish = function(_, result)
                                pending_cbz_count = pending_cbz_count - 1
                                if not (result and result.success) then
                                    pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)
                                    logger.err("Failed to package cbz:", tostring(pending.filePath))
                                    Probe.fail("Chapter", "CBZ打包失败", format_chapter_desc(current_chapter), t_cbz_start, tostring(result and result.output or pending.filePath))
                                    return check_completion(false, string.format("章节[%s]图片打包失败: %s", tostring(current_chapter.title), tostring(result and result.output or pending.filePath)), current_chapter)
                                end
                                current_chapter.cacheFilePath = pending.filePath
                                logger.dbg('Download chapter successfully (cbz):', current_chapter.book_cache_id, current_chapter.chapters_index, pending.filePath)

                                local ok, err = pcall(db_update_success, current_chapter, pending.filePath)
                                if not ok then logger.err('Error saving download to database:', tostring(err)) end

                                pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)

                                completed_count = completed_count + 1
                                local cbz_size = FS.getFileSize(pending.filePath)
                                local progress_str = string.format("进度 %d/%d", completed_count, #chapter_down_tasks)
                                Probe.done("Chapter", "CBZ完成", format_chapter_desc(current_chapter), t_cbz_start, "200 OK", Probe.format_bytes(cbz_size), progress_str)
                                check_completion(completed_count)
                            end,
                        })
                        if not started then
                            pending_cbz_count = pending_cbz_count - 1
                            pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)
                            logger.err("Failed to start cbz packaging:", tostring(start_err))
                            Probe.fail("Chapter", "CBZ启动失败", format_chapter_desc(current_chapter), t_cbz_start, tostring(start_err))
                            return check_completion(false, string.format("章节[%s]图片打包启动失败: %s", tostring(current_chapter.title), tostring(start_err)), current_chapter)
                        end
                        return
                    end

                    if not (success and H.is_tbl(downloaded_chapter) and downloaded_chapter.cacheFilePath) then
                        pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)
                        logger.err("Failed to download chapter:", tostring(downloaded_chapter))
                        Probe.fail("Chapter", "章节下载失败", format_chapter_desc(current_chapter), current_chapter._t_probe_start, tostring(downloaded_chapter))
                        return check_completion(false, string.format("章节[%s]下载失败: %s", tostring(current_chapter.title), tostring(downloaded_chapter)), current_chapter)
                    end

                    local cache_file_path = downloaded_chapter.cacheFilePath
                    logger.dbg('Download chapter successfully:', current_chapter.book_cache_id, current_chapter.chapters_index, cache_file_path)

                    local ok, err = pcall(db_update_success, current_chapter, cache_file_path)
                    if not ok then logger.err('Error saving download to database:', tostring(err)) end

                    pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)

                    completed_count = completed_count + 1
                    local file_size = FS.getFileSize(cache_file_path)
                    local progress_str = string.format("进度 %d/%d", completed_count, #chapter_down_tasks)
                    Probe.done("Chapter", "章节下载完成", format_chapter_desc(current_chapter), current_chapter._t_probe_start, "200 OK", Probe.format_bytes(file_size), progress_str)
                    check_completion(completed_count)
                end,
                {
                    args = {dlChapter},
                    insert_at_head = true,
                    timeout = chapter_timeout,
                    on_start = function()
                        dlChapter._t_probe_start = H.timestamp()
                        Probe.start("Chapter", "下载章节", format_chapter_desc(dlChapter), string.format("(book_id: %s, idx: %s)", tostring(book_cache_id), tostring(dlChapter.chapters_index)))
                        logger.dbg('TaskQueue running: chapter_title:', dlChapter.title or nil)
                    end
                }
            )
        else
            logger.dbg('Legado.preLoadingChapters - Task already processed/locked, skip:', dlChapter.chapters_index)
        end
    end

    if #tasks_to_insert > 0 then
        local lock_ttl = math.max(3600, chapter_timeout * #tasks_to_insert)
        pcall(function() TaskLock.setLock(self.dbManager, tasks_to_insert, true, lock_ttl, batch_id) end)
    else
        if has_result_progress_callback and not has_error then
            UIManager:nextTick(function()
                result_progress_callback(true, "所选章节已在后台下载或已完成")
            end)
        end
    end

    if ch then ch:resume() end
    return true
end

function M:analyzeCacheStatus(book_cache_id, chapter_count)
    if not (H.is_num(chapter_count) and chapter_count > 0 ) then
        chapter_count = self:getChapterCount(book_cache_id)
    end
    return self:analyzeCacheStatusForRange(book_cache_id, 0, chapter_count - 1)
end

function M:analyzeCacheStatusForRange(book_cache_id, start_index, end_index, stats_only)
    local result = { total_count = 0, cached_count = 0, uncached_count = 0, cached_chapters = {}, uncached_chapters = {} }
    if not (H.is_str(book_cache_id) and H.is_num(start_index) and H.is_num(end_index)) then
        logger.err("analyzeCacheStatusForRange err - book_cache_id, start_index, end_index: ",book_cache_id, start_index, end_index)
        return result
    end
    if start_index < 0 or end_index < start_index then
        logger.err("analyzeCacheStatusForRange err - start_index, end_index: ",start_index, end_index)
        return result
    end
    for i = start_index, end_index do
        local chapter = self:getChapterInfoCache(book_cache_id, i)
        if H.is_tbl(chapter) and not chapter.isVolume then
            local is_cached = false
            if chapter.cacheFilePath and util.fileExists(chapter.cacheFilePath) then
                is_cached = true
            else
                local cache_chapter = self:getCacheChapterFilePath(chapter, true)
                if H.is_tbl(cache_chapter) and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
                    is_cached = true
                end
            end
            if is_cached == true then
                result.cached_count = result.cached_count + 1
                if not stats_only then table.insert(result.cached_chapters, chapter) end
            else
                result.uncached_count = result.uncached_count + 1
                if not stats_only then
                    chapter.call_event = 'next'
                    table.insert(result.uncached_chapters, chapter)
                end
            end
            result.total_count = result.total_count + 1
        end
    end
    return result
end

function M:getChapterInfoCache(bookCacheId, chapterIndex)
    local chapter_data = self.dbManager:getChapterInfo(bookCacheId, chapterIndex)
    return chapter_data
end

function M:getChapterCount(bookCacheId)
    return self.dbManager:getChapterCount(bookCacheId)
end

function M:getBookInfoCache(bookCacheId)
    local bookShelfId = self:getCurrentBookShelfId()
    return self.dbManager:getBookinfo(bookShelfId, bookCacheId)
end

function M:getcompleteReadAheadChapters(current_chapter)
    return self.dbManager:getcompleteReadAheadChapters(current_chapter)
end

function M:manuallyPinToTop(bookCacheId, sortOrder)
    local bookShelfId = self:getCurrentBookShelfId()
    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        return wrap_response(nil, '参数错误')
    end
    self.dbManager:setBooksTopStatus(bookShelfId, bookCacheId, sortOrder)
    return wrap_response(true)
end

function M:getBookShelfCache()
    local bookShelfId = self:getCurrentBookShelfId()
    return self.dbManager:getAllBooksByUI(bookShelfId)
end

function M:autoPinToTop(bookCacheId, sortOrder)
    if 0 == sortOrder then
        return wrap_response(true)
    end
    local bookShelfId = self:getCurrentBookShelfId()
    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        return wrap_response(nil, '参数错误')
    end
    self.dbManager:setBooksTopStatus(bookShelfId, bookCacheId, nil, true)
    return wrap_response(true)
end

function M:getLastReadChapter(bookCacheId)
    return self.dbManager:getLastReadChapter(bookCacheId)
end

function M:getChapterLastUpdateTime(bookCacheId)
    return self.dbManager:getChapterLastUpdateTime(bookCacheId)
end

function M:getBookExtras(book_cache_id)
    local book_cache_dir = Env.getBookCachePath(book_cache_id)
    return self:getLuaConfig(FS.joinPath(book_cache_dir, "cache.lua"))
end

function M:bookReaderRoute(book_cache_id, route)
    if not H.is_str(book_cache_id) then
        return route == nil and "auto" or wrap_response(nil, "book_cache_id 参数错误")
    end
    local settings = self:getBookExtras(book_cache_id)
    if route ~= nil then
        if route ~= "auto" and route ~= "reader" and route ~= "comic" then
            return wrap_response(nil, "route 必须是 auto、reader 或 comic")
        end
        settings:saveSetting("reader_route_override", route):flush()
        PlgState:clearReadingRoute(book_cache_id)
        return wrap_response(true)
    end
    local saved = H.is_tbl(settings.data) and settings.data.reader_route_override or nil
    if saved == "reader" or saved == "comic" then return saved end
    return "auto"
end

function M:chapterSortingMode(bookCacheId, mode)
    if not H.is_str(bookCacheId) then
        return wrap_response(nil, 'bookCacheId 参数错误')
    end
    local extras_settings = self:getBookExtras(bookCacheId)
    if mode then
        if not (H.is_str(mode) and (mode == 'ASC' or mode == 'DESC')) then
            return wrap_response(nil, 'mode 参数错误，必须是 "ASC" 或 "DESC"')
        end
        extras_settings:saveSetting("chapter_sorting_mode", mode):flush()
        return wrap_response(true)
    else
        local chapter_sorting_mode = "ASC"
        if H.is_tbl(extras_settings.data) and H.is_str(extras_settings.data.chapter_sorting_mode) then
            chapter_sorting_mode = extras_settings.data.chapter_sorting_mode
        end
        return chapter_sorting_mode
    end
end

function M:getAllChaptersByUI(bookCacheId)
    local chapter_data = self.dbManager:getAllChaptersByUI(bookCacheId, false)
    return chapter_data
end

function M:getBookChapterPlusCache(bookCacheId)
    local chapter_data = self.dbManager:getAllChapters(bookCacheId)
    return chapter_data
end

function M:getReadableChapters(bookCacheId)
    local chapter_data = self.dbManager:getReadableChapters(bookCacheId)
    return chapter_data
end

function M:closeDbManager()
    if self.dbManager and type(self.dbManager.closeDB) == "function" then
        pcall(function() self.dbManager:closeDB() end)
    end
end

local BOOK_CACHE_METADATA_FILES = {
    ["book_defaults.lua"] = true,
    ["cache.lua"] = true,
    ["virtual_book_location.lua"] = true,
}

local function purge_book_cache_files(path, is_root)
    local ok, iterator, state = pcall(lfs.dir, path)
    if not ok or not iterator then return false end
    local success = true
    local scan_ok = pcall(function()
        for entry in iterator, state do
            if entry ~= "." and entry ~= ".." then
                local child = FS.joinPath(path, entry)
                local attr = (lfs.symlinkattributes or lfs.attributes)(child)
                if not attr then
                    success = false
                elseif attr.mode == "directory" then
                    if not purge_book_cache_files(child, false) then success = false end
                    util.removePath(child)
                    if util.pathExists(child) then success = false end
                elseif not is_root or not BOOK_CACHE_METADATA_FILES[entry] then
                    util.removeFile(child)
                    if util.pathExists(child) then success = false end
                end
            end
        end
    end)
    return scan_ok and success
end

function M:purgeBookCache(book_cache_id)
    if not (H.is_str(book_cache_id) and book_cache_id ~= "")
            or book_cache_id:find("[/\\]") then
        return wrap_response(nil, "缓存标识无效")
    end
    if self:isTaskRunning() then
        return wrap_response(nil, "有后台任务进行中，请等待结束或者重启 KOReader")
    end

    local reading = PlgState:readingChapter()
    if H.is_tbl(reading) and reading.book_cache_id == book_cache_id then
        return wrap_response(nil, "当前书籍正在阅读，请关闭后再清理")
    end

    local cached_paths = self.dbManager:getChapterCachePaths(book_cache_id)
    for _, path in ipairs(cached_paths) do
        if util.fileExists(path) then
            pcall(function() DocSettings:open(path):purge() end)
        end
    end

    local cache_path = FS.joinPath(Env.getTempDirectory(), book_cache_id .. ".sdr")
    if util.pathExists(cache_path) then
        if not purge_book_cache_files(cache_path, true) then
            return wrap_response(nil, "缓存目录清理失败")
        end
        util.removePath(cache_path)
    end
    self.dbManager:clearChapterCachePaths(book_cache_id)
    return wrap_response(true)
end

function M:cleanBookCache(book_cache_id)
    if self:isTaskRunning() then
        return wrap_response(nil, '有后台任务进行中，请等待结束或者重启 KOReader')
    end

    local bookShelfId = self:getCurrentBookShelfId()
    local ok_clear, cleared = pcall(self.dbManager.clearBook, self.dbManager, bookShelfId, book_cache_id)
    if not ok_clear or cleared ~= true then
        return wrap_response(nil, '清理章节数据失败')
    end

    local book_cache_path = Env.getBookCachePath(book_cache_id)
    if book_cache_path and util.pathExists(book_cache_path) then
        local ok_purge = pcall(ffiUtil.purgeDir, book_cache_path)
        if not ok_purge then
            return wrap_response(nil, '清理缓存文件失败')
        end
    end
    return wrap_response(true)
end

function M:cleanAllBookCaches()
    pcall(function() TaskLock.cleanExpired(self.dbManager) end)
    if self:isTaskRunning() then
        return wrap_response(nil, '有后台在运行，请等待或重启 KOReader')
    end

    local bookShelfId = self:getCurrentBookShelfId()
    self.dbManager:removeBookShelf(bookShelfId)
    self:closeDbManager()
    local books_cache_dir = Env.getTempDirectory()
    ffiUtil.purgeDir(books_cache_dir)
    require("Legado/EpubHelper").prepareCacheResources()
    self:saveSettings()
    return wrap_response(true)
end

function M:getDBFileSize()
    if not (self.dbManager and self.dbManager.dbPath) then return 0 end
    return FS.getFileSize(self.dbManager.dbPath)
end

function M:vacuumDatabase()
    local old_size = self:getDBFileSize()
    local ok, err = pcall(function()
        return self.dbManager:getDB():exec("VACUUM;")
    end)
    if not ok then
        return wrap_response(nil, tostring(err))
    end
    local new_size = self:getDBFileSize()
    return wrap_response({
        old_size = old_size,
        new_size = new_size
    })
end

function M:MarkReadChapter(chapter, is_update_timestamp)
    chapter.isRead = not chapter.isRead
    self.dbManager:updateIsRead(chapter, chapter.isRead, is_update_timestamp)
    return wrap_response(true)
end

function M:ChangeChapterCache(chapter)
    local cacheFilePath = chapter.cacheFilePath
    local isDownLoaded = chapter.isDownLoaded

    if isDownLoaded ~= true then
        local task_started, err = self:preLoadingChapters({chapter}, 1)
        if task_started == true then
            return wrap_response(true)
        else
            return wrap_response(nil, '下载任务添加失败：' .. tostring(err))
        end
    else
        if util.fileExists(cacheFilePath) then
            pcall(function() DocSettings:open(cacheFilePath):purge() end)
            util.removeFile(cacheFilePath)
        end
        self.dbManager:updateCacheFilePath(chapter, false)
        self:refreshBookContentAsync(chapter)
        return wrap_response(true)
    end
end

function M:refreshBookContentAsync(chapter)
    self:launchProcess(function()
        self:refreshBookContent(chapter)
    end)
end

function M:saveBookProgressAsync(chapter)
    if not self:supportsProviderMethod("saveBookProgress") then return end

    self:launchProcess(function()
            return self:saveBookProgress(chapter)
        end, function(_, response)
        if not (H.is_tbl(response) and response.type == 'SUCCESS') then
            self:_show_notice("自动上传进度失败")
        end
    end)
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

function M:findCustomCoverFileInDir(cover_path_no_ext)
    return ImageUtil.findCustomCoverFileInDir(cover_path_no_ext)
end

function M:emitMetadataChanged(book_file)
    if H.is_str(book_file) and util.fileExists(book_file) then
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", book_file))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end
end

function M:get_default_cover_cache(book_cache_id)
    return ImageUtil.get_default_cover_cache(book_cache_id)
end

local function is_cover_network_failure(err)
    if type(err) ~= "string" then return false end
    return err:find("request interrupted", 1, true) ~= nil
        or err:find("Network or remote server unavailable", 1, true) ~= nil
end

function M:download_cover_img(book_cache_id, cover_url, is_force)
    local candidates = {}
    local function push_candidate(url)
        if not (H.is_str(url) and url ~= "") then return end
        for _, c in ipairs(candidates) do
            if c == url then return end
        end
        table.insert(candidates, url)
    end

    local proxy_result = self:getProxyCoverUrl(cover_url)
    if type(proxy_result) == "table" then
        for _, url in ipairs(proxy_result) do
            push_candidate(url)
        end
    else
        push_candidate(proxy_result)
    end

    local function try_download(url, timeout)
        return ImageUtil.download_cover(book_cache_id, url, is_force, { timeout = timeout })
    end

    for i, url in ipairs(candidates) do
        if (H.is_str(url) and url:match("^%s*[hH][tT][tT][pP][sS]?://")) then
            local skip = false
            if #candidates > 1 and i == 1 then
                local httpReq = require("Legado.Helper.Http")
                local probe_ok, probe_err = httpReq({ url = url, method = "HEAD", timeout = 3 }, true)
                if not probe_ok and is_cover_network_failure(probe_err) then
                    skip = true
                end
            end
            if not skip then
                local timeout = (i < #candidates) and 8 or 15
                local cover_path, cover_name = try_download(url, timeout)
                if cover_path then
                    return cover_path, cover_name
                end
            end
        end
    end
    return nil, nil
end

function M:with_lock(target, fn, ttl, owner_id)
    return TaskLock.withLock(self.dbManager, target, fn, ttl, owner_id)
end

function M:isTaskRunning(target)
    return TaskLock.isLocked(self.dbManager, target)
end

function M:after_reader_chapter_show(chapter)
    if not chapter or chapter.isVolume == true then return end
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    local cache_file_path = chapter.cacheFilePath
    local should_sync_cache_path = cache_file_path == nil or chapter.isDownLoaded ~= true
    if cache_file_path == nil then
        local ch_cache = self:getCacheChapterFilePath(chapter, true)
        if ch_cache and ch_cache.cacheFilePath and util.fileExists(ch_cache.cacheFilePath) then
            chapter.cacheFilePath = ch_cache.cacheFilePath
            cache_file_path = ch_cache.cacheFilePath
        end
    end
    local is_downloaded = H.is_str(cache_file_path) and util.fileExists(cache_file_path) or false
    Probe.start("Reader", "阅读展示", format_chapter_desc(chapter), string.format("(book_id: %s, idx: %s, ext: %s)", tostring(book_cache_id), tostring(chapters_index), tostring(chapter.cacheExt or "txt")))

    local status, err = safe_call(function()
        local bookShelfId = self:getCurrentBookShelfId()
        self.dbManager:transaction(function()
            self.dbManager:updateIsRead(chapter, true, true)
            if book_cache_id and H.is_num(chapters_index) then
                self.dbManager:updateReadingProgress(bookShelfId, book_cache_id, chapters_index, chapter.title or chapter.name, 0)
                if is_downloaded and should_sync_cache_path then
                    self.dbManager:updateCacheFilePath(chapter, cache_file_path)
                end
            end
        end)()
    end)
    if not status then
        dbg.log('updating the read download flag err:', tostring(err))
    end

    if cache_file_path ~= nil then
        local cache_name = select(2, util.splitFilePathName(cache_file_path)) or ''
        local _, extension = util.splitFileNameSuffix(cache_name)
        if extension and chapter.cacheExt ~= extension then
            chapter.cacheExt = extension
            local p_status, p_err = pcall(function()
                local bookShelfId = self:getCurrentBookShelfId()
                self.dbManager:transaction(function()
                    return self.dbManager:dynamicUpdateBooks({
                        book_cache_id = book_cache_id,
                        bookShelfId = bookShelfId
                    }, {
                        cacheExt = extension
                    })
                end)()
            end)
            if not p_status then
                dbg.log('updating cache ext err:', tostring(p_err))
            end
        end
         if G_reader_settings and G_reader_settings.readSetting and
                G_reader_settings:readSetting("lastfile") ~= cache_file_path then
            G_reader_settings:saveSetting("lastfile", cache_file_path)
         end
    end
    if NetworkMgr:isConnected() then
        local settings = self:getSettings()
        if settings.sync_reading == true then
            if self._save_progress_timer_cancel then
                self._save_progress_timer_cancel()
                self._save_progress_timer_cancel = nil
            end

            self._save_progress_timer_cancel = require("Legado.task.v2").delay(8, function()
                self:saveBookProgressAsync(chapter)
                self._save_progress_timer_cancel = nil
            end)
        end
        local preloader = self.preload_read_ahead or self:_newPreloadReadAhead()
        self.preload_read_ahead = preloader
        preloader:ensure(chapter, true)
    end
    chapter.isRead = true
    chapter.isDownLoaded = is_downloaded
end

function M:downloadChapter(chapter)
    if self:isTaskRunning(chapter) then
        Probe.retry("Chapter", "章节正在后台执行中", format_chapter_desc(chapter), nil, "LOCK_HELD")
        return wrap_response(nil, "此章节后台下载中, 请等待...")
    end
    local status, err = safe_call(function()
        return self:_pDownloadChapter(chapter)
    end)
    if not status then
        logger.err('下载章节失败：', err)
        Probe.fail("Chapter", "下载章节失败", format_chapter_desc(chapter), nil, tostring(err))
        return wrap_response(nil, "下载章节失败：" .. tostring(err))
    end
    return wrap_response(err)
end

function M:getCurrentBookShelfId()
    local current_conf_name = self.settings_data and self.settings_data.data and self.settings_data.data.current_conf_name
    if not (H.is_str(current_conf_name) and current_conf_name ~= "") then
        logger.err("[Fatal] BookShelfId is null — cannot proceed without a valid BookShelfId")
        return nil
    end
    return tostring(H.md5(current_conf_name))
end

function M:switchWebConfig(conf_name, is_active_item_changed)
    if not (H.is_str(conf_name) and conf_name ~= "") then
        return wrap_response(nil, "参数错误")
    end
    local settings = self:getSettings()
    local web_configs = settings.web_configs
    if not (H.is_tbl(web_configs) and H.is_tbl(web_configs[conf_name])) then
        return wrap_response(nil, "配置不存在")
    end
    if settings.current_conf_name == conf_name and not is_active_item_changed then
        return wrap_response(nil, "已经是当前激活配置")
    end

    local config = web_configs[conf_name]
    local ok, err_msg = ConfigValidator.check(config.url, config.type, config.user, config.pwd)
    if not ok then
        return wrap_response(nil, tostring(err_msg))
    end
    if H.is_tbl(ok) and ok.url then
        config.url = ok.url
    end
    pcall(function() self.dbManager:disableAllBookShelves() end)

    settings.server_address = config.url
    settings.server_type = config.type
    settings.reader3_un = config.user
    settings.reader3_pwd = config.pwd
    settings.current_conf_name = conf_name
    self:saveSettings(settings)

    self:loadApiProvider()
    return wrap_response(true)
end

function M:deleteWebConfig(conf_name)
    if not (H.is_str(conf_name) and conf_name ~= "") then
        logger.err("deleteWebConfig [Error] Parameter is empty")
        return wrap_response(nil, "参数错误")
    end
    local settings = self:getSettings()
    local web_configs = settings.web_configs
    if not (H.is_tbl(web_configs) and H.is_tbl(web_configs[conf_name])) then
        return wrap_response(nil, "配置不存在")
    end
    if settings.current_conf_name == conf_name then
        return wrap_response(nil, "当前激活配置, 不可删除")
    end

    local book_shelf_id = tostring(H.md5(conf_name))
    pcall(function() self.dbManager:disableBookShelf(book_shelf_id) end)

    self.settings_data.data.web_configs[conf_name] = nil
    self:saveSettings()

    return wrap_response(true)
end

function M:saveWebConfig(conf_name, web_config)
    if not (H.is_tbl(web_config) and conf_name ~= "") then
        logger.err("saveWebConfig [Error] Invalid parameters")
        return wrap_response(nil, "请检查参数是否正确")
    end

    local is_new = (conf_name == nil)
    if not is_new and conf_name ~= web_config.edit_name then
        return wrap_response(nil, "配置名称暂不支持修改")
    end

    local current_conf_name = self.settings_data.data.current_conf_name
    local is_need_switch = not is_new and current_conf_name == conf_name

    if is_new then
        conf_name = web_config.edit_name
    end
    if not (H.is_str(conf_name) and conf_name ~= "") then
        return wrap_response(nil, "配置名称不可为空")
    end
    if #conf_name > 80 then
        return wrap_response(nil, "配置名称过长")
    end

    local url = web_config.url
    local server_type = web_config.type
    local user = web_config.user
    local pwd = web_config.pwd
    local desc = web_config.desc

    local ok, err_msg = ConfigValidator.check(url, server_type, user, pwd)
    if ok then
        if H.is_tbl(ok) and ok.url then
            web_config.url = ok.url
        end
        if not self.settings_data.data.web_configs then
            self.settings_data.data.web_configs = {}
        end

        local cf = self.settings_data.data.web_configs[conf_name]
        if H.is_tbl(cf) then
            if web_config.url == cf.url and server_type == cf.type and user == cf.user and
                pwd == cf.pwd and desc == cf.desc then
                return wrap_response(nil, "配置没有改变")
            end
        end

        web_config.edit_name = nil
        self.settings_data.data.web_configs[conf_name] = web_config

        if is_need_switch then
            return self:switchWebConfig(conf_name, true)
        else
            self:saveSettings()
            return wrap_response(true)
        end
    else
        return wrap_response(nil, tostring(err_msg))
    end
end

function M:getSettings()
    if not self.settings_data then
        self.settings_data = self:getLuaConfig(Env.getUserSettingsPath())
    end
    local settings = self.settings_data.data or {}
    if not H.is_str(settings.server_address) then
        settings.server_address = ""
    end
    return settings
end

function M:saveSettings(settings)
    if not H.is_tbl(settings) then
        self.settings_data:flush()
        self.settings_data = self:getLuaConfig(Env.getUserSettingsPath())
        return wrap_response(true)
    end

    if not ConfigValidator.settings(settings) then
        return wrap_response(nil, '参数校检错误，保存失败')
    end

    self.settings_data.data = settings
    self.settings_data:flush()
    self.settings_data = self:getLuaConfig(Env.getUserSettingsPath())
    return wrap_response(true)
end

function M:launchProcess(job, callback, timeout)
    if not H.is_func(job) then
        logger.err("Legado.launchProcess - job must be a function")
        if H.is_func(callback) then
            callback(false, "invalid_job_function")
        else
            return false, "invalid_job_function"
        end
    end
    if not H.is_func(callback) then
        return TaskQueue.spawnProcess(job, nil, timeout)
    end
    logger.dbg("Legado.launchProcess - START")
    TaskQueue.spawnProcess(job, function(ok, r1, r2)
        logger.dbg("Legado.launchProcess - END")
        local cb_ok, cb_err = pcall(callback, ok, r1, r2)
        if not cb_ok then
            logger.err("Legado.launchProcess - Callback error:", tostring(cb_err))
        end
    end, timeout)
end

function M:backupDbWithPreCheck()
    local temp_dir = Env.getTempDirectory()
    local last_backup_db = FS.joinPath(temp_dir, "bookinfo.db.bak")
    local setting_data = self:getSettings() or {}
    local last_backup_time = tonumber(setting_data.last_backup_time) or 0
    local has_backup = util.fileExists(last_backup_db)
    local needs_backup = not has_backup or (os.time() - last_backup_time > 86400)
    if not needs_backup then
        return true
    end

    local bookinfo_db_path = FS.joinPath(temp_dir, "bookinfo.db")
    if not util.fileExists(bookinfo_db_path) then
        logger.warn("legado plugin: source database file does not exist - " .. bookinfo_db_path)
        return false
    end

    local status, err = pcall(self.getBookShelfCache, self)
    if not status then
        logger.err("legado plugin: database pre-check failed - " .. tostring(err))
        return false
    end

    if has_backup then
        util.removeFile(last_backup_db)
    end
    FS.copyFileFromTo(bookinfo_db_path, last_backup_db)
    logger.info("legado plugin: backup successful")
    setting_data.last_backup_time = os.time()
    self:saveSettings(setting_data)
    return true
end

local function ensure_directory(dir)
    if not (H.is_str(dir) and dir ~= "") then
        return nil, "整本缓存保存目录无效"
    end
    if util.directoryExists(dir) then return dir end
    pcall(FS.checkAndCreateFolder, dir)
    if util.directoryExists(dir) then return dir end
    return nil, "整本缓存保存目录不可用，且无法创建：" .. dir
end

function M:getFullBookCacheOutputDir()
    local dir = self:getSettings().full_book_cache_output_dir
    return H.is_str(dir) and dir ~= "" and dir or Env.getHomeDir()
end

function M:ensureFullBookCacheOutputDir()
    return ensure_directory(self:getFullBookCacheOutputDir())
end

function M:enforceRateLimit(last_time, limit_ms)
    local elapsed = last_time and time.since(last_time)
    if elapsed and elapsed < time.ms(limit_ms) then
        Probe.eventf("RateLimit", "请求被限频", nil,
            "limit_ms=%s elapsed_ms=%s", tostring(limit_ms), tostring(time.to_ms(elapsed)))
        return true
    end
    return false
end
function M:onExitClean()
    dbg.v('Backend call onExitClean')
    self._is_exiting = true
    if preload_callbacks.hide_chapter_loading then preload_callbacks.hide_chapter_loading() end
    PlgState:cancelPreload("backend_exit_clean")
    if preload_callbacks.cleanup then preload_callbacks.cleanup() end
    self:closeDbManager()
    collectgarbage()
    collectgarbage()
    return true
end

require("ffi/__gc")(M, {
    __gc = function()
        M:onExitClean()
    end
})

return M
