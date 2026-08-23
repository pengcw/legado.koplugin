local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local NetworkMgr = require("ui/network/manager")
local ffiUtil = require("ffi/util")
local dbg = require("dbg")
local LuaSettings = require("luasettings")
local util = require("util")
local time = require("ui/time")

local UIManager = require("ui/uimanager")
local TaskQueue = require("Legado.task.Queue")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local safe_call = require("Legado.Helper.Error").pcall
local load_script = require("Legado.Helper.Loader").load_script
local TaskLock = require("Legado.task.Lock")
local ImageUtil = require("Legado.Helper.ImageUtil")
local ContentParser = require("Legado.ContentParser")
local ConfigValidator = require("Legado.ConfigValidator")
local socket = require("socket")
local Probe = require("Legado.Helper.Probe")
local TaskQueueV2 = require("Legado.task.v2")
local PlgState = require("Legado/PlgState")

local function format_chapter_desc(ch)
    if not ch then return "未知章节" end
    local idx = ch.chapters_index or ch.index or "?"
    local title = ch.title or ch.name or ""
    if title ~= "" then
        return string.format("第%s章: %s", tostring(idx), tostring(title))
    end
    return string.format("第%s章", tostring(idx))
end

local function get_file_size(path)
    if not path or not util.fileExists(path) then return 0 end
    local ok, size = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        return lfs.attributes(path, "size")
    end)
    if ok and type(size) == "number" then return size end
    local f = io.open(path, "rb")
    if f then
        local sz = f:seek("end")
        f:close()
        return sz or 0
    end
    return 0
end

-- 太旧版本缺少这个函数
if not dbg.log then
    dbg.log = logger.dbg
end

local M = {
    dbManager = {},
    settings_data = nil,
    task_pid_file = nil,
    apiClient = nil,
}

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
        local clean_err = extract_err_msg(err_message)
        response.message = clean_err or "Unknown error"
    end
    return response
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

function M:onServiceError(err_msg)
    if not self:_isLegadoApp() then return end
    local msg = extract_err_msg(err_msg)
    if not isServiceUnreachable(msg) then return end
    if not NetworkMgr:isConnected() then return end
    local PlgState = require("Legado/PlgState")
    if PlgState.service_guard_cooldown_until
            and PlgState.service_guard_cooldown_until > time.now() then return end
    -- ⚠️ time.now() 返回 fts（定点时间）而非秒：必须用 time.s(30) 换算，
    -- 直接 +30 只加 30 个 fts 单位（毫秒级），冷却会形同虚设
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
                -- 无结果短冷却 10s（用户可能忘了开服务，开完想立即重扫）
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
                -- 取消选择：重置冷却
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
    dialog = ButtonDialog:new{
        title = "请检查阅读 Web 服务是否开启，\n或扫描局域网重连",
        title_align = "center",
        buttons = {{
            { text = "扫描并重连", callback = function()
                UIManager:close(dialog)
                startScan()
            end },
            { text = "忽略", callback = function() UIManager:close(dialog) end },
        }},
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

function M:_isQingread() return self.settings_data.data.server_type == 3 end
function M:_isReader3() return self.settings_data.data.server_type == 2 end
function M:_isLegadoApp() return self.settings_data.data.server_type == 1 end

function M:loadApiProvider()
    local client
    if self:_isReader3() then
        client = require("Legado.spore.reader3")
    elseif self:_isQingread() then
        client = require("Legado.spore.qread")
    else
        client = require("Legado.spore.android_app")
    end
    self.apiClient = client:new{
        settings = self:getSettings()
    }
end

function M:initialize()
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
    self:loadApiProvider()
end

function M:checkOta(is_compel)
    local check_interval = 518400
    local setting_data = self:getSettings()
    local last_check = tonumber(setting_data.last_check_ota) or 0
    local need_check = is_compel == true or (os.time() - last_check > check_interval)

    if need_check and NetworkMgr:isConnected() then
        local legado_update = require("Legado.Update")
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
function M:isBookTypeComic(book_cache_id)
    if not H.is_str(book_cache_id) then return false end
    local chapter = self:getChapterInfoCache(book_cache_id, 1)
    return H.is_tbl(chapter) and chapter.cacheExt == "cbz" or false
end

function M:refreshLibraryCache(last_refresh_time)
    if self:enforceRateLimit(last_refresh_time, 2000) then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
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
        -- isReader3Only = true
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
function M:deleteBook(bookinfo)
    return wrap_response(self.apiClient:deleteBook(bookinfo))
end
function M:getChaptersList(bookinfo)
    return wrap_response(self.apiClient:getChapterList(bookinfo))
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

    return wrap_response(self.apiClient:getChapterList(bookinfo, function(response)
        local status, err = safe_call(function()
            local res = self.dbManager:upsertChapters(book_cache_id, response.data)
            pcall(function() self:syncVirtualBookNewChapters(book_cache_id, bookinfo.name or bookinfo.title) end)
            return res
        end)
        if not status then
            dbg.log('refreshChaptersCache数据写入', tostring(err))
            return nil, '数据写入出错，请重试'
        end
        return true
    end))
end

function M:pGetChapterContent(chapter)
    return wrap_response(self.apiClient:getBookContent(chapter))
end
function M:refreshBookContent(chapter)
    return wrap_response(self.apiClient:refreshBookContent(chapter))
end
function M:saveBookProgress(chapter)
    return wrap_response(self.apiClient:saveBookProgress(chapter))
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
    return wrap_response(self.apiClient:getBookSourcesList(callback))
end
function M:getBookSourcesExploreUrl(bookSourceUrl, callback)
    return wrap_response(self.apiClient:getBookSourcesExploreUrl(bookSourceUrl, callback))
end
function M:getAvailableBookSource(...)
    if type(self.apiClient.getAvailableBookSource) == "function" then
        return self.apiClient:getAvailableBookSource(...)
    end
    return nil
end
function M:exploreBook(options, callback)
    return wrap_response(self.apiClient:exploreBook(options, callback))
end
function M:autoChangeBookSource(bookinfo, callback)
    return wrap_response(self.apiClient:autoChangeBookSource(bookinfo, callback))
end
function M:searchBookSingle(options, callback)
    return wrap_response(self.apiClient:searchBookSingle(options, callback))
end

function M:searchBookMulti(...)
    if type(self.apiClient.searchBookMulti) == "function" then
        return self.apiClient:searchBookMulti(...)
    end
    return nil
end

function M:getReplaceRules(callback)
    if type(self.apiClient.getReplaceRules) == "function" then
        return wrap_response(self.apiClient:getReplaceRules(callback))
    end
    if callback then callback({type="SUCCESS", body={}}) end
    return {type="SUCCESS", body={}}
end

function M:changeBookSource(newBookSource)
    PlgState:cancelPreload("change_book_source")
    return wrap_response(self.apiClient:changeBookSource(newBookSource, function(response)
        if H.is_tbl(response) and H.is_tbl(response.data) and H.is_str(response.data.name) and H.is_str(response.data.bookUrl) and H.is_str(response.data.origin) then
            local bookShelfId = self:getCurrentBookShelfId()
            local r_data = {response.data}
            local status, err = pcall(function()
                return self.dbManager:upsertBooks(bookShelfId, r_data, true)
            end)
            if not status then
                dbg.log('changeBookSource数据写入', tostring(err))
                return nil, '数据写入出错，请重试'
            end
            return true
        else
            return nil, '接口返回数据格式错误'
        end
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

function M:_pDownloadChapter(chapter, download_opts)
    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    -- qread only

    if bookUrl == nil or not book_cache_id then
        error('_pDownloadChapter input parameters err' .. tostring(bookUrl) .. tostring(book_cache_id))
    end

    local cache_chapter = self:getCacheChapterFilePath(chapter, true)
    if cache_chapter and cache_chapter.cacheFilePath then
        local cache_size = get_file_size(cache_chapter.cacheFilePath)
        Probe.done("Chapter", "命中本地缓存", format_chapter_desc(chapter), chapter._t_probe_start, "CACHE_HIT", Probe.format_bytes(cache_size))
        return cache_chapter
    end

    local t_dl_start = Probe.start("Chapter", "下载章节内容", format_chapter_desc(chapter), tostring(bookUrl))
    local response = self:pGetChapterContent(chapter)

    if not H.is_tbl(response) or response.type ~= 'SUCCESS' then
        local err_msg = (response and response.message) or '章节下载失败'
        Probe.fail("Chapter", "章节下载失败", format_chapter_desc(chapter), t_dl_start, tostring(err_msg))
        error(err_msg)
    end

    local raw_body = response.body
    local is_empty = false
    if H.is_str(raw_body) then
        local trimmed = raw_body:gsub("^%s+", ""):gsub("%s+$", "")
        if #trimmed == 0 then
            is_empty = true
        end
    elseif H.is_tbl(raw_body) then
        if #raw_body == 0 then
            is_empty = true
        end
    else
        is_empty = true
    end

    if is_empty then
        local err_msg = "源站返回正文内容为空"
        Probe.fail("Chapter", "章节内容为空", format_chapter_desc(chapter), t_dl_start, err_msg)
        error(err_msg)
    end

    local filePath = Env.getChapterCacheFilePath(book_cache_id, chapters_index, chapter.name)
    local opts = {
        getPorxyPicUrls = function(url, txt) return self:getPorxyPicUrls(url, txt) end,
        getProxyEpubUrl = function(url, line) return self:getProxyEpubUrl(url, line) end,
        getProxyImageUrl = function(url, src) return self:getProxyImageUrl(url, src) end,
        is_txt = self.settings_data.data.istxt == true,
    }
    local result = ContentParser.analyzing(chapter, response.body, filePath, opts)
    if result.kind == "cbz" then
        if download_opts and download_opts.auto_pack_cbz then
            Probe.done("Chapter", "漫画图片解析完成", format_chapter_desc(chapter), t_dl_start, "200 OK", Probe.format_bytes(#(response.body or "")), string.format("(%d P)", #(result.img_sources or {})))
            local max_threads = tonumber(self.settings_data.data.download_threads) or 4
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
        -- 避免静默写空文件
        error(string.format("未知章节解析类型: %s", tostring(result.kind)))
    end
    local written = chapter_writeToFile(result.chapter, result.filePath, result.data)
    local cache_size = get_file_size(result.filePath)
    Probe.done("Chapter", "章节下载完成", format_chapter_desc(chapter), t_dl_start, "200 OK", Probe.format_bytes(cache_size))
    return written
end

-- write_to_db, run in subprocess, no DB writes allowed
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
            -- 清理可能的临时文件
            local tmp_file = cache_file_path .. ".tmp"
            if util.fileExists(tmp_file) then
                pcall(function() util.removeFile(tmp_file) end)
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

function M:clearChapterCache(book_cache_id, chapters_index)
    if not book_cache_id or chapters_index == nil then return false end
    local chapter = { book_cache_id = book_cache_id, chapters_index = chapters_index }
    local ch_cache = self:getCacheChapterFilePath(chapter, true)
    local cacheFilePath = ch_cache and ch_cache.cacheFilePath
    if cacheFilePath and util.fileExists(cacheFilePath) then
        pcall(function()
            require("docsettings"):open(cacheFilePath):purge()
        end)
        pcall(util.removeFile, cacheFilePath)
    end
    if self.dbManager and type(self.dbManager.dynamicUpdateChapters) == "function" then
        pcall(function()
            self.dbManager:dynamicUpdateChapters(chapter, {
                content = '_NULL',
                cacheFilePath = '_NULL',
            })
        end)
    elseif self.dbManager and type(self.dbManager.updateCacheFilePath) == "function" then
        pcall(function()
            self.dbManager:updateCacheFilePath(chapter, false)
        end)
    end
    return true
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
                    table.sort(img_entries)
                    local img_sources = {}
                    for _, entry_name in ipairs(img_entries) do
                        table.insert(img_sources, string.format("cbz://%s#%s", cbz_path, entry_name))
                    end
                    if self.dbManager and type(self.dbManager.updateIsRead) == "function" and chapter.isRead ~= true then
                        self.dbManager:updateIsRead(chapter, true, true)
                    end
                    return img_sources
                end
            end
        end
    end

    return self:HandleResponse(self:pGetChapterContent({
        bookUrl = bookUrl,
        chapters_index = down_chapters_index,
        origin = origin,
    }), function(data)
        local err_msg
        if H.is_str(data) then
            local img_sources = self:getPorxyPicUrls(bookUrl, data)
            if H.is_tbl(img_sources) and #img_sources > 0 then
                if self.dbManager and type(self.dbManager.updateIsRead) == "function" and chapter.isRead ~= true then
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
        -- mark false when input is a list (e.g., 1000 chapters)
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
    local max_threads = tonumber(settings.download_threads) or 2
    max_threads = math.max(1, math.min(16, max_threads))
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

    local is_finalizing = false
    local pending_cbz_count = 0 -- 进行中的异步 CBZ 打包数(from_urls_async 不在 ch 任务队列中)
    local check_completion = function(progress, err_msg)
        if progress == false then
            Probe.fail("Preload", "预加载失败", batch_desc, t_batch_start, tostring(err_msg or "下载中断"))
            if not is_read_ahead and not has_error then
                has_error = true
                if ch then
                    local tasks_to_remove = {}
                    for _, task in ipairs(ch.queue) do
                        if task.args and task.args[1] then
                            local removed_chapter = task.args[1]
                            removed_chapter.is_pre_loading = nil
                            table.insert(tasks_to_remove, removed_chapter)
                        end
                    end
                    pcall(function() TaskLock.setLock(self.dbManager, tasks_to_remove, false, nil, batch_id) end)
                    ch:clearTasks()
                end
                if has_result_progress_callback then
                    result_progress_callback(false, err_msg)
                end
            elseif is_read_ahead and has_result_progress_callback then
                result_progress_callback(false, err_msg)
            end
        elseif not has_error and has_result_progress_callback and type(progress) == "number" then
            result_progress_callback(progress, err_msg)
        end

        if is_finalizing then return end
        UIManager:nextTick(function()
            if ch and not ch:hasTasks() and pending_cbz_count <= 0 then
                -- 并发锁
                if is_finalizing then return end
                is_finalizing = true
                if not is_read_ahead then
                    TaskQueue:destroyChannel(channel_name)
                end
                Probe.done("Preload", "预加载批处理完成", batch_desc, t_batch_start, "SUCCESS", string.format("%d/%d loaded", completed_count, #chapter_down_tasks))
                if has_result_progress_callback and not has_error then
                    result_progress_callback(true, "任务结束")
                end
            end
        end)
    end

    -- read_ahead task flow limit
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
                    -- 图片章节, 子进程已解析出 URL 列表，打包由主进程异步执行
                    -- （不传 check_running：打包期间章节锁仍持有，isTaskRunning == true 会误中止）
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
                                -- 图片下载并发跟随"同时下载数", 与章节级并发解耦
                                max_workers = max_threads,
                            },
                            on_finish = function(_, result)
                                pending_cbz_count = pending_cbz_count - 1
                                if not (result and result.success) then
                                    pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)
                                    logger.err("Failed to package cbz:", tostring(pending.filePath))
                                    Probe.fail("Chapter", "CBZ打包失败", format_chapter_desc(current_chapter), t_cbz_start, tostring(result and result.output or pending.filePath))
                                    return check_completion(false, string.format("章节[%s]图片打包失败: %s", tostring(current_chapter.title), tostring(result and result.output or pending.filePath)))
                                end
                                current_chapter.cacheFilePath = pending.filePath
                                logger.dbg('Download chapter successfully (cbz):', current_chapter.book_cache_id, current_chapter.chapters_index, pending.filePath)

                                local ok, err = pcall(db_update_success, current_chapter, pending.filePath)
                                if not ok then logger.err('Error saving download to database:', tostring(err)) end

                                pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)

                                completed_count = completed_count + 1
                                local cbz_size = get_file_size(pending.filePath)
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
                            return check_completion(false, string.format("章节[%s]图片打包启动失败: %s", tostring(current_chapter.title), tostring(start_err)))
                        end
                        return
                    end

                    if not (success and H.is_tbl(downloaded_chapter) and downloaded_chapter.cacheFilePath) then
                        pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)
                        logger.err("Failed to download chapter:", tostring(downloaded_chapter))
                        Probe.fail("Chapter", "章节下载失败", format_chapter_desc(current_chapter), current_chapter._t_probe_start, tostring(downloaded_chapter))
                        return check_completion(false, string.format("章节[%s]下载失败: %s", tostring(current_chapter.title), tostring(downloaded_chapter)))
                    end

                    local cache_file_path = downloaded_chapter.cacheFilePath
                    logger.dbg('Download chapter successfully:', current_chapter.book_cache_id, current_chapter.chapters_index, cache_file_path)

                    local ok, err = pcall(db_update_success, current_chapter, cache_file_path)
                    if not ok then logger.err('Error saving download to database:', tostring(err)) end

                    pcall(function() TaskLock.setLock(self.dbManager, current_chapter, false, nil, batch_id) end)

                    completed_count = completed_count + 1
                    local file_size = get_file_size(cache_file_path)
                    local progress_str = string.format("进度 %d/%d", completed_count, #chapter_down_tasks)
                    Probe.done("Chapter", "章节下载完成", format_chapter_desc(current_chapter), current_chapter._t_probe_start, "200 OK", Probe.format_bytes(file_size), progress_str)
                    check_completion(completed_count)
                end,
                {
                    args = {dlChapter},
                    insert_at_head = true,
                    timeout = chapter_timeout,
                    on_start = function()
                        dlChapter._t_probe_start = socket.gettime()
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
        -- If all tasks were skipped but we have a callback waiting, resolve it now
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
        -- local all_chapters = self:getBookChapterPlusCache(book_cache_id)
        local chapter = self:getChapterInfoCache(book_cache_id, i)
        if H.is_tbl(chapter) then
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
        -- If it is manually placed on top
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

    local chapter_sorting_mode = self:chapterSortingMode(bookCacheId)
    local is_desc_sort = true
    if chapter_sorting_mode == 'ASC' then
        is_desc_sort = false
    end
    local chapter_data = self.dbManager:getAllChaptersByUI(bookCacheId, is_desc_sort)
    return chapter_data
end

function M:getBookChapterPlusCache(bookCacheId)
    local chapter_data = self.dbManager:getAllChapters(bookCacheId)
    return chapter_data
end

function M:closeDbManager()
    if self.dbManager and type(self.dbManager.closeDB) == "function" then
        self.dbManager:closeDB()
    end
end

function M:cleanBookCache(book_cache_id, bookinfo)
    if self:isTaskRunning() then
        return wrap_response(nil, '有后台任务进行中，请等待结束或者重启 KOReader')
    end
    local bookShelfId = self:getCurrentBookShelfId()
    self.dbManager:clearBook(bookShelfId, book_cache_id)
    local book_cache_path = Env.getBookCachePath(book_cache_id)
    if book_cache_path and util.pathExists(book_cache_path) then
        ffiUtil.purgeDir(book_cache_path)
        if H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl) then
            local refresh_bookinfo = {
                bookUrl = bookinfo.bookUrl,
                origin = bookinfo.origin,
                name = bookinfo.name or bookinfo.book_name,
                refresh = true,
            }
            self:launchProcess(function()
                self:getChaptersList(refresh_bookinfo)
            end)
        end
        return wrap_response(true)
    else
        return wrap_response(nil, '没有缓存')
    end
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
    Env.getTempDirectory()
    self:saveSettings()
    return wrap_response(true)
end

function M:getDBFileSize()
    if not (self.dbManager and self.dbManager.dbPath) then return 0 end
    local lfs = require("lfs")
    return lfs.attributes(self.dbManager.dbPath, "size") or 0
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
            pcall(function()
                require("docsettings"):open(cacheFilePath):purge()
            end)
            util.removeFile(cacheFilePath)
        end

        self.dbManager:dynamicUpdateChapters(chapter, {
            content = '_NULL',
            cacheFilePath = '_NULL'
        })

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
    self:launchProcess(function()
            return self:saveBookProgress(chapter)
        end, function(_, response)
        if not (H.is_tbl(response) and response.type == 'SUCCESS') then
            -- local message = type(response) == 'table' and response.message or "阅读进度自动上传失败"
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
        --[[
        local prop_updated = {
            filepath = file,
            doc_props = book_props,
            metadata_key_updated = prop_updated,
            metadata_value_old = prop_value_old,
        }
        ]]
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", book_file))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end
end

function M:get_default_cover_cache(book_cache_id)
    return ImageUtil.get_default_cover_cache(book_cache_id)
end

-- 网络层失败（连接/超时），区别于 HTTP 层拒绝（403/405 等，GET 仍可能成功）
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
            if c == url then return end -- 去重
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

function M:_pPreloadReadAheadV2(chapter, count)
    -- 首先检查当前正在阅读的 chapter 本身是否已下载缓存！
    -- 若当前章节尚未下载（如快速翻页跳入占位页），必须将当前章节置于下载任务的第一优先级（self-healing）！
    local tasks = {}
    local cur_cache = self:getCacheChapterFilePath(chapter, true)
    if not (cur_cache and cur_cache.cacheFilePath and util.fileExists(cur_cache.cacheFilePath)) then
        table.insert(tasks, chapter)
    end

    local next_tasks = self:findNextChaptersNotDownLoad(chapter, count) or {}
    for _, t in ipairs(next_tasks) do
        if t.chapters_index ~= chapter.chapters_index then
            table.insert(tasks, t)
        end
    end

    if #tasks == 0 then
        Probe.done("Preload", "全部已缓存跳过", format_chapter_desc(chapter), nil, "CACHE_HIT")
        return
    end

    PlgState:cancelPreload("new_preload_started")
    pcall(function() TaskLock.setLock(self.dbManager, tasks, true) end)
    local t_batch_start = Probe.start("Preload", "启动V2预读批次", format_chapter_desc(chapter), string.format("共%d章 (threads=1, mode=spawn)", #tasks))

    local task = TaskQueueV2.spawn(function(ctx)
        for i, ch in ipairs(tasks) do
            if ctx.is_cancelled() then break end
            local t_ch_start = socket.gettime()
            local ok, ch_file = pcall(function()
                return self:_pDownloadChapter(ch, {
                    auto_pack_cbz = true,
                    check_running = function() return ctx.is_cancelled() end,
                })
            end)
            if ok and ch_file and ch_file.cacheFilePath then
                local size = get_file_size(ch_file.cacheFilePath)
                ctx.emit("chapter_done", {
                    chapter = ch,
                    cacheFilePath = ch_file.cacheFilePath,
                    size = size,
                    t_start = t_ch_start,
                    progress = string.format("进度 %d/%d", i, #tasks)
                })
            else
                ctx.emit("chapter_failed", {
                    chapter = ch,
                    t_start = t_ch_start,
                    err = tostring(ch_file)
                })
            end
        end
    end)

    task._target_idx = tasks[1] and tasks[1].chapters_index
    PlgState._preload_task = task

    local pending_updates = {}
    local book_cache_id = tasks[1] and tasks[1].book_cache_id
    local book_name = tasks[1] and tasks[1].name

    local function flush_pending_updates(reason)
        if next(pending_updates) == nil then return end
        local batch_map = pending_updates
        pending_updates = {}
        pcall(function()
            self:syncChaptersToVirtualBook(book_cache_id, batch_map, book_name)
        end)
    end

    local success_count = 0
    task:on("chapter_done", function(data)
        success_count = success_count + 1
        pcall(function() self.dbManager:updateCacheFilePath(data.chapter, data.cacheFilePath) end)
        pcall(function() TaskLock.setLock(self.dbManager, data.chapter, false) end)
        if data.cacheFilePath and util.fileExists(data.cacheFilePath) and data.chapter.cacheExt ~= "cbz" then
            local raw = util.readFromFile(data.cacheFilePath)
            if raw and raw ~= "" then
                local cur_reading = PlgState:readingChapter()
                -- 1. 当前在读章穿透直连 (Fast-Path)：若读者停留在该章占位页，立即单独注水并原地重载呈现正文
                if cur_reading and cur_reading.book_cache_id == data.chapter.book_cache_id and cur_reading.chapters_index == data.chapter.chapters_index then
                    pcall(function()
                        self:syncChapterToVirtualBook(data.chapter.book_cache_id, data.chapter.chapters_index, raw, data.chapter.name)
                    end)
                    UIManager:nextTick(function()
                        self:refreshDocumentInPlace()
                    end)
                else
                    -- 2. 未来预读章进入微批缓冲池 (Adaptive Micro-Batching)
                    pending_updates[data.chapter.chapters_index] = raw
                    local pending_count = 0
                    for _ in pairs(pending_updates) do pending_count = pending_count + 1 end
                    if pending_count >= 3 then
                        flush_pending_updates("batch_threshold_3")
                    end
                end
            end
        end
        Probe.done("Chapter", "章节入库", format_chapter_desc(data.chapter), data.t_start, "200 OK", Probe.format_bytes(data.size), data.progress)
    end)

    task:on("chapter_failed", function(data)
        pcall(function() TaskLock.setLock(self.dbManager, data.chapter, false) end)
        local cur_reading = PlgState:readingChapter()
        local is_cur = cur_reading and data.chapter and (cur_reading.chapters_index == data.chapter.chapters_index)
        local reason = tostring(data.err or ""):find("源站返回正文内容为空") and "源站正文为空" or "下载失败"
        if is_cur then
            local msg = string.format("《%s》%s，请尝试换源或刷新", tostring(data.chapter.title or "当前章节"), reason)
            Probe.done("Chapter", "提示正文异常", format_chapter_desc(data.chapter), data.t_start, "NOTICE_POPUP", msg)
            self:_show_notice(msg)
        else
            Probe.done("Chapter", "后台失败静默", format_chapter_desc(data.chapter), data.t_start, "SILENT_SKIP", string.format("当前在读: %s", tostring(cur_reading and cur_reading.chapters_index or "-")))
        end
    end)

    local function cleanup()
        PlgState._preload_task = nil
        pcall(function() TaskLock.setLock(self.dbManager, tasks, false) end)
    end

    task:on("finish", function()
        cleanup()
        flush_pending_updates("batch_finish")
        -- 仅当真正有新章节注水入 EPUB 时，才执行后台静默热重载
        if success_count > 0 then
            local cur_reading = PlgState:readingChapter()
            local active_in_batch = false
            if cur_reading then
                for _, t in ipairs(tasks) do
                    if t.chapters_index == cur_reading.chapters_index then
                        active_in_batch = true
                        break
                    end
                end
            end
            if active_in_batch then
                pcall(function() self:refreshDocumentInPlace() end)
            else
                if self._idle_reload_timer then
                    UIManager:unschedule(self._idle_reload_timer)
                    self._idle_reload_timer = nil
                end
                self._idle_reload_timer = function()
                    self._idle_reload_timer = nil
                    pcall(function() self:refreshDocumentInPlace() end)
                end
                UIManager:scheduleIn(4, self._idle_reload_timer)
            end
            Probe.done("Preload", "预读批处理完成", format_chapter_desc(chapter), t_batch_start, "SUCCESS", string.format("%d/%d loaded", success_count, #tasks))
        else
            Probe.fail("Preload", "预读批处理未下载任何章节", format_chapter_desc(chapter), t_batch_start, string.format("0/%d succeeded", #tasks))
        end
    end)
    task:on("error", function(err)
        cleanup()
        flush_pending_updates("batch_error")
        Probe.fail("Preload", "预读批处理失败", format_chapter_desc(chapter), t_batch_start, tostring(err))
    end)
    task:on("cancel", function(reason)
        cleanup()
        flush_pending_updates("batch_cancel")
        Probe.retry("Preload", "预读批处理取消", format_chapter_desc(chapter), t_batch_start, tostring(reason or "cancelled"))
    end)
end

function M:after_reader_chapter_show(chapter)
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    local cache_file_path = chapter.cacheFilePath
    Probe.start("Reader", "阅读展示", format_chapter_desc(chapter), string.format("(book_id: %s, idx: %s, ext: %s)", tostring(book_cache_id), tostring(chapters_index), tostring(chapter.cacheExt or "txt")))

    local status, err = safe_call(function()
        local bookShelfId = self:getCurrentBookShelfId()
        self.dbManager:transaction(function()
            self.dbManager:updateIsRead(chapter, true, true)
            if book_cache_id and H.is_num(chapters_index) then
                self.dbManager:updateReadingProgress(bookShelfId, book_cache_id, chapters_index, chapter.title or chapter.name, 0)
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
        -- document_cover
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

            self._save_progress_timer_cancel = TaskQueue.delay(8, function()
                self:saveBookProgressAsync(chapter)
                self._save_progress_timer_cancel = nil
            end)
        end
        local preDownloadNum = tonumber(settings.preload_chapters) or 5
        if chapter.cacheExt == 'cbz' then
            preDownloadNum = 1
        end
        local cached_ahead = self:getcompleteReadAheadChapters(chapter)
        if preDownloadNum > 0 and cached_ahead < 40 then
            if PlgState._preload_timer_cancel then
                PlgState._preload_timer_cancel()
                PlgState._preload_timer_cancel = nil
                Probe.retry("Preload", "防抖重置 (快速切章)", format_chapter_desc(chapter), nil, "取消前次未触发预读")
            end

            local cur_task = PlgState._preload_task
            if cur_task and cur_task._target_idx == (chapter.chapters_index + 1) and not cur_task:is_done() then
                Probe.done("Preload", "顺读复用在途任务", format_chapter_desc(chapter))
            else
                Probe.start("Preload", "预读排队防抖 (1.5s)", format_chapter_desc(chapter), string.format("(预下载: %d章, 已预存: %d/40)", preDownloadNum, cached_ahead))
                PlgState._preload_timer_cancel = TaskQueue.delay(1.5, function()
                    PlgState._preload_timer_cancel = nil
                    self:_pPreloadReadAheadV2(chapter, preDownloadNum)
                end)
            end
        end
    end
    if cache_file_path == nil then
        local ch_cache = self:getCacheChapterFilePath(chapter, true)
        if ch_cache and ch_cache.cacheFilePath and util.fileExists(ch_cache.cacheFilePath) then
            chapter.cacheFilePath = ch_cache.cacheFilePath
            cache_file_path = ch_cache.cacheFilePath
        end
    end
    chapter.isRead = true
    chapter.isDownLoaded = (cache_file_path ~= nil and util.fileExists(cache_file_path)) or false
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
    local current_conf_name = self.settings_data.data.current_conf_name
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

    -- Use the config name to generate the bookshelf ID for deletion
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

    -- 如果修改的是当前激活项, 需要切换
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
            -- 交由switchWebConfig写入，不然可能导致数据不一致
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
        local LuaSettings = require("luasettings")
        self.settings_data = LuaSettings:open(Env.getUserSettingsPath())
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
        self.settings_data = LuaSettings:open(Env.getUserSettingsPath())
        return wrap_response(true)
    end

    if not ConfigValidator.settings(settings) then
        return wrap_response(nil, '参数校检错误，保存失败')
    end

    self.settings_data.data = settings
    self.settings_data:flush()
    self.settings_data = LuaSettings:open(Env.getUserSettingsPath())
    return wrap_response(true)
end

-- Multi-process execution: the job function call chain should not write to the database
-- No need to use pcall for job, errors are already handled inside the function
-- If a callback is provided, there will be no return value, as the callback will always be invoked
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

function M:getVirtualBookEpubPath(book_cache_id, book_name)
    if not book_cache_id then return nil end
    return Env.getVirtualBookEpubPath(book_cache_id, book_name)
end

function M:ensureVirtualBookEpub(bookinfo, target_chapter_idx, custom_output_path)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        return nil, "invalid bookinfo"
    end
    local book_cache_id = bookinfo.cache_id
    local epub_path = custom_output_path or self:getVirtualBookEpubPath(book_cache_id, bookinfo.name or bookinfo.title)
    if not epub_path then
        return nil, "cannot resolve epub path"
    end

    local SkeletonEpub = require("Legado.Helper.SkeletonEpub")

    -- 如果已存在且版本匹配，则直接返回
    local SKELETON_SCHEMA_VERSION = SkeletonEpub.SKELETON_SCHEMA_VERSION or 3
    if util.fileExists(epub_path) then
        local attr = lfs.attributes(epub_path)
        if attr and attr.size > 1024 then
            local DocSettings = require("docsettings")
            local ds = DocSettings:open(epub_path)
            local ver = ds and ds:readSetting("virtual_book_schema_version")
            if ver and ver >= SKELETON_SCHEMA_VERSION then
                return epub_path
            end
        end
    end

    -- 否则快速构建骨架
    local chapters
    if self.dbManager and type(self.dbManager.getAllChapters) == "function" then
        chapters = self.dbManager:getAllChapters(book_cache_id)
    elseif self.dbManager and type(self.dbManager.getChapters) == "function" then
        chapters = self.dbManager:getChapters(book_cache_id)
    else
        chapters = self:getBookChapterPlusCache(book_cache_id)
    end
    if not H.is_tbl(chapters) or #chapters == 0 then
        local cache_info = self:getCacheInfo(book_cache_id)
        if cache_info and cache_info.chapters then
            chapters = cache_info.chapters
        end
    end
    if not H.is_tbl(chapters) or #chapters == 0 then
        return nil, "no chapters found for book"
    end

    local cover_path = bookinfo.cover_path or self:get_default_cover_cache(book_cache_id)
    if not cover_path then
        local ImageUtil = require("Legado.Helper.ImageUtil")
        cover_path = ImageUtil.get_default_cover_cache(book_cache_id)
    end

    local toc = {}
    local chapters_content = {}
    for i, ch in ipairs(chapters) do
        local ch_idx = ch.chapters_index or (i - 1)
        table.insert(toc, {
            index = ch_idx,
            title = ch.title or ch.name or string.format("第%d章", ch_idx + 1),
        })
        local ch_cache = self:getCacheChapterFilePath(ch, true)
        local cache_file = (ch_cache and ch_cache.cacheFilePath) or ch.cacheFilePath
        if cache_file and util.fileExists(cache_file) then
            local data = util.readFromFile(cache_file)
            if data and data ~= "" and not SkeletonEpub.isPlaceholderHtml(data) then
                chapters_content[ch_idx] = data
            end
        end
    end

    local ok_build, err_build = SkeletonEpub.buildSkeleton({
        bookinfo = {
            title = bookinfo.name or bookinfo.title or "未知书名",
            author = bookinfo.author or "未知作者",
            cache_id = book_cache_id,
        },
        toc = toc,
        chapters_content = chapters_content,
        cover_path = cover_path,
        output_path = epub_path,
    })

    if not ok_build then
        return nil, err_build
    end
    return epub_path
end

function M:syncVirtualBookNewChapters(book_cache_id, book_name)
    if not book_cache_id then return false end
    local epub_path = self:getVirtualBookEpubPath(book_cache_id, book_name)
    if not (epub_path and util.fileExists(epub_path)) then return false end

    local chapters
    if self.dbManager and type(self.dbManager.getAllChapters) == "function" then
        chapters = self.dbManager:getAllChapters(book_cache_id)
    elseif self.dbManager and type(self.dbManager.getChapters) == "function" then
        chapters = self.dbManager:getChapters(book_cache_id)
    else
        chapters = self:getBookChapterPlusCache(book_cache_id)
    end
    if not (H.is_tbl(chapters) and #chapters > 0) then return false end

    local DocSettings = require("docsettings")
    local ds = DocSettings:open(epub_path)
    local epub_ch_count = ds and ds:readSetting("virtual_book_chapters_count")
    if not epub_ch_count then
        epub_ch_count = #chapters
        if ds then ds:saveSetting("virtual_book_chapters_count", epub_ch_count) end
        return false
    end

    if #chapters > epub_ch_count then
        local SkeletonEpub = require("Legado.Helper.SkeletonEpub")
        local new_toc = {}
        local new_contents = {}
        for i = epub_ch_count + 1, #chapters do
            local ch = chapters[i]
            local ch_idx = ch.chapters_index or (i - 1)
            table.insert(new_toc, {
                index = ch_idx,
                title = ch.title or ch.name or string.format("第%d章", ch_idx + 1),
            })
            local ch_cache = self:getCacheChapterFilePath(ch, true)
            local cache_file = (ch_cache and ch_cache.cacheFilePath) or ch.cacheFilePath
            if cache_file and util.fileExists(cache_file) then
                local data = util.readFromFile(cache_file)
                if data and data ~= "" and not SkeletonEpub.isPlaceholderHtml(data) then
                    new_contents[ch_idx] = data
                end
            end
        end

        if #new_toc > 0 then
            local ok, err = SkeletonEpub.appendChapters(epub_path, new_toc, new_contents)
            if ok then
                if ds then ds:saveSetting("virtual_book_chapters_count", #chapters) end
                local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
                if ok_r and ReaderUI and ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance.document.file == epub_path then
                    self:refreshDocumentInPlace(ReaderUI.instance)
                end
                return true
            else
                logger.warn("syncVirtualBookNewChapters append failed: " .. tostring(err))
            end
        end
    end
    return false
end

function M:refreshDocumentInPlace(ui)
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    ui = ui or (ok_r and ReaderUI and ReaderUI.instance)
    if not (ui and ui.document and ui.document._document) then
        return false, "no active credocument"
    end
    local doc = ui.document
    local t_start = Probe.start("DOM", "原地热重载", doc.file)
    -- 记录重载前进度：章节占位→正文的 DOM 变化会使旧 xpointer 失效（crengine 静默解析回第 1 页），
    -- 此时按阅读百分比兜底恢复，避免跳回首页
    local old_pos = doc._document:getCurrentPos()
    local old_height = doc._document:getFullHeight()
    local old_page = doc._document:getCurrentPage()
    local old_percent = (old_pos and old_height and old_height > 0) and (old_pos / old_height) or nil
    -- 章节级锚点：从当前 xpointer 提取 DocFragment 前缀，构造章节头锚点。
    -- 占位页与正文页的章节根节点 <div class="legado-ch"><h2>…</h2> 结构一致，
    -- 章节被更新（占位→正文）后旧 xpointer 失效，但该锚点仍有效，可精确回到章节头。
    local cur_chapter_xp
    do
        local cur_xp = doc._document:getXPointer()
        local frag_prefix = cur_xp and cur_xp:match("^(/body/DocFragment%[%d+%])")
        if frag_prefix then
            cur_chapter_xp = frag_prefix .. "/body/div/h2"
        end
    end
    local ok, err = pcall(function()
        -- 临时静音 crengine 进度条回调，防止顶部弹出进度条并引起卡顿
        if doc.setCallback then
            doc:setCallback(nil)
        end
        doc._loaded = false
        if doc.resetCallCache then
            doc:resetCallCache()
        elseif doc.setupCallCache then
            doc:setupCallCache()
        end
        local ok_load = doc._document:loadDocument(doc.file, false)
        if ok_load then
            doc._loaded = true
            doc._document:renderDocument()
            doc.info.doc_height = doc._document:getFullHeight()

            -- 1. 驱动 ReaderRolling 锁定当前视口并通知整页重绘
            if ui.rolling and ui.rolling.onUpdatePos then
                ui.rolling:onUpdatePos(true)
            elseif ui.rolling and ui.rolling.onRedrawCurrentView then
                ui.rolling:onRedrawCurrentView()
            elseif ui.paging and ui.paging.onRedrawCurrentPage then
                ui.paging:onRedrawCurrentPage()
            else
                local Event = require("ui/event")
                ui:handleEvent(Event:new("DocumentRerendered"))
                local UIManager = require("ui/uimanager")
                if ui.view and ui.view.dialog then
                    UIManager:setDirty(ui.view.dialog, "partial")
                end
            end

            -- 2. xpointer 失效兜底：重载后仍落在第 1 页而原本不在（占位→正文 DOM 变化导致旧 xpointer 解析回第 1 页），
            --    按阅读百分比恢复，避免跳回首页
            if old_percent and old_page and old_page > 1 then
                local new_page = doc._document:getCurrentPage()
                if new_page and new_page <= 1 then
                    logger.warn("refreshDocumentInPlace: xpointer lost after reload (page %s -> 1), restoring by percent %.2f",
                        tostring(old_page), old_percent * 100)
                    pcall(function()
                        -- 章节锚点优先；锚点不存在或定位后仍在第 1 页（锚点无效）时降级百分比兜底
                        local restored = false
                        if cur_chapter_xp then
                            local ok_a = pcall(function()
                                -- onGotoXPointer 内部会同步 self.xpointer
                                if ui.rolling and ui.rolling.onGotoXPointer then
                                    ui.rolling:onGotoXPointer(cur_chapter_xp)
                                elseif doc._document.gotoXPointer then
                                    doc._document:gotoXPointer(cur_chapter_xp)
                                end
                            end)
                            if ok_a then
                                local p_after = doc._document:getCurrentPage()
                                restored = not (p_after and p_after <= 1)
                            end
                        end
                        if not restored then
                            -- 百分比兜底（onGotoPercent 公开入口，内部同步 self.xpointer）
                            if ui.rolling and ui.rolling.onGotoPercent then
                                ui.rolling:onGotoPercent(old_percent * 100)
                            elseif doc._document.gotoPos then
                                -- 非 rolling（paging）文档不可达（虚拟书必为 EPUB），防御性兜底
                                local new_height = doc._document:getFullHeight()
                                if new_height and new_height > 0 then
                                    doc._document:gotoPos(math.floor(old_percent * new_height))
                                end
                            end
                        end
                        -- 触发重绘（onUpdatePos 因 hash 未变不会重定位，仅重绘，幂等）
                        if ui.rolling and ui.rolling.onUpdatePos then
                            ui.rolling:onUpdatePos()
                        elseif ui.rolling and ui.rolling.onRedrawCurrentView then
                            ui.rolling:onRedrawCurrentView()
                        end
                    end)
                end
            end

            -- 3. 同步更新底部状态栏（刷新总页数与章节进度）
            if ui.view and ui.view.footer and ui.view.footer.onUpdateFooter then
                pcall(function()
                    ui.view.footer:onUpdateFooter(ui.view.footer_visible)
                end)
            end

            Probe.done("DOM", "原地重载完成", string.format("页数: %s, 高度: %s", tostring(doc:getPageCount()), tostring(doc.info.doc_height)), t_start)
        else
            Probe.fail("DOM", "原地重载失败", doc.file, t_start, "loadDocument failed")
        end
    end)
    return ok, err
end

function M:syncChaptersToVirtualBook(book_cache_id, chapters_map, book_name)
    if not book_cache_id or not chapters_map or next(chapters_map) == nil then return false end
    local epub_path = self:getVirtualBookEpubPath(book_cache_id, book_name)
    if not epub_path or not util.fileExists(epub_path) then return false end

    local count = 0
    for _ in pairs(chapters_map) do count = count + 1 end

    local t_inject_start = Probe.start("Inject", "批量注水", string.format("共%d章 (book_id: %s)", count, tostring(book_cache_id)))
    local SkeletonEpub = require("Legado.Helper.SkeletonEpub")
    local ok, err = SkeletonEpub.updateChapters(epub_path, chapters_map)
    if ok then
        Probe.done("Inject", "批量注水完成", string.format("共%d章 (book_id: %s)", count, tostring(book_cache_id)), t_inject_start, "200 OK")
    else
        Probe.fail("Inject", "批量注水失败", string.format("共%d章 (book_id: %s)", count, tostring(book_cache_id)), t_inject_start, tostring(err))
    end
    return ok, err
end

function M:syncChapterToVirtualBook(book_cache_id, chapter_idx, raw_content, book_name)
    return self:syncChaptersToVirtualBook(book_cache_id, { [chapter_idx] = raw_content }, book_name)
end

--- 针对支持 PR #2477 (LVContainerTransform / loadEpubWithEntryTransform) 的前向兼容钩子
function M:createEpubTransformHook(book_cache_id)
    local SkeletonEpub = require("Legado.Helper.SkeletonEpub")
    return {
        transformEntry = function(self_t, path)
            local ch_idx = SkeletonEpub.parseChapterIndexFromEntryPath(path)
            if ch_idx and self.dbManager then
                local ch = self.dbManager:findChapterByIndex(book_cache_id, ch_idx)
                local ch_cache = ch and self:getCacheChapterFilePath(ch, true)
                local cache_file = (ch_cache and ch_cache.cacheFilePath) or (ch and ch.cacheFilePath)
                if cache_file and util.fileExists(cache_file) then
                    local raw = util.readFromFile(cache_file)
                    if raw and raw ~= "" and not SkeletonEpub.isPlaceholderHtml(raw) then
                        return SkeletonEpub.formatChapterXhtml(ch_idx, ch.title or ch.name, raw)
                    end
                end
            end
            return nil
        end
    }
end

function M:enforceRateLimit(last_time, limit_ms)
    if last_time and time.since(last_time) < time.ms(limit_ms) then
        return true
    end
    return false
end
function M:onExitClean()
    dbg.v('Backend call onExitClean')
    self._is_exiting = true
    PlgState:cancelPreload("backend_exit_clean")
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
