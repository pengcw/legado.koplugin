local UIManager = require("ui/uimanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local Menu = require("ui/widget/menu")
local Device = require("device")
local util = require("util")
local BD = require("ui/bidi")
local Screen = Device.screen

local Icons = require("Legado.res.icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")
local TaskProg = require("Legado.task.Progress")
local PlgState = require("Legado/PlgState")
local logger = require("logger")
local utf8c = require("Legado.Helper.utf8proc")

local M = {
    results = {},
    last_read_chapter = nil,
    
    bookinfo = nil,
    search_text = nil,
    -- call_mode: "CHANGE_SOURCE" / "SEARCH" / "AUTO_CHANGE_SOURCE" / "EXPLORE"
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
    if is_last_page and self.has_more_api_results and self.last_index ~= nil then
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

-- 圆角和is_popout(默认true)互斥
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
    }
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

-- 统一分页批次状态：has_more 落账 + 标题三态。加载中=请求在进行（入口处置），
-- 完成后 has_more→“（还有更多）”，结束→正常/中止；EXPLORE 仅落账标题保持常态
function M:updateBatchState(mode, success, has_more, msg)
    if msg == "没有更多了" then has_more = nil end
    self.has_more_api_results = has_more
    if mode == "EXPLORE" then return has_more end
    local done, aborted
    if mode == "SEARCH" then
        done, aborted = '多源搜索', '搜索中止'
    else
        done, aborted = '换源', '换源中止'
    end
    if not has_more and success then
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
    if not (self.results_menu and cancel_func) then return end
    local orig_close = self.results_menu.close_callback
    self.results_menu.close_callback = function()
        self:hideLoadingSpinner()
        if cancel_func then cancel_func() end
        if orig_close then orig_close() end
    end
end

function M:showLoadingSpinner(message)
    if self._loading_spinner then
        -- 旧 spinner 已被用户手动关闭：重置引用后再新建（否则后续请求不会再显示）
        if self._loading_spinner.closed then
            self._loading_spinner = nil
        else
            return
        end
    end
    local Progress = require("Legado.task.Progress")
    self._loading_spinner = Progress.showSpinner(message or "加载中", {
        show_icon = false,
        dismissable = true,
    })
end

function M:hideLoadingSpinner()
    if self._loading_spinner then
        self._loading_spinner:close()
        self._loading_spinner = nil
    end
end

function M:withLoading(label, task_func, on_success, on_error)
    on_success = H.is_func(on_success) and on_success or function() end
    on_error = H.is_func(on_error) and on_error or function() end
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
    self.results = nil
    self.bookinfo = nil
    self.last_index = nil
    self.is_single_source_search = nil

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
    
    -- 结果不足一页时追加"加载更多"按钮
    if self.has_more_api_results == true then
        local results_menu_perpage = 15
        if self.results_menu and self.results_menu.perpage then
            results_menu_perpage = tonumber(self.results_menu.perpage) or 15
        end
        if not (#self.results > results_menu_perpage) then
            table.insert(item_table, {
                source_index = 0,
                text = Icons.FA_ARROW_DOWN .. " 点击加载更多 ..."
            })
        end
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

    local button_text = (self.call_mode == "SEARCH" or self.call_mode == "EXPLORE") and '添加' or '换源'

    local BookDetailsDialog = require("Legado/BookDetailsDialog")
    local dialog = BookDetailsDialog:new{
        bookinfo = bookinfo,
        buttons = {
            {
                text = button_text,
                callback = function()
                    if self.call_mode == "SEARCH" or self.call_mode == "EXPLORE" then
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
            title = '添加书籍',
            input_hint = "如：剑来",
            input = def_input,
            buttons = {{{
                text = "书源发现",
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
            if not H.is_tbl(data) then
                return MessageBox:notice('服务器返回数据错误')
            end
            if #data == 0 or not H.is_tbl(data[1]) then
                return MessageBox:notice('未找到相关书籍')
            end

            self.results = data
            self.is_single_source_search = true
            self:createBookSourceMenu({
                title = string.format('单源搜索 [%s]', book_source_name),
                subtitle = string.format("key: %s", searchText),
                show_parent = sourceMenu.show_parent,
            })
        end, function(err_msg)
            MessageBox:notice(err_msg or '搜索请求失败')
        end)
    end)
end

function M:handleMultiSourceSearch(search_text, is_more_call)
    if not (H.is_str(search_text) and search_text ~= "") then
        MessageBox:notice("参数错误")
        return
    end
    
    self.last_index = self.last_index ~= nil and self.last_index or -1

    if not is_more_call then
        self.results = {}
        self.has_more_api_results = nil
    end
    self:showLoadingSpinner(string.format("正在搜索[%s]", search_text))
    if not is_more_call then
        self:createBookSourceMenu({
            title = '多源搜索 (加载中...)',
            subtitle = string.format("key: %s", search_text),
        })
    else
        -- 续搜：菜单已存在，不得重建（丢滚动），仅回置标题
        self:updateMenuTitle('多源搜索 (加载中...)')
    end
    -- forceRePaint：否则会被后续计算阻塞不刷新
    UIManager:forceRePaint()

    local cancel_func

    cancel_func = Backend:searchBookMulti({
        search_text = search_text,
        last_index = self.last_index
    }, function(chunk)
        self:hideLoadingSpinner()
        if self.results_menu and UIManager:isWidgetShown(self.results_menu._container) then
            self:refreshItems(false, chunk)
        end
    end, function(success, msg, last_index)
        cancel_func = nil
        self:hideLoadingSpinner()
        -- reader3 SSE 续搜推进 lastIndex；其他端第三参 nil → 永不触发
        local has_more
        if success and H.is_num(last_index) and self.last_index ~= last_index then
            self.last_index = last_index
            has_more = true
        end
        self:updateBatchState("SEARCH", success, has_more, msg)
        if not success and msg ~= "已取消" then
            MessageBox:notice(msg or "搜索失败")
        elseif success and self.results and #self.results == 0 then
            MessageBox:notice('未找到相关书籍')
        end
    end)
    self:attachCancelToMenu(cancel_func)
end

function M:handleAvailableBookSource(bookinfo, is_more_call)

    if not (H.is_tbl(bookinfo) and H.is_str(bookinfo.bookUrl)) then
        return MessageBox:error('参数错误')
    end

    self.last_index = self.last_index ~= nil and self.last_index or -1

    local options = {
        book_url = bookinfo.bookUrl,
        name = bookinfo.name,
        author = bookinfo.author,
        last_index = is_more_call and self.last_index,
        search_size = 8,
    }

    if not is_more_call then
        self.results = {}
        self.has_more_api_results = nil
    end
    self:showLoadingSpinner(string.format("搜索[%s]可用书源", bookinfo.name))
    if not is_more_call then
        self:createBookSourceMenu({
            title = '换源 (加载中...)',
            subtitle = string.format("%s (%s)", bookinfo.name, bookinfo.author),
        })
    else
        self:updateMenuTitle('换源 (加载中...)')
    end
    UIManager:forceRePaint()

    local cancel_func

    cancel_func = Backend:getAvailableBookSource(options, function(success, data, msg, last_index)
        cancel_func = nil
        self:hideLoadingSpinner()
        if not success then
            self:updateBatchState("CHANGE_SOURCE", false, nil, msg or data or "加载失败")
            return MessageBox:error(msg or data or '加载失败')
        end
        if not (H.is_tbl(data) and H.is_tbl(data.list)) then
            return MessageBox:notice('返回书源错误')
        end
        if #data.list == 0 then
            return MessageBox:error('没有找到可用源')
        end

        local has_more
        if H.is_num(last_index) and self.last_index ~= last_index then
            self.last_index = last_index
            has_more = true
        end

        if is_more_call ~= true then
            self.results = data.list
        end
        self:updateBatchState("CHANGE_SOURCE", true, has_more, msg or data)
        -- 重新生成列表（菜单创建时 item_table 为空）
        if self.results_menu and UIManager:isWidgetShown(self.results_menu._container) then
            self:refreshItems(false)
        end
    end, function(chunk)
        self:hideLoadingSpinner()
        if self.results_menu and UIManager:isWidgetShown(self.results_menu._container) then
            self:refreshItems(false, chunk)
        end
    end)

    self:attachCancelToMenu(cancel_func)
    if cancel_func then
        self._available_source_cancel = cancel_func
    end
end

function M:autoChangeSource(bookinfo, _)
    if not H.is_tbl(bookinfo) or not H.is_str(bookinfo.bookUrl) then
        return MessageBox:error('参数错误')
    end
    self:withLoading("正在换源 ", function()
        return Backend:autoChangeBookSource(bookinfo)
    end, function(_)
        MessageBox:notice('更换成功')
        self:modifySuccessCallback(true)
    end, function(err_msg)
        MessageBox:error(err_msg or '操作失败')
    end)
end

function M:selectBookSource(selectCallback)
    self:withLoading("获取源列表 ", function()
        return Backend:getBookSourcesList()
    end, function(data)
        if not H.is_tbl(data) then
            return MessageBox:notice('返回源数据错误')
        end
        if #data == 0 then
            return MessageBox:error('没有可用源')
        end

                local source_list_menu_table = {}
                local source_list_container
                local with_explore_url = self.call_mode == "EXPLORE"

                for _, v in ipairs(data) do
                    -- reader3 无 enabled 字段
                    if H.is_tbl(v) and H.is_str(v.bookSourceName) and H.is_str(v.bookSourceUrl) and (not v.enabled or v.enabled == true) then
                        if with_explore_url and (not v.enabledExplore and not v.exploreUrl) then
                            goto continue
                        end
                        table.insert(source_list_menu_table, {
                            text = string.format("%s [%s]", v.bookSourceName, v.bookSourceGroup or ""),
                            url = v.bookSourceUrl,
                            name = v.bookSourceName,
                        })
                        ::continue::
                    end
                end

                if #source_list_menu_table == 0 and with_explore_url then
                    return MessageBox:notice("没有找到支持探索功能的书源")
                end

                source_list_container = self:menuCenterShow(self:createMenu{
                    title = "请指定要操作的源",
                    subtitle = string.format("key: %s", self.search_text or ""),
                    item_table = source_list_menu_table,
                    items_per_page = 15,
                    onMenuSelect = function(menu_self, item)
                        if H.is_func(selectCallback) then
                            selectCallback(item, menu_self)
                        end
                    end,
                    close_callback = function()
                        UIManager:close(source_list_container)
                        source_list_container = nil
                    end
                })

    end, function(err_msg)
        MessageBox:notice('列表请求失败:', tostring(err_msg))
    end)
end

function M:changeBookSource(bookinfo)
    if not (self.bookinfo and bookinfo) then
        MessageBox:notice('参数错误')
        return
    end
    -- fix legado app 只支持 save
    local new_bookinfo = self.bookinfo
    new_bookinfo.bookSourceUrl = bookinfo.origin
    new_bookinfo.newUrl = bookinfo.bookUrl

    if not (self.call_mode ~= "SEARCH" and H.is_str(self.bookinfo.bookUrl) and H.is_str(bookinfo.bookUrl) and H.is_str(bookinfo.origin)) then
        MessageBox:notice('参数错误')
        return
    end
    Backend:closeDbManager()
    self:withLoading("更换中 ", function()
        return Backend:changeBookSource(new_bookinfo)
    end, function(_)
        MessageBox:notice('换源成功')
    end, function(err_msg)
        MessageBox:error(err_msg or '操作失败')
    end)
end

function M:addBookToLibrary(bookinfo)
    if self.call_mode ~= "SEARCH" and self.call_mode ~= "EXPLORE" then
        return MessageBox:notice('参数错误')
    end
    Backend:closeDbManager()
    self:withLoading("添加中 ", function()
        return Backend:addBookToLibrary(bookinfo)
    end, function(_)
        MessageBox:notice('添加成功')
        self:modifySuccessCallback(true)
    end, function(err_msg)
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

            for title, url in normalized:gmatch("([^%c]+)::%s*([^\n]+)") do
                title = title:match("^%s*(.-)%s*$")
                url = url:match("^%s*(.-)%s*$")
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
            title = string.format("探索 - %s", bookSourceName or ""),
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
        
        -- /exploreBook 返回标准 bookinfo, 不需要添加 origin originName
        if is_more_call ~= true then
            self.results = data
            self.explore_url = url
            self:createBookSourceMenu({
                title = string.format("探索 - %s", source_info.bookSourceName or ""),
                subtitle = url,
            })
        else
            self:refreshItems(false, data)
        end
    end, function(err_msg)
        -- 统一终止信号（"没有更多了"关闭 has_more）
        self:updateBatchState("EXPLORE", true, self.has_more_api_results, err_msg)
        MessageBox:notice(err_msg or '加载失败')
    end)
end

return M
