local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Device = require("device")
local Event = require("ui/event")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template

local Icons = require("libs/Icons")
local Backend = require("Backend")
local MessageBox = require("libs/MessageBox")
local ChapterListing = require("ChapterListing")
local H = require("libs/Helper")

local M = Menu:extend{
    name = "book_search_results",
    is_enable_shortcut = false,
    title = "Search results",
    
    fullscreen = true,
    covers_fullscreen = true,
    single_line = true,
    results = nil,
    bookinfo = nil,
    search_text = nil,

    call_mode = nil,
    last_index = nil,
    -- callback to be called when pressing the back button
    on_return_callback = nil,
    results_menu_container = nil
}

function M:init()
    self.results = self.results or {}

    self.width = math.floor(Screen:getWidth() * 0.9)
    self.height = math.floor(Screen:getHeight() * 0.9)

    Menu.init(self)

    if Device:hasKeys({"Right"}) or Device:hasDPad() then
        self.key_events.Close = {{Device.input.group.Back}}
        self.key_events.FocusRight = {{"Right"}}
    end

    -- see `ChapterListing` for an explanation on this
    -- FIXME we could refactor this into a single class
    self.paths = {{
        callback = self.on_return_callback
    }}
    self.on_return_callback = nil

    self:refreshItems()
end

function M:refreshItems(no_recalculate_dimen, append_data)
    self.item_table = self:generateItemTableFromSearchResults(append_data)
    Menu.updateItems(self, nil, no_recalculate_dimen)
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

function M:generateItemTableFromSearchResults(append_data)

    local item_table = {}
    self.results = self.results or {}
    if not H.is_tbl(append_data) then
        append_data = nil
    end

    if self.call_mode == 11 then
        item_table[1] = {
            source_index = 0,
            text = Icons.FA_MAGNIFYING_GLASS .. " 点击搜索更多书源"
        }
    end

    if H.is_tbl(append_data) and (self.call_mode == 12 or self.call_mode == 2) then
        for _, v in ipairs(append_data) do
            table.insert(self.results, v)
        end
    end

    for source_index, new_bookinfo in ipairs(self.results) do
        local item_table_txt
        if self.call_mode == 1 then
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

    if self.call_mode == 12 or self.call_mode == 2 then
        -- insert comand item_tabl
        table.insert(item_table, {
            source_index = 0,
            text = string.format("%s 点击加载更多 l:%s", Icons.FA_DOWNLOAD, tostring(self.last_index))
        })
    end

    return item_table

end

function M:fetchAndShow(bookinfo, onReturnCallback)
    if not H.is_tbl(bookinfo) or not H.is_str(bookinfo.bookUrl) then
        return MessageBox:error('参数错误')
    end
    local bookUrl = bookinfo.bookUrl
    MessageBox:loading("加载可用书源 ", function()
        return Backend:getAvailableBookSource(bookUrl)
    end, function(state, response)
        if state == true then
            local results_data = {}
            Backend:HandleResponse(response, function(data)

                if not H.is_tbl(data) then
                    return Backend:show_notice('返回书源错误')
                end
                if #data == 0 then
                    return MessageBox:error('没有可用源')
                end
                results_data = data
            end, function(err_msg)
                Backend:show_notice(err_msg or '加载失败')
            end)

            self.results_menu_container = self:menuCenterShow(M:new{
                results = results_data,
                bookinfo = bookinfo,
                call_mode = 11,
                on_return_callback = onReturnCallback,
                subtitle = string.format("%s (%s)", bookinfo.name, bookinfo.author),
                title = "换源",
                items_font_size = Menu.getItemFontSize(8)
            })
        end
    end)
end

function M:showBookInfo(bookinfo)
    local msginfo = [[
书名: <<%1>>
作者: %2
分类: %3
书源名称: %4
书源地址: %5
总章数:%6
总字数：%7
简介：%8
]]

    msginfo = T(msginfo, bookinfo.name or '', bookinfo.author or '', bookinfo.kind or '', bookinfo.originName or '',
        bookinfo.origin or '', bookinfo.totalChapterNum or '', bookinfo.wordCount or '', bookinfo.intro or '')

    MessageBox:confirm(msginfo, nil, {
        icon = "notice-info",
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = {{{
            text = (self.call_mode < 10) and '添加' or '换源',
            callback = function()
                if self.call_mode < 10 then
                    self:addBookToLibrary(bookinfo)
                else
                    self:setBookSource(bookinfo)
                end
            end
        }}}
    })
end

local function validateInput(text)
    return type(text) == 'string' and text:gsub("%s+", "") ~= ""
end

function M:searchAndShow(onReturnCallback)
    local inputText = ""
    local dialog
    dialog = MessageBox:input("请键入要搜索的书籍或作者名称：\n(多源搜索可使用 '=书名' 语法精确匹配)", nil, {
        title = '搜索书籍',
        input_hint = "如：剑来",
        buttons = {{{
            text = "单源搜索",
            callback = function()
                inputText = dialog:getInputText()
                if not validateInput(inputText) then
                    return Backend:show_notice("请输入有效书籍或作者名称")
                end
                UIManager:close(dialog)
                self.search_text = inputText
                self.on_return_callback = onReturnCallback
                self:handleSingleSourceSearch(inputText)
            end
        }, {
            text = "多源搜索",
            is_enter_default = true,
            callback = function()
                inputText = dialog:getInputText()
                if not validateInput(inputText) then
                    return Backend:show_notice("请输入有效书籍或作者名称")
                end
                UIManager:close(dialog)
                self.search_text = inputText
                self.on_return_callback = onReturnCallback
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
        local bookSourceUrl = item.url
        local bookSourceName = item.name
        MessageBox:loading(string.format("%s 查询中 ", item.text or ""), function()
            return Backend:searchBook(searchText, bookSourceUrl)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    if not H.is_tbl(data) then
                        return Backend:show_notice('服务器返回错误')
                    end
                    if #data == 0 or not H.is_tbl(data[1]) then
                        return Backend:show_notice('未找到相关书籍')
                    end

                    self.results_menu_container = self:menuCenterShow(M:new{
                        results = data,
                        call_mode = 1,
                        search_text = searchText,
                        title = string.format('单源搜索 [%s]', bookSourceName),
                        subtitle = string.format("key: %s", searchText),
                        items_font_size = Menu.getItemFontSize(8)
                    })

                    self.results_menu_container.show_parent = sourceMenu.show_parent

                end, function(err_msg)
                    Backend:show_notice(err_msg or '搜索请求失败')
                end)
            end
        end)
    end)
end

function M:handleMultiSourceSearch(search_text, is_more_call)
    if not (H.is_str(search_text) and search_text ~= "") then
        Backend:show_notice("参数错误")
        return
    end

    self.last_index = self.last_index or -1

    MessageBox:loading(string.format("正在搜索[%s] ", search_text), function()
        return Backend:searchBookMulti(search_text, self.last_index)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not H.is_tbl(data) or not H.is_tbl(data.list) then
                    return Backend:show_notice('服务器返回错误')
                end
                if #data.list == 0 then
                    return Backend:show_notice('未找到相关书籍')
                end

                logger.dbg("当前data.lastIndex:", data.lastIndex)

                self.last_index = data.lastIndex

                if is_more_call ~= true then
                    self.results_menu_container = self:menuCenterShow(M:new{
                        results = data.list,
                        call_mode = 2,
                        title = '多源搜索',
                        subtitle = string.format("key: %s", search_text),
                        items_font_size = Menu.getItemFontSize(8)
                    })
                else
                    self:refreshItems(false, data.list)
                end

            end, function(err_msg)
                Backend:show_notice(err_msg or '搜索请求失败')
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
                    return Backend:show_notice('返回数据错误')
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
                    items_font_size = Menu.getItemFontSize(8),
                    single_line = true,
                    covers_fullscreen = true,
                    fullscreen = true,
                    width = math.floor(Screen:getWidth() * 0.9),
                    height = math.floor(Screen:getHeight() * 0.9),
                    onMenuSelect = function(self_menu, item)
                        if selectCallback then
                            selectCallback(item, self_menu)
                        end
                    end,
                    close_callback = function()
                        UIManager:close(source_list_container)
                        source_list_container = nil
                    end
                })

            end, function(err_msg)
                Backend:show_notice('列表请求失败' .. tostring(err_msg))
            end)
        end
    end)
end

function M:setBookSource(bookinfo)
    local old_bookUrl = self.bookinfo.bookUrl
    if not (self.call_mode > 10 and H.is_str(old_bookUrl) and H.is_str(bookinfo.bookUrl) and H.is_str(bookinfo.origin)) then
        Backend:show_notice('参数错误')
        return
    end
    Backend:closeDbManager()
    MessageBox:loading("更换中 ", function()
        return Backend:setBookSource({
            bookUrl = old_bookUrl,
            bookSourceUrl = bookinfo.origin,
            newUrl = bookinfo.bookUrl
        })
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                Backend:show_notice('换源成功')
                self:onCloseUI()
            end, function(err_msg)
                MessageBox:error(err_msg or '操作失败')
            end)
        end
    end)
end

function M:addBookToLibrary(bookinfo)
    if self.call_mode > 10 then
        Backend:show_notice('参数错误')
        return
    end
    Backend:closeDbManager()
    MessageBox:loading("添加中 ", function()
        return Backend:addBookToLibrary(bookinfo)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                Backend:show_notice('添加成功')
                self:onCloseUI()
            end, function(err_msg)
                MessageBox:error(err_msg or '操作失败')
            end)
        end
    end)
end

function M:searchMoreBookSource()
    local old_bookUrl = self.bookinfo.bookUrl
    if not H.is_str(old_bookUrl) then
        Backend:show_notice("参数错误")
        return
    end

    self.last_index = self.last_index or -1

    MessageBox:loading("加载更多书源 ", function()
        return Backend:searchBookSource(old_bookUrl, self.last_index, 5)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not H.is_tbl(data) or not H.is_tbl(data.list) then
                    return Backend:show_notice('返回书源错误')
                end
                if #data.list == 0 then
                    return MessageBox:error('没有可用源')
                end
                self.last_index = data.lastIndex

                if self.call_mode == 11 then
                    self.results = data.list
                    self.call_mode = 12
                    self:refreshItems()
                elseif self.call_mode == 12 then
                    self:refreshItems(false, data.list)
                end
            end, function(err_msg)
                MessageBox:error(err_msg or '加载失败')
            end)
        end
    end)

end

function M:onMenuChoice(item)
    local source_index = item.source_index
    if H.is_num(source_index) and source_index > 0 then
        local bookinfo = self.results[source_index]
        self:showBookInfo(bookinfo)
    else

        if self.call_mode == 11 or self.call_mode == 12 then
            self:searchMoreBookSource()
        elseif self.call_mode == 1 or self.call_mode == 2 then
            self:handleMultiSourceSearch(self.search_text, true)
        end
        return true
        -- commond item
        -- self.call_mode == 11 -- 换源->搜索更多
        -- self.call_mode == 12 -- 换源->搜索更多->加载更多 追加
        -- self.call_mode == 2 -- 搜书->搜索更多->加载更多 追加
    end

end

function M:onMenuHold(item)
    self:onMenuChoice(item)
end

function M:onClose()
    self.results = nil
    self.bookinfo = nil
    self.search_text = nil
    self.call_mode = nil
    self.last_index = nil
    if self.results_menu_container then
        UIManager:close(self.results_menu_container)
        self.results_menu_container = nil
    end
    Menu.onClose(self)
end

function M:onCloseUI()
    if self.results_menu_container then
        UIManager:close(self.results_menu_container)
        self.results_menu_container = nil
    end
    local path = table.remove(self.paths)
    Menu.onClose(self)
    path.callback()
end

return M
