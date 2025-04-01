local logger = require("logger")
local Device = require("device")
local ffiUtil = require("ffi/util")
local setmetatable_gc = require("ffi/__gc")
local md5 = require("ffi/sha2").md5
local Notification = require("ui/widget/notification")
local dbg = require("dbg")

local socket_url = require("socket.url")

local util = require("util")
local time = require("ui/time")
local JSON = require("json")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")

local H = require("libs/Helper")

local BookInfoDB = require("BookInfoDB")

local function wrap_response(data, err_message)
    return data ~= nil and {
        type = 'SUCCESS',
        body = data
    } or {
        type = 'ERROR',
        message = err_message or "Unknown error"
    }
end

local function requestJson(request)

    local ltn12 = require("ltn12")
    local http = require("socket.http")
    local socketutil = require("socketutil")

    local parsed_url = socket_url.parse(request.url)

    local query_params = request.query_params or {}
    local built_query_params = ""
    for name, value in pairs(query_params) do
        if built_query_params ~= "" then
            built_query_params = built_query_params .. "&"
        end
        built_query_params = built_query_params .. name .. "=" .. socket_url.escape(value)
    end

    parsed_url.query = built_query_params ~= "" and built_query_params or nil
    local built_url = socket_url.build(parsed_url)

    local headers = {}
    local serialized_body = nil
    if request.body ~= nil then
        serialized_body = JSON.encode(request.body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = serialized_body:len()
    end

    local timeout = request.timeout or 15
    socketutil:set_timeout(timeout, timeout)

    local sink = {}
    local _, status_code, response_headers = http.request({
        url = built_url,
        method = request.method or "GET",
        headers = headers,
        source = serialized_body ~= nil and ltn12.source.string(serialized_body) or nil,
        sink = ltn12.sink.table(sink),
        create = socketutil.tcp
    })

    socketutil:reset_timeout()

    local response_body = table.concat(sink)

    if status_code == 200 and response_body ~= "" then
        local _, parsed_body = pcall(JSON.decode, response_body)
        if type(parsed_body) ~= 'table' then
            error("Expected to be able to decode the response body as JSON: " .. response_body .. "(status code: " ..
                      status_code .. ")")
        end
        return parsed_body
    end

    loggerlog.warn("requestJson: cannot get access token:", status_code)
    logger.warn("requestJson: error:", response_body)
    error("Connection error, please check the server")
end

local M = {
    settings_data = nil,
    task_pid_file = nil,
    dbManager = {},
    ui_refresh_time = 0
}

function M:HandleResponse(response, on_success, on_error)
    if response == nil and on_error then
        return on_error("Response is nil")
    end
    if response.type == 'SUCCESS' and on_success then
        return on_success(response.body)
    elseif response.type == 'ERROR' and on_error then
        return on_error(response.message or '')
    end
end

function M:initialize()

    self.settings_data = LuaSettings:open(H.getUserSettingsPath())
    self.task_pid_file = H.getTempDirectory() .. '/task.pid.lua'

    if self.settings_data and not self.settings_data.data['legado_server'] then
        self.settings_data.data = {
            legado_server = 'http://127.0.0.1:1122',
            chapter_sorting_mode = "chapter_descending",
            server_address_md5 = 'f528764d624db129b32c21fbca0cb8d6'
        }
        self.settings_data:flush()
    end

    self.dbManager = BookInfoDB:new({
        dbPath = H.getTempDirectory() .. "/bookinfo.db"
    })

    self.ui_refresh_time = os.time()
end

function M:show_notice(msg, timeout)
    Notification:notify(msg, Notification.SOURCE_ALWAYS_SHOW)
end

function M:getCacheChapterFilePath(chapter)

    if not H.is_tbl(chapter) or chapter.book_cache_id == nil or chapter.chapters_index == nil then
        dbg.log('getCacheChapterFilePath Incorrect input parameters:', chapter)
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

    local extensions = {'txt', 'cbz', 'jpg', 'png'}

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
        dbg.log('findNextChaptersNotDownLoad Incorrect input parameters:', current_chapter)
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
        dbg.log('findNextChapter Input parameters error:', current_chapter)
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

local function convertToGrayscale(image_data)
    local Png = require("lib/Png")
    return Png.processImage(Png.toGrayscale, image_data, 1)

end

local function get_img_src(html)
    local img_sources = {}

    local img_pattern = '<img[^>]*src="([^"]+)"[^>]*>'
    if type(html) == 'string' and html:match(img_pattern) then

        for src in html:gmatch(img_pattern) do
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
    if not H.is_str(image_data) then
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

        return nil
    end
end

function M:getProxyCoverUrl(coverUrl)

    if H.is_str(coverUrl) then
        coverUrl = util.urlEncode(coverUrl)
    end
    local legado_server = self.settings_data.data['legado_server']

    return table.concat({legado_server, '/cover?path=', coverUrl})
end

function M:getProxyImageUrl(bookUrl, picUrls)

    if not H.is_tbl(picUrls) then
        return {}
    end
    local new_porxy_picurls = {}

    local width = Device.screen:getWidth() or 800
    local legado_server = self.settings_data.data['legado_server']

    for i, img_src in ipairs(picUrls) do
        local new_url =
            legado_server .. '/image?url=' .. util.urlEncode(bookUrl) .. '&path=' .. util.urlEncode(img_src) ..
                '&width=' .. width
        table.insert(new_porxy_picurls, new_url)
    end
    return new_porxy_picurls
end

local function pDownload_Image(img_src, timeout)

    local ltn12 = require("ltn12")
    local http = require("socket.http")
    local socketutil = require("socketutil")

    timeout = timeout or 600

    local imageData = {}

    socketutil:set_timeout(timeout, timeout)

    local success, statusCode, headers, statusLine = http.request {
        url = img_src,
        sink = ltn12.sink.table(imageData),
        create = socketutil.tcp
    }

    socketutil:reset_timeout()

    if not success then
        error("Request failed:" .. (statusLine or "Unknown error"))
    end

    if statusCode ~= 200 then
        error("Download failed, HTTP status code:" .. tostring(statusCode))
    end

    local merge_image_data = table.concat(imageData)

    local extension = ''

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

    if not filePath or not H.is_tbl(img_sources) then
        return false, 'Cbz generates input parameters error'
    end

    local is_convertToGrayscale = false

    local cbz_path_tmp = filePath .. '.downloading'

    if util.fileExists(cbz_path_tmp) then
        return false,
            'There are other threads downloading, this download will be cancelled, please wait for the download to be completed'
    end

    local ZipWriter = require("ffi/zipwriter")

    local cbz = ZipWriter:new{}
    if not cbz:open(cbz_path_tmp) then
        return false
    end
    cbz:add("mimetype", "application/vnd.comicbook+zip", true)

    local no_compression = true

    for i, img_src in ipairs(img_sources) do

        local status, err = pcall(pDownload_Image, img_src)

        if status and H.is_tbl(err) and err['data'] then

            local imgdata = err['data']
            local img_extension = err['ext']

            local img_name = i .. '.' .. img_extension

            if is_convertToGrayscale == true and img_extension == 'png' then
                local success, imgdata_new = convertToGrayscale(imgdata)
                if success ~= true then

                    goto continue
                end
                imgdata = imgdata_new.data
            end

            cbz:add(img_name, imgdata, no_compression)

        end
        ::continue::
    end

    cbz:close()

    if util.fileExists(filePath) ~= true then
        os.rename(cbz_path_tmp, filePath)
    else
        if util.fileExists(cbz_path_tmp) == true then
            util.removeFile(cbz_path_tmp)
        end
        return false,
            'The cbz file has failed to generate, there is already a target file, this download is cancelled, it has been cleaned or please wait for the background download to be completed'
    end

    return true
end

function M:DownAllChapter(chapters)
    local begin_chapter = chapters[1]

    begin_chapter.call_event = 'next'

    local status, err = self:preLoadingChapters(begin_chapter, #chapters)
    if not status then
        return wrap_response(nil, err or '数据请求错误')
    else
        return wrap_response(err)
    end
end

function M:preLoadingChapters(chapter, download_chapter_count)

    if not H.is_tbl(chapter) then
        return false, 'preLoadingChaptersIncorrect call parameters'
    end

    if self:isExtractingInBackground() == true then
        dbg.log('There are still tasks in the background that have not been completed. Cannot create new tasks:')
        return false, 'There are still tasks in the background that have not been completed. Cannot create new tasks:'
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

    self.dbManager:closeDB()

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
                                dbg.log('An error occurred when cleaning the download task to write to the database:',
                                    tostring(err))
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
                dbg.v('Multi-threaded tasks in progress:runInSubProcess_start_title:', nextChapter.title)

                local status, err = pcall(function()
                    return self:pDownloadChapter(nextChapter)
                end)

                if not status then
                    dbg.log("Chapter download failed: ", tostring(err))
                else

                    if H.is_tbl(err) and err.cacheFilePath then

                        local cache_file_path = err.cacheFilePath
                        local chapters_index = tonumber(nextChapter.chapters_index)
                        local book_cache_id = nextChapter.book_cache_id

                        task_return_ok_list['ok_' .. chapters_index] = true

                        dbg.v('Download the chapter successfully', book_cache_id, chapters_index, cache_file_path)

                        status, err = pcall(function()
                            return task_return_db_add(book_cache_id, chapters_index, cache_file_path)
                        end)
                        if not status then
                            dbg.log('An error occurred when downloading successfully to write to the database:',
                                tostring(err))
                        end
                    end

                end
            else
                dbg.log("Cache next chapter next chapter data source error")

            end

            if not util.fileExists(self.task_pid_file) then
                dbg.v('The downloader receives a mid-way stop signal')
                break
            end

        end

        dbg.v('Download and clean up the unfinished chapters~')
        local status, err = pcall(function()
            return task_return_db_clear(chapter_down_tasks, task_return_ok_list)
        end)
        if not status and err then
            dbg.v('Chapters that end the load cleanup are not completed:', tostring(err))
        end

        self.dbManager:closeDB()

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
        return false, "Failed to create a background download task: " .. tostring(err)
    else

        dbg.v("The background download task was created successfully, and the task PID: " .. tostring(task_pid))

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
            dbg.v('Failed to write to download flag:', tostring(err))
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

function M:setBooksTopUp(bookCacheId)
    if not H.is_str(bookCacheId) then
        return
    end
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:setBooksTopUp(bookShelfId, bookCacheId)
end

function M:getBookShelfCache()
    local bookShelfId = self:getServerPathCode()
    local books_data = self.dbManager:getAllBooksByUI(bookShelfId)
    return books_data
end

function M:getBookSelfLastUpdateTime()
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:getBookSelfLastUpdateTime(bookShelfId)
end

function M:getBookLastUpdateTime(bookCacheId)
    local bookShelfId = self:getServerPathCode()
    return self.dbManager:getBookLastUpdateTime(bookShelfId, bookCacheId)
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

function M:refreshChaptersCache(bookinfo)

    if os.time() - self.ui_refresh_time < 3 then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(true)
    end

    local book_cache_id = bookinfo.cache_id
    local bookUrl = bookinfo.bookUrl

    local legado_server = self.settings_data.data['legado_server']

    if not bookUrl or not H.is_str(book_cache_id) then
        return wrap_response(nil, "获取目录参数错误")
    end

    local status, err = pcall(function()
        return requestJson({
            url = table.concat({legado_server, '/getChapterList'}),
            query_params = {
                url = bookUrl,
                v = os.time()
            },
            timeout = 10
        })
    end)

    if not status then
        dbg.log(err)
        return wrap_response(nil, '请求出错,请检查服务')
    end

    if not err or not H.is_tbl(err.data) then
        return wrap_response(nil, err.errorMsg or "无效的服务器响应格式")
    end

    local response = err.data
    status, err = pcall(function()
        return self.dbManager:upsertChapters(book_cache_id, response)
    end)

    if not status then
        dbg.log('refreshChaptersCache数据写入', tostring(err))
        return wrap_response(nil, '数据写入出错,请重试')
    end
    self.ui_refresh_time = os.time()
    return wrap_response(true)

end

function M:refreshLibraryCache()

    if os.time() - self.ui_refresh_time < 3 then
        dbg.v('ui_refresh_time prevent refreshChaptersCache')
        return wrap_response(true)
    end

    local bookShelfId = self:getServerPathCode()

    local legado_server = self.settings_data.data['legado_server']

    local status, err = pcall(function()
        return requestJson({
            url = legado_server .. '/getBookshelf?v=' .. os.time(),
            timeout = 6
        })
    end)

    if not status then
        dbg.log('refreshLibraryCache请求出错', tostring(err))
        return wrap_response(nil, '请求出错,请检查服务后重试')
    end

    local response = err

    if not response or not H.is_tbl(response.data) then

        return wrap_response(nil, response.errorMsg or "服务器返回了无效的数据结构")
    end

    status, err = pcall(function()
        return self.dbManager:upsertBooks(bookShelfId, response.data)
    end)

    if not status then
        dbg.log('refreshLibraryCache数据写入', tostring(err))
        return wrap_response(nil, '写入数据库出错,请重试')
    end

    self.ui_refresh_time = os.time()
    return wrap_response(true)
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
    self.dbManager:closeDB()
    local books_cache = H.getTempDirectory()
    ffiUtil.purgeDir(books_cache)
    H.getTempDirectory()
    return wrap_response(true)
end

function M:MarkReadChapter(chapter)
    local chapters_index = chapter.chapters_index

    chapter.isRead = not chapter.isRead
    self.dbManager:updateIsRead(chapter, chapter.isRead)

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
            return wrap_response(nil, '下载任务添加失败:' .. tostring(err))
        end
    else

        if util.fileExists(cacheFilePath) then
            util.removeFile(cacheFilePath)
        end

        self.dbManager:dynamicUpdateChapters(chapter, {
            content = '_NULL',
            cacheFilePath = '_NULL'
        })

        return wrap_response(true)
    end
end

function M:runTaskWithRetry(taskFunc, timeoutMs, intervalMs)

    if not H.is_func(taskFunc) then
        dbg.log("Invalid taskFunc: must be a function")
        return
    end

    if not H.is_num(timeoutMs) or timeoutMs <= 10 then
        dbg.log("Invalid timeoutMs: must be a positive number")
        return
    end

    if not H.is_num(intervalMs) or intervalMs <= 10 then
        dbg.log("Invalid intervalMs: must be a positive number")
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

            dbg.v("Task not completed yet. Checking again in %d milliseconds...", currentTime)

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
        dbg.v('The inspector receives a stop signal')
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
    elseif  downloaded_num < total_num then
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

    if util.fileExists(self.task_pid_file) then
        if H.isFileOlderThan(self.task_pid_file, 24 * 60 * 60) then
            util.removeFile(self.task_pid_file)

            return false
        else
            return true
        end
    else

        return false
    end
end

M.saveBookProgress = function(self, chapter)

    local msTime = time.to_ms(time.now())
    local chapter_index = chapter.chapters_index

    local mark_chapter = {
        name = chapter.name,
        author = chapter.author,
        durChapterPos = 0,

        durChapterIndex = chapter_index,
        durChapterTime = msTime,
        durChapterTitle = chapter.title or '',
        index = chapter_index,
        url = chapter.bookUrl
    }

    local legado_server = self.settings_data.data['legado_server']

    local task_pid, err = ffiUtil.runInSubProcess(function()
        local status, err = pcall(function()
            return requestJson({
                url = legado_server .. '/saveBookProgress',
                body = mark_chapter,
                method = 'POST',
                timeout = 3
            })
        end)
        if not status then
            dbg.log('Reading progress synchronization failed:', tostring(err))
        end

    end, nil, true)

    return wrap_response({})

end

function M:after_reader_chapter_show(chapter)

    local chapters_index = chapter.chapters_index
    local cache_file_path = chapter.cacheFilePath
    local book_cache_id = chapter.book_cache_id

    local status, err = pcall(function()
        if chapter.isRead ~= true or chapter.isDownLoaded ~= true or chapter.cacheFilePath == nil then

            self.dbManager:dynamicUpdateChapters(chapter, {
                content = 'downloaded',
                isRead = true,
                cacheFilePath = cache_file_path
            })

            chapter.isRead = true
            chapter.isDownLoaded = true
            chapter.cacheFilePath = cache_file_path
        end

    end)
    if not status then
        dbg.log('An error occurred when updating the read download flag:', tostring(err))
    end

    if cache_file_path ~= nil and chapter.cacheExt == nil then

        local cache_name = select(2, util.splitFilePathName(cache_file_path))
        local _, extension = util.splitFileNameSuffix(cache_name)

        local bookShelfId = self:getServerPathCode()

        status, err = pcall(function()
            self.dbManager:dynamicUpdateBooks({
                book_cache_id = book_cache_id,
                bookShelfId = bookShelfId
            }, {
                cacheExt = extension
            })
        end)
        if not status then
            dbg.log('An error occurred when updating cache ext:', tostring(err))
        end
    end

    UIManager:unschedule(M.saveBookProgress)
    UIManager:scheduleIn(5, M.saveBookProgress, self, chapter)

    local preDownloadNum = 2
    if chapter.cacheExt and chapter.cacheExt == 'txt' then
        preDownloadNum = 4
    end
    local complete_count = self:getcompleteReadAheadChapters(chapter)

    if complete_count < 40 then
        self:preLoadingChapters(chapter, preDownloadNum)
    end
end

function M:pDownloadChapter(chapter, message_dialog)

    local bookUrl = chapter.bookUrl
    local book_cache_id = chapter.book_cache_id
    local chapters_index = chapter.chapters_index
    local chapter_title = chapter.title or ''
    local down_chapter_index = chapter.chapters_index

    local function message_show(msg)
        if message_dialog then
            message_dialog.text = msg
            UIManager:setDirty(message_dialog, "ui")
            UIManager:forceRePaint()
        end
    end

    if bookUrl == nil or not book_cache_id then
        error('pDownloadChapter An error occurred in input parameters' .. tostring(bookUrl) .. tostring(book_cache_id))
    end

    local cache_chapter = self:getCacheChapterFilePath(chapter)
    if cache_chapter and cache_chapter.cacheFilePath then
        return cache_chapter
    end

    local legado_server = self.settings_data.data['legado_server']

    local status, err = pcall(function()
        return requestJson({
            url = table.concat({legado_server, '/getBookContent'}),
            query_params = {
                url = bookUrl,
                index = down_chapter_index,
                v = os.time()
            },
            timeout = 10
        })
    end)

    if not status then
        error(type(err) == 'string' and err or 'getBookContent数据请求出错')
    end

    local response = err

    if response and response.data then
        local content = response.data

        if type(content) ~= "string" then
            content = tostring(content)
        end

        local filePath = H.getChapterCacheFilePath(book_cache_id, chapters_index)

        local is_img_sources = get_img_src(content)

        if type(is_img_sources) == 'table' and #is_img_sources > 0 then

            local img_sources = self:getProxyImageUrl(bookUrl, is_img_sources)

            filePath = filePath .. '.cbz'

            if img_sources and #img_sources > 0 then
                local status, err = pDownload_CreateCBZ(filePath, img_sources)
                if status == true then

                    if chapter.is_pre_loading == true then
                        dbg.v('Cache task completed chapter.title:', chapter_title)
                    end

                    chapter.cacheFilePath = filePath
                    return chapter
                elseif err then

                    error(err)
                end
            else
                error('生成代理图片列表失败')
            end
        else

            filePath = filePath .. '.txt'

            content = tostring(chapter_title) .. "\r\n" .. content

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

    else
        error(response.errorMsg or '章节下载失败')
    end

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
        dbg.log(err)
        return wrap_response(nil, "下载章节失败,请检查服务")
    end
    return wrap_response(err)

end

function M:getServerPathCode()

    if self.settings_data.data['server_address_md5'] == nil then
        local server_address_md5 = socket_url.parse(self.settings_data.data['legado_server']).host
        self.settings_data.data['server_address_md5'] = md5(server_address_md5)
        self.settings_data:flush()
    end
    return tostring(self.settings_data.data['server_address_md5'])
end

function M:getSettings()
    return self.settings_data.data
end

function M:setSettings(settings)

    local new_legado_server = settings.legado_server

    if not H.is_str(new_legado_server) or new_legado_server == '' then
        return wrap_response(nil, '参数校检错误，保存失败')
    end

    local parsed = socket_url.parse(new_legado_server)
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

    settings.legado_server = new_legado_server
    if not H.is_str(settings.chapter_sorting_mode) then
        return wrap_response(nil, '参数校检错误，保存失败')
    end

    settings.server_address_md5 = md5(parsed.host)
    self.settings_data.data = settings
    self.settings_data:flush()

    return wrap_response(settings)
end

function M:searchBookSource(search_text, lastIndex)

    if not search_text or search_text == '' then
        return wrap_response(nil, "输入参数错误")
    end
    lastIndex = lastIndex or 0
    local legado_server = self.settings_data.data['legado_server']

    if string.find(string.lower(legado_server), "/reader3/") then
        local status, err = pcall(function()
            return requestJson({
                url = legado_server .. '/searchBookSource?name=' .. search_text .. '&lastIndex=' .. lastIndex,
                query_params = {
                    name = search_text,
                    lastIndex = lastIndex
                },
                timeout = 20
            })
        end)
        if status then
            return err
        end
    else
        return wrap_response(nil, "仅支持服务器版本,其他请在app操作")
    end
end

function M:deleteBook(bookinfo)
    local status, err = pcall(function()
        return requestJson({
            url = legado_server .. '/deleteBook',
            body = bookinfo,
            method = 'POST',
            timeout = 5
        })
    end)
    if not status then
        return wrap_response(nil, err or '数据请求出错')
    end
    return wrap_response(true)
end

function M:addBookToLibrary(bookinfo)
    local legado_server = self.settings_data.data['legado_server']

    local nowTime = time.now()
    bookinfo.time = time.to_ms(nowTime)

    local status, err = pcall(function()
        return requestJson({
            url = legado_server .. '/saveBook',
            body = bookinfo,
            method = 'POST',
            timeout = 5
        })
    end)
    if not status then
        return wrap_response(nil, err or '数据请求出错')
    end

    local response = err

    if not response or response.isSuccess ~= true then
        return wrap_response(nil, response.errorMsg or "无效的服务器响应格式")
    end

    return wrap_response(nil, "暂不支持,请从阅读客户端操作")

end

function M:onExitClean()
    dbg.v('Backend对象释放,onExitClean执行清理工作')

    self.dbManager:closeDB()

    if util.fileExists(self.task_pid_file) then
        util.removeFile(self.task_pid_file)
    end

    collectgarbage()
    collectgarbage()
    return true
end

setmetatable_gc(M, {
    __gc = function(t)
        M:onExitClean()
    end
})

return M
