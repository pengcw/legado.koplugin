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
local ChapterListing = require("Legado/ChapterListing")
local H = require("Legado/Helper")

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
    last_read_chapter = nil,

    call_mode = nil,
    last_index = nil,
    -- callback to be called when pressing the back button
    on_return_callback = nil,
    results_menu_container = nil,
    _last_search_input = nil
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
    local name = bookinfo.name
    local author = bookinfo.author
    MessageBox:loading("加载可用书源 ", function()
        return Backend:getAvailableBookSource({
                bookUrl = bookUrl,
                name = name,
                author = author
            })
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
                call_mode = Backend:getSettings().server_type == 2 and 11 or 31,
                on_return_callback = onReturnCallback,
                subtitle = string.format("%s (%s)", bookinfo.name, bookinfo.author),
                title = "换源",
                items_font_size = Menu.getItemFontSize(8)
            })
        end
    end)
end

function M:checkChapterContent(bookUrl, chapterIndex)
    if not (bookUrl and H.is_num(chapterIndex)) then
        return false
    end
    local response = Backend:HandleResponse(Backend:pGetChapterContent({
        bookUrl = bookUrl,
        chapters_index = chapterIndex
    }), function(data)
        if not H.is_tbl(data) or data.type == 'SUCCESS' and H.is_str(data.body) and #data.body > 80 then
            return true
        end
    end, function(err_msg)
        logger.err("checkChapterContent err:", err_msg)
    end)
    return response == true and true or false
end

local function source_list_shuffle(t)
    local n = #t
    for i = n, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function M:autoChangeSourceSocket(bookinfo, onReturnCallback)

    if Backend:getSettings().server_type ~= 1 then
        Backend:show_notice("仅支持阅读 App")
        return
    end

    if not H.is_tbl(bookinfo) or not H.is_str(bookinfo.bookUrl) then
        return MessageBox:error('参数错误')
    end

    self.bookinfo = bookinfo
    self.call_mode = 30
    self.paths = {{
        callback = onReturnCallback
    }}

    local old_bookUrl = self.bookinfo.bookUrl
    local old_originName = self.bookinfo.originName
    local old_origin = self.bookinfo.origin

    local book_cache_id = self.bookinfo.cache_id
    local total_source_count = 0
    math.randomseed(os.time())

    MessageBox:loading("加载可用书源 ", function()
        return Backend:getAvailableBookSource({
            bookUrl = old_bookUrl,
            name = bookinfo.name,
            author = bookinfo.author

        })
    end, function(state, response)
        if state == true then
            local results_data = {}
            Backend:HandleResponse(response, function(data)
                if H.is_tbl(data) and #data > 0 then
                    results_data = data
                end
            end, function(err_msg)
                Backend:show_notice(err_msg or '加载失败')
            end)

            total_source_count = #results_data

            if total_source_count == 0 then
                return MessageBox:error('没有可用源')
            end

            local check_source = function(sourceList)
                if not (H.is_tbl(sourceList) and #sourceList > 0 and sourceList[1].origin) then
                    return
                end

                local response_origin
                local all_chapters_count = 0

                -- 乱序
                sourceList = source_list_shuffle(sourceList)

                for source_index, new_bookinfo in ipairs(sourceList) do

                    local name = new_bookinfo.name
                    local author = new_bookinfo.author
                    local bookUrl = new_bookinfo.bookUrl
                    local origin = new_bookinfo.origin
                    local originName = new_bookinfo.originName
                    all_chapters_count = 0

                    -- 有的源bookUrl每次添加有参数会改变,如sign
                    if old_origin and origin == old_origin then
                        logger.dbg("自动换源忽略相同源：", originName)
                        goto continue
                    end
                    new_bookinfo.cache_id = book_cache_id

                    -- legado app 需要先添加到库
                    Backend:addBookToLibrary(new_bookinfo)

                    -- 返回目录
                    Backend:HandleResponse(Backend:refreshChaptersList(new_bookinfo), function(data)
                        if H.is_tbl(data) and H.is_tbl(data[1]) and data[1].bookUrl then
                            all_chapters_count = #data
                        end
                    end, function(err_msg)
                        logger.err("source err：", originName, err_msg)
                    end)

                    --  有章节目录
                    if all_chapters_count > 0 then
                        if not self.last_read_chapter then
                            self.last_read_chapter = Backend:getLastReadChapter(book_cache_id)
                            self.last_read_chapter = tonumber(self.last_read_chapter) or 2
                        end

                        --logger.info("autoChangeSource:", originName, old_bookUrl, bookUrl, self.last_read_chapter,all_chapters_count)

                        -- 对比当前章节
                        if all_chapters_count >= self.last_read_chapter then
                            local next_check_chapter = self.last_read_chapter + 1
                            if next_check_chapter > all_chapters_count then
                                next_check_chapter = self.last_read_chapter - 1
                            end

                            -- 检查正文
                            if self:checkChapterContent(bookUrl, self.last_read_chapter) and
                                self:checkChapterContent(bookUrl, next_check_chapter) then
               
                                response_origin = new_bookinfo
                                break
                            end
                        end
                    end
                    -- 清理
                    Backend:deleteBook(new_bookinfo)
                    ::continue::
                end

                return response_origin
            end

            MessageBox:loading(string.format("预选书源%s个，检查中 ", total_source_count), function()
                return check_source(results_data)
            end, function(state, response)
                results_data = nil
                if state == true and H.is_tbl(response) and response.bookUrl and response.origin then
                        Backend:show_notice("换源成功")
                        Backend:refreshLibraryCache()
                         return self:onCloseUI()
             
                else
                         return MessageBox:error(string.format(
                        "换源失败，检查书源%s个\n(可搜索添加同名同作者书籍方式手动换源，或者使用 app 换源后刷新)",
                        total_source_count))
                end
            end)
        end
    end)
end

function M:autoChangeSource(bookinfo, onReturnCallback)
    if not H.is_tbl(bookinfo) or not H.is_str(bookinfo.bookUrl) then
        return MessageBox:error('参数错误')
    end

    if Backend:getSettings().server_type == 1 then
        return self:autoChangeSourceSocket(bookinfo, onReturnCallback)
    end

    self.bookinfo = bookinfo
    self.call_mode = 30
    self.paths = {{
        callback = onReturnCallback
    }}

    local old_bookUrl = self.bookinfo.bookUrl
    local old_originName = self.bookinfo.originName
    local old_origin = self.bookinfo.origin

    local book_cache_id = self.bookinfo.cache_id
    local total_source_count = 0
    math.randomseed(os.time())

    MessageBox:loading("加载可用书源 ", function()
        return Backend:getAvailableBookSource({
            bookUrl = old_bookUrl,
            name = bookinfo.name,
            author = bookinfo.author
        })
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
            total_source_count = #results_data

            local check_source = function(sourceList)
                if not (H.is_tbl(sourceList) and #sourceList > 0 and sourceList[1].origin) then
                    return
                end

                local response_origin
                local all_chapters_count = 0

                sourceList = source_list_shuffle(sourceList)

                for source_index, new_bookinfo in ipairs(sourceList) do

                    local name = new_bookinfo.name
                    local author = new_bookinfo.author
                    local bookUrl = new_bookinfo.bookUrl
                    local origin = new_bookinfo.origin
                    local originName = new_bookinfo.originName
                    all_chapters_count = 0

                    if old_origin and origin == old_origin then
                        logger.dbg("自动换源忽略相同源：", originName)
                        goto continue
                    end
                    new_bookinfo.cache_id = book_cache_id

                    Backend:HandleResponse(Backend:refreshChaptersList(new_bookinfo), function(data)
                        if H.is_tbl(data) and H.is_tbl(data[1]) and data[1].bookUrl then
                            all_chapters_count = #data
                        end
                    end, function(err_msg)
                        logger.err("source err：", originName, err_msg)
                    end)

                    if all_chapters_count == 0 then
                        goto continue
                    end

                    if not self.last_read_chapter then
                        self.last_read_chapter = Backend:getLastReadChapter(book_cache_id)
                        self.last_read_chapter = tonumber(self.last_read_chapter) or 2
                    end

                    if all_chapters_count < self.last_read_chapter then
                        goto continue
                    end

                    local next_check_chapter = self.last_read_chapter + 1
                    if next_check_chapter > all_chapters_count then
                        next_check_chapter = self.last_read_chapter - 1
                    end

                    if self:checkChapterContent(bookUrl, self.last_read_chapter) and
                        self:checkChapterContent(bookUrl, next_check_chapter) then
                        response_origin = new_bookinfo
                        break
                    end

                    ::continue::
                end
                return response_origin
            end

            MessageBox:loading(string.format("预选书源%s个，检查中 ", total_source_count), function()
                return check_source(results_data)
            end, function(state, response)
                if state == true and H.is_tbl(response) and response.bookUrl and response.origin then
                    self:setBookSource(response)
                else
                    results_data = nil

                    MessageBox:loading(string.format("已扫描书源%s个，更多查询中 ", total_source_count),
                        function()

                            local response_origin
                            if old_bookUrl then
                                local lastIndex = -1
                                local count = 1
                                local sourceList

                                while true do
                                    --logger.dbg("autoChangeSource:", count, lastIndex)
                                    Backend:HandleResponse(Backend:searchBookSource(old_bookUrl, lastIndex, 12),
                                        function(data)
                                            if H.is_tbl(data) and H.is_tbl(data.list) then
                                                sourceList = data.list
                                            end
                                        end)
                                    if not H.is_tbl(sourceList) or sourceList.lastIndex == nil then
                                        logger.err("没有更多源了")
                                        break
                                    end

                                    response_origin = check_source(sourceList)

                                    -- 最多检测800个源,避免等待时间太长
                                    if H.is_tbl(response_origin) or count > 800 then
                                        break
                                    end

                                    lastIndex = sourceList.lastIndex
                                    sourceList = 0
                                    count = count + 1
                                end

                                total_source_count = total_source_count + count * 12
                            end

                            return type(response_origin) == 'table' and response_origin or total_source_count
                        end, function(state, response)
                            if state == true and H.is_tbl(response) and response.bookUrl and response.origin then
                                    self:setBookSource(response)
                            else
                                    response = H.is_num(response) and response or 0
                                    MessageBox:error(string.format("换源失败，检查书源%s个", response))
                            end
                        end)
                end
            end)
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
总章数：%6
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
                if self.call_mode < 10 or self.call_mode == 31 then
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

function M:searchAndShow(onReturnCallback, def_input)
    local inputText = ""
    local dialog

    if self._last_search_input and not def_input then
        def_input = self._last_search_input
    end
    dialog = MessageBox:input(
        "请键入要搜索的书籍或作者名称：\n(多源搜索可使用 '=书名' 语法精确匹配)", nil, {
            title = '搜索书籍',
            input_hint = "如：剑来",
            input = def_input,
            buttons = {{{
                text = "单源搜索",
                callback = function()
                    if Backend:getSettings().server_type == 1 then
                        return Backend:show_notice('阅读 App 仅支持多源搜索')
                    end
                    inputText = dialog:getInputText()
                    inputText = util.trim(inputText)

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
                    inputText = util.trim(inputText)
                    if not validateInput(inputText) then
                        return Backend:show_notice("请输入有效书籍或作者名称")
                    end
                    UIManager:close(dialog)
                    self.search_text = inputText
                    self.on_return_callback = onReturnCallback
                    if Backend:getSettings().server_type == 1 then
                        self:searchBookSocket(inputText)
                    else
                        self:handleMultiSourceSearch(inputText)
                    end
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

function M:searchBookSocket(search_text)

    if not (H.is_str(search_text) and search_text ~= "") then
        Backend:show_notice("参数错误")
        return
    end

    MessageBox:loading(string.sub(search_text, 1, 1) ~= '=' and string.format("正在搜索 [%s] ", search_text) or
                           string.format("精准搜索 [%s] ", string.sub(search_text, 2)), function()
        return Backend:searchBookSocket(search_text)
    end, function(state, response)
        if state == true then
            Backend:HandleResponse(response, function(data)
                if not H.is_tbl(data) or not H.is_tbl(data[1]) then
                    return Backend:show_notice('服务器返回为空')
                end

                self.results_menu_container = self:menuCenterShow(M:new{
                    results = data,
                    call_mode = 31,
                    title = '多源搜索',
                    subtitle = string.format("key: %s", search_text),
                    items_font_size = Menu.getItemFontSize(8)
                })
            end, function(err_msg)
                Backend:show_notice(err_msg or '搜索请求失败')
            end)
        end
    end)
end

function M:handleMultiSourceSearch(search_text, is_more_call)
    if not (H.is_str(search_text) and search_text ~= "") then
        Backend:show_notice("参数错误")
        return
    end

    self.last_index = self.last_index or -1

    MessageBox:loading(string.sub(search_text, 1, 1) ~= '=' and string.format("正在搜索 [%s] ", search_text) or
                           string.format("精准搜索 [%s] ", string.sub(search_text, 2)), function()
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
    if not self.bookinfo then
        Backend:show_notice('参数错误')
        return
    end
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
    if self.call_mode > 10 and self.call_mode ~= 31 then
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
        return Backend:searchBookSource(old_bookUrl, self.last_index, 8)
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
        -- command item
        -- self.call_mode == 11 -- 换源->搜索更多
        -- == 12 -- 换源->搜索更多->加载更多 追加
        -- == 2 -- 搜书->搜索更多->加载更多 追加
        -- == 30 自动换源
        -- == 31 app 添加
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
    if self.call_mode ~= 30 then
        Menu.onClose(self)
    end
    if self.paths then
        local path = table.remove(self.paths)
        if path and type(path.callback) == "function" then
            path.callback()
        end
    end
end

return M
