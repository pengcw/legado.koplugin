local M = {
    _mark = "_c8eeb679f"
}

M._setMark = function(instance)
    instance[M._mark] = true
end

M.verifyPatched = function(instance)
    if not instance then
        instance = require("apps/reader/modules/readerrolling")
    end
    return instance[M._mark] == true
end

M.install = function()
    local Event = require("ui/event")

    -- If the plugin is disabled, no functional patch is applied
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["legado"] == true then
            return
        end
    end
    local is_legado_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find('cache/legado.cache/', 1, true)
    end
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    local onGotoViewRel_original = ReaderRolling.onGotoViewRel
    ReaderRolling.onGotoViewRel = function(self, diff)
        local scroll_mode = self.view.view_mode == "scroll"
        local old_pos = scroll_mode and self.current_pos or self.current_page
        onGotoViewRel_original(self, diff)
        local new_pos = scroll_mode and self.current_pos or self.current_page
        -- local beginning_page = self.ui.document:getNextPage(0)
        -- old_pos cannot be equal to 1, otherwise it won't work in scroll mode.
        if diff < 0 and old_pos == new_pos and is_legado_path(nil, self.ui) then
            self.ui:handleEvent(Event:new("StartOfBook"))
        end
        return true
    end
    M._setMark(ReaderRolling)
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    local onGotoViewRel_orig = ReaderPaging.onGotoViewRel
    -- In scroll mode, one screen may have multiple pages
    function ReaderPaging:onGotoViewRel(diff)
        local scroll_mode = self.view.view_mode == "scroll"
        local old_pos = self:getTopPage()
        onGotoViewRel_orig(self, diff)
        local new_pos = self:getTopPage()
        -- require("logger").info("ReaderPaging:onGotoViewRel scroll_mode old_pos new_pos diff ",scroll_mode,old_pos,new_pos,diff)
        if diff < 0 and old_pos == 1 and old_pos == new_pos and is_legado_path(nil, self.ui) then
            self.ui:handleEvent(Event:new("StartOfBook"))
        end
        return true
    end
    local ReadHistory = require("readhistory")
    local original_addItem = ReadHistory.addItem
    function ReadHistory:addItem(file, ts, no_flush)
        if is_legado_path(file) then
            return
        end
        return original_addItem(self, file, ts, no_flush)
    end
    local original_updateLastBookTime = ReadHistory.updateLastBookTime
    function ReadHistory:updateLastBookTime(no_flush)
        if self.hist and self.hist[1] ~= nil then
            original_updateLastBookTime(self, no_flush)
        end
    end
    local ReaderToc = require("apps/reader/modules/readertoc")
    local original_onShowToc = ReaderToc.onShowToc
    function ReaderToc:onShowToc()
        if self.ui and is_legado_path(nil, self.ui) then
            self.ui:handleEvent(Event:new("ShowLegadoToc"))
            return true
        else
            return original_onShowToc(self)
        end
    end
    local ReaderUI = require("apps/reader/readerui")
    local original_showFileManager = ReaderUI.showFileManager
    function ReaderUI:showFileManager(file, selected_files)
        original_showFileManager(self, file, selected_files)
        local FileManager = require("apps/filemanager/filemanager")
        if is_legado_path(file) and FileManager.instance and FileManager.instance.handleEvent then
            FileManager.instance:handleEvent(Event:new("ShowLegadoLibraryView"))
        end
    end
    -- fix koreader .cbz next chapter crash
    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local original_getBookProgress = ReaderFooter.getBookProgress
    function ReaderFooter:getBookProgress()
        if self.ui and self.ui.document then
            return original_getBookProgress(self)
        else
            return self.pageno / self.pages
        end
    end
    local original_updateFooterPage = ReaderFooter.updateFooterPage
    function ReaderFooter:updateFooterPage(force_repaint, full_repaint)
        if self.ui and self.ui.document then
            return original_updateFooterPage(self, force_repaint, full_repaint)
        end
        return
    end
end

return M
