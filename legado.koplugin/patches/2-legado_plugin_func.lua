local logger = require("logger")
local Device = require("device")
local Event = require("ui/event")
local Screen = Device.screen

local ReaderRolling = require("apps/reader/modules/readerrolling")
local onGotoViewRel_original = ReaderRolling.onGotoViewRel
ReaderRolling.onGotoViewRel = function(self, diff)
    local scroll_mode = self.view.view_mode == "scroll"
    local old_pos = scroll_mode and self.current_pos or self.current_page
    onGotoViewRel_original(self, diff)
    local new_pos = scroll_mode and self.current_pos or self.current_page
    if diff < 0 and old_pos == new_pos then
        self.ui:handleEvent(Event:new("StartOfBook"))
    end
    return true
end

ReaderRolling.c8eeb679b = true
local ReadHistory = require("readhistory")
local original_addItem = ReadHistory.addItem
function ReadHistory:addItem(file, ts, no_flush)
    if type(file) == 'string' and file:lower():find('/legado.cache/', 1, true) then
        return true
    end
    return original_addItem(self, file, ts, no_flush)
end

local original_updateLastBookTime = ReadHistory.updateLastBookTime
function ReadHistory:updateLastBookTime(no_flush)
    if self.hist[1] ~= nil then
        original_updateLastBookTime(self, no_flush)
    end
end

