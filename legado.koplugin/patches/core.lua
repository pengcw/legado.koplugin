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
        return type(file_path) == 'string' and file_path:lower():find('/cache/legado.cache/', 1, true) or false
    end
    local is_legado_browser_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:find("/Legado\u{200B}书目/", 1, true) or false
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
        if is_legado_path(file) or is_legado_browser_path(file) then
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
        if is_legado_path(nil, self.ui) then
            self.ui:handleEvent(Event:new("ShowLegadoToc"))
            return true
        else
            return original_onShowToc(self)
        end
    end
    local FileManager = require("apps/filemanager/filemanager")
    local original_showOpenWithDialog = FileManager.showOpenWithDialog
    function FileManager:showOpenWithDialog(file)
        if file and is_legado_browser_path(file) then
            self:handleEvent(Event:new("ShowLegadoLibraryView"))
        else
            original_showOpenWithDialog(self, file)
        end
    end
    local original_showFiles = FileManager.showFiles
    function FileManager:showFiles(path, focused_file, selected_files)
        if is_legado_path(path) then
            local home_dir = G_reader_settings:readSetting("home_dir") or
                                 require("apps/filemanager/filemanagerutil").getDefaultDir()
            if home_dir then
                local legado_homedir = home_dir .. "/Legado\u{200B}书目"
                path = legado_homedir
            end
        end
        original_showFiles(self, path, focused_file, selected_files)
    end
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local original_genBookCoverButton = filemanagerutil.genBookCoverButton
    function filemanagerutil.genBookCoverButton(file, book_props, caller_callback, button_disabled)
        if file and is_legado_browser_path(file) then
            return {
                text = "legado 设置",
                enabled = true,
                callback = function()
                    caller_callback()
                    local ui = require("apps/filemanager/filemanager").instance or
                                   require("apps/reader/readerui").instance
                    if ui then
                        ui:handleEvent(Event:new("ShowLegadoBrowserOption", file))
                    end
                end
            }
        else
            return original_genBookCoverButton(file, book_props, caller_callback, button_disabled)
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
