local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Device = require("device")
local Event = require("ui/event")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template

local Backend = require("Backend")
local Menu = require("libs/Menu")
local MessageBox = require("libs/MessageBox")
local ChapterListing = require("ChapterListing")
local H = require("libs/Helper")

local BookSourceResults = Menu:extend{
    name = "book_search_results",
    single_line = false,
    is_enable_shortcut = false,
    is_popout = false,
    title = "Search results",
    with_context_menu = true,
    fullscreen = true,
    results = nil,
    bookinfo = nil,
    -- callback to be called when pressing the back button
    on_return_callback = nil
}

function BookSourceResults:init()
    self.results = self.results or {}
    self.width = self.width or Screen:getWidth() - Screen:scaleBySize(50)
    self.width = math.min(self.width, Screen:scaleBySize(600))
    self.height = Screen:getHeight() - Screen:scaleBySize(50)

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

    self:updateItems()
end

function BookSourceResults:updateItems()
    self.item_table = self:generateItemTableFromSearchResults(self.results)

    Menu.updateItems(self)
end


function BookSourceResults:generateItemTableFromSearchResults(results)
    local item_table = {}
    for _, new_bookinfo in ipairs(results) do
        if H.is_tbl(self.bookinfo) then
            new_bookinfo.old_bookUrl = self.bookinfo.bookUrl
        end
        table.insert(item_table, {
            bookinfo = new_bookinfo,
            text = string.format("%s (%s)[%s]", new_bookinfo.name, new_bookinfo.author or '', new_bookinfo.originName)
        })
    end

    return item_table
end

function BookSourceResults:onCloseUI()
    local path = table.remove(self.paths)
    Menu.onClose(self)
    path.callback()
end

function BookSourceResults:fetchAndShow(bookinfo, onReturnCallback)
    local bookUrl = bookinfo.bookUrl
    MessageBox:loading("加载可用书源 ", function()
        return Backend:searchBookSource(bookUrl, 1)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not H.is_tbl(data) or not H.is_tbl(data.list) then
                    return Backend:show_notice('书源信息错误')
                end
                if #data.list == 0 then
                    return MessageBox:error('没有可用源')
                end

                UIManager:show(BookSourceResults:new{
                    results = data.list,
                    bookinfo = bookinfo,
                    on_return_callback = onReturnCallback,
                    title = string.format("换源 %s (%s)", bookinfo.name, bookinfo.author),
                    covers_fullscreen = true
                })

            end, function(err_msg)
                MessageBox:error(err_msg or '加载失败')
            end)
        end
    end)
end

function BookSourceResults:searchAndShow(search_text, onReturnCallback)
    MessageBox:loading("正在搜索 ", function()
        return Backend:searchBookMulti(search_text)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not H.is_tbl(data) or not H.is_tbl(data.list) then
                    return Backend:show_notice('服务器返回错误')
                end
                if #data.list == 0 then
                    return MessageBox:error('没有可用源')
                end
                UIManager:show(BookSourceResults:new{
                    results = data.list,
                    on_return_callback = onReturnCallback,
                    title = string.format('搜索书源 [%s]', search_text),
                    covers_fullscreen = true -- hint for UIManager:_repaint()
                })
            end, function(err_msg)
                MessageBox:error(err_msg or '加载失败')
            end)
        end
    end)
end

function BookSourceResults:onFocusRight()
    local focused_widget = Menu.getFocusItem(self)
    if focused_widget then
        local point = focused_widget.dimen:copy()
        point.x = point.x + point.w
        point.y = point.y + point.h / 2
        point.w = 0
        point.h = 0
        UIManager:sendEvent(Event:new("Gesture", {
            ges = "tap",
            pos = point
        }))
        return true
    end
end

function BookSourceResults:onPrimaryMenuChoice(item)
    self:onContextMenuChoice(item)
end

function BookSourceResults:setBookSource(bookinfo)
    Backend:closeDbManager()
    MessageBox:loading("更换中 ", function()
        return Backend:setBookSource({
            bookUrl = bookinfo.old_bookUrl,
            bookSourceUrl = bookinfo.origin,
            newUrl = bookinfo.bookUrl
        })
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                Backend:show_notice('换源成功')
                self:onCloseUI()
            end, function(err_msg)
                MessageBox:error(err_msg or '加载失败')
            end)
        end
    end)
end

function BookSourceResults:addBookToLibrary(bookinfo)
    Backend:closeDbManager()
    MessageBox:loading("添加中 ", function()
        return Backend:addBookToLibrary(bookinfo)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                Backend:show_notice('添加成功')
                self:onCloseUI()
            end, function(err_msg)
                MessageBox:error(err_msg or '加载失败')
            end)
        end
    end)
end

function BookSourceResults:onContextMenuChoice(item)

    local bookinfo = item.bookinfo
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
            text = H.is_str(bookinfo.old_bookUrl) and '换源' or '添加',
            callback = function()
                -- logger.dbg('old_bookUrl:', bookinfo.old_bookUrl)
                if H.is_str(bookinfo.old_bookUrl) then
                    self:setBookSource(bookinfo)
                else
                    self:addBookToLibrary(bookinfo)
                end
            end
        }}}
    })
end

return BookSourceResults
