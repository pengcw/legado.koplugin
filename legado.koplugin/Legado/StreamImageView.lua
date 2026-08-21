local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local RenderImage = require("ui/renderimage")
local ImageViewer = require("ui/widget/imageviewer")
local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
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

    -- 首图是否已就绪（未就绪前显示优雅的加载卡片）
    _first_image_ready = false,

    -- 内存滑动窗口 LRU：[page_idx] = { bb = BlitBuffer, data = string, size = num }
    _mem_cache = nil,
    _active_fetches = nil,
    _failed_pages = nil,

    -- 跨章预取缓存
    _next_chapter_info = nil,
    _next_chapter_imglist = nil,
    _prev_chapter_info = nil,
    _prev_chapter_imglist = nil,

    -- 章节生命周期 Generation 标记（防止跨章图片回调泄漏与脏状态写入）
    _chapter_gen = 0,
    _initial_blank_bb = nil,

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

function M:init()
    self._mem_cache = self._mem_cache or {}
    self._active_fetches = self._active_fetches or {}
    self._failed_pages = self._failed_pages or {}
    self._is_closed = (self._is_closed == true)
    self._first_image_ready = (self._first_image_ready == true)
    self._chapter_gen = self._chapter_gen or 0

    self.fullscreen = true
    self.with_title_bar = false
    self.image_disposable = false
    self.image_padding = 0

    -- 初始化空白画布，防止 ImageViewer:init() -> ImageWidget:init() 因 image 为空抛出 attempt to index field '_bb'
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

    -- 章节图源拉取失败：展示图源错误重试卡片
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

    -- 当前页拉取失败：展示单页错误重试卡片
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

    -- 首图尚未就绪时，展示居中加载卡片
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
            sf = 0 -- contain
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
        -- 限制滑动窗口后台并发数为 2，防止快速翻页引发进程争抢与收集延迟
        self._channel = TaskQueue:createChannel("stream_ch_" .. tostring(socket.gettime()):gsub("%.", ""), 2, nil)
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
    self._first_image_ready = false
    self._failed_pages = {}
    self._chapter_error = nil
    self._chapter_gen = (self._chapter_gen or 0) + 1

    -- 切章时强行清空上一章节的在途后台任务，释放管道与带宽
    if self._channel then
        pcall(function() self._channel:clearTasks() end)
    end
    self._active_fetches = {}

    -- 清空当前章节的内存位图缓存
    self:clearMemCache()
    self:update()

    local cur_gen = self._chapter_gen
    local t_open_start = Probe.start("Stream", "打开流式漫画", format_desc(chapter), string.format("起始页: %d", self.chapter_imglist_cur))
    local t_src_start = Probe.start("Stream", "拉取章节图源", format_desc(chapter))

    -- 异步拉取章节图片 URL 列表
    self:pushStreamTask(function()
        local list, err_msg = Backend:getChapterImgList(chapter)
        return { list = list, err_msg = err_msg }
    end, function(result, err)
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

        Probe.done("Stream", "章节图源就绪", format_desc(chapter), t_src_start, "200 OK", nil, string.format("共 %d P", total_p))

        -- 标记已读并保存进度
        self:persistProgress(self.chapter_imglist_cur)

        -- 立即呈现当前页
        self:showPage(self.chapter_imglist_cur)

        -- 启动滑动窗口后台预取
        self:prefetchWindow(self.chapter_imglist_cur)
    end, { insert_at_head = true })
end

function M:readSecondaryCache(chapter, page_idx, url)
    return nil
end

function M:writeSecondaryCache(chapter, page_idx, url, data)
end

function M:fetchSingleImage(page_idx, callback)
    if self._is_closed then return end
    if not (self.chapter_imglist and self.chapter_imglist[page_idx]) then
        if callback then callback(nil, 0, "invalid page index") end
        return
    end

    -- 检查内存缓存
    if self._mem_cache[page_idx] then
        if callback then callback(self._mem_cache[page_idx].bb, self._mem_cache[page_idx].size, nil) end
        return
    end

    local url = self.chapter_imglist[page_idx]
    local desc = format_desc(self.chapter, page_idx, #self.chapter_imglist)
    local t_fetch_start = socket.gettime()
    local cur_gen = self._chapter_gen

    -- 检查二级扩展缓存 (预留扩展，默认纯内存流返回 nil)
    local cached_data = self:readSecondaryCache(self.chapter, page_idx, url)
    if cached_data and #cached_data > 0 then
        local bb = RenderImage:renderImageData(cached_data, #cached_data, false)
        if bb then
            if self._is_closed or self._chapter_gen ~= cur_gen then
                if bb.free then pcall(bb.free, bb) end
                return
            end
            self._mem_cache[page_idx] = { bb = bb, data = cached_data, size = #cached_data }
            Probe.done("Stream", "流式图片就绪", desc, t_fetch_start, "200 OK", Probe.format_bytes(#cached_data), "[HIT_CACHE]")
            if callback then callback(bb, #cached_data, nil) end
            return
        end
    end

    if self._active_fetches[page_idx] then return end
    self._active_fetches[page_idx] = true

    self:pushStreamTask(function()
        if url:match("^cbz://") then
            local cbz_path, entry_name = url:match("^cbz://(.-)#(.*)$")
            if cbz_path and entry_name then
                local ZipUtil = require("Legado.Helper.ZipUtil")
                local reader = ZipUtil.Reader:new()
                if reader and reader.open and reader:open(cbz_path) then
                    local data = reader:extractToMemory(entry_name)
                    if data and #data > 0 then
                        return { data = data, is_cbz = true }
                    end
                end
                return nil, "CBZ 内存解压失败"
            end
        end

        local data, ext_or_err = ImageUtil.download_image(url, { timeout = 15 })
        if not data then
            Probe.retry("Stream", "单图重试", desc, t_fetch_start, tostring(ext_or_err))
            socket.sleep(0.5)
            data, ext_or_err = ImageUtil.download_image(url, { timeout = 15 })
        end
        return { data = data, err = ext_or_err, is_cbz = false }
    end, function(res, err)
        self._active_fetches[page_idx] = nil
        if self._is_closed or self._chapter_gen ~= cur_gen then return end

        if res and res.data and #res.data > 0 then
            self:writeSecondaryCache(self.chapter, page_idx, url, res.data)

            local bb = RenderImage:renderImageData(res.data, #res.data, false)
            if bb then
                if self._is_closed or self._chapter_gen ~= cur_gen then
                    if bb.free then pcall(bb.free, bb) end
                    return
                end
                self._mem_cache[page_idx] = { bb = bb, data = res.data, size = #res.data }
                self._failed_pages[page_idx] = nil
                local hit_tag = res.is_cbz and "[HIT_CBZ_MEM]" or "[ASYNC]"
                Probe.done("Stream", "流式图片就绪", desc, t_fetch_start, "200 OK", Probe.format_bytes(#res.data), hit_tag)
                if callback then callback(bb, #res.data, nil) end
                return
            end
        end

        local err_msg = extract_error_str((res and res.err) or err or "图片解析失败")
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

    -- 释放初始化时的白色空白底图
    if self._initial_blank_bb then
        pcall(function() if self._initial_blank_bb.free then self._initial_blank_bb:free() end end)
        self._initial_blank_bb = nil
    end

    if self._mem_cache[page_idx] then
        self._first_image_ready = true
        self._failed_pages[page_idx] = nil
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
            self._first_image_ready = true
            self._failed_pages[page_idx] = nil
            self.image = bb
            self:update()
            Probe.done("Stream", "翻页渲染", desc, t_render_start, "200 OK", Probe.format_bytes(size), "[流式就绪]")
            self:scheduleSaveProgress(page_idx)
            self:prefetchWindow(page_idx)
        else
            -- 记录错误并刷新呈现交互重试卡片
            self._first_image_ready = true
            self._failed_pages[page_idx] = extract_error_str(err or "图片加载失败")
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

    -- 若当前处于失败状态（章节图源失败 或 单页图片失败），点击中央区域触发重新拉取
    if self._chapter_error or (self._failed_pages and self._failed_pages[self.chapter_imglist_cur]) then
        if x >= w / 3 and x <= w * 2 / 3 then
            self:retryCurrentPage()
            return true
        end
    end

    -- 三区分割触控
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

    pcall(function()
        local bookShelfId = Backend:getCurrentBookShelfId()
        if Backend.dbManager and Backend.dbManager.transaction then
            Backend.dbManager:transaction(function()
                if Backend.dbManager.updateIsRead then
                    Backend.dbManager:updateIsRead(self.chapter, true, true)
                end
                if Backend.dbManager.updateReadingProgress then
                    Backend.dbManager:updateReadingProgress(bookShelfId, book_cache_id, ch_idx, ch_title, page_idx)
                end
            end)()
        end
    end)
    Probe.done("Stream", "进度持久化", format_desc(self.chapter, page_idx, self.chapter_imglist and #self.chapter_imglist), nil, "200 OK", nil, string.format("durChapterPos=%d", page_idx))
end

function M:clearMemCache()
    if self._initial_blank_bb then
        if self._initial_blank_bb.free then pcall(self._initial_blank_bb.free, self._initial_blank_bb) end
        self._initial_blank_bb = nil
    end
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
