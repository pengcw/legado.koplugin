local logger = require("logger")
local Device = require("device")
local Event = require("ui/event")
local Screen = Device.screen

-- 插件被禁用则不应用补丁
if G_reader_settings and G_reader_settings.readSetting then 
    local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
    if plugins_disabled and plugins_disabled ["legado"] == true then 
        return
    end
end

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
ReaderRolling.c8eeb679e = true
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

-- fix ver_2024.11 .cbz err
local ReaderFooter = require("apps/reader/modules/readerfooter")
local original_getBookProgress = ReaderFooter.getBookProgress
function ReaderFooter:getBookProgress()
    if self.ui and self.ui.document then
        return original_getBookProgress(self)
    else
        return self.pageno / self.pages
    end
end