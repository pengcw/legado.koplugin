local logger = require("logger")
local Device = require("device")
local Event = require("ui/event")
local Screen = Device.screen
local ReaderRolling = require("apps/reader/modules/readerrolling")

function ReaderRolling:onGotoViewRel(diff)
    logger.dbg("goto relative screen:", diff, "in mode:", self.view.view_mode)

    if self.view.view_mode == "scroll" then
        local footer_height = ((self.view.footer_visible and not self.view.footer.settings.reclaim_height) and 1 or 0) *
                                  self.view.footer:getHeight()
        local page_visible_height = self.ui.dimen.h - footer_height
        local pan_diff = diff * page_visible_height
        if self.view.page_overlap_enable then
            local overlap_lines = G_reader_settings:readSetting("copt_overlap_lines") or 1
            local overlap_h = Screen:scaleBySize(self.configurable.font_size * 1.1 * self.configurable.line_spacing *
                                                     (1 / 100)) * overlap_lines
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

