-- Legado/BookShelf.lua
local BD = require("ui/bidi")
local Menu = require("ui/widget/menu")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local NetworkMgr = require("ui/network/manager")
local time = require("ui/time")
local MessageBox = require("Legado/MessageBox")
local Backend = require("Legado/Backend")
local H = require("Legado/Helper")
local Icons = require("Legado/Icons")
local PlgState = require("Legado/PlgState")

local function init_book_shelf(parent)
    if parent.book_shelf then
        return parent.book_shelf
    end
    local book_shelf = Menu:new{
        name = "library_view",
        title = "书架",
        with_context_menu = true,
        align_baselines = true,
        covers_fullscreen = true, 
        is_borderless = true,
        title_bar_left_icon = "appbar.menu",
        title_bar_fm_style = true,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        close_callback = function() Backend:closeDbManager() end,
        refresh_menu_key = nil,
        parent_ref = parent,
        show_cover = true,
    }

    if Device:hasKeys() then
        book_shelf.refresh_menu_key = "Home"
        if Device:hasKeyboard() then
            book_shelf.refresh_menu_key = "F5"
        end
        book_shelf.key_events.RefreshLibrary = { { book_shelf.refresh_menu_key } }
    end
    if Device:hasDPad() then
        book_shelf.key_events.FocusRight = {{ "Right" }}
        book_shelf.key_events.Right = nil
    end

    function book_shelf:onLeftButtonTap()
        local dimen
        if self.title_bar and self.title_bar.left_button and self.title_bar.left_button.image then
            dimen = self.title_bar.left_button.image.dimen
        end
        parent:openMenu(dimen)
    end
    
    function book_shelf:onFocusRight()
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
    
    function book_shelf:onSwipe(arg, ges_ev)
        local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
        if direction == "south" then
            if NetworkMgr:isConnected() then
                UIManager:nextTick(function()
                    self:onRefreshLibrary()
                end)
            else
                NetworkMgr:runWhenConnected(function() self:onRefreshLibrary() end)  
            end
            return
        end
        Menu.onSwipe(self, arg, ges_ev)
    end

    function book_shelf:refreshItems(no_recalculate_dimen)
        local books_cache_data = Backend:getBookShelfCache()
        if H.is_tbl(books_cache_data) and #books_cache_data > 0 then
            self.item_table = self:generateItemTableFromMangas(books_cache_data)
            self.multilines_show_more_text = false
            self.items_per_page = nil
        else
            self.item_table = self:generateEmptyViewItemTable()
            self.multilines_show_more_text = true
            self.items_per_page = 1
        end
        self:updateItems(nil, no_recalculate_dimen)
    end

    function book_shelf:onPrimaryMenuChoice(item)
        if not item.cache_id then
            require("Legado/BookSourceResults"):searchBookDialog(function()
                self:onRefreshLibrary()
            end)
            return
        end
        
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        PlgState:currentSelectedBook(item)

        if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
            return MessageBox:error("书籍信息查询出错")
        end

        local onReturnCallBack = function()
            self:show_view()
            self:refreshItems(true)
        end

        self.parent_ref:refreshBookTocWidget(bookinfo, onReturnCallBack, true)
        self:onClose()
        
        UIManager:nextTick(function()
            Backend:autoPinToTop(bookinfo.cache_id, bookinfo.sortOrder)
            self.parent_ref:addBkShortcut(bookinfo)
        end)
    end

    function book_shelf:onRefreshLibrary()
        Backend:closeDbManager()
        MessageBox:loading("Refreshing Library", function()
            return Backend:refreshLibraryCache(PlgState.ui_refresh_time)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    MessageBox:notice('同步成功')
                    self:refreshItems()
                    PlgState.ui_refresh_time = time.now()
                end, function(err_msg)
                    MessageBox:notice(tostring(err_msg) or '同步失败')
                end)
            end
        end)
    end

    function book_shelf:onMenuHold(item)
        if not item.cache_id then
            self.parent_ref:openSearchBooksDialog()
            return
        end
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then return end

        local pin_top_text = (H.is_num(bookinfo.sortOrder) and bookinfo.sortOrder > 0) and '置顶' or '取消置顶'
        local BookDetailsDialog = require("Legado/BookDetailsDialog")
        local dialog = BookDetailsDialog:new{
            bookinfo = bookinfo,
            has_reload_btn = true,
            callbacks = {
                [pin_top_text] = function()
                    Backend:manuallyPinToTop(item.cache_id, bookinfo.sortOrder)
                    self:refreshItems(true)
                end,
                ["云端书籍链接"] = function()
                    UIManager:nextTick(function()
                        self.parent_ref:addBkShortcut(bookinfo, true)
                    end)
                    MessageBox:notice("云端书籍链接已保存至 Home 目录")
                end,
                ["删除"] = function()
                    MessageBox:confirm(string.format(
                        "是否从书架删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复",
                        bookinfo.name), function(result)
                        if result then
                            Backend:closeDbManager()
                            MessageBox:loading("删除中...", function()
                                Backend:deleteBook(bookinfo)
                                return Backend:refreshLibraryCache()
                            end, function(state, response)
                                if state == true then
                                    Backend:HandleResponse(response, function(data)
                                        MessageBox:notice("删除成功")
                                        self:refreshItems(true)
                                    end, function(err_msg)
                                        MessageBox:error('删除失败：', err_msg)
                                    end)
                                end
                            end)
                        end
                    end, { ok_text = "删除", cancel_text = "取消" })
                end,
            }
        }
        UIManager:show(dialog)
    end

    function book_shelf:onMenuSelect(entry, pos)
        if entry.select_enabled == false then return true end
        local selected_context_menu = pos ~= nil and pos.x > 0.8
        if selected_context_menu then
            self:onMenuHold(entry, pos)
        else
            self:onPrimaryMenuChoice(entry, pos)
        end
        return true
    end

    function book_shelf:generateEmptyViewItemTable()
        local hint = (self.refresh_menu_key and not Device:isTouchDevice())
            and string.format("press the %s button", self.refresh_menu_key)
            or "swiping down"
        return {{
            text = string.format("No books found. Try %s to refresh.", hint),
            dim = true,
            select_enabled = false,
        }}
    end

    function book_shelf:generateItemTableFromMangas(books)
        local item_table = {}
        for _, bookinfo in ipairs(books) do
            local show_book_title = ("\u{FFF1}\u{FFF2}%s\u{FFF3} (%s)[%s]"):format(bookinfo.name or "未命名书籍",
                bookinfo.author or "未知作者", bookinfo.originName)
            table.insert(item_table, {
                cache_id = bookinfo.cache_id,
                text = show_book_title,
                mandatory = Icons.FA_ELLIPSIS_VERTICAL
            })
        end
        return item_table
    end

    function book_shelf:show_view()
        UIManager:show(self)
    end

    parent.book_shelf = book_shelf
    return book_shelf
end

return init_book_shelf