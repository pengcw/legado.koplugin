local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local logger = require("logger")
local dbg = require("dbg")
local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")

local ReaderRolling = require("apps/reader/modules/readerrolling")
local Device = require("device")
local Screen = Device.screen

local M = {
    on_return_callback = nil,
    on_end_of_book_callback = nil,
    on_start_of_book_callback = nil,
    on_read_settings_callback = nil,
    is_showing = false
}

function M:show(options)
    self.on_return_callback = options.on_return_callback
    self.on_end_of_book_callback = options.on_end_of_book_callback
    self.on_start_of_book_callback = options.on_start_of_book_callback
    self.chapter_call_event = options.chapter_call_event

    dbg.v('ReaderUI.instance', type(ReaderUI.instance))
    dbg.v('ReaderRolling.c8:', ReaderRolling.c8eeb679b)

    if self.is_showing and ReaderUI.instance then
        if ReaderRolling.c8eeb679b ~= true then
            M.overriderollingHandler()
        end
        ReaderUI.instance:switchDocument(options.path, true)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(options.path, nil, true)
    end

    self.is_showing = true
end

function M:initializeFromReaderUI(ui)
    if self.is_showing then
        ui.menu:registerToMainMenu(M)
    end

    ui:registerPostInitCallback(function()
        self:hookWithPriorityOntoReaderUiEvents(ui)
    end)

end

function M:hookWithPriorityOntoReaderUiEvents(ui)

    assert(ui.name == "ReaderUI", "expected to be inside ReaderUI")

    local eventListener = WidgetContainer:new{}

    eventListener.onEndOfBook = function()

        return self:onEndOfBook()
    end
    eventListener.onCloseWidget = function()
        self:onReaderUiCloseWidget()
    end

    eventListener.onStartOfBook = function()
        return self:onStartOfBook()

    end

    table.insert(ui, 3, eventListener)
end

function M:addToMainMenu(menu_items)
    menu_items.go_back_to_legado = {
        text = "返回 Legado...",
        sorting_hint = "main",
        callback = function()
            self:onReturn()
        end
    }
end

function M:onReturn()
    self:closeReaderUi(function()
        self.on_return_callback()
    end)
end

function M:getIsShowing()
    return self.is_showing
end

function M:closeReaderUi(done_callback)

    UIManager:nextTick(function()
        local FileManager = require("apps/filemanager/filemanager")

        ReaderUI.instance:onClose()
        if FileManager.instance then
            FileManager.instance:reinit()
        else
            FileManager:showFiles()
        end

        (done_callback or function()
        end)()
    end)
end

function M:onEndOfBook()
    if self.is_showing then

        self.on_end_of_book_callback()
        return true
    end
end

function M:onStartOfBook()
    if self.is_showing then

        self.on_start_of_book_callback()

        return true
    end
end

function M:onReaderUiCloseWidget()
    self.is_showing = false
end

M.overriderollingHandler = function()
    if ReaderUI.instance == nil then
        dbg.log("Got nil readerUI instance, canceling")
        return
    end

    local pan_rate = Screen.low_pan_rate and 2.0 or 30.0

    ReaderUI.postInitCallback = {}
    ReaderUI.postReaderReadyCallback = {}
    local ui_rolling_module_instance = ReaderRolling:new{
        configurable = ReaderUI.instance.document.configurable,
        pan_rate = pan_rate,
        dialog = ReaderUI.instance.dialog,
        view = ReaderUI.instance.view,
        ui = ReaderUI.instance
    }

    function ReaderRolling:onGotoViewRel(diff)
        dbg.log("goto relative screen:", diff, "in mode:", self.view.view_mode)

        if self.view.view_mode == "scroll" then
            local footer_height = ((self.view.footer_visible and not self.view.footer.settings.reclaim_height) and 1 or
                                      0) * self.view.footer:getHeight()
            local page_visible_height = self.ui.dimen.h - footer_height
            local pan_diff = diff * page_visible_height
            if self.view.page_overlap_enable then
                local overlap_lines = G_reader_settings:readSetting("copt_overlap_lines") or 1
                local overlap_h = Screen:scaleBySize(
                    self.configurable.font_size * 1.1 * self.configurable.line_spacing * (1 / 100)) * overlap_lines
                if pan_diff > overlap_h then
                    pan_diff = pan_diff - overlap_h
                elseif pan_diff < -overlap_h then
                    pan_diff = pan_diff + overlap_h
                end
            end
            local old_pos = self.current_pos

            local do_dim_area = math.abs(diff) == 1
            self:_gotoPos(self.current_pos + pan_diff, do_dim_area)

            if diff > 0 and old_pos == self.current_pos then
                self.ui:handleEvent(Event:new("EndOfBook"))
            elseif diff < 0 and old_pos == self.current_pos then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
        elseif self.view.view_mode == "page" then
            local page_count = self.ui.document:getVisiblePageNumberCount()
            local old_page = self.current_page

            if diff > 0 then
                diff = math.ceil(diff)
            else
                diff = math.floor(diff)
            end
            local new_page = self.current_page
            if self.ui.document:hasHiddenFlows() then
                local test_page
                for i = 1, math.abs(diff * page_count) do
                    if diff > 0 then
                        test_page = self.ui.document:getNextPage(new_page)
                    else
                        test_page = self.ui.document:getPrevPage(new_page)
                    end
                    if test_page > 0 then
                        new_page = test_page
                    end
                end
            else
                new_page = new_page + diff * page_count
            end
            self:_gotoPage(new_page)

            if diff > 0 and old_page == self.current_page then
                self.ui:handleEvent(Event:new("EndOfBook"))
            elseif diff < 0 and old_page == self.current_page then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
        end
        if self.ui.document ~= nil then
            self.xpointer = self.ui.document:getXPointer()
        end
        return true
    end

    ReaderUI:registerModule("rolling", ui_rolling_module_instance)
    ReaderUI.postInitCallback = nil
    ReaderUI.postReaderReadyCallback = nil
end

return M
