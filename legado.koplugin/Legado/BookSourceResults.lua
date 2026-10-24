local UIManager = require("ui/uimanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local Menu = require("ui/widget/menu")
local Device = require("device")
local util = require("util")
local BD = require("ui/bidi")
local Screen = Device.screen

local Icons = require("Legado.res.icons")
local Backend = require("Legado/Backend")
local LocalExtension = require("Legado.LocalExtension")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")
local TaskProg = require("Legado.task.Progress")
local PlgState = require("Legado/PlgState")
local logger = require("logger")
local utf8c = require("Legado.Helper.utf8proc")
local Probe = require("Legado.Helper.Probe")

local M = {
    results = {},
    last_read_chapter = nil,

    bookinfo = nil,
    search_text = nil,
    call_mode = nil,
    is_single_source_search = nil,

    explore_url = nil,
    explore_page = nil,
    selected_source = nil,

    last_index = nil,
    has_more_api_results = nil,

    on_success_callback = nil,
    results_menu = nil,

    width = nil,
    height = nil,
    items_font_size = nil,
}

function M:init()
    self.width = math.floor(Screen:getWidth() * 0.9)
    self.height = math.floor(Screen:getHeight() * 0.9)
    self.items_font_size = Menu.getItemFontSize(8)
end

function M:getApiMoreRresults()
    if self.is_loading then return end
    if not self.has_more_api_results then return end
    if self.call_mode == "SEARCH" then
        self:handleMultiSourceSearch(self.search_text, true)
    elseif self.call_mode == "CHANGE_SOURCE" then
        self:handleAvailableBookSource(self.bookinfo, true)
    elseif self.call_mode == "EXPLORE" then
        self:handleExploreBook(self.selected_source, self.explore_url, true)
    end
end

function M:onMenuGotoPage(menu_self, new_page)
    Menu.onGotoPage(menu_self, new_page)
    local is_last_page = new_page == menu_self.page_num
    if is_last_page and self.has_more_api_results and not self.is_loading and self.last_index ~= nil then
        UIManager:nextTick(function()
            self:getApiMoreRresults()
        end)
    end
    return true
end

function M:menuCenterShow(menuObj)
    local menu_container = CenterContainer:new{
        dimen = Screen:getSize(),
        menuObj
    }
    menuObj.show_parent = menu_container
    UIManager:show(menu_container)
    return menu_container
end

function M:createMenu(opts)
    opts = opts or {}
    local disable_close_gestures = opts.disable_close_gestures ~= false
    local menu = Menu:new{
        is_enable_shortcut = false,
        fullscreen = true,
        covers_fullscreen = true,
        items_font_size = self.items_font_size,
        width = self.width,
        height = self.height,
        name = opts.name,
        title = opts.title,
        subtitle = opts.subtitle,
        item_table = opts.item_table,
        items_per_page = opts.items_per_page,
        onMenuSelect = opts.onMenuSelect,
        close_callback = opts.close_callback,
        title_bar_left_icon = opts.title_bar_left_icon,
    }
    if H.is_func(opts.onLeftButtonTap) then
        menu.onLeftButtonTap = opts.onLeftButtonTap
    end
    if disable_close_gestures then
        menu.onTapCloseAllMenus = function(self_m, _, ges_ev)
            if ges_ev.pos:notIntersectWith(self_m.dimen) then
                return true
            end
        end
        menu.onSwipe = function(self_m, arg, ges_ev)
            local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
            if direction == "south" then
                return true
            end
            return Menu.onSwipe(self_m, arg, ges_ev)
        end
    end
    return menu
end

function M:refreshItems(no_recalculate_dimen, append_data)
    if self.results_menu then
        self.results_menu.item_table = self:generateItemTableFromResults(append_data)
        Menu.updateItems(self.results_menu, nil, no_recalculate_dimen)
    end
end

function M:updateMenuTitle(new_title)
    if not (self.results_menu and UIManager:isWidgetShown(self.results_menu._container)) then
        return
    end
    self.results_menu.title = new_title
    if self.results_menu.title_bar then
        self.results_menu.title_bar:setTitle(new_title)
        UIManager:setDirty(self.results_menu._container or self.results_menu, "ui")
    end
    self.results_menu:updateItems()
end

local function truncate_utf8(s, n)
    if type(s) ~= "string" or utf8c.len(s) <= n then return s end
    return utf8c.sub(s, 1, n)
end

local function is_cancel_message(msg)
    return msg == "已取消" or msg == "user_cancelled" or msg == "cancelled"
        or (type(msg) == "string" and msg:lower():find("cancel", 1, true) ~= nil)
end

function M:updateBatchState(mode, success, has_more, msg)
    local is_normal_end = msg == "没有更多了"
    if is_normal_end then has_more = nil end
    self.has_more_api_results = has_more
    if mode == "EXPLORE" then return has_more end
    local done, aborted
    if mode == "SEARCH" then
        done, aborted = '多源搜索', '搜索中止'
    else
        done, aborted = '换源', '换源中止'
    end
    if not has_more and (success or is_normal_end) then
        self:updateMenuTitle(done)
    elseif has_more then
        self:updateMenuTitle(done .. '（还有更多）')
    else
        local err = tostring(msg or '')
        local head = truncate_utf8(err, 20)
        logger.warn("[BookSourceResults] " .. aborted .. ": " .. err)
        self:updateMenuTitle(aborted .. ' (' .. (err ~= head and head .. '…' or head) .. ')')
    end
    return has_more
end

function M:attachCancelToMenu(cancel_func)
    if not self.results_menu then return end
    local orig_close = self.results_menu.close_callback
    self.results_menu.close_callback = function()
        self:hideLoadingSpinner()
        if H.is_func(cancel_func) then cancel_func() end
        if orig_close then orig_close() end
    end
end

function M:showLoadingSpinner(message)
    self:hideLoadingSpinner()
    local Progress = require("Legado.task.Progress")
    self._loading_spinner = Progress.showSpinner(message or "加载中", {
        show_icon = false,
        dismissable = true,
    })
end

function M:hideLoadingSpinner()
    if self._loading_spinner then
        if type(self._loading_spinner.close) == "function" then
            self._loading_spinner:close()
        end
        self._loading_spinner = nil
    end
end

function M:withLoading(label, task_func, on_success, on_error)
    on_success = H.is_func(on_success) and on_success or function() end
    on_error = H.is_func(on_error) and on_error or function() end
    if Backend:_isLocal() then Backend:closeDbManager() end
    TaskProg.loading(label, task_func, function(state, response)
        if state == true then
            Backend:HandleResponse(response, on_success, on_error)
        end
    end, nil, true)
end

function M:modifySuccessCallback(is_close_menu)
    if H.is_func(self.on_success_callback) then
        UIManager:nextTick(function()
            self.on_success_callback()
        end)
    end
    return is_close_menu and self:onCloseMenu()
end

function M:onCloseMenu()
    self._multi_search_request_id = (self._multi_search_request_id or 0) + 1
    self._available_source_request_id = (self._available_source_request_id or 0) + 1
    self._multi_search_cancel = nil
    self._available_source_cancel = nil
    self.results = nil
    self.bookinfo = nil
    self.last_index = nil
    self.is_single_source_search = nil
    self.is_loading = nil

    self.explore_url = nil
    self.explore_page = nil
    self.selected_source = nil

    if self.results_menu and self.results_menu._container then
        UIManager:close(self.results_menu._container)
        self.results_menu._container = nil
    end
end

function M:createBookSourceMenu(option)
    local title = option.title
    local subtitle = option.subtitle

    local results_menu = self:createMenu{
        name = "book_search_results",
        title = title or "Search results",
        subtitle = subtitle,
        onMenuSelect = function(_, item)
            local source_index = item and item.source_index
            if not H.is_num(source_index) then return true end

            if source_index > 0 and H.is_tbl(self.results) then
                local bookinfo = self.results[source_index]
                self:showBookInfo(bookinfo)
            elseif source_index == 0 then
                self:getApiMoreRresults()
            end
            return true
        end,
        close_callback = function()
            self:onCloseMenu()
        end
    }

    if Device:hasDPad() then
        results_menu.key_events.FocusRight = nil
        results_menu.key_events.Right = {{ "Right" }}
    end

    results_menu.onGotoPage = function(menu_self, new_page)
        return self:onMenuGotoPage(menu_self, new_page)
    end

    results_menu.onMenuHold = results_menu.onMenuSelect

    self.results_menu = results_menu
    self.results_menu._container = self:menuCenterShow(results_menu)

    if option.show_parent then
        self.results_menu._container.show_parent = option.show_parent
    end

    self:refreshItems()

    return results_menu
end

function M:generateItemTableFromResults(append_data)

    local item_table = {}
    self.results = self.results or {}

    if H.is_tbl(append_data) then
        for _, v in ipairs(append_data) do
            table.insert(self.results, v)
        end
    end

    for source_index, new_bookinfo in ipairs(self.results) do
        local item_table_txt
        if self.is_single_source_search then
            item_table_txt = string.format("%s (%s)", new_bookinfo.name, new_bookinfo.author or "")
        else
            item_table_txt = string.format("%s (%s)[%s]", new_bookinfo.name, new_bookinfo.author or "",
                new_bookinfo.originName or "")
        end
        table.insert(item_table, {
            source_index = source_index,
            text = item_table_txt
        })
    end

    if self.has_more_api_results == true then
        table.insert(item_table, {
            source_index = 0,
            text = Icons.FA_ARROW_DOWN .. " 加载更多"
        })
    end

    return item_table
end

function M:changeSourceDialog(bookinfo, onReturnCallback)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl)) then
        return MessageBox:error('参数错误')
    end

    self:init()

    self.bookinfo = bookinfo
    self.call_mode = "CHANGE_SOURCE"
    self.on_success_callback = onReturnCallback

    return self:handleAvailableBookSource(bookinfo)
end

function M:showBookInfo(bookinfo)
    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.name) and bookinfo.name ~= "") then
        return MessageBox:error("书籍信息错误")
    end

    local download_book = Backend:isDownloadBook(bookinfo)
    local button_text = download_book and '下载整本'
        or ((self.call_mode == "SEARCH" or self.call_mode == "EXPLORE") and '添加' or '换源')

    local BookDetailsDialog = require("Legado/BookDetailsDialog")
    local dialog = BookDetailsDialog:new{
        bookinfo = bookinfo,
        buttons = {
            {
                text = button_text,
                callback = function()
                    if download_book then
                        LocalExtension.downloadBook(bookinfo)
                    elseif self.call_mode == "SEARCH" or self.call_mode == "EXPLORE" then
                        self:addBookToLibrary(bookinfo)
                    else
                        self:changeBookSource(bookinfo)
                    end
                end,
            },
        },
    }
    UIManager:show(dialog)
end

local function validateInput(text)
    return type(text) == 'string' and text:gsub("%s+", "") ~= ""
end

function M:searchBookDialog(onReturnCallback, def_input)
    if not Backend:canUseBookDiscovery() then
        return MessageBox:notice("本地接管解析模式下不支持添加书籍、搜索和探索")
    end

    local inputText
    local dialog
    self:init()
    local last_search_input = PlgState.last_search_input
    if last_search_input and not def_input then
        def_input = last_search_input
    end
    self.call_mode = "SEARCH"
    self.on_success_callback = onReturnCallback
    dialog = MessageBox:input(
        "请键入要搜索的书籍或作者名称：\n(多源搜索可使用 '=书名' 语法精确匹配)", nil, {
            title = '搜书',
            input_hint = "如：剑来",
            input = def_input,
            buttons = {{{
                text = "发现",
                callback = function()
                    UIManager:close(dialog)
                    self:exploreBookDialog()
                end
            }, {
                text = "单源搜索",
                callback = function()
                    inputText = dialog:getInputText()
                    inputText = util.trim(inputText)
                    if not validateInput(inputText) then
                        return MessageBox:notice("请输入有效书籍或作者名称")
                    end
                    UIManager:close(dialog)
                    self.search_text = inputText
                    PlgState.last_search_input = inputText
                    UIManager:nextTick(function()
                        self:handleSingleSourceSearch(inputText)
                    end)
                end
            }, {
                text = "多源搜索",
                is_enter_default = true,
                callback = function()
                    inputText = dialog:getInputText()
                    inputText = util.trim(inputText)
                    if not validateInput(inputText) then
                        return MessageBox:notice("请输入有效书籍或作者名称")
                    end
                    UIManager:close(dialog)
                    self.search_text = inputText
                    PlgState.last_search_input = inputText
                    UIManager:nextTick(function()
                        self:handleMultiSourceSearch(inputText)
                    end)
                end
            }, {
                text = "取消",
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end
            }}}
        })
end

function M:handleSingleSourceSearch(searchText)
    self:selectBookSource(function(item, sourceMenu)
        if not H.is_tbl(item) then return end
        local book_source_url = item.url
        local book_source_name = item.name
        self:withLoading(string.format("%s 查询中 ", item.text or ""), function()
            return Backend:searchBookSingle({
                search_text = searchText,
                book_source_url = book_source_url,
            })
        end, function(data)
            if not (H.is_tbl(data) or H.is_str(data)) then
                return MessageBox:notice('服务器返回数据错误')
            end
            if #data == 0 or not H.is_tbl(data[1]) then
                return MessageBox:notice('未找到相关书籍')
            end

            self.results = data
            self.is_single_source_search = true
            self:createBookSourceMenu({
                title = string.format('单源搜索 [%s]', book_source_name),
                subtitle = string.format("关键词：%s", searchText),
                show_parent = sourceMenu.show_parent,
            })
        end, function(err_msg)
            MessageBox:notice(err_msg or '搜索请求失败')
        end)
    end)
end

function M:handleMultiSourceSearch(search_text, is_more_call)
    if is_more_call and self.is_loading then return end
    if not (H.is_str(search_text) and search_text ~= "") then
        MessageBox:notice("参数错误")
        return
    end

    if not is_more_call then
        self._multi_search_request_id = (self._multi_search_request_id or 0) + 1
        local previous_cancel = self._multi_search_cancel
        self._multi_search_cancel = nil
        if H.is_func(previous_cancel) then previous_cancel() end
    elseif not self._multi_search_request_id then
        self._multi_search_request_id = 1
    end
    local request_id = self._multi_search_request_id

    self.call_mode = "SEARCH"
    self.search_text = search_text
    self.is_loading = true

    if not is_more_call then
        self.results = {}
        self.last_index = -1
        self.has_more_api_results = nil
    else
        self.last_index = (self.last_index ~= nil and self.last_index >= 0) and self.last_index or -1
    end

    self:showLoadingSpinner(string.format("正在搜索[%s]", search_text))
    local t_search_start = Probe.start("Source", "多源搜索", search_text, string.format("(last_index: %s, is_more: %s)", tostring(self.last_index), tostring(is_more_call or false)))
    if not is_more_call then
        self:createBookSourceMenu({
            title = '多源搜索 (加载中...)',
            subtitle = string.format("关键词：%s", search_text),
        })
    else
        self:updateMenuTitle('多源搜索 (加载中...)')
    end
    UIManager:forceRePaint()

    local cancel_func
    local finished = false

    cancel_func = Backend:searchBookMulti({
        search_text = search_text,
        last_index = self.last_index
    }, function(chunk)
        if request_id ~= self._multi_search_request_id then return end
        self:hideLoadingSpinner()
        Probe.event("Source", "搜索分片推流", string.format("chunk_size=%d total=%d last_index=%s", #(chunk or {}), #(self.results or {}), tostring(self.last_index or "-")))
        if self.results_menu and UIManager:isWidgetShown(self.results_menu._container) then
            self:refreshItems(false, chunk)
        end
    end, function(success, msg, last_index)
        if request_id ~= self._multi_search_request_id then return end
        finished = true
        self.is_loading = false
        if self._multi_search_cancel == cancel_func then self._multi_search_cancel = nil end
        cancel_func = nil
        self:hideLoadingSpinner()
        local has_more
        if success and H.is_num(last_index) and last_index >= 0 and self.last_index ~= last_index then
            self.last_index = last_index
            has_more = true
        end
        local Error = require("Legado.Helper.Error")
        local clean_msg = Error.extract_message(msg)
        self:updateBatchState("SEARCH", success, has_more, clean_msg)
        if self.results_menu and UIManager:isWidgetShown(self.results_menu._container) then
            self:refreshItems(false)
        end
        local is_cancel = is_cancel_message(clean_msg)
        if success then
            Probe.done("Source", "多源搜索", search_text, t_search_start, "200 OK", string.format("%d items", #(self.results or {})), string.format("has_more=%s", tostring(has_more or false)))
        elseif is_cancel then
            Probe.retry("Source", "多源搜索取消", search_text, t_search_start, clean_msg or "cancelled")
        else
            Probe.fail("Source", "多源搜索", search_text, t_search_start, clean_msg or "搜索失败")
        end
        if not success and not is_cancel and clean_msg ~= "没有更多了" then
            MessageBox:notice(clean_msg or "搜索失败")
        elseif success and clean_msg then
            MessageBox:notice(clean_msg)
        elseif success and self.results and #self.results == 0 then
            MessageBox:notice('未找到相关书籍')
        end
    end)
    if not finished then self._multi_search_cancel = cancel_func end
    self:attachCancelToMenu(function()
        if request_id == self._multi_search_request_id then
            self._multi_search_request_id = request_id + 1
            self._multi_search_cancel = nil
        end
        if H.is_func(cancel_func) then cancel_func() end
    end)
end

function M:handleAvailableBookSource(bookinfo, is_more_call)
    if is_more_call and self.is_loading then return end

    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl)) then
        return MessageBox:error('参数错误')
    end

    self._available_source_request_id = (self._available_source_request_id or 0) + 1
    local request_id = self._available_source_request_id
    local previous_cancel = self._available_source_cancel
    self._available_source_cancel = nil
    if H.is_func(previous_cancel) then previous_cancel() end

    self.call_mode = "CHANGE_SOURCE"
    self.bookinfo = bookinfo
    self.is_loading = true
    if not is_more_call then
        self.results = {}
        self.last_index = -1
        self.has_more_api_results = nil
    else
        self.last_index = (self.last_index ~= nil and self.last_index >= 0) and self.last_index or -1
    end

    local options = {
        book_url = bookinfo.bookUrl,
        name = bookinfo.name,
        author = bookinfo.author,
        last_index = is_more_call and self.last_index,
        search_size = 8,
    }

    self:showLoadingSpinner(string.format("搜索[%s]可用书源", bookinfo.name))
    local t_source_start = Probe.start("Source", "检索可用书源", bookinfo.name, string.format("(author: %s, origin: %s, is_more: %s)", tostring(bookinfo.author or "-"), tostring(bookinfo.origin or bookinfo.originName or "-"), tostring(is_more_call or false)))
    if not is_more_call then
        self:createBookSourceMenu({
            title = '正在查找书源…',
            subtitle = string.format("%s (%s)", bookinfo.name, bookinfo.author),
        })
    else
        self:updateMenuTitle('正在查找书源…')
    end
    UIManager:forceRePaint()

    local cancel_func
    local finished = false

    cancel_func = Backend:getAvailableBookSource(options, function(success, data, msg, last_index)
        if request_id ~= self._available_source_request_id then return end
        finished = true
        self.is_loading = false
        if self._available_source_cancel == cancel_func then self._available_source_cancel = nil end
        cancel_func = nil
        self:hideLoadingSpinner()

        local Error = require("Legado.Helper.Error")
        local clean_msg = msg ~= nil and Error.extract_message(msg)
            or (not success and Error.extract_message(data) or nil)
        if not success then
            if is_cancel_message(clean_msg) then
                Probe.retry("Source", "检索可用书源取消", bookinfo.name, t_source_start, clean_msg or "cancelled")
                return
            end
            self:updateBatchState("CHANGE_SOURCE", false, nil, clean_msg or "加载失败")
            Probe.fail("Source", "检索可用书源", bookinfo.name, t_source_start, clean_msg or "加载失败")
            return MessageBox:error(clean_msg or '加载失败')
        end
        if not (H.is_tbl(data) and H.is_tbl(data.list)) then
            Probe.fail("Source", "检索可用书源", bookinfo.name, t_source_start, "返回书源数据结构异常")
            return MessageBox:notice('返回书源错误')
        end
        if #data.list == 0 and not is_more_call then
            if data.partial then
                self:updateBatchState("CHANGE_SOURCE", true, nil, clean_msg)
                self:updateMenuTitle("换源（部分结果）")
                Probe.done("Source", "检索可用书源", bookinfo.name, t_source_start, "206 PARTIAL", "0 sources", clean_msg)
                return MessageBox:notice(clean_msg and ("当前范围未找到可用源；" .. clean_msg)
                    or "仅搜索部分书源，未找到可用源")
            end
            Probe.done("Source", "检索可用书源", bookinfo.name, t_source_start, "404 NOT_FOUND", "0 sources")
            return MessageBox:error('没有找到可用源')
        end

        local has_more
        if H.is_num(last_index) and last_index >= 0 and self.last_index ~= last_index then
            self.last_index = last_index
            has_more = true
        end

        if is_more_call ~= true then
            self.results = data.list
        else
            for _, item in ipairs(data.list) do
                table.insert(self.results, item)
            end
        end
        self:updateBatchState("CHANGE_SOURCE", true, has_more, clean_msg or data)
        if data.partial then self:updateMenuTitle("换源（部分结果）") end
        Probe.done("Source", "检索可用书源", bookinfo.name, t_source_start,
            data.partial and "206 PARTIAL" or "200 OK",
            string.format("%d sources", #(self.results or {})),
            data.partial and tostring(clean_msg or "搜索范围受限") or string.format("has_more=%s", tostring(has_more or false)))
        if self.results_menu and UIManager:isWidgetShown(self.results_menu._container) then
            self:refreshItems(false)
        end
    end, function(chunk)
        if request_id ~= self._available_source_request_id then return end
        self:hideLoadingSpinner()
        if self.results_menu and UIManager:isWidgetShown(self.results_menu._container) then
            self:refreshItems(false, chunk)
        end
        Probe.event("Source", "书源分片推流", string.format("chunk_size=%d total=%d", #(chunk or {}), #(self.results or {})))
    end)

    if not finished then self._available_source_cancel = cancel_func end
    self:attachCancelToMenu(function()
        if request_id == self._available_source_request_id then
            self._available_source_request_id = request_id + 1
            self._available_source_cancel = nil
        end
        if H.is_func(cancel_func) then cancel_func() end
    end)
end

function M:autoChangeSource(bookinfo, _)
    if not H.is_tbl(bookinfo) or not H.is_str(bookinfo.bookUrl) then
        return MessageBox:error('参数错误')
    end
    local t_auto_start = Probe.start("Source", "自动换源", bookinfo.name, string.format("(origin: %s)", tostring(bookinfo.origin or bookinfo.originName or "-")))
    self:withLoading("正在换源 ", function()
        return Backend:autoChangeBookSource(bookinfo)
    end, function()
        Probe.done("Source", "自动换源", bookinfo.name, t_auto_start, "200 OK")
        MessageBox:notice('更换成功')
        self:modifySuccessCallback(true)
    end, function(err_msg)
        Probe.fail("Source", "自动换源", bookinfo.name, t_auto_start, tostring(err_msg))
        MessageBox:error(err_msg or '操作失败')
    end)
end

function M:selectBookSource(selectCallback, options)
    options = options or {}
    self:init()
    Backend:closeDbManager()
    self:withLoading(options.loading_text or "获取源列表 ", function()
        return Backend:getBookSourcesListCached()
    end, function(data)
        if not H.is_tbl(data) then
            return MessageBox:notice('返回源数据错误')
        end
        if #data == 0 then
            return MessageBox:error(options.empty_text or '没有可用源')
        end

        Backend:BookSourcesAndRulesAsync()

                local source_list_menu_table = {}
                local source_list_container
                local with_explore_url = self.call_mode == "EXPLORE"

                for _, v in ipairs(data) do
                    if H.is_tbl(v) and H.is_str(v.bookSourceName) and H.is_str(v.bookSourceUrl) and (not v.enabled or v.enabled == true) then
                        if with_explore_url and (not v.enabledExplore and not v.exploreUrl) then
                            goto continue
                        end
                        local group = (H.is_str(v.bookSourceGroup) and v.bookSourceGroup ~= "") and string.format(" [%s]", v.bookSourceGroup) or ""
                        local login_tag = (options.sort_has_login and v.hasLogin) and " [登录]" or ""
                        table.insert(source_list_menu_table, {
                            text = string.format("%s%s%s", v.bookSourceName, group, login_tag),
                            url = v.bookSourceUrl,
                            name = v.bookSourceName,
                            bookSourceUrl = v.bookSourceUrl,
                            bookSourceName = v.bookSourceName,
                            bookSourceGroup = H.is_str(v.bookSourceGroup) and v.bookSourceGroup or nil,
                            hasLogin = v.hasLogin and true or false,
                            _orig_idx = #source_list_menu_table + 1,
                        })
                        ::continue::
                    end
                end

                if options.sort_has_login then
                    table.sort(source_list_menu_table, function(a, b)
                        local a_login = a.hasLogin and 1 or 0
                        local b_login = b.hasLogin and 1 or 0
                        if a_login ~= b_login then
                            return a_login > b_login
                        end
                        return (a._orig_idx or 0) < (b._orig_idx or 0)
                    end)
                end

                if #source_list_menu_table == 0 and with_explore_url then
                    return MessageBox:notice("没有找到支持探索功能的书源")
                end

                local all_source_items = source_list_menu_table
                local active_search_query = ""
                local source_list_menu
                local function applySourceFilter(query)
                    active_search_query = type(query) == "string" and util.trim(query) or ""
                    local normalized_query = string.lower(active_search_query)
                    local filtered_items = {}

                    for _, item in ipairs(all_source_items) do
                        local matches = normalized_query == ""
                            or string.find(string.lower(item.bookSourceName), normalized_query, 1, true)
                            or string.find(string.lower(item.bookSourceUrl), normalized_query, 1, true)
                            or (item.bookSourceGroup
                                and string.find(string.lower(item.bookSourceGroup), normalized_query, 1, true))
                        if matches then
                            table.insert(filtered_items, item)
                        end
                    end

                    source_list_menu:switchItemTable(nil, filtered_items, nil)
                    if #filtered_items == 0 then
                        MessageBox:notice("没有匹配的书源")
                    end
                end

                local default_subtitle = Backend:_isLocal() and "点击选择书源" or string.format("关键词：%s", self.search_text or "")
                source_list_menu = self:createMenu{
                    title = options.title or "选择书源",
                    subtitle = options.subtitle or default_subtitle,
                    item_table = source_list_menu_table,
                    items_per_page = 15,
                    title_bar_left_icon = options.title_bar_left_icon == nil and "appbar.search" or options.title_bar_left_icon,
                    onLeftButtonTap = options.onLeftButtonTap or function()
                        MessageBox:input("请输入书源名称、URL 或分组：", function(query)
                            if query ~= nil then
                                applySourceFilter(query)
                            end
                        end, {
                            title = "筛选书源",
                            input_hint = "名称、URL 或分组",
                            input = active_search_query,
                        })
                    end,
                    onMenuSelect = function(menu_self, item)
                        if H.is_func(selectCallback) then
                            selectCallback(item, menu_self)
                        end
                    end,
                    close_callback = function()
                        UIManager:close(source_list_container)
                        source_list_container = nil
                    end
                }
                source_list_menu.onLeftButtonHold = options.onLeftButtonHold or function()
                    local started, err = Backend:BookSourcesAndRulesAsync(true)
                    if started == false then
                        return MessageBox:notice(tostring(err or "当前模式不支持刷新书源"))
                    end
                    MessageBox:notice("已加入书源刷新任务")
                end
                if options.onMenuHold then
                    source_list_menu.onMenuHold = options.onMenuHold
                end
                source_list_container = self:menuCenterShow(source_list_menu)

    end, function(err_msg)
        MessageBox:notice('列表请求失败:', tostring(err_msg))
    end)
end

function M:showSourceContextMenu(item)
    if not item then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local source_name = item.bookSourceName or item.name or "当前书源"
    local source_actions = {
        {
            text = "测试",
            callback = function()
                UIManager:close(dialog)
                LocalExtension.testSource(item)
            end,
        },
    }
    local has_login = item.hasLogin
    if has_login == nil and Backend.dbManager
            and type(Backend.dbManager.getBookSourceByUrl) == "function" then
        local source = Backend.dbManager:getBookSourceByUrl(Backend:getCurrentBookShelfId(), item.bookSourceUrl or item.url)
        has_login = require("Legado.Helper.BookSourceLogin").hasLogin(source)
    end
    if has_login == true then
        source_actions[#source_actions + 1] = {
            text = "登录",
            callback = function()
                UIManager:close(dialog)
                LocalExtension.showSourceLogin(item)
            end,
        }
    end
    local function clear_source(action, label)
        UIManager:close(dialog)
        TaskProg.loading("正在" .. label, function()
            return Backend:loginBookSource({bookSourceUrl = item.bookSourceUrl or item.url, action = action})
        end, function(state, response)
            if state ~= true then return end
            Backend:HandleResponse(response, function(result)
                MessageBox:notice(result.message)
            end, function(err)
                MessageBox:error(label .. "失败", tostring(err))
            end)
        end, nil, true)
    end
    local buttons = {}
    for _, action in ipairs(source_actions) do buttons[#buttons + 1] = {action} end
    buttons[#buttons + 1] = {{text = "清除cache", callback = function() clear_source("clear_cache", "清除cache") end}}
    buttons[#buttons + 1] = {{text = "清除cookie", callback = function() clear_source("logout", "清除cookie") end}}
    buttons[#buttons + 1] = {{text = "取消", callback = function() UIManager:close(dialog) end}}
    dialog = ButtonDialog:new{
        title = "书源操作：" .. source_name,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:openLocalBookSourceSettings()
    if not Backend:_isLocal() then
        return MessageBox:notice("远程模式请在阅读 App 内登录书源")
    end
    self:selectBookSource(function(item)
        if item then
            self:showSourceContextMenu(item)
        end
    end, {
        title = "本地书源设置",
        subtitle = "点击设置",
        loading_text = "获取书源列表 ",
        empty_text = "本地没有可用书源",
        sort_has_login = true,
    })
end

function M:changeBookSource(bookinfo)
    if not (self.bookinfo and bookinfo) then
        MessageBox:notice('参数错误')
        return
    end
    local new_bookinfo = {
        bookUrl = self.bookinfo.bookUrl,
        newUrl = bookinfo.bookUrl,
        bookSourceUrl = bookinfo.origin,
        name = self.bookinfo.name,
        author = self.bookinfo.author,
        originName = bookinfo.originName,
    }

    if not (self.call_mode ~= "SEARCH" and H.is_str(self.bookinfo.bookUrl) and H.is_str(bookinfo.bookUrl) and H.is_str(bookinfo.origin)) then
        MessageBox:notice('参数错误')
        return
    end
    local target_source_name = bookinfo.originName or bookinfo.origin or "未知源"
    local t_change_start = Probe.start("Source", "执行换源", self.bookinfo.name, string.format("-> 新源: %s", target_source_name))
    Backend:closeDbManager()
    self:withLoading("更换中 ", function()
        return Backend:changeBookSource(new_bookinfo)
    end, function()
        Probe.done("Source", "执行换源", self.bookinfo.name, t_change_start, "200 OK", nil, string.format("新源: %s", target_source_name))
        MessageBox:notice('换源成功')
        self:modifySuccessCallback(true)
    end, function(err_msg)
        Probe.fail("Source", "执行换源", self.bookinfo.name, t_change_start, tostring(err_msg))
        MessageBox:error(err_msg or '操作失败')
    end)
end

function M:addBookToLibrary(bookinfo)
    if self.call_mode ~= "SEARCH" and self.call_mode ~= "EXPLORE" then
        return MessageBox:notice('参数错误')
    end
    local book_name = (H.is_tbl(bookinfo) and bookinfo.name) or "未知书籍"
    local source_name = (H.is_tbl(bookinfo) and (bookinfo.originName or bookinfo.origin)) or "-"
    local t_add_start = Probe.start("Source", "书籍入库", book_name, string.format("(source: %s, url: %s)", source_name, tostring(bookinfo.bookUrl or "-")))
    Backend:closeDbManager()
    self:withLoading("添加中 ", function()
        return Backend:addBookToLibrary(bookinfo)
    end, function()
        Probe.done("Source", "书籍入库", book_name, t_add_start, "200 OK", nil, string.format("源: %s", source_name))
        MessageBox:notice('添加成功')
        self:modifySuccessCallback(true)
    end, function(err_msg)
        Probe.fail("Source", "书籍入库", book_name, t_add_start, tostring(err_msg))
        MessageBox:error(err_msg or '操作失败')
    end)
end

function M:exploreBookDialog(onReturnCallback)
    self:init()
    self.on_success_callback = onReturnCallback
    self.call_mode = "EXPLORE"
    self.search_text = "书源探索"

    self:selectBookSource(function(item, _)
        if not (H.is_tbl(item) and H.is_str(item.url)) then return end

        local selected_source = {
                bookSourceName = item.name,
                bookSourceUrl = item.url,
        }
        self.selected_source = selected_source
        self:selectExploreCategory(selected_source)
    end)
end

function M:selectExploreCategory(source)
    if not ( H.is_tbl(source) and H.is_str(source.bookSourceUrl) and source.bookSourceUrl ~= "") then
        return MessageBox:error("书源参数缺失")
    end

    local bookSourceUrl = source.bookSourceUrl
    local bookSourceName = source.bookSourceName

    local decode_explore_url = function(explore_url)
        if not (H.is_str(explore_url) and explore_url ~= "") then
            return MessageBox:info("书源没有探索选项")
        end

        local json = require("json")
        local success, categories = pcall(json.decode, explore_url, json.decode.simple)
        if not (success and H.is_tbl(categories)) then

            categories = {}
            local normalized = explore_url
                :gsub("&&", "\n")
                :gsub("\r", "\n")
                :gsub("\n+", "\n")

            for raw_title, raw_url in normalized:gmatch("([^%c]+)::%s*([^\n]+)") do
                local title = raw_title:match("^%s*(.-)%s*$")
                local url = raw_url:match("^%s*(.-)%s*$")
                table.insert(categories, { title = title, url = url })
            end
        end

        if not (H.is_tbl(categories) and #categories > 0) then
            return MessageBox:error("此源没有有效探索配置")
        end

        local category_dialog
        local category_buttons = {}
        local row = {}
        local is_title_line
        local has_valid_line

        for i, category in ipairs(categories) do
            if H.is_str(category.title) and category.title ~= "" then

                is_title_line = not (H.is_str(category.url) and category.url ~= "")
                if not is_title_line then
                    table.insert(row, {
                        text = category.title,
                        callback = function()
                            self:handleExploreBook(source, category.url)
                        end,
                    })
                end
                if #row == 4 or (i == #categories and #row > 0) then
                    table.insert(category_buttons, row)
                    row = {}
                    has_valid_line = true
                end
                if is_title_line then
                    table.insert(category_buttons, {{
                        text = category.title,
                        callback = function() end,
                        enabled = false,
                    }})
                end
            end
        end

        if #category_buttons == 0 or has_valid_line ~= true then
            return MessageBox:error("无有效探索分类")
        end

        local Font = require("ui/font")
        category_dialog = require("ui/widget/buttondialog"):new{
            title = string.format("发现 · %s", bookSourceName or ""),
            title_align = "center",
            title_face = Font:getFace("smallffont"),
            info_face = Font:getFace("ffont"),
            buttons = category_buttons,
            dismissable = true,
            width_factor = 0.8,
        }

        UIManager:show(category_dialog)
    end

    self:withLoading("正在获取探索信息...", function()
            return Backend:getBookSourcesExploreUrl(bookSourceUrl)
    end, function(data)
        if not (H.is_tbl(data) and H.is_str(data.exploreUrl) )then
            return MessageBox:notice('服务器返回数据异常')
        end
        decode_explore_url(data.exploreUrl)
    end, function(err_msg)
        MessageBox:notice(err_msg or '加载失败')
    end)
end

function M:handleExploreBook(source_info, url, is_more_call)
    if not( H.is_tbl(source_info) and H.is_str(url) ) then
        return MessageBox:error("参数错误")
    end

    self.explore_page = is_more_call and (self.explore_page + 1) or 1

    local options = {
        bookSourceUrl = source_info.bookSourceUrl,
        ruleFindUrl = url,
        page = self.explore_page,
    }

    self:withLoading("正在加载书籍...", function()
       return Backend:exploreBook(options)
    end, function(data)
        if not H.is_tbl(data) then
            return MessageBox:notice('服务器返回数据错误')
        end
        if #data == 0 and not is_more_call then
           return MessageBox:notice('没有更多书籍')
        end
        self:updateBatchState("EXPLORE", true, #data > 0, nil)

        if is_more_call ~= true then
            self.results = data
            self.explore_url = url
            self:createBookSourceMenu({
                title = string.format("发现 · %s", source_info.bookSourceName or ""),
                subtitle = url,
            })
        else
            self:refreshItems(false, data)
        end
    end, function(err_msg)
        self:updateBatchState("EXPLORE", true, self.has_more_api_results, err_msg)
        MessageBox:notice(err_msg or '加载失败')
    end)
end

return M
