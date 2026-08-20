local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local logger = require("logger")
local socket = require("socket")
local util = require("util")

local MessageBox = require("Legado/MessageBox")
local Backend = require("Legado/Backend")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")
local ImageUtil = require("Legado.Helper.ImageUtil")
local Probe = require("Legado.Helper.Probe")
local TaskQueue = require("Legado.task.Queue")

local M = ImageViewer:extend{
    bookinfo = nil,
    chapter = nil,
    chapter_imglist = nil,
    chapter_imglist_cur = 1,
    on_return_callback = nil,

    -- 全屏填充模式：cover（铺满裁剪，默认）| contain（完整适配）| stretch（拉伸填满）
    _fullscreen_fill = "cover",

    -- 内存滑动窗口 LRU：[page_idx] = { bb = BlitBuffer, data = string, size = num }
    _mem_cache = nil,
    _active_fetches = nil,
    _failed_pages = nil,

    -- 跨章预取缓存
    _next_chapter_info = nil,
    _next_chapter_imglist = nil,
    _prev_chapter_info = nil,
    _prev_chapter_imglist = nil,

    -- 进度防抖计时器
    _save_progress_timer = nil,
    _is_closed = false,
}

local function format_desc(chapter, page_idx, total)
    local ch_title = chapter and (chapter.title or chapter.name or "") or ""
    local idx = chapter and chapter.chapters_index or 0
    if page_idx and total then
        return string.format("第%d章_%d/%dP %s", idx, page_idx, total, ch_title)
    end
    return string.format("第%d章 %s", idx, ch_title)
end

function M:init()
    self._mem_cache = {}
    self._active_fetches = {}
    self._failed_pages = {}
    self._is_closed = false

    self.fullscreen = true
    self.with_title_bar = false
    self.image_disposable = true
    self.image_padding = 0

    ImageViewer.init(self)
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

    -- 断点续读：若书本当前记录正是本章，继承上次的页码位置
    local start_page = 1
    if bookinfo and bookinfo.durChapterIndex == chapter.chapters_index and tonumber(bookinfo.durChapterPos) then
        start_page = math.max(1, tonumber(bookinfo.durChapterPos))
    end

    local viewer = M:new{
        chapter = chapter,
        bookinfo = bookinfo,
        on_return_callback = options.on_return_callback,
    }

    UIManager:show(viewer)
    viewer:loadChapter(chapter, start_page)
    return viewer
end

function M:getChannel()
    if not self._channel then
        self._channel = TaskQueue:createChannel("stream_ch_" .. tostring(socket.gettime()):gsub("%.", ""), 3, nil)
    end
    return self._channel
end

function M:pushStreamTask(task_func, callback, opts)
    if self._is_closed then return end
    opts = opts or {}
    self:getChannel():pushTask(task_func, function(ok, res, r2)
        if self._is_closed then return end
        if callback then
            callback(ok and res or nil, not ok and tostring(res) or r2)
        end
    end, opts)
end

function M:loadChapter(chapter, start_page)
    if self._is_closed then return end
    self.chapter = chapter
    self.chapter_imglist = nil
    self.chapter_imglist_cur = start_page or 1
    self._failed_pages = {}

    -- 清空当前章节的内存位图缓存
    self:clearMemCache()

    local t_open_start = Probe.start("Stream", "打开流式漫画", format_desc(chapter), string.format("起始页: %d", self.chapter_imglist_cur))
    local t_src_start = Probe.start("Stream", "拉取章节图源", format_desc(chapter))

    -- 异步拉取章节图片 URL 列表
    self:pushStreamTask(function()
        local list, err_msg = Backend:getChapterImgList(chapter)
        return { list = list, err_msg = err_msg }
    end, function(result, err)
        if self._is_closed then return end

        if not (result and H.is_tbl(result.list) and #result.list > 0) then
            local err_msg = (result and result.err_msg) or err or "获取章节图源失败"
            Probe.fail("Stream", "章节图源失败", format_desc(chapter), t_src_start, tostring(err_msg))
            MessageBox:notice("加载失败", tostring(err_msg))
            return
        end

        self.chapter_imglist = result.list
        self.chapter_imglist_cur = math.min(#self.chapter_imglist, math.max(1, self.chapter_imglist_cur))
        local total_p = #self.chapter_imglist

        Probe.done("Stream", "章节图源就绪", format_desc(chapter), t_src_start, "200 OK", nil, string.format("共 %d P", total_p))

        -- 标记已读并保存进度
        self:persistProgress(self.chapter_imglist_cur)

        -- 立即呈现当前页
        self:showPage(self.chapter_imglist_cur)

        -- 启动滑动窗口后台预取
        self:prefetchWindow(self.chapter_imglist_cur)
    end, { insert_at_head = true })
end

function M:getDiskCachePath(chapter, page_idx)
    local book_id = chapter and chapter.book_cache_id or "default"
    local ch_idx = chapter and chapter.chapters_index or 0
    local dir = FS.joinPath(Env.getTempDirectory(), "stream_cache", tostring(book_id))
    FS.checkAndCreateFolder(dir)
    return FS.joinPath(dir, string.format("%d_%d.raw", ch_idx, page_idx))
end

function M:fetchSingleImage(page_idx, callback)
    if self._is_closed then return end
    if not (self.chapter_imglist and self.chapter_imglist[page_idx]) then
        if callback then callback(nil, 0, "invalid page index") end
        return
    end

    -- 1. 检查内存缓存
    if self._mem_cache[page_idx] then
        if callback then callback(self._mem_cache[page_idx].bb, self._mem_cache[page_idx].size, nil) end
        return
    end

    local url = self.chapter_imglist[page_idx]
    local disk_path = self:getDiskCachePath(self.chapter, page_idx)
    local desc = format_desc(self.chapter, page_idx, #self.chapter_imglist)
    local t_fetch_start = socket.gettime()

    -- 2. 检查本地磁盘缓存
    if util.fileExists(disk_path) then
        local f = io.open(disk_path, "rb")
        if f then
            local data = f:read("*a")
            f:close()
            if data and #data > 0 then
                local bb = RenderImage:renderImageData(data, #data, false)
                if bb then
                    self._mem_cache[page_idx] = { bb = bb, data = data, size = #data }
                    Probe.done("Stream", "流式图片就绪", desc, t_fetch_start, "200 OK", Probe.format_bytes(#data), "[HIT_DISK]")
                    if callback then callback(bb, #data, nil) end
                    return
                end
            end
        end
    end

    -- 3. 网络异步拉取
    if self._active_fetches[page_idx] then return end
    self._active_fetches[page_idx] = true

    self:pushStreamTask(function()
        local data, ext_or_err = ImageUtil.download_image(url, { timeout = 15 })
        -- 单图网络失败自动退避重试 1 次
        if not data then
            Probe.retry("Stream", "单图重试", desc, t_fetch_start, tostring(ext_or_err))
            socket.sleep(0.5)
            data, ext_or_err = ImageUtil.download_image(url, { timeout = 15 })
        end
        return { data = data, err = ext_or_err }
    end, function(res, err)
        self._active_fetches[page_idx] = nil
        if self._is_closed then return end

        if res and res.data and #res.data > 0 then
            -- 写入轻量磁盘缓存
            pcall(util.writeToFile, res.data, disk_path, true)

            local bb = RenderImage:renderImageData(res.data, #res.data, false)
            if bb then
                self._mem_cache[page_idx] = { bb = bb, data = res.data, size = #res.data }
                self._failed_pages[page_idx] = nil
                Probe.done("Stream", "流式图片就绪", desc, t_fetch_start, "200 OK", Probe.format_bytes(#res.data), "[ASYNC]")
                if callback then callback(bb, #res.data, nil) end
                return
            end
        end

        local err_msg = (res and res.err) or err or "图片解析失败"
        self._failed_pages[page_idx] = err_msg
        Probe.fail("Stream", "图片加载失败", desc, t_fetch_start, tostring(err_msg))
        if callback then callback(nil, 0, err_msg) end
    end, { insert_at_head = (callback ~= nil) })
end

function M:showPage(page_idx)
    if self._is_closed or not self.chapter_imglist then return end
    self.chapter_imglist_cur = page_idx
    local total_p = #self.chapter_imglist
    local desc = format_desc(self.chapter, page_idx, total_p)
    local t_render_start = socket.gettime()

    -- 检查内存命中
    if self._mem_cache[page_idx] then
        self.image = self._mem_cache[page_idx].bb
        self:update()
        Probe.done("Stream", "翻页渲染", desc, t_render_start, "0ms", Probe.format_bytes(self._mem_cache[page_idx].size), "[HIT_MEM 瞬开]")
        self:scheduleSaveProgress(page_idx)
        self:prefetchWindow(page_idx)
        return
    end

    -- 未命中内存：触发最高优先级流式拉取
    Probe.start("Stream", "流式图片请求", desc, tostring(self.chapter_imglist[page_idx]))
    self:fetchSingleImage(page_idx, function(bb, size, err)
        if self._is_closed or self.chapter_imglist_cur ~= page_idx then return end

        if bb then
            self.image = bb
            self:update()
            Probe.done("Stream", "翻页渲染", desc, t_render_start, "200 OK", Probe.format_bytes(size), "[流式就绪]")
            self:scheduleSaveProgress(page_idx)
            self:prefetchWindow(page_idx)
        else
            -- 错误降级占位屏
            self.image = self:createErrorPlaceholder(page_idx, err)
            self:update()
        end
    end)
end

function M:prefetchWindow(center_idx)
    if self._is_closed or not self.chapter_imglist then return end
    local total_p = #self.chapter_imglist

    -- 滑动窗口：优先向后预取 3 页，向前预取 1 页 [center+1, center+2, center+3, center-1]
    local targets = { center_idx + 1, center_idx + 2, center_idx + 3, center_idx - 1 }
    for _, target_idx in ipairs(targets) do
        if target_idx >= 1 and target_idx <= total_p then
            if not self._mem_cache[target_idx] and not self._active_fetches[target_idx] then
                self:fetchSingleImage(target_idx, nil)
            end
        end
    end

    -- 内存 LRU 淘汰：释放距离中心超过 4 页的位图
    for cached_idx, entry in pairs(self._mem_cache) do
        if math.abs(cached_idx - center_idx) > 4 then
            if entry and entry.bb and entry.bb.free then
                pcall(entry.bb.free, entry.bb)
            end
            self._mem_cache[cached_idx] = nil
        end
    end

    -- 跨章智能预取：当读到当前章最后 2 页时，自动异步预取下一章图源
    if center_idx >= total_p - 2 and not self._next_chapter_imglist then
        self:prefetchNextChapter()
    end
end

function M:prefetchNextChapter()
    if self._is_closed then return end
    local next_ch = Backend:findNextChapter(self.chapter, nil)
    if next_ch and next_ch.chapters_index then
        self._next_chapter_info = next_ch
        local t_cross_start = Probe.start("Stream", "跨章图源预取", format_desc(next_ch))
        self:pushStreamTask(function()
            return Backend:getChapterImgList(next_ch)
        end, function(list)
            if self._is_closed then return end
            if H.is_tbl(list) and #list > 0 then
                self._next_chapter_imglist = list
                Probe.done("Stream", "跨章图源预取", format_desc(next_ch), t_cross_start, "200 OK", nil, string.format("共 %d P", #list))
            end
        end)
    end
end

function M:createErrorPlaceholder(page_idx, err_msg)
    local fallback = RenderImage:renderImageFile("resources/koreader.png", false)
    return fallback
end

function M:onShowNextImage()
    if not self.chapter_imglist then return end
    local next_idx = self.chapter_imglist_cur + 1
    if next_idx <= #self.chapter_imglist then
        self:showPage(next_idx)
    else
        -- 跨入下一章
        self:transitionToChapter("next")
    end
end

function M:onShowPrevImage()
    if not self.chapter_imglist then return end
    local prev_idx = self.chapter_imglist_cur - 1
    if prev_idx >= 1 then
        self:showPage(prev_idx)
    else
        -- 跨入上一章
        self:transitionToChapter("prev")
    end
end

function M:transitionToChapter(dir)
    if self._is_closed then return end
    local target_ch = (dir == "next" and self._next_chapter_info) or Backend:findNextChapter(self.chapter, nil)
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

    -- 经典三区分割触控（参考 ArtGallery）
    if x < w / 3 then
        self:onShowPrevImage()
    elseif x > w * 2 / 3 then
        self:onShowNextImage()
    else
        -- 中央区域：呼出/隐藏沉浸式信息与填充切换
        self:toggleFillMode()
    end
    return true
end

function M:onSwipe(_, ges)
    local direction = ges.direction
    if direction == "south" then
        -- 向下滑动退出流式漫画
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

function M:scheduleSaveProgress(page_idx)
    if self._save_progress_timer then
        self._save_progress_timer()
        self._save_progress_timer = nil
    end

    self._save_progress_timer = TaskQueue.delay(2.0, function()
        self._save_progress_timer = nil
        self:persistProgress(page_idx)
    end)
end

function M:persistProgress(page_idx)
    if not (self.chapter and self.chapter.book_cache_id) then return end
    local book_cache_id = self.chapter.book_cache_id
    local ch_idx = self.chapter.chapters_index
    local ch_title = self.chapter.title or self.chapter.name or ""
    local bookShelfId = Backend:getCurrentBookShelfId()

    pcall(function()
        Backend.dbManager:transaction(function()
            Backend.dbManager:updateIsRead(self.chapter, true, true)
            Backend.dbManager:updateReadingProgress(bookShelfId, book_cache_id, ch_idx, ch_title, page_idx)
        end)()
    end)
    Probe.done("Stream", "进度持久化", format_desc(self.chapter, page_idx, self.chapter_imglist and #self.chapter_imglist), nil, "200 OK", nil, string.format("durChapterPos=%d", page_idx))
end

function M:clearMemCache()
    if self._mem_cache then
        for _, entry in pairs(self._mem_cache) do
            if entry and entry.bb and entry.bb.free then
                pcall(entry.bb.free, entry.bb)
            end
        end
    end
    self._mem_cache = {}
end

function M:onClose()
    if self._is_closed then return end
    self._is_closed = true

    if self._channel then
        pcall(function() self._channel:abortDrain() end)
        self._channel = nil
    end

    if self._save_progress_timer then
        self._save_progress_timer()
        self._save_progress_timer = nil
    end

    -- 退出时立即持久化最新页码进度
    self:persistProgress(self.chapter_imglist_cur)

    -- 释放所有位图资源
    self:clearMemCache()

    Probe.done("Stream", "退出流式漫画", format_desc(self.chapter, self.chapter_imglist_cur, self.chapter_imglist and #self.chapter_imglist))

    ImageViewer.onClose(self)
    if H.is_func(self.on_return_callback) then
        self.on_return_callback()
    end
end

return M
