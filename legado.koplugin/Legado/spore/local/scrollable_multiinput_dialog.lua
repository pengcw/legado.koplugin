local MultiInputDialog = require("ui/widget/multiinputdialog")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")

local FieldScroll = ScrollableContainer:extend{}
function FieldScroll:propagateEvent(event)
    if self._is_scrollable and event.handler == "onGesture" and #event.args == 1 then
        local ges = event.args[1]
        if ges.ges == "swipe" and (ges.direction == "north" or ges.direction == "south")
            and ges.pos and ges.pos:intersectWith(self.dimen) then
            return self:onScrollableSwipe(nil, ges)
        end
    end
    return ScrollableContainer.propagateEvent(self, event)
end

local Dialog = MultiInputDialog:extend{}

function Dialog:init()
    self._scroll_body = nil
    self.cropping_widget = nil
    MultiInputDialog.init(self)
    local original = self.dialog_frame[1]
    self._scroll_title = original[1]
    self._scroll_buttons = original[#original]
    self._scroll_frame_extra = self.dialog_frame:getSize().h - original:getSize().h
    self._scroll_body = VerticalGroup:new{align = "left"}
    local width = self.title_bar:getSize().w
    local inner_width = width - ScrollableContainer:getScrollbarWidth()
    for i = 2, #original - 1 do
        local wrapper = original[i]
        wrapper.dimen.w = inner_width
        table.insert(self._scroll_body, wrapper)
    end
    self.cropping_widget = FieldScroll:new{
        dimen = Geom:new{w = width, h = 1},
        show_parent = self,
        self._scroll_body,
    }
    self.dialog_frame[1] = VerticalGroup:new{
        align = "left",
        self._scroll_title,
        self.cropping_widget,
        self._scroll_buttons,
    }
    self:_resizeFieldViewport()
end

function Dialog:_resizeFieldViewport()
    if not self._scroll_body then return end
    local keyboard_height = self.keyboard_visible and self._input_widget:getKeyboardDimen().h or 0
    local available = Screen:getHeight() - keyboard_height
    local body_height = self._scroll_body:getSize().h
    local fixed_height = self._scroll_title:getSize().h + self._scroll_buttons:getSize().h
        + self._scroll_frame_extra + 2 * Screen:scaleBySize(12)
    if keyboard_height > 0 and available <= fixed_height then
        MultiInputDialog.onCloseKeyboard(self)
        available = Screen:getHeight()
    end
    local scroll = self.cropping_widget
    local offset = scroll:getScrolledOffset().y
    scroll:reset()
    scroll.dimen.h = math.min(body_height, math.max(1, available - fixed_height))
    scroll:initState()
    self[1].dimen.h = available
    self.dialog_frame[1]:resetLayout()

    local y = 0
    for _, wrapper in ipairs(self._scroll_body) do
        local height = wrapper:getSize().h
        if wrapper[1] == self._input_widget then
            if y < offset then offset = y end
            if y + height > offset + scroll.dimen.h then offset = y + height - scroll.dimen.h end
            break
        end
        y = y + height
    end
    if body_height > scroll.dimen.h then
        offset = math.max(0, math.min(offset, body_height - scroll.dimen.h))
        scroll:scrollToRatio(nil, (offset + scroll.dimen.h / 2) / body_height)
    end
    UIManager:setDirty(self, function()
        return "ui", self.dialog_frame.dimen
    end)
end

function Dialog:onShowKeyboard(...)
    MultiInputDialog.onShowKeyboard(self, ...)
    self:_resizeFieldViewport()
end

function Dialog:onCloseKeyboard(...)
    MultiInputDialog.onCloseKeyboard(self, ...)
    self:_resizeFieldViewport()
end

function Dialog:onSwitchFocus(inputbox)
    MultiInputDialog.onSwitchFocus(self, inputbox)
    self:_resizeFieldViewport()
end

return Dialog
