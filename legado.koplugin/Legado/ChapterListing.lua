local BD = require("ui/bidi")
local Font = require("ui/font")
local util = require("util")
local logger = require("logger")
local dbg = require("dbg")
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
    is_enable_shortcut = false,
    is_popout = false,
    title = "catalogue",
    align_baselines = true,

    bookinfo = nil,
    chapter_sorting_mode = nil,
    all_chapters_count = nil,
    on_return_callback = nil,
    on_show_chapter_callback = nil,
    ui_refresh_time = nil,
}

function ChapterListing:init()
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:openMenu()
    end

    self.width, self.height = Screen:getWidth(), Screen:getHeight()

    Menu.init(self)

    self.paths = {{
        callback = self.on_return_callback
    }}

    self.on_return_callback = nil

    if Device:hasKeys({"Home"}) or Device:hasDPad() then
        self.key_events.Close = {{Device.input.group.Back}}
        self.key_events.RefreshChapters = {{"Home"}}
        self.key_events.Right = {{"Right"}}
    end

    self.ui_refresh_time = os.time()
    self:updateChapterList()
end

function ChapterListing:updateChapterList()
    self:refreshItems()
    Backend:onBookOpening(self.bookinfo.cache_id)
end

function ChapterListing:refreshItems(no_recalculate_dimen)

    local book_cache_id = self.bookinfo.cache_id
    local chapter_cache_data = Backend:getBookChapterCache(book_cache_id)

    if chapter_cache_data and #chapter_cache_data > 0 then

        self.item_table = self:generateItemTableFromChapters(chapter_cache_data)
        self.multilines_show_more_text = false
        self.items_per_page = nil

    else
        self.item_table = self:generateEmptyViewItemTable()
        self.multilines_show_more_text = true
        self.items_per_page = 1
    end
    Menu.updateItems(self, nil, no_recalculate_dimen)
    self:gotoLastReadChapter()
end

function ChapterListing:generateEmptyViewItemTable()
    return {{
        text = string.format("No chapters found in library. Try%s swiping down to refresh.",
            (Device:hasKeys({"Home"}) and ' Press the home button or ' or '')),
        dim = true,
        select_enabled = false
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
            mandatory = mandatory
        })

    end

    return item_table
end

function ChapterListing:closeUI()
    Menu.onClose(self)
end

function ChapterListing:onClose()
    Backend:closeDbManager()
    self:onReturn()
end

function ChapterListing:onReturn()
    local path = table.remove(self.paths)
    self:closeUI()
    pcall(path.callback)
end

function ChapterListing:onCloseWidget()
    Backend:closeDbManager()
    Menu.onCloseWidget(self)
end

function ChapterListing:fetchAndShow(bookinfo, onReturnCallBack, showChapterCallBack, accept_cached_results)
    accept_cached_results = accept_cached_results or false

    if not H.is_tbl(bookinfo) or not H.is_str(bookinfo.cache_id) then
        MessageBox:error('书籍信息出错')
        return
    end

    local settings = Backend:getSettings()
    if not H.is_tbl(settings) then
        MessageBox:error('获取设置出错')
        return
    end
    local chapter_listing = ChapterListing:new{
        bookinfo = bookinfo,
        chapter_sorting_mode = settings.chapter_sorting_mode,
        on_return_callback = onReturnCallBack,
        on_show_chapter_callback = showChapterCallBack,
        covers_fullscreen = true,
        subtitle = "目录",
        title = string.format("%s (%s)%s", bookinfo.name, bookinfo.author, (bookinfo.cacheExt == 'cbz' and
            Backend:getSettings().stream_image_view == true) and "[流式]" or "")
    }
    UIManager:show(chapter_listing)
    return chapter_listing
end

function ChapterListing:gotoLastReadChapter()
    local last_read_chapter = Backend:getLastReadChapter(self.bookinfo.cache_id)
    if H.is_num(last_read_chapter) then
        last_read_chapter = tonumber(last_read_chapter + 1)
        self:onGotoPage(self:getPageNumber(last_read_chapter))
    end
end

function ChapterListing:onMenuChoice(item)
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
            end)
        end)
        Backend:show_notice("流式漫画开启")
    else
        self:openChapterOnReader(chapter)
    end
end

function ChapterListing:onMenuHold(item)

    local book_cache_id = self.bookinfo.cache_id
    local chapters_index = item.chapters_index
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
    }}, {{
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
                    Backend:show_notice('删除成功')
                else
                    MessageBox:success('后台下载章节任务已添加，请稍后下拉刷新')
                end
            end, function(err_msg)
                MessageBox:error('失败:', err_msg)
            end)
        end
    }}, {{
        text = table.concat({Icons.FA_THUMB_TACK, " 上传进度"}),
        callback = function()
            UIManager:close(dialog)
            self:syncProgressShow(chapter)
        end
    }}, {{
        text = table.concat({Icons.FA_INFO_CIRCLE, " 缓存章节"}),
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
                extra_callback =function()
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
        self:onRefreshChapters()

        return
    end

    Menu.onSwipe(self, arg, ges_ev)
end

function ChapterListing:onBookReaderCallback(chapter, closeReaderUiCallback)

    local nextChapter = Backend:findNextChapter({
        chapters_index = chapter.chapters_index,
        call_event = chapter.call_event,
        book_cache_id = chapter.book_cache_id,
        totalChapterNum = chapter.totalChapterNum
    })

    if nextChapter ~= nil then

        nextChapter.call_event = chapter.call_event
        self:openChapterOnReader(nextChapter, true)
    else
        if H.is_func(closeReaderUiCallback) then
            closeReaderUiCallback(function()
                self:refreshItems(true)
                UIManager:show(self)
            end)
        end
    end

end

function ChapterListing:onRefreshChapters()
    NetworkMgr:runWhenOnline(function()
        Backend:closeDbManager()
        MessageBox:loading("正在刷新章节数据", function()
            return Backend:refreshChaptersCache({
                cache_id = self.bookinfo.cache_id,
                bookUrl = self.bookinfo.bookUrl
            }, self.ui_refresh_time)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    Backend:show_notice('同步成功')
                    self:refreshItems()
                    self.all_chapters_count = nil
                    self.ui_refresh_time = os.time()
                end, function(err_msg)
                    Backend:show_notice(err_msg or '同步失败')
                    if err_msg ~= '处理中' then
                        Backend:show_notice("请检查并刷新书架")
                    end
                end)
            end
        end)
    end)
end

function ChapterListing:showReaderUI(chapter)
    self.on_show_chapter_callback(chapter)
end

function ChapterListing:openChapterOnReader(chapter, is_callback)

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)

    if (H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath)) then
        if is_callback ~= true then
            self:closeUI()
        end
        self:showReaderUI(cache_chapter)
    else
        Backend:closeDbManager()
        return MessageBox:loading("正在下载正文", function()
            return Backend:downloadChapter(chapter)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    if not H.is_tbl(data) or not H.is_str(data.cacheFilePath) then
                        MessageBox:error('下载失败')
                        return
                    end
                    if is_callback ~= true then
                        self:closeUI()
                    end
                    self:showReaderUI(data)
                end, function(err_msg)
                    Backend:show_notice("请检查并刷新书架")
                    MessageBox:error(err_msg or '错误')
                end)
            end

        end)

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

    if not H.is_tbl(begin_chapter) or begin_chapter.chapters_index == nil then
        MessageBox:error('没有可下载章节')
        return
    end

    if down_chapters_count == nil then
        down_chapters_count = Backend:getChapterCount(book_cache_id)
    end

    down_chapters_count = tonumber(down_chapters_count)
    local status, err = Backend:preLoadingChapters(begin_chapter, down_chapters_count)

    if not status then
        MessageBox:error('后台下载任务提交出错', tostring(err))
        return
    end

    local chapter_down_tasks = err

    dbg.v('chapter_down_tasks:', chapter_down_tasks)

    if H.is_tbl(chapter_down_tasks) and chapter_down_tasks[1] ~= nil and chapter_down_tasks[1].book_cache_id ~= nil then

        local job = {
            poll = function()

                return Backend:check_the_background_download_job(chapter_down_tasks)
            end,
            requestCancellation = function()

                Backend:quit_the_background_download_job()
                if H.is_func(cancel_callback) then
                    cancel_callback()
                end

            end
        }

        local dialog = require("Legado/DownloadUnreadChaptersJobDialog"):new{
            show_parent = self,
            job = job,
            job_inspection_interval = 0.8,
            dismiss_callback = function()
                Backend:show_notice('下载结束')
                self:refreshItems(true)
                if H.is_func(dismiss_callback) then
                    dismiss_callback()
                end
            end
        }
        dialog:show()
    else
        MessageBox:error('下载任务返回参数出错')
    end

end

function ChapterListing:syncProgressShow(chapter)
    Backend:closeDbManager()
    MessageBox:loading("同步中 ", function()
        if H.is_tbl(chapter) and H.is_num(chapter.chapters_index) then
            local response = Backend:saveBookProgress(chapter)
            if not (type(response) == 'table' and response.type == 'SUCCESS') then
                local message = (type(response) == 'table' and response.message) or
                                    "进度上传失败，请稍后重试"
                return {
                    type = 'ERROR',
                    message = message
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
                    Backend:show_notice('同步完成')
                    local last_chapter = tonumber(bookinfo.durChapterIndex + 1)
                    self:onGotoPage(self:getPageNumber(last_chapter))
                    self.ui_refresh_time = os.time()
                end
            end, function(err_msg)
                MessageBox:error('同步失败：'..tostring(err_msg))
            end)
        end
    end)
end

function ChapterListing:openMenu()

    local dialog

    local buttons = {{{
        text = Icons.FA_REFRESH .. " 自动换源",
        callback = function()
            UIManager:close(dialog)
            NetworkMgr:runWhenOnline(function()
                require("Legado/BookSourceResults"):autoChangeSource(self.bookinfo, function()
                        self:onReturn()
                    end) 
            end)
        end
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
        end
    }}, {{
        text = table.concat({Icons.FA_THUMB_TACK, " 拉取网络进度"}),
        callback = function()
            if self.multilines_show_more_text == true then
                Backend:show_notice('章节列表为空')
                return
            end
            UIManager:close(dialog)
            self:syncProgressShow()
        end
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
                        Backend:show_notice("已清理，刷新重新可添加")
                        self:onReturn()

                    end, function(err_msg)
                        MessageBox:error('操作失败：', err_msg)
                    end)

                end

            end)

        end
    }}, {{
        text = Icons.FA_SHARE .. " 跳转到指定章节",
        callback = function()
            UIManager:close(dialog)
            if self.multilines_show_more_text == true then
                Backend:show_notice('章节列表为空')
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
                    value_max = tonumber(all_chapters_count) or 10,
                    value_step = 1,
                    value_hold_step = 5,
                    ok_text = "跳转",
                    title_text = "请选择需要跳转的章节：",
                    info_text = "( 点击中间可直接输入数字 )",
                    callback = function(autoturn_spin)
                        autoturn_spin.value = tonumber(autoturn_spin.value)
                        self:onGotoPage(self:getPageNumber(autoturn_spin.value))
                    end
                })
            else
                self:onShowGotoDialog()
            end

        end
    }}}

    if not Device:isTouchDevice() then
        table.insert(buttons, 3, {{
            text = Icons.FA_EXCLAMATION_CIRCLE .. ' ' .. "刷新目录",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshChapters()
            end
        }})
    end
    local book_cache_id = self.bookinfo.cache_id
    local lastUpdated = Backend:getChapterLastUpdateTime(book_cache_id)
    lastUpdated = tonumber(lastUpdated)
    dialog = ButtonDialog:new{
        title = "chapters_cache_" .. os.date("%m-%d %H:%M:%S", lastUpdated),
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }

    UIManager:show(dialog)

end

return ChapterListing