local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local logger = require("logger")

local MessageBox = require("Legado/MessageBox")
local Backend = require("Legado/Backend")
local H = require("Legado/Helper")
local ImageUtil = require("Legado.Helper.ImageUtil")
local Probe = require("Legado.Helper.Probe")
local TaskQueueV2 = require("Legado.task.v2")

local RAW_CACHE_LIMIT = 16 * 1024 * 1024
local RENDER_CACHE_RADIUS = 1
local PREFETCH_RETRY_DELAY = 5

local M = ImageViewer:extend{
    bookinfo = nil,
    chapter = nil,
    chapter_imglist = nil,
    chapter_imglist_cur = 1,
    on_return_callback = nil,
    on_fallback_callback = nil,

    _fullscreen_fill = "cover",

    _first_image_ready = false,

    _raw_cache = nil,
    _raw_cache_bytes = 0,
    _render_cache = nil,
    _active_fetches = nil,
    _failed_pages = nil,
    _prefetch_retry_at = nil,
    _prefetch_blocked_center = nil,

    _next_chapter_info = nil,
    _next_chapter_imglist = nil,
    _next_chapter_imglist_index = nil,
    _next_chapter_first_raw = nil,
    _next_chapter_first_raw_index = nil,
    _cross_image_batch = nil,
    _prev_chapter_info = nil,
    _prev_chapter_imglist = nil,
    _prev_chapter_imglist_index = nil,
    _prev_chapter_last_raw = nil,
    _prev_chapter_last_raw_index = nil,
    _prev_cross_image_batch = nil,

    _chapter_gen = 0,
    _initial_blank_bb = nil,

    _save_progress_timer = nil,
    _last_displayed_page = nil,
    _is_closed = false,

    _image_batch = nil,
    _image_batch_pages = nil,
    _image_batch_seq = 0,
    _image_batch_id = nil,
    _image_batches = nil,
    _image_callbacks = nil,
}

local function format_desc(chapter, page_idx, total)
    local ch_title = chapter and (chapter.title or chapter.name or "") or ""
    local idx = chapter and chapter.chapters_index or 0
    if page_idx and total then
        return string.format("第%d章_%d/%dP %s", idx, page_idx, total, ch_title)
    end
    return string.format("第%d章 %s", idx, ch_title)
end

local function extract_error_str(err)
    if err == nil then return "网络请求超时" end
    if type(err) == "string" then
        if err:match("^table:%s*0x") then return "网络连接超时或远程图源中断" end
        return err
    end
    if type(err) == "table" then
        if err.err then return extract_error_str(err.err) end
        if err.error then return extract_error_str(err.error) end
        if err.message then return extract_error_str(err.message) end
        if err.msg then return extract_error_str(err.msg) end
        if err.err_msg then return extract_error_str(err.err_msg) end
        if err[1] then return extract_error_str(err[1]) end
        return "网络连接超时或远程图源中断"
    end
    local s = tostring(err)
    if s:match("^table:%s*0x") then return "网络连接超时或远程图源中断" end
    return s
end

local function find_adjacent_chapter(chapter, direction)
    if not (chapter and chapter.book_cache_id and tonumber(chapter.chapters_index)) then
        return nil
    end
    return Backend:findNextChapter({
        book_cache_id = chapter.book_cache_id,
        chapters_index = tonumber(chapter.chapters_index),
        call_event = direction == "prev" and "prev" or "next",
    })
end

function M:init()
    self._raw_cache = self._raw_cache or {}
    self._raw_cache_bytes = self._raw_cache_bytes or 0
    self._render_cache = self._render_cache or {}
    self._active_fetches = self._active_fetches or {}
    self._failed_pages = self._failed_pages or {}
    self._prefetch_retry_at = self._prefetch_retry_at or {}
    self._is_closed = (self._is_closed == true)
    self._first_image_ready = (self._first_image_ready == true)
    self._chapter_gen = self._chapter_gen or 0
    self._last_displayed_page = nil

    self.fullscreen = true
    self.with_title_bar = false
    self.image_disposable = false
    self.image_padding = 0

    if not self.image then
        local bb_type = (Screen.bb and Screen.bb.getType and Screen.bb:getType()) or Blitbuffer.TYPE_BBRGB32 or 1
        local ok, blank_bb = pcall(Blitbuffer.new, Screen:getWidth(), Screen:getHeight(), bb_type)
        if ok and blank_bb then
            if blank_bb.fill then pcall(blank_bb.fill, blank_bb, Blitbuffer.COLOR_WHITE or 0xFFFFFF) end
            self.image = blank_bb
            self._initial_blank_bb = blank_bb
        end
    end

    ImageViewer.init(self)
end

function M:_new_image_wg()
    local max_image_h = self.img_container_h
    local max_image_w = self.width
    if self.buttons_visible or self.with_title_bar then
        max_image_h = self.img_container_h - self.image_padding * 2
        max_image_w = self.width - self.image_padding * 2
    end

    local Progress = require("Legado.task.Progress")

    local cur_p = self.chapter_imglist_cur or 1
    local ch_idx = self.chapter and self.chapter.chapters_index or 1
    local ch_title = self.chapter and (self.chapter.title or self.chapter.name or "") or ""
    local total_p = (self.chapter_imglist and #self.chapter_imglist) or 0

    if self._chapter_error then
        local card = Progress.createCardWidget{
            title = "⚠️ 章节图源拉取失败",
            subtitle = string.format("第 %d 章 %s", ch_idx, ch_title),
            detail = string.format("原因: %s", self._chapter_error),
            action_text = "【 轻触屏幕中央 重新拉取 】",
        }

        self.image_container = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = self.img_container_h,
            },
            card,
        }
        return
    end

    if self._failed_pages and self._failed_pages[cur_p] then
        local err_msg = extract_error_str(self._failed_pages[cur_p])
        local card = Progress.createCardWidget{
            title = "⚠️ 图片加载失败",
            subtitle = string.format("第 %d 章 · 第 %d/%d 页 %s", ch_idx, cur_p, total_p, ch_title),
            detail = string.format("原因: %s", err_msg),
            action_text = "【 轻触屏幕中央 重新拉取 】",
        }

        self.image_container = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = self.img_container_h,
            },
            card,
        }
        return
    end

    if not self._first_image_ready then
        local page_str = string.format("第 %d 页", cur_p)
        local card = Progress.createCardWidget{
            title = "⚡ 流式漫画载入中...",
            subtitle = string.format("第 %d 章 %s", ch_idx, ch_title),
            detail = string.format("正在解析图源并拉取首图 (%s)", page_str),
        }

        self.image_container = CenterContainer:new{
            dimen = Geom:new{
                w = self.width,
                h = self.img_container_h,
            },
            card,
        }
        return
    end

    local sf = 0
    if self.image and self.image.getWidth and self.image.getHeight then
        local img_w = self.image:getWidth()
        local img_h = self.image:getHeight()
        if self._fullscreen_fill == "cover" and img_w > 0 and img_h > 0 then
            sf = math.max(max_image_w / img_w, max_image_h / img_h)
        elseif self._fullscreen_fill == "stretch" then
            sf = nil
        else
            sf = 0
        end
    end

    self._image_wg = ImageWidget:new{
        image = self.image,
        image_disposable = false,
        file_do_cache = false,
        alpha = false,
        width = max_image_w,
        height = max_image_h,
        rotation_angle = 0,
        scale_factor = sf,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
    }

    self.image_container = CenterContainer:new{
        dimen = Geom:new{
            w = self.width,
            h = self.img_container_h,
        },
        self._image_wg,
    }
end

function M:fetchAndShow(options)
    if not (H.is_tbl(options) and H.is_tbl(options.chapter)) then
        logger.err("StreamImageView:fetchAndShow - 无效的 options 或 chapter")
        MessageBox:notice("参数错误", "无法打开流式漫画。")
        return nil
    end

    local chapter = options.chapter
    local book_cache_id = chapter.book_cache_id
    local bookinfo = Backend:getBookInfoCache(book_cache_id)

    local start_page = 1
    if bookinfo and bookinfo.durChapterIndex == chapter.chapters_index and tonumber(bookinfo.durChapterPos) then
        start_page = math.max(1, tonumber(bookinfo.durChapterPos))
    end

    local viewer = M:new{
        chapter = chapter,
        bookinfo = bookinfo,
        on_return_callback = options.on_return_callback,
        on_fallback_callback = options.on_fallback_callback,
    }

    UIManager:show(viewer)
    viewer:loadChapter(chapter, start_page)
    return viewer
end

function M:getChannel()
    if not self._channel then
        self._channel_name = "stream_v2_" .. tostring(H.timestamp()):gsub("%.", "")
        self._channel = TaskQueueV2.channel(self._channel_name, { max_workers = 2 })
    end
    return self._channel
end

function M:pushStreamTask(task_func, callback, opts)
    if self._is_closed then return end
    opts = opts or {}
    local priority = opts.priority
    if opts.insert_at_head then priority = math.max(tonumber(priority) or 0, 1000) end
    local task = self:getChannel():submit(task_func, {
        engine = "process",
        priority = priority or 0,
        timeout = opts.timeout or 180,
        retry = opts.retry,
    })
    task:on("done", function(ok, value)
        if self._is_closed or type(callback) ~= "function" then return end
        if ok then
            callback(value, nil)
        else
            callback(nil, extract_error_str(value))
        end
    end)
    return task
end

function M:loadChapter(chapter, start_page)
    if self._is_closed then return end

    self:_flushProgress()

    local cached_imglist
    local cached_first_raw
    local cached_last_raw
    local chapter_index = chapter and tonumber(chapter.chapters_index)
    if chapter_index and self._next_chapter_imglist_index == chapter_index
            and H.is_tbl(self._next_chapter_imglist) and #self._next_chapter_imglist > 0 then
        cached_imglist = self._next_chapter_imglist
        if self._next_chapter_first_raw_index == chapter_index then
            cached_first_raw = self._next_chapter_first_raw
        end
    end
    if not cached_imglist and chapter_index and self._prev_chapter_imglist_index == chapter_index
            and H.is_tbl(self._prev_chapter_imglist) and #self._prev_chapter_imglist > 0 then
        cached_imglist = self._prev_chapter_imglist
        if self._prev_chapter_last_raw_index == chapter_index then
            cached_last_raw = self._prev_chapter_last_raw
        end
    end
    self._next_chapter_imglist = nil
    self._next_chapter_imglist_index = nil
    self._next_chapter_first_raw = nil
    self._next_chapter_first_raw_index = nil
    self._prev_chapter_imglist = nil
    self._prev_chapter_imglist_index = nil
    self._prev_chapter_last_raw = nil
    self._prev_chapter_last_raw_index = nil
    self._next_chapter_info = nil
    self._prev_chapter_info = nil
    if self._cross_image_batch then
        pcall(function() self._cross_image_batch.cancel("chapter_changed") end)
        self._cross_image_batch = nil
    end
    if self._prev_cross_image_batch then
        pcall(function() self._prev_cross_image_batch.cancel("chapter_changed") end)
        self._prev_cross_image_batch = nil
    end
    self.chapter = chapter
    self.chapter_imglist = nil
    self.chapter_imglist_cur = start_page or 1
    self._last_displayed_page = nil
    self._first_image_ready = false
    self._failed_pages = {}
    self._prefetch_retry_at = {}
    self._prefetch_blocked_center = nil
    self._chapter_error = nil
    self._chapter_gen = (self._chapter_gen or 0) + 1

    if self._channel then
        pcall(function() self._channel:shutdown("chapter_changed") end)
        if self._channel_name then
            pcall(TaskQueueV2.destroyChannel, self._channel_name)
        end
        self._channel = nil
        self._channel_name = nil
    end
    if self._image_batches then
        for lane, batch in pairs(self._image_batches) do
            if batch then pcall(function() batch.cancel("chapter_changed") end) end
            self._image_batches[lane] = nil
        end
    elseif self._image_batch then
        pcall(function() self._image_batch.cancel("chapter_changed") end)
    end
    self._image_batch = nil
    self._image_batch_pages = nil
    self._image_batch_id = nil
    self._image_callbacks = {}
    self._active_fetches = {}

    self:clearImageCaches()
    if cached_first_raw and cached_first_raw.data then
        self:_putRaw(1, cached_first_raw.data)
    elseif cached_last_raw and cached_last_raw.data and cached_imglist then
        self:_putRaw(#cached_imglist, cached_last_raw.data)
        self.chapter_imglist_cur = #cached_imglist
    end
    self:update()

    local cur_gen = self._chapter_gen
    local t_open_start = Probe.start("Stream", "打开流式漫画", format_desc(chapter), string.format("起始页: %d", self.chapter_imglist_cur))
    local t_src_start = Probe.start("Stream", "拉取章节图源", format_desc(chapter))

    local function on_imglist_ready(result, err)
        if self._is_closed or self._chapter_gen ~= cur_gen then return end

        if not (result and H.is_tbl(result.list) and #result.list > 0) then
            local err_msg = extract_error_str((result and result.err_msg) or err or "获取章节图源失败")
            Probe.fail("Stream", "章节图源失败", format_desc(chapter), t_src_start, tostring(err_msg))
            self._chapter_error = err_msg
            self:update()
            return
        end

        self.chapter_imglist = result.list
        self.chapter_imglist_cur = math.min(#self.chapter_imglist, math.max(1, self.chapter_imglist_cur))
        local total_p = #self.chapter_imglist
        local source_desc = cached_imglist and "[HIT_CROSS_CHAPTER_LIST]" or nil

        Probe.done("Stream", "章节图源就绪", format_desc(chapter), t_src_start, "200 OK", nil,
            string.format("共 %d P %s", total_p, source_desc or ""))
        self:showPage(self.chapter_imglist_cur)
        self:prefetchWindow(self.chapter_imglist_cur)
    end

    if cached_imglist then
        on_imglist_ready({ list = cached_imglist })
    else
        self:pushStreamTask(function()
            local list, err_msg = Backend:getChapterImgList(chapter)
            return { list = list, err_msg = err_msg }
        end, on_imglist_ready, { insert_at_head = true })
    end
end

function M:_trimRawCache()
    local center = self.chapter_imglist_cur or 1
    while self._raw_cache_bytes > RAW_CACHE_LIMIT do
        local farthest_page
        local farthest_distance = -1
        for page_idx in pairs(self._raw_cache) do
            if page_idx ~= center then
                local distance = math.abs(page_idx - center)
                if distance > farthest_distance then
                    farthest_page = page_idx
                    farthest_distance = distance
                end
            end
        end
        if not farthest_page then break end

        local entry = self._raw_cache[farthest_page]
        self._raw_cache_bytes = math.max(0, self._raw_cache_bytes - entry.size)
        self._raw_cache[farthest_page] = nil
    end
end

function M:_putRaw(page_idx, data)
    if type(data) ~= "string" or #data == 0 then return false end

    local old = self._raw_cache[page_idx]
    if old then
        self._raw_cache_bytes = math.max(0, self._raw_cache_bytes - old.size)
    end

    local size = #data
    self._raw_cache[page_idx] = { data = data, size = size }
    self._raw_cache_bytes = self._raw_cache_bytes + size
    self:_trimRawCache()
    return self._raw_cache[page_idx] ~= nil
end

function M:_trimRenderCache(center)
    for page_idx, entry in pairs(self._render_cache) do
        if math.abs(page_idx - center) > RENDER_CACHE_RADIUS
                and entry.bb ~= self.image then
            if entry.bb and entry.bb.free then
                pcall(entry.bb.free, entry.bb)
            end
            self._render_cache[page_idx] = nil
        end
    end
end

function M:_decodePage(page_idx, data, size)
    if type(data) ~= "string" or #data == 0 then return nil end

    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok or not bb then return nil end

    local old = self._render_cache[page_idx]
    if old and old.bb and old.bb ~= bb and old.bb ~= self.image and old.bb.free then
        pcall(old.bb.free, old.bb)
    end
    self._render_cache[page_idx] = { bb = bb, size = size or #data }
    self:_trimRenderCache(page_idx)
    return bb
end

function M:_hasPageCallbacks(page_idx)
    local callbacks = self._image_callbacks and self._image_callbacks[page_idx]
    return callbacks and #callbacks > 0 or false
end

function M:_finishPageCallbacks(page_idx, bb, size, err)
    local callbacks = self._image_callbacks and self._image_callbacks[page_idx] or {}
    if self._image_callbacks then self._image_callbacks[page_idx] = nil end
    for _, callback in ipairs(callbacks) do
        pcall(callback, bb, size or 0, err)
    end
end

function M:_shouldPrefetch(page_idx, total)
    if page_idx < 1 or page_idx > total then return false end
    if self._raw_cache[page_idx] or self._render_cache[page_idx] or self._active_fetches[page_idx] then
        return false
    end

    local retry_at = self._prefetch_retry_at[page_idx]
    if retry_at and retry_at > H.timestamp() then return false end
    if retry_at then self._prefetch_retry_at[page_idx] = nil end
    return true
end

function M:_startImageBatch(page_indexes, callbacks, lane)
    if self._is_closed or not self.chapter_imglist or #page_indexes == 0 then return end
    local cur_gen = self._chapter_gen
    local items, pages = {}, {}
    callbacks = callbacks or {}
    self._image_batches = self._image_batches or {}
    self._image_callbacks = self._image_callbacks or {}
    lane = lane == "urgent" and "urgent" or "prefetch"
    local priority = lane == "urgent" and 100 or 10
    local configured_concurrency = Backend:normalizeDownloadThreads(Backend:getSettings().download_threads)

    for page_idx, callback in pairs(callbacks) do
        if callback then
            self._image_callbacks[page_idx] = self._image_callbacks[page_idx] or {}
            table.insert(self._image_callbacks[page_idx], callback)
        end
    end
    if lane == "urgent" and #page_indexes == 1 and self._active_fetches[page_indexes[1]] then
        return
    end

    if lane == "prefetch" and self._image_batches.prefetch then return end
    if lane == "urgent" and configured_concurrency == 1 and self._image_batches.prefetch then
        pcall(function() self._image_batches.prefetch.cancel("urgent_page") end)
        self._image_batches.prefetch = nil
    end
    if lane == "urgent" and self._image_batches.urgent then
        pcall(function() self._image_batches.urgent.cancel("page_changed") end)
        self._image_batches.urgent = nil
    end
    for _, page_idx in ipairs(page_indexes) do
        local url = self.chapter_imglist[page_idx]
        if type(url) == "string" and url ~= ""
                and not self._raw_cache[page_idx]
                and not self._render_cache[page_idx]
                and not self._active_fetches[page_idx] then
            self._active_fetches[page_idx] = true
            table.insert(pages, page_idx)
            table.insert(items, { page = page_idx, url = url })
        end
    end
    if #items == 0 then return end

    self._image_batch_seq = (self._image_batch_seq or 0) + 1
    local batch_id = string.format("img:%s:%d:%d", tostring(self.chapter and self.chapter.chapters_index or "?"), cur_gen, self._image_batch_seq)
    Probe.event("Stream", "启动图片批次", string.format("batch=%s lane=%s pages=%d priority=%d", batch_id, lane, #pages, priority))

    local t_batch = H.timestamp()
    local batch_cancelled = false
    local batch_group
    batch_group = TaskQueueV2.batch(items, function(item, _, ctx)
        ctx.throw_if_cancelled()
        local data, ext_or_err
        if item.url:match("^cbz://") then
            local cbz_path, entry_name = item.url:match("^cbz://(.-)#(.*)$")
            if cbz_path and entry_name then
                local ZipUtil = require("Legado.Helper.ZipUtil")
                local reader = ZipUtil.Reader:new()
                if reader and reader.open and reader:open(cbz_path) then
                    local extract_ok, extracted = pcall(reader.extractToMemory, reader, entry_name)
                    data = extract_ok and extracted or nil
                end
                if reader and reader.close then pcall(reader.close, reader) end
                ext_or_err = data and nil or "CBZ 内存解压失败"
            end
        else
            data, ext_or_err = ImageUtil.download_image(item.url, { timeout = 15 })
            if not data and lane == "urgent" then
                Probe.retry("Stream", "图片重试", format_desc(self.chapter, item.page, #self.chapter_imglist), t_batch, tostring(ext_or_err))
                ctx.throw_if_cancelled()
                ctx.sleep(0.5)
                data, ext_or_err = ImageUtil.download_image(item.url, { timeout = 15 })
            end
        end
        ctx.throw_if_cancelled()
        if not data or #data == 0 then return false, ext_or_err or "图片下载失败" end
        return { page = item.page, data = data, size = #data, is_cbz = item.url:match("^cbz://") ~= nil }
    end, {
        engine = "copas",
        concurrency = math.min(math.max(1, configured_concurrency
            - (lane == "prefetch" and 1 or 0)), #items),
        priority = priority,
        on_item = function(item_idx, success, result)
            local page_idx = (result and result.page) or pages[item_idx]
            if not page_idx or batch_cancelled then return end
            self._active_fetches[page_idx] = nil
            if self._is_closed or self._chapter_gen ~= cur_gen then return end

            local desc = format_desc(self.chapter, page_idx, #self.chapter_imglist)
            local has_callbacks = self:_hasPageCallbacks(page_idx)
            local needs_render = lane == "urgent" or has_callbacks
            local download_failed = not (success and result.data and #result.data > 0)
            local bb, size, err_msg

            if not download_failed then
                size = result.size or #result.data
                local cached = self:_putRaw(page_idx, result.data)
                if lane == "prefetch" and not cached then
                    self._prefetch_blocked_center = self.chapter_imglist_cur
                end
                if needs_render then
                    bb = self:_decodePage(page_idx, result.data, size)
                    if not bb then err_msg = "图片解析失败" end
                end

                if not err_msg then
                    self._prefetch_retry_at[page_idx] = nil
                    self._failed_pages[page_idx] = nil
                    Probe.done("Stream", "流式图片就绪", desc, t_batch, "200 OK", Probe.format_bytes(size),
                        string.format("[%s batch=%s lane=%s]", needs_render and "RENDER_READY" or "RAW_READY", batch_id, lane))
                end
            else
                local raw_err = type(result) == "table" and result.err or result
                err_msg = extract_error_str(raw_err or "图片下载失败")
            end

            if download_failed and lane == "prefetch" then
                Probe.fail("Stream", "图片预取失败", desc, t_batch, err_msg)
                if has_callbacks then
                    UIManager:nextTick(function()
                        if self._is_closed or self._chapter_gen ~= cur_gen then return end
                        if self.chapter_imglist_cur ~= page_idx then
                            self._image_callbacks[page_idx] = nil
                            return
                        end
                        self:_startImageBatch({ page_idx }, nil, "urgent")
                    end)
                else
                    self._prefetch_retry_at[page_idx] = H.timestamp() + PREFETCH_RETRY_DELAY
                end
                return
            end

            if err_msg then
                self._failed_pages[page_idx] = err_msg
                Probe.fail("Stream", "图片加载失败", desc, t_batch, err_msg)
            end
            self:_finishPageCallbacks(page_idx, bb, size, err_msg)
        end,
    })
    self._image_batches[lane] = batch_group
    self._image_batch = batch_group
    self._image_batch_pages = pages
    self._image_batch_id = batch_id
    local task = batch_group.task
    if task then
        local terminal_reported = false

        local function clear_batch_state()
            if self._chapter_gen == cur_gen then
                for _, page_idx in ipairs(pages) do
                    self._active_fetches[page_idx] = nil
                end
            end
            if self._image_batches[lane] == batch_group then
                self._image_batches[lane] = nil
            end
        end

        local function refill_prefetch()
            if lane ~= "prefetch" or self._is_closed or self._chapter_gen ~= cur_gen then return end
            UIManager:nextTick(function()
                if self._is_closed or self._chapter_gen ~= cur_gen then return end
                self:prefetchWindow(self.chapter_imglist_cur)
            end)
        end

        local function finalize(refill)
            if terminal_reported then return false end
            terminal_reported = true
            clear_batch_state()
            if refill then refill_prefetch() end
            return true
        end

        local function fail_batch(err)
            if not finalize(false) then return end
            if self._is_closed or self._chapter_gen ~= cur_gen then return end

            local err_msg = extract_error_str(err or "图片批次失败")
            for _, page_idx in ipairs(pages) do
                if lane == "prefetch" then
                    self._prefetch_retry_at[page_idx] = H.timestamp() + PREFETCH_RETRY_DELAY
                    if self:_hasPageCallbacks(page_idx) and self.chapter_imglist_cur == page_idx then
                        local target_page = page_idx
                        UIManager:nextTick(function()
                            if self._is_closed or self._chapter_gen ~= cur_gen then return end
                            self:_startImageBatch({ target_page }, nil, "urgent")
                        end)
                    else
                        self._image_callbacks[page_idx] = nil
                    end
                else
                    self:_finishPageCallbacks(page_idx, nil, 0, err_msg)
                end
            end
            Probe.fail("Stream", "图片批次失败", format_desc(self.chapter), t_batch,
                string.format("batch=%s %s", batch_id, err_msg))
            refill_prefetch()
        end

        task:on("cancel", function(reason)
            if not finalize(false) then return end
            if self._chapter_gen == cur_gen then
                for _, page_idx in ipairs(pages) do
                    if lane == "urgent" or self.chapter_imglist_cur ~= page_idx then
                        self._image_callbacks[page_idx] = nil
                    end
                end
            end
            batch_cancelled = true
            Probe.event("Stream", "取消图片批次",
                string.format("batch=%s lane=%s reason=%s", batch_id, lane, tostring(reason or "cancelled")))
        end)
        task:on("error", fail_batch)
        task:on("timeout", function() fail_batch("timeout") end)
        task:on("finish", function()
            finalize(lane == "prefetch")
        end)
    end
end

function M:fetchSingleImage(page_idx, callback)
    if self._is_closed then return end
    if not (self.chapter_imglist and self.chapter_imglist[page_idx]) then
        if callback then callback(nil, 0, "invalid page index") end
        return
    end

    self._prefetch_retry_at[page_idx] = nil

    local rendered = self._render_cache[page_idx]
    if rendered then
        if callback then callback(rendered.bb, rendered.size, nil) end
        return
    end

    local raw = self._raw_cache[page_idx]
    if raw then
        local bb = self:_decodePage(page_idx, raw.data, raw.size)
        if callback then callback(bb, raw.size, bb and nil or "图片解析失败") end
        return
    end

    self:_startImageBatch({ page_idx }, { [page_idx] = callback }, "urgent")
end

function M:showPage(page_idx)
    if self._is_closed or not self.chapter_imglist then return end
    self.chapter_imglist_cur = page_idx
    local total_p = #self.chapter_imglist
    local desc = format_desc(self.chapter, page_idx, total_p)
    local t_render_start = H.timestamp()

    if self._initial_blank_bb then
        pcall(function() if self._initial_blank_bb.free then self._initial_blank_bb:free() end end)
        self._initial_blank_bb = nil
    end

    if self._render_cache[page_idx] then
        self._first_image_ready = true
        self._failed_pages[page_idx] = nil
        self.image = self._render_cache[page_idx].bb
        self:update()
        self:_trimRenderCache(page_idx)
        Probe.done("Stream", "翻页渲染", desc, t_render_start, "0ms", Probe.format_bytes(self._render_cache[page_idx].size), "[HIT_RENDER 瞬开]")
        self:_markPageDisplayed(page_idx)
        self:prefetchWindow(page_idx)
        return
    end

    Probe.start("Stream", "流式图片请求", desc, tostring(self.chapter_imglist[page_idx]))
    self:fetchSingleImage(page_idx, function(bb, size, err)
        if self._is_closed or self.chapter_imglist_cur ~= page_idx then return end

        if bb then
            self._first_image_ready = true
            self._failed_pages[page_idx] = nil
            self.image = bb
            self:update()
            self:_trimRenderCache(page_idx)
            Probe.done("Stream", "翻页渲染", desc, t_render_start, "200 OK", Probe.format_bytes(size), "[流式就绪]")
            self:_markPageDisplayed(page_idx)
            self:prefetchWindow(page_idx)
        else
            self._first_image_ready = true
            self._failed_pages[page_idx] = extract_error_str(err or "图片加载失败")
            self:update()
        end
    end)
end

function M:prefetchWindow(center_idx)
    if self._is_closed or not self.chapter_imglist then return end
    local total_p = #self.chapter_imglist

    if self._prefetch_blocked_center == center_idx then return end
    if self._prefetch_blocked_center ~= nil then self._prefetch_blocked_center = nil end

    local pending = {}
    for _, target_idx in ipairs({ center_idx + 1, center_idx + 2, center_idx + 3, center_idx - 1 }) do
        if self:_shouldPrefetch(target_idx, total_p) then
            table.insert(pending, target_idx)
        end
    end
    self:_startImageBatch(pending, nil, "prefetch")

    if center_idx >= total_p - 2 and not self._next_chapter_imglist then
        self:prefetchNextChapter()
    end
    if center_idx <= 3 and not self._prev_chapter_imglist then
        self:prefetchPreviousChapter()
    end
end

function M:_prefetchAdjacentChapterRaw(chapter, imglist, page, cross_gen, direction)
    local is_next = direction == "next"
    local batch_field = is_next and "_cross_image_batch" or "_prev_cross_image_batch"
    local raw_field = is_next and "_next_chapter_first_raw" or "_prev_chapter_last_raw"
    local index_field = is_next and "_next_chapter_first_raw_index" or "_prev_chapter_last_raw_index"
    if self._is_closed or self[batch_field] or not (chapter and imglist and imglist[page]) then return end
    local url = imglist[page]
    local chapter_index = tonumber(chapter.chapters_index)
    if type(url) ~= "string" or url == "" or not chapter_index then return end

    local batch_cancelled = false
    local batch = TaskQueueV2.batch({ { page = page, url = url } }, function(item, _, ctx)
        ctx.throw_if_cancelled()
        local data, err = ImageUtil.download_image(item.url, { timeout = 15 })
        ctx.throw_if_cancelled()
        if not data or #data == 0 then return false, err or "跨章图片下载失败" end
        return { data = data, size = #data }
    end, {
        engine = "copas", concurrency = 1, priority = 5,
        on_item = function(_, success, result)
            if batch_cancelled or not success or self._is_closed or self._chapter_gen ~= cross_gen then return end
            if not (result and result.data and #result.data > 0) then return end
            self[raw_field] = { data = result.data, size = result.size or #result.data }
            self[index_field] = chapter_index
            Probe.event("Stream", is_next and "跨章首图就绪" or "向前跨章末图就绪",
                string.format("chapter=%d page=%d size=%d [%s_RAW_READY]", chapter_index, page, result.size or 0,
                    is_next and "CROSS_FIRST" or "CROSS_LAST"))
        end,
    })
    self[batch_field] = batch
    if batch.task then
        batch.task:on("cancel", function()
            batch_cancelled = true
            if self[batch_field] == batch then self[batch_field] = nil end
        end)
        batch.task:on("finish", function()
            if self[batch_field] == batch then self[batch_field] = nil end
        end)
        batch.task:on("error", function()
            if self[batch_field] == batch then self[batch_field] = nil end
        end)
    end
end

function M:prefetchNextChapter()
    if self._is_closed then return end
    local next_ch = find_adjacent_chapter(self.chapter, "next")
    if next_ch and next_ch.chapters_index then
        self._next_chapter_info = next_ch
        local cross_gen = self._chapter_gen
        local t_cross_start = Probe.start("Stream", "跨章图源预取", format_desc(next_ch))
        self:pushStreamTask(function()
            return Backend:getChapterImgList(next_ch)
        end, function(list)
            if self._is_closed then return end
            if H.is_tbl(list) and #list > 0 and self._chapter_gen == cross_gen then
                self._next_chapter_imglist = list
                self._next_chapter_imglist_index = tonumber(next_ch.chapters_index)
                self:_prefetchAdjacentChapterRaw(next_ch, list, 1, cross_gen, "next")
                Probe.done("Stream", "跨章图源预取", format_desc(next_ch), t_cross_start, "200 OK", nil,
                    string.format("共 %d P [CROSS_READY]", #list))
            end
        end)
    end
end

function M:prefetchPreviousChapter()
    if self._is_closed then return end
    local prev_ch = find_adjacent_chapter(self.chapter, "prev")
    if not (prev_ch and prev_ch.chapters_index) then return end
    self._prev_chapter_info = prev_ch
    local cross_gen = self._chapter_gen
    local t_cross_start = Probe.start("Stream", "向前跨章图源预取", format_desc(prev_ch))
    self:pushStreamTask(function()
        return Backend:getChapterImgList(prev_ch)
    end, function(list)
        if self._is_closed then return end
        if H.is_tbl(list) and #list > 0 and self._chapter_gen == cross_gen then
            self._prev_chapter_imglist = list
            self._prev_chapter_imglist_index = tonumber(prev_ch.chapters_index)
            self:_prefetchAdjacentChapterRaw(prev_ch, list, #list, cross_gen, "prev")
            Probe.done("Stream", "向前跨章图源预取", format_desc(prev_ch), t_cross_start, "200 OK", nil,
                string.format("共 %d P [CROSS_PREV_READY]", #list))
        end
    end)
end

function M:createErrorPlaceholder(page_idx, err_msg)
    self._failed_pages[page_idx] = err_msg or "图片加载失败"
    return nil
end

function M:retryCurrentPage()
    if self._chapter_error then
        self._chapter_error = nil
        MessageBox:notice("正在重新拉取章节图源...")
        self:loadChapter(self.chapter, self.chapter_imglist_cur)
        return
    end
    local cur = self.chapter_imglist_cur
    if not cur then return end
    self._failed_pages[cur] = nil
    self._prefetch_retry_at[cur] = nil
    self._active_fetches[cur] = nil
    MessageBox:notice("正在重新拉取...")
    self:showPage(cur)
end

function M:onShowNextImage()
    if not self.chapter_imglist then return end
    local next_idx = self.chapter_imglist_cur + 1
    if next_idx <= #self.chapter_imglist then
        self:showPage(next_idx)
    else
        self:transitionToChapter("next")
    end
end

function M:onShowPrevImage()
    if not self.chapter_imglist then return end
    local prev_idx = self.chapter_imglist_cur - 1
    if prev_idx >= 1 then
        self:showPage(prev_idx)
    else
        self:transitionToChapter("prev")
    end
end

function M:transitionToChapter(dir)
    if self._is_closed then return end
    local target_ch = (dir == "next" and self._next_chapter_info)
        or (dir == "prev" and self._prev_chapter_info)
        or find_adjacent_chapter(self.chapter, dir)
    if target_ch and target_ch.chapters_index then
        local target_page = (dir == "next") and 1 or 9999
        self:loadChapter(target_ch, target_page)
    else
        MessageBox:notice(dir == "next" and "已经是最后一章" or "已经是第一章")
    end
end

function M:onTap(_, ges)
    local w = Screen:getWidth()
    local x = ges.pos.x

    if self._chapter_error or (self._failed_pages and self._failed_pages[self.chapter_imglist_cur]) then
        if x >= w / 3 and x <= w * 2 / 3 then
            if self._chapter_error and H.is_func(self.on_fallback_callback) then
                MessageBox:confirm("图源不可用。可重试，或使用普通阅读器打开本章。", function(use_reader)
                    if use_reader then
                        local callback = self.on_fallback_callback
                        self.on_return_callback = nil
                        self.on_fallback_callback = nil
                        self:onClose()
                        UIManager:nextTick(callback)
                    else
                        self:retryCurrentPage()
                    end
                end, {
                    ok_text = "普通阅读",
                    cancel_text = "重试",
                })
            else
                self:retryCurrentPage()
            end
            return true
        end
    end

    if x < w / 3 then
        self:onShowPrevImage()
    elseif x > w * 2 / 3 then
        self:onShowNextImage()
    else
        self:toggleFillMode()
    end
    return true
end

function M:onSwipe(_, ges)
    local direction = ges.direction
    if direction == "south" then
        self:onClose()
        return true
    elseif direction == "west" then
        self:onShowNextImage()
        return true
    elseif direction == "east" then
        self:onShowPrevImage()
        return true
    end
    return ImageViewer.onSwipe(self, _, ges)
end

function M:onSpread(_, ges)
    if not self._image_wg then return true end
    return ImageViewer.onSpread(self, _, ges)
end

function M:onPinch(_, ges)
    if not self._image_wg then return true end
    return ImageViewer.onPinch(self, _, ges)
end

function M:onZoomIn(inc)
    if not self._image_wg then return true end
    return ImageViewer.onZoomIn(self, inc)
end

function M:onZoomOut(dec)
    if not self._image_wg then return true end
    return ImageViewer.onZoomOut(self, dec)
end

function M:toggleFillMode()
    local modes = { "cover", "contain", "stretch" }
    local cur_idx = 1
    for i, m in ipairs(modes) do
        if m == self._fullscreen_fill then cur_idx = i break end
    end
    self._fullscreen_fill = modes[(cur_idx % #modes) + 1]
    MessageBox:notice(string.format("填充模式: %s", self._fullscreen_fill))
    self:update()
end

function M:_cancelProgressTimer()
    if not self._save_progress_timer then return end
    self._save_progress_timer()
    self._save_progress_timer = nil
end

function M:_markPageDisplayed(page_idx)
    self._last_displayed_page = page_idx
    self:scheduleSaveProgress(page_idx)
end

function M:_flushProgress()
    self:_cancelProgressTimer()
    if not (self.chapter and self._last_displayed_page) then return end
    self:persistProgress(self.chapter, self._last_displayed_page)
end

function M:scheduleSaveProgress(page_idx)
    self:_cancelProgressTimer()

    local chapter = self.chapter
    local gen = self._chapter_gen
    self._save_progress_timer = TaskQueueV2.delay(2.0, function()
        self._save_progress_timer = nil
        if self._is_closed
                or self._chapter_gen ~= gen
                or self.chapter ~= chapter
                or self._last_displayed_page ~= page_idx then
            return
        end
        self:persistProgress(chapter, page_idx)
    end)
end

function M:persistProgress(chapter, page_idx)
    if not (chapter and chapter.book_cache_id and page_idx) then return end
    local book_cache_id = chapter.book_cache_id
    local ch_idx = chapter.chapters_index
    local ch_title = chapter.title or chapter.name or ""

    pcall(function()
        local bookShelfId = Backend:getCurrentBookShelfId()
        if Backend.dbManager and Backend.dbManager.transaction then
            Backend.dbManager:transaction(function()
                if Backend.dbManager.updateIsRead then
                    Backend.dbManager:updateIsRead(chapter, true, true)
                end
                if Backend.dbManager.updateReadingProgress then
                    Backend.dbManager:updateReadingProgress(bookShelfId, book_cache_id, ch_idx, ch_title, page_idx)
                end
            end)()
        end
    end)
    local total = self.chapter == chapter and self.chapter_imglist and #self.chapter_imglist or nil
    Probe.done("Stream", "进度持久化", format_desc(chapter, page_idx, total), nil, "200 OK", nil,
        string.format("durChapterPos=%d", page_idx))
end

function M:clearImageCaches()
    if self._initial_blank_bb then
        if self._initial_blank_bb.free then pcall(self._initial_blank_bb.free, self._initial_blank_bb) end
        self._initial_blank_bb = nil
    end
    for _, entry in pairs(self._render_cache or {}) do
        if entry.bb and entry.bb.free then
            pcall(entry.bb.free, entry.bb)
        end
    end
    self._render_cache = {}
    self._raw_cache = {}
    self._raw_cache_bytes = 0
    self._prefetch_retry_at = {}
    self._prefetch_blocked_center = nil
end

function M:onClose()
    if self._is_closed then return end
    self:_flushProgress()
    self._is_closed = true
    if self._channel then
        pcall(function() self._channel:shutdown("viewer_closed") end)
        if self._channel_name then
            pcall(TaskQueueV2.destroyChannel, self._channel_name)
        end
        self._channel = nil
        self._channel_name = nil
    end
    if self._cross_image_batch then
        pcall(function() self._cross_image_batch.cancel("viewer_closed") end)
        self._cross_image_batch = nil
    end
    self._next_chapter_first_raw = nil
    self._next_chapter_first_raw_index = nil
    if self._prev_cross_image_batch then
        pcall(function() self._prev_cross_image_batch.cancel("viewer_closed") end)
        self._prev_cross_image_batch = nil
    end
    self._prev_chapter_last_raw = nil
    self._prev_chapter_last_raw_index = nil
    if self._image_batches then
        for lane, batch in pairs(self._image_batches) do
            if batch then pcall(function() batch.cancel("viewer_closed") end) end
            self._image_batches[lane] = nil
        end
    elseif self._image_batch then
        pcall(function() self._image_batch.cancel("viewer_closed") end)
    end
    self._image_batch = nil
    self._image_batch_pages = nil
    self._image_batch_id = nil
    self._image_callbacks = {}
    self:clearImageCaches()
    Probe.done("Stream", "退出流式漫画", format_desc(self.chapter, self.chapter_imglist_cur, self.chapter_imglist and #self.chapter_imglist))
    ImageViewer.onClose(self)
    if H.is_func(self.on_return_callback) then
        local ok, err = pcall(self.on_return_callback)
        if not ok then logger.err("StreamImageView:onClose callback failed:", err) end
    end
end

return M
