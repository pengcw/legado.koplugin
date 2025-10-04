local UIManager = require("ui/uimanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local Menu = require("ui/widget/menu")
local Device = require("device")
local Event = require("ui/event")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local util = require("util")
local Screen = Device.screen
local T = ffiUtil.template

local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local M = {
    results = {},
    last_read_chapter = nil,
    _last_search_input = nil,

    bookinfo = nil,
    search_text = nil,
    -- "CHANGE_SOURCE"
    -- "SEARCH"
    -- "AUTO_CHANGE_SOURCE"
    call_mode = nil,
    is_single_source_search = nil,

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

function M:refreshItems(no_recalculate_dimen, append_data)
    if self.results_menu then
        self.results_menu.item_table = self:generateItemTableFromResults(append_data)
        Menu.updateItems(self.results_menu, nil, no_recalculate_dimen)
    end
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
    self.search_text = nil
    self.call_mode = nil
    self.last_index = nil
    self.is_single_source_search = nil
    if self.results_menu and self.results_menu._container then
        UIManager:close(self.results_menu._container)
        self.results_menu._container = nil
    end
end

function M:createBookSourceMenu(option)
    local title = option.title
    local subtitle = option.subtitle

    local results_menu
    results_menu = Menu:new{
        name = "book_search_results",
        is_enable_shortcut = false,
        fullscreen = true,
        covers_fullscreen = true,
        items_font_size = self.items_font_size,
        width = self.width,
        height = self.height,

        title = title or "Search results",
        subtitle = subtitle,
        onMenuSelect = function(self_menu, item)
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
    
    -- add command item; if not enough to fill one page, add a button
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
    if not H.is_tbl(bookinfo) then
        return MessageBox:error("参数错误")
    end

    local msginfo = [[
书名: <<%1>>
作者: %2
分类: %3
书源名称: %4
书源地址: %5
总章数：%6
总字数：%7
简介：%8
]]

    -- 限制简介长度，避免字体过小
    local intro = bookinfo.intro or ''
    local max_intro_length = 200
    if #intro > max_intro_length then
        intro = intro:sub(1, max_intro_length) .. "..."
    end

    msginfo = T(msginfo, bookinfo.name or '', bookinfo.author or '', bookinfo.kind or '', bookinfo.originName or '',
        bookinfo.origin or '', bookinfo.totalChapterNum or '', bookinfo.wordCount or '', intro)

    MessageBox:confirm(msginfo, nil, {
        icon = "notice-info",
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = {{{
            text = (self.call_mode == "SEARCH") and '添加' or '换源',
            callback = function()
                if self.call_mode == "SEARCH" then
                    self:addBookToLibrary(bookinfo)
                else
                    self:changeBookSource(bookinfo)
                end
            end
        }}}
    })
end

local function validateInput(text)
    return type(text) == 'string' and text:gsub("%s+", "") ~= ""
end

function M:searchBookDialog(onReturnCallback, def_input)
    local inputText
    local dialog

    self:init()

    if self._last_search_input and not def_input then
        def_input = self._last_search_input
    end
    
    self.call_mode = "SEARCH"
    self.on_success_callback = onReturnCallback

    dialog = MessageBox:input(
        "请键入要搜索的书籍或作者名称：\n(多源搜索可使用 '=书名' 语法精确匹配)", nil, {
            title = '添加书籍',
            input_hint = "如：剑来",
            input = def_input,
            buttons = {{{
                text = "单源搜索",
                callback = function()
                    inputText = dialog:getInputText()
                    inputText = util.trim(inputText)

                    if not validateInput(inputText) then
                        return MessageBox:notice("请输入有效书籍或作者名称")
                    end
                    UIManager:close(dialog)
                    self.search_text = inputText
                    self:handleSingleSourceSearch(inputText)
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
                    self:handleMultiSourceSearch(inputText)
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
        MessageBox:loading(string.format("%s 查询中 ", item.text or ""), function()
            return Backend:searchBookSingle({
                search_text = searchText, 
                book_source_url = book_source_url,
            })
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
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
            end
        end)
    end)
end

function M:handleMultiSourceSearch(search_text, is_more_call)
    if not (H.is_str(search_text) and search_text ~= "") then
        MessageBox:notice("参数错误")
        return
    end
    
    self.last_index = self.last_index ~= nil and self.last_index or -1

    MessageBox:loading(string.sub(search_text, 1, 1) ~= '=' and string.format("正在搜索 [%s] ", search_text) or
                           string.format("精准搜索 [%s] ", string.sub(search_text, 2)), function()
        return Backend:searchBookMulti({
            search_text = search_text, 
            last_index = self.last_index
        })
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not H.is_tbl(data) or not H.is_tbl(data.list) then
                    return MessageBox:notice('服务器返回数据错误')
                end
                if #data.list == 0 then
                    self.has_more_api_results = nil
                    return MessageBox:notice('未找到相关书籍')
                end

                logger.dbg("当前data.lastIndex:", data.lastIndex)
                if H.is_num(data.lastIndex) and self.last_index ~= data.lastIndex then
                    self.has_more_api_results = true
                    self.last_index = data.lastIndex
                else
                    self.has_more_api_results = nil
                end

                if is_more_call ~= true then
                    self.results = data.list
                    self:createBookSourceMenu({
                        title = '多源搜索',
                        subtitle = string.format("key: %s", search_text),
                    })
                else
                    self:refreshItems(false, data.list)
                end

            end, function(err_msg)
                if err_msg == "没有更多了" then self.has_more_api_results = nil end
                MessageBox:notice(err_msg or '搜索请求失败')
            end)
        end
    end)
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
    MessageBox:loading(
        string.format("搜索[%s]可用书源 ", bookinfo.name), function()
        return Backend:getAvailableBookSource(options)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not (H.is_tbl(data) and H.is_tbl(data.list)) then
                    return MessageBox:notice('返回书源错误')
                end
                if #data.list == 0 then
                    self.has_more_api_results = nil
                    return MessageBox:error('没有找到可用源')
                end

                if H.is_num(data.lastIndex) and self.last_index ~= data.lastIndex then
                    self.has_more_api_results = true
                    self.last_index = data.lastIndex
                else
                    self.has_more_api_results = nil
                end

                if is_more_call ~= true then
                    self.results = data.list
                    self:createBookSourceMenu({
                        title = "换源",
                        subtitle = string.format("%s (%s)", bookinfo.name, bookinfo.author),
                    })
                else
                    self:refreshItems(false, data.list)
                end

            end, function(err_msg)
                if err_msg == "没有更多了" then self.has_more_api_results = nil end
                MessageBox:error(err_msg or '加载失败')
            end)
        end
    end)
end

function M:autoChangeSource(bookinfo, onReturnCallback)
    if not H.is_tbl(bookinfo) or not H.is_str(bookinfo.bookUrl) then
        return MessageBox:error('参数错误')
    end

    MessageBox:loading("正在换源 ", function()
        return Backend:autoChangeBookSource(bookinfo)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                MessageBox:notice('更换成功')
                self:modifySuccessCallback(true)
            end, function(err_msg)
                MessageBox:error(err_msg or '操作失败')
            end)
        end
    end)
end

function M:selectBookSource(selectCallback)
    MessageBox:loading("获取源列表 ", function()
        return Backend:getBookSourcesList()
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not H.is_tbl(data) then
                    return MessageBox:notice('返回源数据错误')
                end
                if #data == 0 then
                    return MessageBox:error('没有可用源')
                end

                local source_list_menu_table = {}
                local source_list_container
                for _, v in ipairs(data) do
                    if H.is_tbl(v) and H.is_str(v.bookSourceName) and H.is_str(v.bookSourceUrl) then
                        table.insert(source_list_menu_table, {
                            text = string.format("%s [%s]", v.bookSourceName, v.bookSourceGroup or ""),
                            url = v.bookSourceUrl,
                            name = v.bookSourceName
                        })
                    end
                end

                source_list_container = self:menuCenterShow(Menu:new{
                    title = "请指定要搜索的源",
                    subtitle = string.format("key: %s", self.search_text or ""),
                    item_table = source_list_menu_table,
                    items_per_page = 15,
                    items_font_size = self.items_font_size,
                    covers_fullscreen = true,
                    fullscreen = true,
                    width = self.width,
                    height = self.height,
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
    end)
end

function M:changeBookSource(bookinfo)
    if not (self.bookinfo and bookinfo) then
        MessageBox:notice('参数错误')
        return
    end

    local old_bookUrl = self.bookinfo.bookUrl
    if not (self.call_mode ~= "SEARCH" and H.is_str(old_bookUrl) and H.is_str(bookinfo.bookUrl) and H.is_str(bookinfo.origin)) then
        MessageBox:notice('参数错误')
        return
    end
    Backend:closeDbManager()
    MessageBox:loading("更换中 ", function()
        return Backend:changeBookSource({
            bookUrl = old_bookUrl,
            bookSourceUrl = bookinfo.origin,
            newUrl = bookinfo.bookUrl
        })
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                MessageBox:notice('换源成功')
            end, function(err_msg)
                MessageBox:error(err_msg or '操作失败')
            end)
        end
    end)
end

function M:addBookToLibrary(bookinfo)
    if self.call_mode ~= "SEARCH" then
        return MessageBox:notice('参数错误')
    end
    Backend:closeDbManager()
    MessageBox:loading("添加中 ", function()
        return Backend:addBookToLibrary(bookinfo)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                MessageBox:notice('添加成功')
                self:modifySuccessCallback(true)
            end, function(err_msg)
                MessageBox:error(err_msg or '操作失败')
            end)
        end
    end)
end

return M
