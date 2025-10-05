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
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

-- 太旧版本缺少这个函数
if not dbg.log then
    dbg.log = logger.dbg
end

local M = {
    dbManager = {},
    settings_data = nil,
    task_pid_file = nil,
    apiClient = nil,
    httpReq = nil
}

local function wrap_response(data, err_message)
    local response = { 
        type = data ~= nil and 'SUCCESS' or 'ERROR' 
    }
    if data ~= nil then
        response.body = data
    else
        response.message = H.is_str(err_message) and err_message or "Unknown error"
    end
    return response
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

local function convertToGrayscale(image_data)
    local Png = require("Legado/Png")
    return Png.processImage(Png.toGrayscale, image_data, 1)
end

local function pGetUrlContent(options)
    if not M.httpReq then 
        M.httpReq = require("Legado.HttpRequest")
    end
    return M.httpReq(options, true)
end

local function pDownload_CreateCBZ(filePath, img_sources)

    dbg.v('CreateCBZ strat:')

    if not filePath or not H.is_tbl(img_sources) then
        error("Cbz param error:")
    end

    local is_convertToGrayscale = false

    local cbz_path_tmp = filePath .. '.downloading'

    if util.fileExists(cbz_path_tmp) then
        if M:getBackgroundTaskInfo() ~= false then
            error("Other threads downloading, cancelled")
        else
            util.removeFile(cbz_path_tmp)
        end
    end

    local cbz
    local cbz_lib
    local no_compression
    local mtime

    -- 20250525 PR # 2090: Archive.Writer replaces ZipWriter
    local ok , ZipWriter = pcall(require, "ffi/zipwriter")
    if ok and ZipWriter then
        cbz_lib = "zipwriter"
        no_compression = true

        cbz = ZipWriter:new{}
        if not cbz:open(cbz_path_tmp) then
            error('CreateCBZ cbz:open err')
        end
        cbz:add("mimetype", "application/vnd.comicbook+zip", true)
    else
        cbz_lib = "archiver"
        mtime = os.time()

        local Archiver = require("ffi/archiver").Writer
        cbz = Archiver:new{}
        if not cbz:open(cbz_path_tmp, "epub") then
            error(string.format("CreateCBZ cbz:open err: %s", tostring(cbz.err)))
        end

        cbz:setZipCompression("store")
        cbz:addFileFromMemory("mimetype", "application/vnd.comicbook+zip", mtime)
        cbz:setZipCompression("deflate")
    end

    for i, img_src in ipairs(img_sources) do

        dbg.v('Download_Image start', i, img_src)
        local status, err = pGetUrlContent({
                url = img_src,
                timeout = 15,
                maxtime = 60,
                is_pic = true,
        })

        if status and H.is_tbl(err) and err['data'] then

            local imgdata = err['data']
            local img_extension = err['ext']
            if not img_extension or img_extension == "" then
                img_extension = get_url_extension(img_src)
            end
            -- qread may fail to get ext
            if not img_extension or img_extension == "" then
                img_extension = "png"
            end
            local img_name = string.format("%d.%s", i, img_extension)
            if is_convertToGrayscale == true and img_extension == 'png' then
                local success, imgdata_new = convertToGrayscale(imgdata)
                if success ~= true then

                    goto continue
                end
                imgdata = imgdata_new.data
            end

            if cbz_lib == "zipwriter" then
                cbz:add(img_name, imgdata, no_compression)
            else
                cbz:addFileFromMemory(img_name, imgdata, mtime)
            end

        else
            dbg.v('Download_Image err', tostring(err))
        end
        ::continue::
    end
    if cbz and cbz.close then
        cbz:close()
    end
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
    on_success = H.is_func(on_success) and on_success or function() end
    on_error   = H.is_func(on_error)   and on_error   or function() end
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

function M:_isQingread() return self.settings_data.data.server_type == 3 end
function M:_isReader3() return self.settings_data.data.server_type == 2 end
function M:_isLegadoApp() return self.settings_data.data.server_type == 1 end

function M:loadApiProvider()
    local client
    if self:_isLegadoApp() then
        client = require("Legado/web_android_app")
    elseif self:_isReader3() then
        client = require("Legado/web_reader3")
    elseif self:_isQingread() then
        client = require("Legado/web_qread")
    end
    self.apiClient = client:new{
        settings = self:getSettings()
    }
end

function M:initialize()
    local ok, err_msg = pcall(function()
        local fn, file_path = H.require("Legado/_r3l_once")
        return fn and fn() == true and util.removeFile(file_path)
    end)
    if not ok then
        logger.err("run_once_task loading loading failed", err_msg)
    end

    self.task_pid_file = H.getTempDirectory() .. '/task.pid.lua'
    self.settings_data = self:getLuaConfig(H.getUserSettingsPath())
    if self.settings_data and not self.settings_data.data['server_address'] then
        self.settings_data.data = {
            chapter_sorting_mode = "chapter_descending",
            server_address = 'http://127.0.0.1:1122',
            server_address_md5 = 'f528764d624db129b32c21fbca0cb8d6',
            server_type = 1,
            reader3_un = '',
            reader3_pwd = '',
            stream_image_view = nil,
            disable_browser = nil,
            sync_reading = nil,
            open_at_last_read = nil,
        }
        self.settings_data:flush()
    end

    self:loadApiProvider()
    local BookInfoDB = require("Legado/BookInfoDB")
    self.dbManager = BookInfoDB:new({
        dbPath = H.getTempDirectory() .. "/bookinfo.db"
    })
end

function M:installPatches()
    local patches_file_path = H.joinPath(H.getUserPatchesDirectory(), '2-legado_plugin_func.lua')
    local source_patches = H.joinPath(H.getPluginDirectory(), 'patches/2-legado_plugin_func.lua')
    local disabled_patches = patches_file_path .. '.disabled'
    for _, file in ipairs({patches_file_path, disabled_patches}) do
        if util.fileExists(file) then
            util.removeFile(file)
        end
    end
    H.copyFileFromTo(source_patches, patches_file_path)
    UIManager:restartKOReader()
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
            local setting_data = self:getSettings()
            setting_data.last_check_ota = os.time()
            self:saveSettings(setting_data)
        end)
    end
end

function M:_show_notice(msg, timeout)
    local Notification = require("ui/widget/notification")
    Notification:notify(msg or '', Notification.SOURCE_ALWAYS_SHOW)
end
function M:getLuaConfig(path)
    return LuaSettings:open(path)
end
function M:backgroundCacheConfig()
    return self:getLuaConfig(H.getTempDirectory() .. '/cache.lua')
end

function M:isBookTypeComic(book_cache_id)
    if not H.is_str(book_cache_id) then return false end
    local chapter = self:getChapterInfoCache(book_cache_id, 1)
    return H.is_tbl(chapter) and chapter.cacheExt == "cbz" or false
end

function M:refreshLibraryCache(last_refresh_time)
    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
    end
    local ret, err_msg = self.apiClient:getBookshelf(function(response)
        local bookShelfId = self:getServerPathCode()
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
function M:addBookToLibrary(bookinfo)
    return wrap_response(self.apiClient:saveBook(bookinfo, function(response)
        -- isReader3Only = true
        if H.is_tbl(response) and H.is_tbl(response.data) and H.is_str(response.data.name) and H.is_str(response.data.bookUrl) and H.is_str(response.data.origin) then
            local bookShelfId = self:getServerPathCode()
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
    if last_refresh_time and os.time() - last_refresh_time < 2 then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(nil, '处理中')
    end
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl) and H.is_str(bookinfo.cache_id)) then
        return wrap_response(nil, "获取目录参数错误")
    end
    local book_cache_id = bookinfo.cache_id
    local bookUrl = bookinfo.bookUrl

    return wrap_response(self.apiClient:getChapterList(bookinfo, function(response)
        local status, err = H.pcall(function()
            return self.dbManager:upsertChapters(book_cache_id, response.data)
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
    return self.apiClient:getProxyImageUrl(bookUrl, img_src)
end
function M:getBookSourcesList(callback)
    return wrap_response(self.apiClient:getBookSourcesList(callback))
end
--- return list lastIndex
function M:getAvailableBookSource(options, callback)
    return wrap_response(self.apiClient:getAvailableBookSource(options, callback))
end
function M:autoChangeBookSource(bookinfo, callback)
    return wrap_response(self.apiClient:autoChangeBookSource(bookinfo, callback))
end
function M:searchBookSingle(options, callback)
    return wrap_response(self.apiClient:searchBookSingle(options, callback))
end
--- return list lastIndex
function M:searchBookMulti(options, callback)
    return wrap_response(self.apiClient:searchBookMulti(options, callback))
end
function M:changeBookSource(newBookSource)
    return wrap_response(self.apiClient:changeBookSource(newBookSource, function(response)
        if H.is_tbl(response) and H.is_tbl(response.data) and H.is_str(response.data.name) and H.is_str(response.data.bookUrl) and H.is_str(response.data.origin) then
            local bookShelfId = self:getServerPathCode()
            local response = {response.data}
            local status, err = pcall(function()
                return self.dbManager:upsertBooks(bookShelfId, response, true)
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
                -- [修复] 修正了反向遍历成功时的指针更新逻辑
                -- 它应该回退到当前字符之前的位置，以便下一次循环可以正确地处理前一个字节
                pos = reverse and (pos - bytes + 1) or (pos + bytes - 1)
                return ret_pos, tonumber(codepoint[0]), char
            elseif bytes < 0 then
                -- [修复] 解码失败时（bytes < 0），不做任何操作
                -- 循环会自动将指针移动到前一个/后一个字节继续尝试，避免跳字节
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

    -- cache already exists
    if ext ~= "" and resources_filepath and util.fileExists(resources_filepath) then
        return resources_relpath
    end

    local status, err = pGetUrlContent({
                url = processed_src,
                timeout = 15,
                maxtime = 60
        })
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
                line = M:utf8_trim(line)
                if line == "" then
                    -- 抛弃仅重复标题行
                    goto continue
                end
            end
            
            local rep_text = line:match(util.UTF8_CHAR_PATTERN)
            
            -- [修复] 增加对 rep_text 的有效性检查
            if rep_text and rep_text ~= "" then
                -- 只有在成功获取到首字符时，才进行替换和格式化
                line = plain_text_replace(line, rep_text, "", 1)
                el_tags = string.format('<p style="text-indent: 0em;"><span class="duokan-dropcaps-two">%s</span>%s</p>',
                    rep_text, line)
                dropcaps = true
            else
                -- 如果没有有效的首字符（例如，行是空的或只包含不可见字符），则作为普通段落处理
                el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
            end
        else
            el_tags = (line ~= "") and string.format('<p>%s</p>', line) or "<br>"
        end
        table.insert(lines, el_tags)
        ::continue::
    end

    if #lines > 0 then
        content = table.concat(lines)
    end

    local epub = require("Legado/EpubHelper")
    epub.addCssRes(book_cache_id)
    return epub.addchapterT(title, content)
end

local htmlparser
function M:_AnalyzingChapters(chapter, content, filePath)

    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    local chapter_title = chapter.title or ''
    local down_chapters_index = chapter.chapters_index

    content = H.is_str(content) and content or tostring(content)
    filePath = filePath or H.getChapterCacheFilePath(book_cache_id, chapters_index, chapter.name)
 
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
                local status, err = pGetUrlContent({
                        url = res_url,
                        timeout = 15,
                        maxtime = 60,
                        is_pic = true,
                })
                if not status then
                    error('请求错误，' .. tostring(err))
                end
                if not (H.is_tbl(err) and err["data"]) then
                    error('下载失败，数据为空')
                end

                local ext = get_url_extension(res_url)
                if (not ext or ext == "") and not not err.ext then
                    ext = err['ext']
                end
                -- qread may fail to get ext
                if not ext or ext == "" then ext = "png" end
                filePath = string.format("%s.%s", filePath, ext)
                return chapter_writeToFile(chapter, filePath, err['data'])
            else
                filePath = filePath .. '.cbz'
                local status, err = H.pcall(pDownload_CreateCBZ, filePath, img_sources)

                if not status then
                    error('CreateCBZ err: ' .. tostring(err))
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
        local status, err = pGetUrlContent({
                        url = html_url,
                        timeout = 15,
                        maxtime = 60
                })
        if not status then
            error('请求错误，' .. tostring(err))
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

function M:_pDownloadChapter(chapter, message_dialog, is_recursive)

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
        error('_pDownloadChapter input parameters err' .. tostring(bookUrl) .. tostring(book_cache_id))
    end

    local cache_chapter = self:getCacheChapterFilePath(chapter, true)
    if cache_chapter and cache_chapter.cacheFilePath then
        return cache_chapter
    end

    local response = self:pGetChapterContent(chapter)

    if is_recursive ~= true and H.is_tbl(response) and response.type == 'ERROR' and 
            self.apiClient:isNeedLogin(response.message) == true then
        self.apiClient:reader3Token(nil)
        return self:_pDownloadChapter(chapter, message_dialog, true)
    end

    if not H.is_tbl(response) or response.type ~= 'SUCCESS' then
        error((response and response.message) or '章节下载失败')
    end

    return self:_AnalyzingChapters(chapter, response.body)
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
    local status, err = pGetUrlContent({
                    url = img_src,
                    timeout = timeout or 15,
                    maxtime = 60,
                    is_pic = true,
                })
    if status and H.is_tbl(err) and err['data'] then
        return wrap_response(err)
    else
        return wrap_response(nil, tostring(err))
    end
end

function M:getChapterImgList(chapter)
    local chapters_index = chapter.chapters_index
    local bookUrl = chapter.bookUrl
    local origin = chapter.origin
    local down_chapters_index = chapters_index

    return self:HandleResponse(self:pGetChapterContent({
        bookUrl = bookUrl,
        chapters_index = down_chapters_index,
        origin = origin,
    }), function(data)
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

function M:preLoadingChapters(chapter, download_chapter_count, result_progress_callback)

    local has_result_progress_callback = H.is_func(result_progress_callback)
    local return_error_handle = function(error_msg)
        error_msg = error_msg or "未知错误"
        logger.dbg("Legado.preLoadingChapters - ", error_msg)
        if has_result_progress_callback then
            result_progress_callback(false, error_msg)
        else
            return false, error_msg
        end
    end

    if not H.is_tbl(chapter) then
        return return_error_handle('Incorrect call parameters')
    end

    if self:getBackgroundTaskInfo() ~= false then
        return return_error_handle("Cannot create new tasks.")
    end

    local chapter_down_tasks = {}

    -- Support passing multiple chapters directly
    if H.is_tbl(chapter[1]) and chapter[1].chapters_index ~= nil and chapter[1].book_cache_id ~= nil then
        chapter_down_tasks = chapter
    else
        local down_count = tonumber(download_chapter_count)
        down_count = (down_count and down_count > 1) and down_count or 1
        chapter_down_tasks = self:findNextChaptersNotDownLoad(chapter, down_count)
    end

    if not H.is_tbl(chapter_down_tasks) or #chapter_down_tasks < 1 then
        -- 所有章节已缓存，视为成功
        logger.dbg("Legado.preLoadingChapters - All chapters already cached")
        if has_result_progress_callback then
            result_progress_callback(true, "所有章节已缓存")
        end
        return true, "所有章节已缓存"
    end

    -- 获取线程数设置
    local settings = self:getSettings()
    local max_threads = tonumber(settings.download_threads) or 1
    max_threads = math.max(1, math.min(16, max_threads)) -- 限制在1-16之间

    -- 判断书籍类型，设置超时时间（漫画120秒，普通书籍20秒）
    local book_cache_id = chapter_down_tasks[1] and chapter_down_tasks[1].book_cache_id
    local is_comic = book_cache_id and self:isBookTypeComic(book_cache_id) or false
    local chapter_timeout = is_comic and 120 or 20

    -- task mark
    local task_pid_info = self:getLuaConfig(self.task_pid_file)
    local write_to_pid_file = function(chapter_info)
        task_pid_info:saveSetting("chapter", {
            chapters_index = chapter_info.chapters_index,
            book_cache_id = chapter_info.book_cache_id,
            stime = os.time(),
        }):flush()
    end

    local chapter_down_tasks_count = #chapter_down_tasks
    local completed_count = 0
    local running_count = 0
    local current_index = 0
    local has_error = false
    local error_msg = nil
    local timeout_timers = {}  -- 存储超时定时器

    local end_task_clean = function(is_complete, exit_msg)
        -- 清理所有超时定时器
        for _, timer in ipairs(timeout_timers) do
            UIManager:unschedule(timer)
        end
        timeout_timers = {}

        local status, err = pcall(function()
            task_pid_info:purge()
            if util.fileExists(self.task_pid_file) then
                util.removeFile(self.task_pid_file)
            end
        end)

        is_complete = is_complete and true or false
        if has_result_progress_callback then
            result_progress_callback(is_complete, exit_msg)
        end
    end

    local process_task
    local start_next_task

    -- 启动下一个任务
    start_next_task = function()
        -- 如果已经出错，不再启动新任务
        if has_error then
            return
        end

        -- 启动所有可以启动的任务（直到达到最大并发数）
        while running_count < max_threads and current_index < chapter_down_tasks_count do
            current_index = current_index + 1
            local dlChapter = chapter_down_tasks[current_index]

            if not (H.is_tbl(dlChapter) and dlChapter.chapters_index ~= nil and dlChapter.book_cache_id ~= nil) then
                logger.err("error: next chapter data source")
                has_error = true
                error_msg = "task 参数错误：" .. (current_index or "")
                break
            end

            -- 标记任务启动
            running_count = running_count + 1
            dlChapter.is_pre_loading = true
            write_to_pid_file(dlChapter)

            logger.dbg('Threaded tasks running: chapter_title:', dlChapter.title or nil, 'thread:', current_index, '/', chapter_down_tasks_count)

            -- 为每个任务设置超时定时器（漫画120秒，普通书籍20秒）
            local task_index = current_index
            local task_completed = false
            local timeout_timer = UIManager:scheduleIn(chapter_timeout, function()
                if not task_completed then
                    logger.err("Chapter download timeout:", dlChapter.title or task_index)
                    running_count = running_count - 1
                    has_error = true
                    error_msg = string.format("章节下载超时: %s", dlChapter.title or ("第" .. task_index .. "章"))

                    -- 检查是否所有任务完成
                    if current_index >= chapter_down_tasks_count and running_count == 0 then
                        return end_task_clean(false, error_msg)
                    end
                end
            end)
            table.insert(timeout_timers, timeout_timer)

            -- 启动异步下载任务
            self:launchProcess(function()
                return self:_pDownloadChapter(dlChapter)
            end, function(status, downloaded_chapter, r2)
                -- 标记任务完成，取消超时
                task_completed = true

                -- 任务完成回调
                running_count = running_count - 1

                if not (status and H.is_tbl(downloaded_chapter) and downloaded_chapter.cacheFilePath) then
                    logger.err("Failed to download chapter or job execution error: ", downloaded_chapter, r2)
                    -- 标记错误但继续处理其他任务
                    if not has_error then
                        has_error = true
                        error_msg = "下载错误：" .. tostring(downloaded_chapter)
                    end
                else
                    local cache_file_path = downloaded_chapter.cacheFilePath
                    local chapters_index = tonumber(dlChapter.chapters_index)
                    local book_cache_id = dlChapter.book_cache_id

                    logger.dbg('Download chapter successfully:', book_cache_id, chapters_index, cache_file_path)

                    local ok, err = pcall(function()
                        return self.dbManager:updateCacheFilePath(dlChapter, cache_file_path)
                    end)
                    if not ok then
                        logger.err('Error saving download to database, updateCacheFilePath:', tostring(err))
                    end

                    completed_count = completed_count + 1

                    if has_result_progress_callback then
                        ok, err = pcall(result_progress_callback, completed_count)
                        if not ok then
                            logger.err("result_progress_callback run error")
                        end
                    end
                end

                logger.dbg("task info - completed/running/total:", completed_count, running_count, chapter_down_tasks_count)

                -- 检查是否所有任务都完成
                if completed_count >= chapter_down_tasks_count then
                    logger.dbg("Legado.preLoadingChapters - All tasks completed")
                    return end_task_clean(true, "任务结束")
                elseif current_index >= chapter_down_tasks_count and running_count == 0 then
                    -- 所有任务都已启动且全部完成（可能有失败）
                    logger.dbg("Legado.preLoadingChapters - All tasks finished (some may have failed)")
                    if has_error then
                        return end_task_clean(false, error_msg or "部分章节下载失败")
                    else
                        return end_task_clean(true, "任务结束")
                    end
                elseif has_error and running_count == 0 then
                    -- 发生错误且没有正在运行的任务，立即结束
                    logger.dbg("Legado.preLoadingChapters - Error occurred, stopping")
                    return end_task_clean(false, error_msg or "下载出错")
                elseif not has_error then
                    -- 没有错误才继续启动下一个任务
                    UIManager:scheduleIn(0.1, function()
                        start_next_task()
                    end)
                else
                    -- 有错误但还有任务在运行，等待它们完成
                    logger.dbg("Error occurred, waiting for running tasks to complete. Running:", running_count)
                end
            end)
        end

        -- 如果所有任务都已启动但还有任务在运行中，等待它们完成
        if current_index >= chapter_down_tasks_count and running_count > 0 then
            logger.dbg("All tasks started, waiting for completion. Running:", running_count)
        end
    end

    logger.dbg("Legado.preLoadingChapters - START with", max_threads, "threads,",
               "type:", is_comic and "comic" or "text",
               "timeout:", chapter_timeout .. "s")
    start_next_task()
    return true
end

-- 缓存全书功能：统计并返回未缓存章节信息
function M:analyzeCacheStatus(book_cache_id, chapter_count)
    local cached_count = 0
    local uncached_chapters = {}

    -- 遍历所有章节，统计和收集未缓存章节
    for i = 0, chapter_count - 1 do
        local chapter = self:getChapterInfoCache(book_cache_id, i)
        if chapter then
            local is_cached = false

            -- 快速检查：如果数据库有缓存路径且文件存在
            if chapter.cacheFilePath and util.fileExists(chapter.cacheFilePath) then
                is_cached = true
                cached_count = cached_count + 1
            else
                -- 完整检查并收集未缓存章节
                local cache_chapter = self:getCacheChapterFilePath(chapter, true)
                if cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath) then
                    is_cached = true
                    cached_count = cached_count + 1
                else
                    -- 未缓存，添加到列表
                    chapter.call_event = 'next'
                    table.insert(uncached_chapters, chapter)
                end
            end
        end
    end

    return {
        total_count = chapter_count,
        cached_count = cached_count,
        uncached_count = #uncached_chapters,
        uncached_chapters = uncached_chapters
    }
end

-- 缓存全书功能
function M:cacheAllChapters(bookinfo, completion_callback)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        MessageBox:error("书籍信息错误")
        return
    end

    -- 获取章节总数
    local chapter_count = self:getChapterCount(bookinfo.cache_id)
    if not chapter_count or chapter_count == 0 then
        MessageBox:error("该书章节列表为空，请手动刷新目录后再缓存")
        return
    end

    -- 显示统计进度
    local loading_msg = MessageBox:showloadingMessage("正在统计章节...")

    UIManager:nextTick(function()
        -- 使用Backend的统计功能
        local cache_status = self:analyzeCacheStatus(bookinfo.cache_id, chapter_count)

        if loading_msg then
            if loading_msg.close then
                loading_msg:close()
            else
                UIManager:close(loading_msg)
            end
        end

        if cache_status.uncached_count == 0 then
            MessageBox:notice(string.format("全书已缓存完毕！\n总章节：%d", chapter_count))
            -- 即使已全部缓存，也调用完成回调
            if H.is_func(completion_callback) then
                completion_callback(true)
            end
            return
        end

        -- 确认是否开始缓存
        MessageBox:confirm(string.format(
            "书名：<<%s>>\n作者：%s\n\n总章节：%d\n已缓存：%d\n待缓存：%d\n\n是否开始缓存全书？",
            bookinfo.name or "未命名",
            bookinfo.author or "未知作者",
            chapter_count,
            cache_status.cached_count,
            cache_status.uncached_count
        ), function(result)
            if not result then
                -- 用户取消，调用完成回调
                if H.is_func(completion_callback) then
                    completion_callback(false)
                end
                return
            end

            -- 直接开始缓存，使用已统计的未缓存章节列表，传递completion_callback
            self:startCacheChapters(bookinfo, cache_status.uncached_chapters, chapter_count, nil, completion_callback)
        end, {
            ok_text = "开始缓存",
            cancel_text = "取消"
        })
    end)
end

-- 开始缓存章节（统一所有下载功能）
function M:startCacheChapters(bookinfo, uncached_chapters, chapter_count, retry_count, completion_callback)
    retry_count = retry_count or 0
    local uncached_count = #uncached_chapters

    -- 显示缓存进度
    local title_text = string.format("%s - 正在缓存 %d/%d 章节", bookinfo.name, uncached_count, chapter_count)
    if retry_count > 0 then
        title_text = title_text .. string.format(" (重试 %d)", retry_count)
    end

    local cache_msg = MessageBox:progressBar("缓存进度", {
        title = title_text,
        max = uncached_count
    })

    if not cache_msg then
        cache_msg = MessageBox:showloadingMessage("正在缓存章节...")
    end

    local cache_complete = false

    -- 缓存进度回调
    local cache_progress_callback = function(progress, err_msg)
        if progress == false or progress == true then
            if cache_msg and cache_msg.close then
                cache_msg:close()
            end
            cache_complete = true

            if progress == true then
                -- 缓存完成，检查完整性
                UIManager:nextTick(function()
                    self:checkCacheIntegrity(bookinfo, chapter_count, completion_callback)
                end)
            elseif err_msg then
                -- 首次出错自动重试一次
                if retry_count == 0 then
                    UIManager:scheduleIn(1, function()
                        self:startCacheChapters(bookinfo, uncached_chapters, chapter_count, 1, completion_callback)
                    end)
                    return
                end

                -- 重试后仍失败，显示重试对话框
                local error_title = "⚠ 缓存出错"
                local is_timeout = err_msg:find("超时")
                local is_toc_empty = err_msg:find("目录为空") or err_msg:find("TOC") or err_msg:find("章节列表")

                if is_timeout then
                    error_title = "⚠ 下载超时"
                elseif is_toc_empty then
                    error_title = "⚠ 目录为空"
                end

                UIManager:nextTick(function()
                    -- 所有错误统一提供重试选项
                    MessageBox:confirm(
                        string.format("%s\n\n%s\n\n已自动重试1次仍失败，是否继续重试？", error_title, err_msg),
                        function(result)
                            if result then
                                self:cacheAllChapters(bookinfo)
                            else
                                -- 用户取消重试，调用完成回调
                                if H.is_func(completion_callback) then
                                    completion_callback(false)
                                end
                            end
                        end,
                        {
                            ok_text = "重试",
                            cancel_text = "取消",
                            other_buttons = {{
                                {
                                    text = "查看已缓存",
                                    callback = function()
                                        self:checkCacheIntegrity(bookinfo, chapter_count, completion_callback)
                                    end
                                }
                            }}
                        }
                    )
                end)
            end
        elseif H.is_num(progress) then
            if cache_msg and cache_msg.reportProgress then
                cache_msg:reportProgress(progress)
            end
        end
    end

    -- 开始缓存
    self:preLoadingChapters(uncached_chapters, nil, cache_progress_callback)
end

-- 检查缓存完整性
function M:checkCacheIntegrity(bookinfo, chapter_count, completion_callback)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        return
    end

    local checking_msg = MessageBox:showloadingMessage("正在检查缓存完整性...")

    UIManager:nextTick(function()
        local book_cache_id = bookinfo.cache_id
        local missing_chapters = {}
        local cached_count = 0

        -- 检查每个章节
        for i = 0, chapter_count - 1 do
            local chapter = self:getChapterInfoCache(book_cache_id, i)
            if chapter then
                local cache_chapter = self:getCacheChapterFilePath(chapter, true)
                local is_cached = cache_chapter and cache_chapter.cacheFilePath and util.fileExists(cache_chapter.cacheFilePath)

                if is_cached then
                    cached_count = cached_count + 1
                else
                    table.insert(missing_chapters, {
                        index = i,
                        title = chapter.title or string.format("第%d章", i + 1)
                    })
                end
            end
        end

        if checking_msg then
            if checking_msg.close then
                checking_msg:close()
            else
                UIManager:close(checking_msg)
            end
        end

        local missing_count = #missing_chapters

        if missing_count == 0 then
            -- 缓存完整，使用MessageBox:confirm提示
            UIManager:nextTick(function()
                MessageBox:confirm(
                    string.format("✓ 缓存完成\n\n书名：%s\n总章节：%d\n已缓存：%d",
                        bookinfo.name or "未命名",
                        chapter_count,
                        cached_count),
                    function()
                        -- 用户点击确定后，调用完成回调
                        if H.is_func(completion_callback) then
                            completion_callback(true)
                        end
                    end,
                    {
                        no_ok_button = true,
                        cancel_text = "确定"
                    }
                )
            end)
        else
            -- 构建缺失章节列表文本
            local missing_text = ""
            local max_display = 10
            for i, missing in ipairs(missing_chapters) do
                if i > max_display then
                    missing_text = missing_text .. string.format("\n...还有 %d 章未缓存", missing_count - max_display)
                    break
                end
                missing_text = missing_text .. string.format("\n第 %d 章: %s", missing.index + 1, missing.title)
            end

            MessageBox:confirm(string.format(
                "缓存不完整！\n\n书名：<<%s>>\n总章节：%d\n已缓存：%d\n未缓存：%d\n%s\n\n是否重新缓存缺失章节？",
                bookinfo.name or "未命名",
                chapter_count,
                cached_count,
                missing_count,
                missing_text
            ), function(result)
                if result then
                    -- 重新缓存缺失章节
                    self:cacheAllChapters(bookinfo)
                else
                    -- 用户取消重新缓存，调用完成回调
                    if H.is_func(completion_callback) then
                        completion_callback(false)
                    end
                end
            end, {
                ok_text = "重新缓存",
                cancel_text = "完成"
            })
        end
    end)
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

function M:manuallyPinToTop(bookCacheId, sortOrder)
    local bookShelfId = self:getServerPathCode()
    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        return wrap_response(nil, '参数错误')
    end
    self.dbManager:transaction(function()
        return self.dbManager:setBooksTopStatus(bookShelfId, bookCacheId, sortOrder)
    end)()
    return wrap_response(true)
end

function M:getBookShelfCache()
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:getAllBooksByUI(bookShelfId)
end

function M:autoPinToTop(bookCacheId, sortOrder)
    if 0 == sortOrder then
        -- If it is manually placed on top
        return wrap_response(true)
    end
    local bookShelfId = self:getServerPathCode()
    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        return wrap_response(nil, '参数错误')
    end
    self.dbManager:setBooksTopStatus(bookShelfId, bookCacheId, nil, 0)
    return wrap_response(true)
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
    if self:getBackgroundTaskInfo() ~= false then
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
    if self:getBackgroundTaskInfo() ~= false then
        return wrap_response(nil, '有后台任务进行中，请等待结束或者重启 KOReader')
    end

    local bookShelfId = self:getServerPathCode()
    self.dbManager:clearBooks(bookShelfId)
    self:closeDbManager()
    local books_cache_dir = H.getTempDirectory()
    ffiUtil.purgeDir(books_cache_dir)
    H.getTempDirectory()
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
        end, function(status, response, r2)
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

function M:download_cover_img(book_cache_id, cover_url, is_force)
     if not (H.is_str(book_cache_id) and book_cache_id ~= "" 
        and H.is_str(cover_url) and cover_url ~= "") then
        logger.err("download_cover_img: invalid parameter", book_cache_id, cover_url)
        return nil, nil
    end
    
    local cover_path_no_ext = H.getCoverCacheFilePath(book_cache_id)
    local dir, image_filename = util.splitFilePathName(cover_path_no_ext)
    if not (dir and image_filename) then
        logger.err(string.format("download_cover_img: invalid name (%s, %s)", tostring(dir), tostring(image_filename)))
        return nil, nil
    end
    H.checkAndCreateFolder(dir)

    if not is_force then
        local function find_cover(base_path)
            -- 可能的封面图片格式
            local extensions = { "jpg", "jpeg", "png", "webp", "bmp", "tiff" }
            for _, ext in ipairs(extensions) do
                local cover_full_path = string.format("%s.%s", base_path, ext)
                if util.fileExists(cover_full_path) then
                    return cover_full_path
                end
            end
            return nil
        end

        local cover_full_path = find_cover(cover_path_no_ext)
        if cover_full_path then
            return cover_full_path, image_filename
        end
    end

    local img_src = self:getProxyCoverUrl(cover_url)
    local ok, resp = pGetUrlContent({
                        url = img_src,
                        timeout = 15,
                        maxtime = 60,
                        is_pic = true,
                })
    if ok and resp and resp['data'] then
        local ext = resp.ext or "jpg"
        local cover_img_path = string.format("%s.%s", cover_path_no_ext, ext)
        util.writeToFile(resp.data, cover_img_path, true)
        return cover_img_path, image_filename
    else
        logger.err("download_cover_img: failed", cover_url, resp)
        return nil, nil
    end
end

function M:getBackgroundTaskInfo()
    -- ffiUtil.isSubProcessDone(task_pid)
    local pid_file = self.task_pid_file
    if not util.fileExists(pid_file) then
        return false
    end
    local task_pid_info = self:getLuaConfig(pid_file)
    local task_chapter = task_pid_info:readSetting("chapter")
    if not H.is_tbl(task_chapter) then
        return false
    end
    -- timeout
    if task_chapter.stime and os.time() - task_chapter.stime > 7200 then
        util.removeFile(pid_file)
        return false
    end 
    return task_chapter
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

        self.dbManager:dynamicUpdateChapters(chapter, update_state)
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

    if NetworkMgr:isConnected() then
        local settings = self:getSettings()
        if settings.sync_reading == true then
            UIManager:unschedule(M.saveBookProgressAsync)
            UIManager:scheduleIn(8, M.saveBookProgressAsync, self, chapter)
        end
        if chapter.isRead ~= true then
            local complete_count = self:getcompleteReadAheadChapters(chapter)
            if complete_count < 40 then
                local preDownloadNum = 3
                if chapter.cacheExt and chapter.cacheExt == 'cbz' then
                    preDownloadNum = 1
                end
                self:preLoadingChapters(chapter, preDownloadNum)
            end
        end
    end

    chapter.isRead = true
    chapter.isDownLoaded = true
end

function M:downloadChapter(chapter, message_dialog)

    local bookCacheId = chapter.book_cache_id
    local chapterIndex = chapter.chapters_index
    local chapterName = chapter.name

    local background_task_info = self:getBackgroundTaskInfo()
    if H.is_tbl(background_task_info) and background_task_info.book_cache_id == bookCacheId and 
            background_task_info.chapters_index == chapterIndex then
            
            return wrap_response(nil, "此章节后台下载中, 请等待...")
    end

    local status, err = H.pcall(function()
        return self:_pDownloadChapter(chapter, message_dialog)
    end)
    if not status then
        logger.err('下载章节失败：', err)
        return wrap_response(nil, "下载章节失败：" .. tostring(err))
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

local function check_web_conf(url, server_type, user, pwd)
    if not (H.is_num(server_type) and (server_type == 1  or server_type == 2 or server_type == 3)) then
        return nil, '服务器类型必须是1、2或3'
    end
    if server_type == 3 then
        if not (H.is_str(user) and user ~= '') then
            return nil, '轻阅读必须认证凭证'
        end
        if not (H.is_str(pwd) or pwd ~= '') then
            return nil, '轻阅读必须认证凭证'
        end
    elseif server_type == 2 then
        if H.is_str(user) and user ~= "" and (pwd == "" or not H.is_str(pwd)) then
            return nil, "请清空用户名或补全用户凭证"
        end
    end

    if not (H.is_str(url) and url ~= '') then
        return nil, '地址为空，保存失败'
    end

    local parsed = socket_url.parse(url)
    if not parsed then
        return nil, '地址不合规则，请检查'
    end
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return nil, '不支持的协议，请检查'
    end
    if not parsed.host or parsed.host == "" then
        return nil, "没有主机名"
    end
    if parsed.port then
        local port_num = tonumber(parsed.port)
        if not port_num or port_num < 1 or port_num > 65535 then
            return nil, "端口号不正确"
        end
    end

    local clean_url = socket_url.build(parsed)
    -- 根据服务器类型调整URL
    if  server_type == 2 and not string.find(string.lower(parsed.path or ""), "/reader3$") then
        clean_url = socket_url.absolute(clean_url, "/reader3")
    elseif server_type == 3 and not string.find(string.lower(parsed.path or ""), "/api/5$") then
        clean_url = socket_url.absolute(clean_url, "/api/5")
    end

    return { url = clean_url, type = server_type, user = user, pwd = pwd }
end

function M:switchWebConfig(conf_name)
    if not (H.is_str(conf_name) and conf_name ~= "") then
        return wrap_response(nil, "参数错误")
    end
    local settings = self:getSettings()
    local web_configs = settings.web_configs
    if not (H.is_tbl(web_configs) and H.is_tbl(web_configs[conf_name])) then
        return wrap_response(nil, "配置不存在")
    end
    if settings.current_conf_name == conf_name then
        return wrap_response(nil, "已经是当前激活配置")
    end
    local config = web_configs[conf_name]
    settings.server_address = config.url
    settings.server_type = config.type
    settings.reader3_un = config.user
    settings.reader3_pwd = config.pwd
    settings.current_conf_name = conf_name
    return self:saveSettings(settings)
end

function M:deleteWebConfig(conf_name)
    if not (H.is_str(conf_name) and conf_name ~= "") then
        logger.err("deleteWebConfig [Error] Parameter is empty")
        return wrap_response(nil, "参数错误")
    end
    local settings = self:getSettings()
    local web_configs = settings.web_configs
    if not (H.is_tbl(web_configs) and web_configs[conf_name]) then
        return wrap_response(nil, "配置不存在")
    end
    if settings.current_conf_name == conf_name then
        return wrap_response(nil, "当前激活配置, 不可删除")
    end

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
    
    local ok, err_msg = check_web_conf(url, server_type, user, pwd)
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
            return self:switchWebConfig(conf_name)
        else
            self:saveSettings()
            return wrap_response(true)
        end
    else
        return wrap_response(nil, tostring(err_msg))
    end
end

function M:getSettings()
    return self.settings_data.data
end

function M:saveSettings(settings)
    if not settings then
        self.settings_data:flush()
        self.settings_data = LuaSettings:open(H.getUserSettingsPath())
        return wrap_response(true)
    end
    
    if not (H.is_tbl(settings) and H.is_str(settings.server_address) and
           H.is_num(settings.server_type) and H.is_str(settings.chapter_sorting_mode)) then
            return wrap_response(nil, '参数校检错误，保存失败')
    end

    -- 一致性检查
    if H.is_tbl(settings.web_confings) and H.is_str(settings.current_conf_name) then
        local current_config = settings.web_confings[settings.current_conf_name]
        if not (H.is_tbl(current_config) and current_config.user == settings.reader3_un and current_config.pwd == settings.reader3_pwd and
           current_config.type == settings.server_type ) then
                return wrap_response(nil, 'web_config 数据不一致，保存失败')
        end
    end

    local new_setting_url = settings.server_address
    local user, pwd = settings.reader3_un, settings.reader3_pwd
    local server_type = settings.server_type
    local ok, err_msg = check_web_conf(new_setting_url, server_type, user, pwd)
    if not ok then
        return wrap_response(nil, tostring(err_msg))
    end

    local clean_url = new_setting_url
    if H.is_tbl(ok) and H.is_str(ok.url) then
        clean_url = ok.url
    end
    
    -- -- Changes detected, recalculate MD5
    if self.settings_data.data.server_address ~= clean_url then
        settings.server_address_md5 = md5(socket_url.parse(clean_url).host)
    end

    self.settings_data.data = settings
    self.settings_data.data.server_address = clean_url
    self.settings_data:flush()
    self.settings_data = LuaSettings:open(H.getUserSettingsPath())

    self:loadApiProvider()
    return wrap_response(true)
end

-- Multi-process execution: the job function call chain should not write to the database
-- No need to use pcall for job, errors are already handled inside the function
-- If a callback is provided, there will be no return value, as the callback will always be invoked
function M:launchProcess(job, callback, timeout)
    if not H.is_func(job) then
        logger.err("launchProcess - job must be a function")
        if H.is_func(callback) then
            callback(false, "invalid_job_function")
        else
            return false, "invalid_job_function"
        end
    end

    -- return task_pid, err other callback(ok, ...)
    if not H.is_func(callback) then
        return ffiUtil.runInSubProcess(job, nil, true)
    end

    local Trapper = require("ui/trapper")
    local buffer = require("string.buffer")

    Trapper:wrap(function()
        pcall(function() Device:enableCPUCores(2) end)

        logger.dbg("Legado.launchProcess - START")
        local start_time = os.time()
        local pid, parent_read_fd = nil, nil

        local function deliver_result(ok, r1, r2)
            if parent_read_fd then
                pcall(ffiUtil.readAllFromFD, parent_read_fd)
                parent_read_fd = nil
            end
            local status, err = pcall(function() Device:enableCPUCores(1) end)
            if not status then
                logger.err('Legado.launchProcess - Device.enableCPUCores err', tostring(err))
            end
            logger.dbg("Legado.launchProcess - END")
            callback(ok, r1, r2)
        end

        pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd)
            local ok, r1, r2 = pcall(job)
            local ret_tbl = { ok = ok, r1 = r1, r2 = r2 }
            -- NOTE: LuaJIT's serializer currently doesn't support:
            --       functions, coroutines, non-numerical FFI cdata & full userdata.
            local output_str = ""
            local ok, str = pcall(buffer.encode, ret_tbl)
            if ok and str then
                output_str = str
            else
                logger.warn("Legado.launchProcess - serialization failed:", str or "unknown error")
                ret_tbl = { ok = false, r1 = "serialization_error", r2 = tostring(str)}
                output_str = buffer.encode(ret_tbl) or ""
            end
            ffiUtil.writeToFD(child_write_fd, output_str, true)
        end, true)

        if not pid then
            logger.dbg("Legado.launchProcess - background task failed to start")
            deliver_result(false, "start_failed", parent_read_fd)
            return
        end

        local function poll()
            if timeout and os.difftime(os.time(), start_time) >= timeout then
                logger.dbg("Legado.launchProcess - timeout reached, killing subprocess")
                ffiUtil.terminateSubProcess(pid)
                UIManager:scheduleIn(1, function()
                   deliver_result(false, "timeout")
                end)
                return
            end

            local subprocess_done = ffiUtil.isSubProcessDone(pid)
            local stuff_to_read = parent_read_fd and ffiUtil.getNonBlockingReadSize(parent_read_fd) ~= 0
            if subprocess_done or stuff_to_read then
               -- Subprocess is gone or nearly gone
                local ok, r1, r2 = false, nil, nil
                if parent_read_fd then
                    local ret_str = ffiUtil.readAllFromFD(parent_read_fd) or ""
                    local dec_ok, ret_tbl = pcall(buffer.decode, ret_str)
                    if dec_ok and ret_tbl and type(ret_tbl) == "table" then
                        ok, r1, r2 = ret_tbl.ok, ret_tbl.r1, ret_tbl.r2
                    else
                        logger.warn("Legado.launchProcess - malformed serialized data:", ret_tbl)
                        ok, r1, r2 = false, "decode_error", nil
                    end
                    parent_read_fd = nil
                end
                logger.dbg("Legado.launchProcess - background task completed")
                deliver_result(ok, r1, r2)
            else
                UIManager:scheduleIn(0.2, poll)
            end
        end

        poll()
    end)
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
