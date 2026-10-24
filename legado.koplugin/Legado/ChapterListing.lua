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
local Button = require("ui/widget/button")
local TextWidget = require("ui/widget/textwidget")
local Screen = Device.screen

local Backend = require("Legado/Backend")
local LocalExtension = require("Legado.LocalExtension")
local Icons = require("Legado.res.icons")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")
local H = require("Legado/Helper")
local PlgState = require("Legado/PlgState")

if not dbg.log then
    dbg.log = logger.dbg
end

local ChapterListing = Menu:extend{
    name = "chapter_listing",
    title = "catalogue",
    align_baselines = true,
    is_borderless = true,
    line_color = Blitbuffer.COLOR_WHITE,
    covers_fullscreen = true,
    single_line = true,
    toc_items_per_page_default = 14,
    title_bar_left_icon = "appbar.menu",
    title_bar_fm_style = true,

    bookinfo = nil,
    all_chapters_count = nil,
    on_return_callback = nil,
    on_show_chapter_callback = nil,
    _ui_refresh_time = nil,
    refresh_menu_key = nil,
    is_enable_shortcut = false,

    raw_toc = nil,
    expanded_nodes = nil,
    has_volume = false,
    expand_button = nil,
    collapse_button = nil,
    toc_indent = nil,
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

    self:initButtons()
    self:refreshItems(nil, true)
end

function ChapterListing:initButtons()
    local items_per_page = self.items_per_page or self.toc_items_per_page_default
    local icon_size = math.floor(Screen:getHeight() / items_per_page * 2 / 5)
    local button_width = icon_size * 2

    self.expand_button = Button:new{
        icon = "control.expand",
        icon_rotation_angle = BD.mirroredUILayout() and 180 or 0,
        width = button_width,
        icon_width = icon_size,
        icon_height = icon_size,
        bordersize = 0,
        show_parent = self,
        callback = function(raw_index) self:expandToc(raw_index) end,
        onTapSelectButton = function() end,
    }
    self.collapse_button = Button:new{
        icon = "control.collapse",
        width = button_width,
        icon_width = icon_size,
        icon_height = icon_size,
        bordersize = 0,
        show_parent = self,
        callback = function(raw_index) self:collapseToc(raw_index) end,
        onTapSelectButton = function() end,
    }

    local items_font_size = self.items_font_size or Menu.getItemFontSize(items_per_page)
    local face = Font:getFace("smallinfofont", items_font_size)
    if face then
        local tmp = TextWidget:new{
            text = "    ",
            face = face,
        }
        self.toc_indent = tmp:getSize().w
        tmp:free()
    else
        self.toc_indent = Screen:scaleBySize(24)
    end
end

function ChapterListing:refreshItems(no_recalculate_dimen, go_last_read)
    local book_cache_id = self.bookinfo.cache_id
    local chapter_cache_data = Backend:getAllChaptersByUI(book_cache_id)

    if H.is_tbl(chapter_cache_data) and #chapter_cache_data > 0 then
        self.raw_toc = self:generateRawToc(chapter_cache_data)
        if not self.expanded_nodes then
            self.expanded_nodes = {}
            self:ensureLastReadExpanded(self.raw_toc)
        end
        self.item_table = self:buildVisibleItems()
        self.multilines_show_more_text = false
        self.items_per_page = nil
        self.single_line = true
    else
        self.raw_toc = nil
        self.item_table = self:generateEmptyViewItemTable()
        self.multilines_show_more_text = true
        self.items_per_page = 1
        self.single_line = false
    end
    Menu.updateItems(self, nil, no_recalculate_dimen)
    if go_last_read then
        self:gotoLastReadChapter()
    end
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

function ChapterListing:getActualLastReadChapter()
    local book_cache_id = self.bookinfo and self.bookinfo.cache_id
    local current_reading = PlgState:readingChapter()
    if current_reading and current_reading.book_cache_id == book_cache_id and H.is_num(current_reading.chapters_index) then
        return current_reading.chapters_index
    end
    local dur_idx = self.bookinfo and tonumber(self.bookinfo.durChapterIndex)
    if book_cache_id then
        local db_last = Backend:getLastReadChapter(book_cache_id)
        if H.is_num(db_last) and db_last >= 0 then
            return db_last
        end
    end
    return dur_idx or 0
end

function ChapterListing:generateRawToc(chapters)
    local book_cache_id = self.bookinfo.cache_id
    local is_desc_sort = (Backend:chapterSortingMode(book_cache_id) == "DESC")
    local last_read_chapter = self:getActualLastReadChapter()

    local has_volume = false
    for _, ch in ipairs(chapters) do
        if ch.isVolume == true then
            has_volume = true
            break
        end
    end
    self.has_volume = has_volume

    local button_width = self.expand_button and self.expand_button.width or 0
    self.state_w = has_volume and button_width or 0

    local raw_list = {}
    if has_volume then
        local groups = {}
        local cur_group = nil
        for _, ch in ipairs(chapters) do
            if ch.isVolume == true then
                cur_group = {
                    volume = ch,
                    chapters = {},
                }
                table.insert(groups, cur_group)
            else
                if not cur_group then
                    cur_group = {
                        volume = nil,
                        chapters = {},
                    }
                    table.insert(groups, cur_group)
                end
                table.insert(cur_group.chapters, ch)
            end
        end

        if is_desc_sort then
            local rev_groups = {}
            for i = #groups, 1, -1 do
                table.insert(rev_groups, groups[i])
            end
            groups = rev_groups
            for _, grp in ipairs(groups) do
                local rev_chs = {}
                for i = #grp.chapters, 1, -1 do
                    table.insert(rev_chs, grp.chapters[i])
                end
                grp.chapters = rev_chs
            end
        end

        for _, grp in ipairs(groups) do
            if grp.volume then
                table.insert(raw_list, {
                    chapter = grp.volume,
                    is_volume = true,
                    depth = 1,
                })
            end
            for _, ch in ipairs(grp.chapters) do
                table.insert(raw_list, {
                    chapter = ch,
                    is_volume = false,
                    depth = grp.volume and 2 or 1,
                })
            end
        end
    else
        if is_desc_sort then
            for i = #chapters, 1, -1 do
                table.insert(raw_list, { chapter = chapters[i], is_volume = false, depth = 1 })
            end
        else
            for _, ch in ipairs(chapters) do
                table.insert(raw_list, { chapter = ch, is_volume = false, depth = 1 })
            end
        end
    end

    local raw_toc = {}
    for i, entry in ipairs(raw_list) do
        local ch = entry.chapter
        local is_volume = entry.is_volume
        local depth = entry.depth
        local mandatory = ""
        if not is_volume then
            mandatory = (ch.chapters_index == last_read_chapter and Icons.FA_THUMB_TACK or "") ..
                        (ch.isRead and Icons.FA_CHECK_CIRCLE or "") ..
                        (ch.isDownLoaded ~= true and Icons.FA_DOWNLOAD or "")
            if mandatory == "" then mandatory = "  " end
        end

        raw_toc[i] = {
            raw_index = i,
            chapters_index = ch.chapters_index,
            text = ch.title or tostring(ch.chapters_index),
            isVolume = is_volume,
            isRead = ch.isRead,
            isDownLoaded = ch.isDownLoaded,
            cacheFilePath = ch.cacheFilePath,
            depth = depth,
            indent = has_volume and (self.toc_indent * (depth - 1)) or 0,
            bold = is_volume or (ch.chapters_index == last_read_chapter),
            mandatory = mandatory,
            bidi_wrap_func = BD.auto,
        }
    end

    local next_depth = 0
    for i = #raw_toc, 1, -1 do
        local item = raw_toc[i]
        if item.depth < next_depth then
            item.has_children = true
        end
        next_depth = item.depth
    end

    return raw_toc
end

function ChapterListing:ensureLastReadExpanded(raw_toc)
    local last_read_chapter = self:getActualLastReadChapter()
    local target_raw_idx = nil
    if H.is_num(last_read_chapter) then
        for i, item in ipairs(raw_toc) do
            if item.chapters_index == last_read_chapter and not item.isVolume then
                target_raw_idx = i
                break
            end
        end
    end

    if target_raw_idx then
        local depth = raw_toc[target_raw_idx].depth
        for i = target_raw_idx - 1, 1, -1 do
            if depth > raw_toc[i].depth then
                depth = raw_toc[i].depth
                self.expanded_nodes[i] = true
                if depth == 1 then break end
            end
        end
    elseif self.has_volume and raw_toc[1] and raw_toc[1].has_children then
        self.expanded_nodes[1] = true
    end
end

function ChapterListing:buildVisibleItems()
    if not self.has_volume then
        return self.raw_toc
    end

    local visible = {}
    local hidden_depth = nil
    for i, item in ipairs(self.raw_toc) do
        if hidden_depth and item.depth > hidden_depth then
        else
            hidden_depth = nil
            if item.has_children then
                if self.expanded_nodes[i] then
                    item.state = self.collapse_button:new{
                        callback = function() self:collapseToc(i) end,
                    }
                else
                    item.state = self.expand_button:new{
                        callback = function() self:expandToc(i) end,
                    }
                    hidden_depth = item.depth
                end
            else
                item.state = nil
            end
            table.insert(visible, item)
        end
    end
    return visible
end

function ChapterListing:expandToc(raw_index)
    if not self.expanded_nodes[raw_index] then
        self.expanded_nodes[raw_index] = true
        self:refreshVisibleItems(raw_index)
    end
end

function ChapterListing:collapseToc(raw_index)
    if self.expanded_nodes[raw_index] then
        self.expanded_nodes[raw_index] = nil
        self:refreshVisibleItems(raw_index)
    end
end

function ChapterListing:toggleTocNode(raw_index)
    if self.expanded_nodes[raw_index] then
        self:collapseToc(raw_index)
    else
        self:expandToc(raw_index)
    end
end

function ChapterListing:expandAll()
    for i, item in ipairs(self.raw_toc or {}) do
        if item.has_children then
            self.expanded_nodes[i] = true
        end
    end
    self:refreshVisibleItems()
end

function ChapterListing:collapseAll()
    self.expanded_nodes = {}
    self:refreshVisibleItems()
end

function ChapterListing:refreshVisibleItems(target_raw_index)
    self.item_table = self:buildVisibleItems()
    local target_v_idx = nil
    if target_raw_index then
        for v_idx, item in ipairs(self.item_table) do
            if item.raw_index == target_raw_index then
                target_v_idx = v_idx
                break
            end
        end
    end
    self:switchItemTable(nil, self.item_table, target_v_idx or -1)
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

    local is_stream_image_mode = false
    if Backend:isBookTypeComic(bookinfo.cache_id) then
        local extras_settings = Backend:getBookExtras(bookinfo.cache_id)
        if H.is_tbl(extras_settings) and H.is_tbl(extras_settings.data) then
            is_stream_image_mode = extras_settings.data.stream_image_view ~= false
        end
    end

    local chapter_listing = ChapterListing:new{
        bookinfo = bookinfo,
        on_return_callback = onReturnCallBack,
        on_show_chapter_callback = showChapterCallBack,

        title = "目录",
        with_dots = items_with_dots,
        items_per_page = items_per_page,
        items_font_size = items_font_size,
        subtitle = string.format("%s (%s)%s", bookinfo.name, bookinfo.author, is_stream_image_mode and "[流式]" or "")
    }
    if visible == true then
        UIManager:show(chapter_listing)
    end
    return chapter_listing
end

function ChapterListing:gotoLastReadChapter()
    local last_read_chapter = self:getActualLastReadChapter()
    if H.is_num(last_read_chapter) and self.item_table then
        for v_idx, item in ipairs(self.item_table) do
            if item.chapters_index == last_read_chapter and not item.isVolume then
                self:switchItemTable(nil, self.item_table, v_idx)
                return
            end
        end
    end
end

function ChapterListing:onMenuSelect(item, pos)
    if not item then return true end
    if item.select_enabled == false then return true end

    local do_toggle = false
    if item.isVolume then
        do_toggle = true
    elseif item.state and pos and pos.x then
        if BD.mirroredUILayout() then
            do_toggle = pos.x > 0.7
        else
            do_toggle = pos.x < 0.3
        end
    end

    if do_toggle and item.has_children then
        self:toggleTocNode(item.raw_index)
        return true
    end

    if item.isVolume then
        return true
    end

    return Menu.onMenuSelect(self, item)
end

function ChapterListing:onMenuChoice(item)
    if item.chapters_index == nil or item.isVolume then
        return true
    end
    local book_cache_id = self.bookinfo.cache_id
    local chapters_index = item.chapters_index

    local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
    if self.onShowingReader then self:onShowingReader() end
    self:showReaderUI(chapter)
    return true
end

function ChapterListing:onMenuHold(item)
    if not item or item.isVolume then
        return true
    end

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
                title = chapter.title,
                origin = chapter.origin,
                variable = chapter.variable,
                bookVariable = chapter.bookVariable,
                name = chapter.name,
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
        text = table.concat({Icons.FA_BOOK, " 向后缓存"}),
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
                info_text = "(点击中间数字可直接输入)",
                extra_text = Icons.FA_DOWNLOAD .. " 下载本章后全部",
                callback = function(autoturn_spin)
                    require("Legado/ExportDialog"):new({
                        bookinfo = self.bookinfo
                    }):cacheSelectedChapters(tonumber(chapters_index), autoturn_spin.value, function(success)
                        self:refreshItems(true)
                    end)
                end,
                extra_callback = function()
                    require("Legado/ExportDialog"):new({
                        bookinfo = self.bookinfo
                    }):cacheSelectedChapters(tonumber(chapters_index), nil, function(success)
                        self:refreshItems(true)
                    end)
                end
            }

            UIManager:show(autoturn_spin)
        end
    }}}
    if not Backend:supportsProviderMethod("saveBookProgress") then
        table.remove(buttons[2], 1)
    end

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
        if NetworkMgr:isConnected() then
            UIManager:nextTick(function()
                self:onRefreshChapters()
            end)
        else
            NetworkMgr:runWhenConnected(function() self:onRefreshChapters() end)
        end
        return
    end
    Menu.onSwipe(self, arg, ges_ev)
end

function ChapterListing:onRefreshChapters()
        if not NetworkMgr:isConnected() then
            MessageBox:notice("操作失败, 请检查网络")
            return
        end
        Backend:closeDbManager()
        TaskProg.loading({
            text = "正在刷新章节数据 ",
            dismissable = true,
            runnable = function()
                return Backend:refreshChaptersCache({
                    cache_id = self.bookinfo.cache_id,
                    bookUrl = self.bookinfo.bookUrl,
                    origin = self.bookinfo.origin,
                    name = self.bookinfo.name,
                    variable = self.bookinfo.variable,
                    refresh = self._force_refresh_after_clear == true,
                }, self._ui_refresh_time)
            end,
            callback = function(ok, result)
                if ok == true then
                    Backend:HandleResponse(result, function(data)
                        self._force_refresh_after_clear = nil
                        MessageBox:notice('同步成功')
                        self.expanded_nodes = nil
                        self:refreshItems(nil, true)
                        self.all_chapters_count = nil
                        self._ui_refresh_time = time.now()
                    end, function(err_msg)
                        pcall(function() Backend:onServiceError(err_msg) end)
                        MessageBox:notice(err_msg or '同步失败')
                        if err_msg ~= '处理中' then
                            MessageBox:notice("请检查并刷新书架")
                        end
                    end)
                end
            end,
        })
end

function ChapterListing:showReaderUI(chapter)
    if H.is_func(self.on_show_chapter_callback) then
        self.on_show_chapter_callback(chapter)
    end
end

function ChapterListing:syncProgressShow(chapter)
    local method = H.is_tbl(chapter) and "saveBookProgress" or "getBookshelf"
    if not Backend:supportsProviderMethod(method) then
        MessageBox:notice(H.is_tbl(chapter) and "当前模式不支持上传阅读进度" or "当前模式不支持拉取阅读进度")
        return
    end

    Backend:closeDbManager()
    TaskProg.loading({
        text = "同步中 ",
        dismissable = true,
        runnable = function()
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
        end,
        callback = function(ok, result)
            if ok == true then
                Backend:HandleResponse(result, function(data)
                    local bookCacheId = self.bookinfo.cache_id
                    local bookinfo = Backend:getBookInfoCache(bookCacheId)
                    if H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex) then
                        self.bookinfo = bookinfo
                        Backend:MarkReadChapter({
                            book_cache_id = bookCacheId,
                            chapters_index = bookinfo.durChapterIndex,
                            isRead = true
                        }, true)
                        if UIManager:isWidgetShown(self) then
                            self:refreshItems(true, true)
                        end
                        MessageBox:notice('同步完成')
                        self._ui_refresh_time = time.now()
                    end
                end, function(err_msg)
                    MessageBox:error('同步失败：', tostring(err_msg))
                end)
            end
        end,
    })
end

function ChapterListing:openMenu()

    local dialog
    local pull_progress_button = {{
        text = table.concat({Icons.FA_THUMB_TACK, " 拉取进度"}),
        callback = function()
            if self.multilines_show_more_text == true then
                MessageBox:notice('章节列表为空')
                return
            end
            UIManager:close(dialog)
            self:syncProgressShow()
        end,
        align = "left",
    }}
    local function change_source()
        UIManager:nextTick(function()
            require("Legado/BookSourceResults"):changeSourceDialog(self.bookinfo, function()
                self:onReturn()
            end)
        end)
    end

    local buttons = {{},{{
        text = Icons.FA_GLOBE .. " 切换书源",
        callback = function()
            if not NetworkMgr:isConnected() then
                MessageBox:notice("操作失败，请检查网络")
                return
            end
            UIManager:close(dialog)

            local has_origin = H.is_tbl(self.bookinfo) and H.is_str(self.bookinfo.origin) and self.bookinfo.origin ~= ""
            if not has_origin then
                change_source()
                return
            end

            local is_local = Backend:_isLocal()
            local engine_ok = LocalExtension.available()
            if not is_local and not engine_ok then
                change_source()
                return
            end

            local source_name = self.bookinfo.originName
            if not H.is_str(source_name) or source_name == "" then source_name = self.bookinfo.origin end
            local source_name_chars = util.splitToChars(source_name)
            if #source_name_chars > 16 then
                source_name = table.concat(source_name_chars, "", 1, 16) .. "…"
            end

            local source_item = {
                bookSourceUrl = self.bookinfo.origin,
                bookSourceName = self.bookinfo.originName or self.bookinfo.origin,
            }

            local source_dialog
            local action_buttons = {}

            if is_local then
                table.insert(action_buttons, {{
                    text = "设置",
                    callback = function()
                        UIManager:close(source_dialog)
                        require("Legado/BookSourceResults"):showSourceContextMenu(source_item)
                    end,
                }})
            elseif engine_ok then
                table.insert(action_buttons, {{
                    text = "本地测试",
                    callback = function()
                        UIManager:close(source_dialog)
                        LocalExtension.testSource(source_item)
                    end,
                }})
            end

            table.insert(action_buttons, {{
                text = "切换",
                callback = function()
                    UIManager:close(source_dialog)
                    change_source()
                end,
            }})

            source_dialog = ButtonDialog:new{
                title = "书源：" .. source_name,
                buttons = action_buttons,
            }
            UIManager:show(source_dialog)
        end,
        align = "left",
    }}, {{
        text = Icons.FA_EXCHANGE .. " " .. (Backend:chapterSortingMode(self.bookinfo.cache_id) == "ASC" and "目录倒序" or "目录正序"),
        callback = function()
            UIManager:close(dialog)
            self:toggleSortMode()
        end,
        align = "left",
    }}, {{
        text = Icons.FA_DOWNLOAD .. " 本书缓存",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(
                    string.format("《%s》: \n\n (部分书源存在访问频率限制，如遇章节缺失或内容不完整，可尝试: \n  长按章节分章下载、调低并发下载数)", self.bookinfo.name),
                    function(result)
                        if result then
                            require("Legado/ExportDialog"):new({
                                bookinfo = self.bookinfo
                            }):cacheAllChapters(function(success)
                                self:refreshItems(true)
                            end)
                        end
                    end,
                    {
                        ok_text = "缓存全书",
                        cancel_text = "取消",
                        other_buttons_first = true,
                        other_buttons = {{{
                            text = "导出书籍",
                            callback = function()
                                require("Legado/ExportDialog"):new({ bookinfo = self.bookinfo }):exportBook()
                            end,
                        }, {
                            text = "清除缓存",
                            callback = function()
                                MessageBox:confirm(
                                    "请确认清除本书缓存：\n",
                                    function(result)
                                        if not result then return end
                                        Backend:closeDbManager()
                                        TaskProg.loading("清理中 ", function()
                                            return Backend:cleanBookCache(self.bookinfo.cache_id, self.bookinfo)
                                        end, function(state, response)
                                            if state == true then
                                                Backend:HandleResponse(response, function()
                                                    self._force_refresh_after_clear = true
                                                    MessageBox:success("已清理，可刷新目录")
                                                    self:onReturn()
                                                end, function(err_msg)
                                                    MessageBox:error('请稍后重试：', err_msg)
                                                end)
                                            else
                                                MessageBox:error("清理失败：", tostring(response))
                                            end
                                        end)
                                end)
                            end,
                        }}},
                    }
                )
        end,
        align = "left",
    }},}
    if Backend:supportsProviderMethod("getBookshelf") then
        table.insert(buttons, 4, pull_progress_button)
    end

    if self.has_volume then
        local all_expanded = true
        for _, item in ipairs(self.raw_toc or {}) do
            if item.has_children and not self.expanded_nodes[item.raw_index] then
                all_expanded = false
                break
            end
        end
        table.insert(buttons, 4, {{
            text = Icons.FA_FOLDER .. " " .. (all_expanded and "折叠全部目录" or "展开全部目录"),
            callback = function()
                UIManager:close(dialog)
                if all_expanded then
                    self:collapseAll()
                else
                    self:expandAll()
                end
            end,
            align = "left",
        }})
    end

    local stream_mode_item =self:getStreamModeItem(function()
        if dialog then UIManager:close(dialog) end
    end)
    if H.is_tbl(stream_mode_item) then
        table.insert(buttons, stream_mode_item)
    end

    if not Device:isTouchDevice() then
        table.insert(buttons, {{
            text = Icons.FA_REFRESH .. ' ' .. "刷新目录",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshChapters()
            end,
            align = "left",
        }})
    end

    table.insert(buttons, {{
        text = Icons.FA_SHARE .. " 跳转章节",
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
    }})

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
        info_face = Font:getFace("tfont"),
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = dimen and function()
            return dimen
        end or nil,
    }

    UIManager:show(dialog)
end

function ChapterListing:toggleSortMode()
    local book_cache_id = self.bookinfo.cache_id
    local current_sorting_mode = Backend:chapterSortingMode(book_cache_id)
    local new_sorting_mode = (current_sorting_mode == 'ASC') and 'DESC' or 'ASC'

    Backend:HandleResponse(Backend:chapterSortingMode(book_cache_id, new_sorting_mode),
        function()
            self.expanded_nodes = nil
            self:refreshItems(true, true)
        end,
        function(err_msg)
            MessageBox:error('切换排序模式失败: ', err_msg)
        end
    )
end

function ChapterListing:getReaderRouteItem(close_dialog, callback)
    local route = Backend:bookReaderRoute(self.bookinfo.cache_id)
    local labels = { auto = "自动", reader = "文本与图文", comic = "漫画" }
    return {{
        text = string.format("阅读方式: %s", labels[route] or labels.auto),
        callback = function()
            if H.is_func(close_dialog) then close_dialog() end
            local selector
            local function choose(value)
                if selector then UIManager:close(selector) end
                Backend:HandleResponse(Backend:bookReaderRoute(self.bookinfo.cache_id, value), function()
                    MessageBox:notice("阅读方式已更新")
                    if H.is_func(callback) then callback(value) end
                end, function(err_msg)
                    MessageBox:error(err_msg or "设置失败")
                end)
            end
            selector = ButtonDialog:new{
                title = "阅读方式",
                buttons = {
                    {{ text = "自动", callback = function() choose("auto") end }},
                    {{ text = "文本与图文", callback = function() choose("reader") end }},
                    {{ text = "漫画", callback = function() choose("comic") end }},
                },
            }
            UIManager:show(selector)
        end,
        align = "left",
    }}
end

function ChapterListing:getStreamModeItem(close_dialog, callback)
    local book_cache_id = self.bookinfo.cache_id
    local is_comic = Backend:isBookTypeComic(book_cache_id)
    if is_comic then
        local extras_settings = Backend:getBookExtras(book_cache_id)
        if H.is_tbl(extras_settings.data) then
            local stream_image_view = extras_settings.data.stream_image_view
            return {{
                text = string.format("%s 漫画免缓存", (stream_image_view ~= false and Icons.FA_CHECK_SQUARE or Icons.FA_SQUARE_O)),
                callback = function()
                    if H.is_func(close_dialog) then close_dialog() end
                    UIManager:nextTick(function()
                        ChapterListing.switchStreamMode(extras_settings, callback, book_cache_id)
                    end)
                end,
                align = "left",
            }}
        end
    end
end

function ChapterListing.switchStreamMode(settings, callback, book_cache_id)
    local b_id = book_cache_id
    local extras_settings = (H.is_tbl(settings) and settings.data) and settings or (b_id and Backend:getBookExtras(b_id))
    if not (extras_settings and H.is_tbl(extras_settings.data)) then return end
    local stream_image_view = extras_settings.data.stream_image_view
    MessageBox:confirm(string.format(
        "当前模式: %s \r\n \r\n缓存模式: 边看边下载。\n缺点：占空间。\n优点：预加载后相对流畅。\r\n \r\n免缓存：不下载图片到磁盘。\n缺点：对网络要求较高且画质缺少优化，需要下载任一章节后才能开启（建议服务端开启图片代理）。\n优点：不占空间。",
        (stream_image_view ~= false and '[免缓存]' or '[缓存]')), function(result)
        if result then
            stream_image_view = stream_image_view == false
            extras_settings:saveSetting("stream_image_view", stream_image_view):flush()
            if b_id then
                local PlgState = require("Legado/PlgState")
                PlgState:clearReadingRoute(b_id)
            end
            MessageBox:notice("设置成功")
            if H.is_func(callback) then callback() end
        end
    end, {
        ok_text = "切换",
        cancel_text = "取消"
    })
end

return ChapterListing
