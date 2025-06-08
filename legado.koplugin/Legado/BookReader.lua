local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local logger = require("logger")
local dbg = require("dbg")
local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")
local verify_patched = require("patches.core").verifyPatched

local Device = require("device")
local Screen = Device.screen

if not dbg.log then
    dbg.log = logger.dbg
end

local M = {
    on_return_callback = nil,
    on_end_of_book_callback = nil,
    on_start_of_book_callback = nil,
    on_read_settings_callback = nil,
    is_showing = false,
    chapter = nil
}

function M:show(options)
    self.on_return_callback = options.on_return_callback
    self.on_end_of_book_callback = options.on_end_of_book_callback
    self.on_start_of_book_callback = options.on_start_of_book_callback
    self.chapter_call_event = options.chapter_call_event
    self.chapter = options.chapter

    local book_path = options.chapter.cacheFilePath

    if self.is_showing and ReaderUI.instance then
        if ReaderUI.instance.rolling and verify_patched(ReaderUI.instance.rolling) ~= true and
            ReaderUI.instance.rolling.c8eeb679k ~= true then
            M.overriderollingHandler()
        end
        ReaderUI.instance:switchDocument(book_path, true)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(book_path, nil, true)
    end

    self.is_showing = true
    return self
end

function M:initializeFromReaderUI(ui, add_menu)
    if ui and ui.name == "ReaderUI" then
        if ui.menu and self.is_showing and add_menu ~= true then
            ui.menu:registerToMainMenu(M)
        end
        ui:registerPostInitCallback(function()
            self:hookWithPriorityOntoReaderUiEvents(ui)
        end)
    end
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
        help_text = "点击返回 Legado 书籍目录",
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

    local ReaderRolling = require("apps/reader/modules/readerrolling")
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
    ReaderRolling.c8eeb679k = true
    ReaderRolling.original_onGotoViewRel = ReaderRolling.onGotoViewRel
    function ReaderRolling:onGotoViewRel(diff)
        local scroll_mode = self.view.view_mode == "scroll"
        local old_pos = scroll_mode and self.current_pos or self.current_page
        self:original_onGotoViewRel(diff)
        local new_pos = scroll_mode and self.current_pos or self.current_page
        if diff < 0 and old_pos == new_pos then
            self.ui:handleEvent(Event:new("StartOfBook"))
        end
        return true
    end

    ReaderUI:registerModule("rolling", ui_rolling_module_instance)
    ReaderUI.postInitCallback = nil
    ReaderUI.postReaderReadyCallback = nil
end

return M
