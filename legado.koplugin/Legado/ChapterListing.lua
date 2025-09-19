local BD = require("ui/bidi")
local Font = require("ui/font")
local util = require("util")
local logger = require("logger")
local dbg = require("dbg")
local Blitbuffer = require("ffi/blitbuffer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local time = require("ui/time")
local SpinWidget = require("ui/widget/spinwidget")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = Device.screen

local Backend = require("Legado/Backend")
local Icons = require("Legado/Icons")
local MessageBox = require("Legado/MessageBox")
local StreamImageView = require("Legado/StreamImageView")
local H = require("Legado/Helper")

if not dbg.log then
    dbg.log = logger.dbg
end

local ChapterListing = Menu:extend{
    name = "chapter_listing",
    title = "catalogue",
    align_baselines = true,
    is_borderless = true,
    line_color = Blitbuffer.COLOR_WHITE,
    -- can't be 0 → no key move indicator
    -- linesize = 0,
    covers_fullscreen = true,
    single_line = true,
    toc_items_per_page_default = 14,
    title_bar_left_icon = "appbar.menu",
    title_bar_fm_style = true,

    bookinfo = nil,
    chapter_sorting_mode = nil,
    all_chapters_count = nil,
    on_return_callback = nil,
    on_show_chapter_callback = nil,
    ui_refresh_time = nil,
    refresh_menu_key = nil,
}

function ChapterListing:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.onLeftButtonTap = function()
        self:openMenu()
    end

    Menu.init(self)
    
    
    if Device:hasKeys() then
        self.refresh_menu_key = "Home"
        if Device:hasKeyboard() then
            self.refresh_menu_key = "F5"
        end
        self.key_events.RefreshChapters = {{ self.refresh_menu_key }}
    end

    if Device:hasDPad() then
        self.key_events.FocusRight = nil
        self.key_events.Right = {{ "Right" }}
    end

    self.ui_refresh_time = os.time()
    self:refreshItems()
end

function ChapterListing:refreshItems(no_recalculate_dimen)

    local book_cache_id = self.bookinfo.cache_id
    local chapter_cache_data = Backend:getBookChapterCache(book_cache_id)

    if H.is_tbl(chapter_cache_data) and #chapter_cache_data > 0 then
        self.item_table = self:generateItemTableFromChapters(chapter_cache_data)
        self.multilines_show_more_text = false
        self.items_per_page = nil
        self.single_line = true
    else
        self.item_table = self:generateEmptyViewItemTable()
        self.multilines_show_more_text = true
        self.items_per_page = 1
        self.single_line = false
    end
    Menu.updateItems(self, nil, no_recalculate_dimen)
    self:gotoLastReadChapter()
end

function ChapterListing:generateEmptyViewItemTable()
    local hint = (self.refresh_menu_key and not Device:isTouchDevice())
    and string.format("press the %s button", self.refresh_menu_key)
     or "swiping down"
    return {{
        text = string.format("Chapter list is empty. Try %s to refresh.", hint),
        dim = true,
        select_enabled = false,
    }}
end

function ChapterListing:generateItemTableFromChapters(chapters)

    local item_table = {}
    local last_read_chapter = Backend:getLastReadChapter(self.bookinfo.cache_id)

    for _, chapter in ipairs(chapters) do

        local mandatory = (chapter.chapters_index == last_read_chapter and Icons.FA_THUMB_TACK or '') ..
                              (chapter.isRead and Icons.FA_CHECK_CIRCLE or "") ..
                              (chapter.isDownLoaded ~= true and Icons.FA_DOWNLOAD or "")

        table.insert(item_table, {
            chapters_index = chapter.chapters_index,
            text = chapter.title or tostring(chapter.chapters_index),
            mandatory = mandatory ~= "" and mandatory or "  "
        })
    end
    return item_table
end

function ChapterListing:onClose()
    Backend:closeDbManager()
    self:onReturn()
end

function ChapterListing:onReturn()
    Menu.onClose(self)
    if H.is_func(self.on_return_callback) then
        UIManager:nextTick(function()
            self.on_return_callback()
        end)
    end
end

function ChapterListing:onCloseWidget()
    Backend:closeDbManager()
    Menu.onCloseWidget(self)
end

function ChapterListing:updateReturnCallback(callback)
    -- Skip changes when callback is nil
    if H.is_func(callback) then
        self.on_return_callback = callback
    end
end

function ChapterListing:fetchAndShow(bookinfo, onReturnCallBack, showChapterCallBack, accept_cached_results, visible)
    accept_cached_results = accept_cached_results or false

    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.cache_id)) then
        MessageBox:error('书籍信息出错')
        return
    end

    if not H.is_func(onReturnCallBack) then
        onReturnCallBack = function() end
    end
    
    local settings = Backend:getSettings()
    if not H.is_tbl(settings) then
        MessageBox:error('获取设置出错')
        return
    end

    local items_per_page = G_reader_settings:readSetting("toc_items_per_page") or self.toc_items_per_page_default
    local items_font_size = G_reader_settings:readSetting("toc_items_font_size") or Menu.getItemFontSize(items_per_page)
    local items_with_dots = G_reader_settings:nilOrTrue("toc_items_with_dots")

    local chapter_listing = ChapterListing:new{
        bookinfo = bookinfo,
        chapter_sorting_mode = settings.chapter_sorting_mode,
        on_return_callback = onReturnCallBack,
        on_show_chapter_callback = showChapterCallBack,

        title = "目录",
        with_dots = items_with_dots,
        items_per_page = items_per_page,
        items_font_size = items_font_size,
        subtitle = string.format("%s (%s)%s", bookinfo.name, bookinfo.author, (bookinfo.cacheExt == 'cbz' and
            Backend:getSettings().stream_image_view == true) and "[流式]" or "")
    }
    if visible == true then
        UIManager:show(chapter_listing)
    end
    return chapter_listing
end

function ChapterListing:gotoLastReadChapter()
    local last_read_chapter = Backend:getLastReadChapter(self.bookinfo.cache_id)
    if H.is_num(last_read_chapter) then
        self:switchItemTable(nil, self.item_table, last_read_chapter)
    end
end

function ChapterListing:onMenuChoice(item)
    if item.chapters_index == nil then
        return true
    end
    local book_cache_id = self.bookinfo.cache_id
    local chapters_index = item.chapters_index

    local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
    if chapter.cacheExt == 'cbz' and Backend:getSettings().stream_image_view == true then
        ChapterListing.onReturnCallback = function()
            self:gotoLastReadChapter()
        end
        NetworkMgr:runWhenOnline(function()
            UIManager:nextTick(function()
                StreamImageView:fetchAndShow({
                    bookinfo = self.bookinfo,
                    chapter = chapter,
                    on_return_callback = ChapterListing.onReturnCallback
                })
                UIManager:close(self)
            end)
        end)
        MessageBox:notice("流式漫画开启")
    else
        if self.onShowingReader then self:onShowingReader() end
        self:showReaderUI(chapter)
    end
    return true
end

function ChapterListing:onMenuHold(item)
    
    local book_cache_id = self.bookinfo.cache_id
    local chapters_index = item.chapters_index
    if item.chapters_index == nil then
        self:onRefreshChapters()
        return true
    end
    local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
    local is_read = chapter.isRead
    local cacheFilePath = chapter.cacheFilePath
    local isDownLoaded = chapter.isDownLoaded
    local dialog
    local buttons = {{{
        text = table.concat({Icons.FA_CHECK_CIRCLE, (is_read and ' 取消' or ' 标记'), "已读"}),
        callback = function()
            UIManager:close(dialog)
            Backend:HandleResponse(Backend:MarkReadChapter({
                chapters_index = item.chapters_index,
                isRead = chapter.isRead,
                book_cache_id = chapter.book_cache_id
            }), function(data)
                self:refreshItems(true)

            end, function(err_msg)
                MessageBox:error('标记失败 ', err_msg)
            end)
        end
    }, {
        text = table.concat({Icons.FA_DOWNLOAD, (isDownLoaded and ' 刷新' or ' 下载'), '章节'}),
        callback = function()
            UIManager:close(dialog)
            Backend:HandleResponse(Backend:ChangeChapterCache({
                chapters_index = item.chapters_index,
                cacheFilePath = cacheFilePath,
                book_cache_id = chapter.book_cache_id,
                isDownLoaded = isDownLoaded,

                bookUrl = chapter.bookUrl,

                title = chapter
            }), function(data)
                self:refreshItems(true)
                if isDownLoaded == true then
                    MessageBox:notice('删除成功')
                else
                    MessageBox:success('后台下载章节任务已添加，请稍后下拉刷新')
                end
            end, function(err_msg)
                MessageBox:error('失败:', err_msg)
            end)
        end
    }}, {{
        text = table.concat({Icons.FA_CLOUD, " 上传进度"}),
        callback = function()
            UIManager:close(dialog)
            self:syncProgressShow(chapter)
        end
    }, {
        text = table.concat({Icons.FA_BOOK, " 缓存章节"}),
        callback = function()
            UIManager:close(dialog)
            if not self.all_chapters_count then
                self.all_chapters_count = Backend:getChapterCount(book_cache_id)
            end
            local autoturn_spin = SpinWidget:new{
                value = 1,
                value_min = 1,
                value_max = tonumber(self.all_chapters_count),
                value_step = 1,
                value_hold_step = 5,
                ok_text = "下载",
                title_text = "请选择需下载的章数：",
                info_text = "( 默认跳过已读和已下载, 点击中间数字可直接输入)",
                extra_text = Icons.FA_DOWNLOAD .. " 缓存全部",
                callback = function(autoturn_spin)

                    local status, err = pcall(function()

                        self:ChapterDownManager(tonumber(chapters_index), 'next', autoturn_spin.value)
                    end)
                    if not status and err then
                        dbg.log('向后下载出错：', H.errorHandler(err))
                    end
                end,
                extra_callback = function()
                    MessageBox:confirm("请确认缓存全部章节 (短时间大量下载有可能触发反爬)",
                        function(result)
                            if result then
                                local status, err = pcall(function()
                                    self:ChapterDownManager(0, 'next')
                                end)
                                if not status then
                                    dbg.log('缓存全部章节出错：', tostring(err))
                                end
                            end
                        end, {
                            ok_text = "开始",
                            cancel_text = "取消"
                        })
                end
            }

            UIManager:show(autoturn_spin)
        end
    }}}

    local dialog_title = table.concat({"[", tostring(item.text), ']'})
    dialog = ButtonDialog:new{
        buttons = buttons,
        title = dialog_title,
        title_align = "center"
    }

    UIManager:show(dialog)
end

function ChapterListing:onSwipe(arg, ges_ev)
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "south" then
        NetworkMgr:runWhenOnline(function()
            self:onRefreshChapters()
        end)
        return
    end
    Menu.onSwipe(self, arg, ges_ev)
end

function ChapterListing:onRefreshChapters()
        Backend:closeDbManager()
        MessageBox:loading("正在刷新章节数据", function()
            return Backend:refreshChaptersCache({
                cache_id = self.bookinfo.cache_id,
                bookUrl = self.bookinfo.bookUrl
            }, self.ui_refresh_time)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    MessageBox:notice('同步成功')
                    self:refreshItems()
                    self.all_chapters_count = nil
                    self.ui_refresh_time = os.time()
                end, function(err_msg)
                    MessageBox:notice(err_msg or '同步失败')
                    if err_msg ~= '处理中' then
                        MessageBox:notice("请检查并刷新书架")
                    end
                end)
            end
    end)
end

function ChapterListing:showReaderUI(chapter)
    if H.is_func(self.on_show_chapter_callback) then
        self.on_show_chapter_callback(chapter)
    end
end

function ChapterListing:ChapterDownManager(begin_chapters_index, call_event, down_chapters_count, dismiss_callback,
    cancel_callback)
    if not H.is_num(begin_chapters_index) then
        MessageBox:error('下载参数错误')
        return
    end

    local book_cache_id = self.bookinfo.cache_id

    call_event = call_event and call_event or 'next'

    local begin_chapter = Backend:getChapterInfoCache(book_cache_id, begin_chapters_index)
    begin_chapter.call_event = call_event

    if not (H.is_tbl(begin_chapter) and begin_chapter.chapters_index ~= nil) then
        MessageBox:error('没有可下载章节')
        return
    end

    if down_chapters_count == nil then
        down_chapters_count = Backend:getChapterCount(book_cache_id)
    end
    down_chapters_count = tonumber(down_chapters_count)

    if not (down_chapters_count and down_chapters_count > 0) then
        MessageBox:error('没有查询到可下载章节')
        return
    end

    -- down_chapters_count > 10 call progressBar
    local dialog_title = string.format("缓存书籍共%s章", down_chapters_count)
    local loading_msg = down_chapters_count > 10 and 
        MessageBox:progressBar(dialog_title, {title = "正在下载章节", max =  down_chapters_count}) or 
        MessageBox:showloadingMessage(dialog_title, {progress_max = down_chapters_count})

    if not (loading_msg and loading_msg.reportProgress and loading_msg.close) then
        return MessageBox:error("进度显示控件生成失败")
    end

    local result_progress_callback = function(progress, err_msg)
        if progress == false or progress == true then
            loading_msg:close()
            if progress == true then
                MessageBox:notice('下载完成')
                self:refreshItems(true)
            elseif err_msg then
                MessageBox:error('后台下载任务出错:', tostring(err_msg))
            end
        end
        if H.is_num(progress) then
            loading_msg:reportProgress(progress)
        end
         logger.dbg("result_progress_callback:", progress, err_msg)
    end

    Backend:preLoadingChapters(begin_chapter, down_chapters_count, result_progress_callback)
end

function ChapterListing:syncProgressShow(chapter)
    Backend:closeDbManager()
    MessageBox:loading("同步中 ", function()
        if H.is_tbl(chapter) and H.is_num(chapter.chapters_index) then
            local response = Backend:saveBookProgress(chapter)
            if not (type(response) == 'table' and response.type == 'SUCCESS') then
                local message = type(response) == 'table' and response.message or
                                    "进度上传失败，请稍后重试"
                return {
                    type = 'ERROR',
                    message = message or ""
                }
            end
        end
        return Backend:refreshLibraryCache()
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)

                local bookCacheId = self.bookinfo.cache_id
                local bookinfo = Backend:getBookInfoCache(bookCacheId)

                if H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex) then

                    Backend:MarkReadChapter({
                        book_cache_id = bookCacheId,
                        chapters_index = bookinfo.durChapterIndex,
                        isRead = true
                    }, true)
                    self:refreshItems(true)
                    MessageBox:notice('同步完成')
                    self:switchItemTable(nil, self.item_table, tonumber(bookinfo.durChapterIndex))
                    self.ui_refresh_time = os.time()
                end
            end, function(err_msg)
                MessageBox:error('同步失败：' .. tostring(err_msg))
            end)
        end
    end)
end

function ChapterListing:openMenu()
    
    local dialog
    local buttons = {{},{{
        text = Icons.FA_GLOBE .. " 切换书源",
        callback = function()
            UIManager:close(dialog)
            NetworkMgr:runWhenOnline(function()
                require("Legado/BookSourceResults"):autoChangeSource(self.bookinfo, function()
                    self:onReturn()
                end)
            end)
        end,
        align = "left",
    }}, {{
        text = Icons.FA_EXCHANGE .. " 排序反转",
        callback = function()
            UIManager:close(dialog)
            local settings = Backend:getSettings()
            if settings.chapter_sorting_mode == 'chapter_ascending' then
                settings.chapter_sorting_mode = 'chapter_descending'
            else
                settings.chapter_sorting_mode = 'chapter_ascending'
            end
            Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                self:refreshItems(true)
            end, function(err_msg)
                MessageBox:error('设置失败:', err_msg)
            end)
        end,
        align = "left",
    }}, {{
        text = table.concat({Icons.FA_THUMB_TACK, " 拉取网络进度"}),
        callback = function()
            if self.multilines_show_more_text == true then
                MessageBox:notice('章节列表为空')
                return
            end
            UIManager:close(dialog)
            self:syncProgressShow()
        end,
        align = "left",
    }}, {{
        text = Icons.FA_TRASH .. " 清空本书缓存",
        callback = function()
            UIManager:close(dialog)
            Backend:closeDbManager()
            MessageBox:loading("清理中 ", function()
                return Backend:cleanBookCache(self.bookinfo.cache_id)
            end, function(state, response)
                if state == true then
                    Backend:HandleResponse(response, function(data)
                        MessageBox:notice("已清理，刷新重新可添加")
                        self:onReturn()

                    end, function(err_msg)
                        MessageBox:error('操作失败：', err_msg)
                    end)

                end

            end)

        end,
        align = "left",
    }}, {{
        text = Icons.FA_SHARE .. " 跳转到指定章节",
        callback = function()
            UIManager:close(dialog)
            if self.multilines_show_more_text == true then
                MessageBox:notice('章节列表为空')
                return
            end
            if Device.isAndroid() then
                local book_cache_id = self.bookinfo.cache_id
                if not self.all_chapters_count then
                    self.all_chapters_count = Backend:getChapterCount(book_cache_id)
                end
                UIManager:show(SpinWidget:new{
                    value = 1,
                    value_min = 1,
                    value_max = tonumber(self.all_chapters_count) or 10,
                    value_step = 1,
                    value_hold_step = 5,
                    ok_text = "跳转",
                    title_text = "请选择需要跳转的章节：",
                    info_text = "( 点击中间可直接输入数字 )",
                    callback = function(autoturn_spin)
                        local autoturn_spin_value = autoturn_spin and tonumber(autoturn_spin.value)
                        self:onGotoPage(self:getPageNumber(autoturn_spin_value))
                    end
                })
            else
                self:onShowGotoDialog()
            end

        end,
        align = "left",
    }}}

    if not Device:isTouchDevice() then
        table.insert(buttons, #buttons, {{
            text = Icons.FA_REFRESH .. ' ' .. "刷新目录",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshChapters()
            end,
            align = "left",
        }})
    end
    local book_cache_id = self.bookinfo.cache_id
    local lastUpdated = Backend:getChapterLastUpdateTime(book_cache_id)
    lastUpdated = tonumber(lastUpdated)
    local dimen
    if self.title_bar and self.title_bar.left_button and self.title_bar.left_button.image then
        dimen = self.title_bar.left_button.image.dimen
    end
    dialog = ButtonDialog:new{
        title = os.date("%m-%d %H:%M", lastUpdated),
        title_align = "left",
        -- title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = dimen and function()
            return dimen
        end or nil,
    }

    UIManager:show(dialog)
end
return ChapterListing
