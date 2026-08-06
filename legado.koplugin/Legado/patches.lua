
local util = require("util")
local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ReadHistory = require("readhistory")
local Env = require("Legado.Helper.Env")

-- Do not use util.wrapMethod; may be overridden by other plugins
-- Minimal hook scope. Avoid restoring — may affect plugins that patch later
-- Before you: plugin A patches (you wrap it)
-- After you: plugin C patches (it wraps you)
-- ui.rolling, ui.paging, ReaderUI, ui.view.footer, etc. are frequently destroyed and recreated as books open/close

local M = {
    -- "soft unload" and "state penetration"
    is_enabled = false,
}

M.readui_runtime = function(read_ui)
    if not read_ui then return end
    local ui = read_ui.name == "ReaderUI" and read_ui or read_ui.ui
    if not ui or ui.name ~= "ReaderUI" then return end
    if ui._ref_legado_wrapped == true then return end

    ui._ref_legado_wrapped = true

    if ui.rolling then
        local orig_rolling_onGotoViewRel = ui.rolling.onGotoViewRel
        ui.rolling.onGotoViewRel = function(self, diff)
            if not M.is_enabled then return orig_rolling_onGotoViewRel(self, diff) end
            local scroll_mode = self.view.view_mode == "scroll"
            local old_pos = scroll_mode and self.current_pos or self.current_page
            orig_rolling_onGotoViewRel(self, diff)
            -- local beginning_page = self.ui.document:getNextPage(0)
            -- old_pos cannot be equal to 1, otherwise it won't work in scroll mode.
            local new_pos = scroll_mode and self.current_pos or self.current_page
            if diff < 0 and old_pos == new_pos and Env.is_legado_path(nil, self.ui) then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
            return true
        end
    end

    if ui.paging then
        -- In scroll mode, one screen may have multiple pages
        local orig_paging_onGotoViewRel = ui.paging.onGotoViewRel
        ui.paging.onGotoViewRel = function(self, diff)
            if not M.is_enabled then return orig_paging_onGotoViewRel(self, diff) end
            local old_pos = self:getTopPage()
            orig_paging_onGotoViewRel(self, diff)
            local new_pos = self:getTopPage()
            if diff < 0 and old_pos == 1 and old_pos == new_pos and Env.is_legado_path(nil, self.ui) then
                self.ui:handleEvent(Event:new("StartOfBook"))
            end
            return true
        end
    end

    -- hook footer (fix koreader .cbz next chapter crash)
    if ui.view and ui.view.footer then
        local orig_footer_getBookProgress = ui.view.footer.getBookProgress
        ui.view.footer.getBookProgress = function(self)
            if not M.is_enabled or (self.ui and self.ui.document) then
                return orig_footer_getBookProgress(self)
            else
                local pageno = self.pageno or 0
                local pages = self.pages or 1
                if pages == 0 then pages = 1 end
                return pageno / pages
            end
        end

        local orig_footer_updateFooterPage = ui.view.footer.updateFooterPage
        ui.view.footer.updateFooterPage = function(self, force_repaint, full_repaint)
            if not M.is_enabled or (self.ui and self.ui.document) then
                return orig_footer_updateFooterPage(self, force_repaint, full_repaint)
            end
        end
    end
    
    return true
end

M.install = function(parent_ref)
    -- In the plugin init, ReaderUI.instance == nil
    -- If the plugin is disabled, no functional patch is applied
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["legado"] == true then
            return
        end
    end
    if not parent_ref then return end

    M.is_enabled = true

    if FileManager._legado_wrapped == nil then
        FileManager._legado_wrapped = true

        local orig_FileManager_showOpenWithDialog = FileManager.showOpenWithDialog
        FileManager.showOpenWithDialog = function(self, file)
            if M.is_enabled and file and Env.is_legado_browser_book(file) then
                self:handleEvent(Event:new("ShowLegadoLibraryView"))
            else
                return orig_FileManager_showOpenWithDialog(self, file)
            end
        end
    end

    if ReaderUI._legado_wrapped == nil then
        ReaderUI._legado_wrapped = true
        -- fix bookself.koplugin
        local orig_ReaderUI_showReader = ReaderUI.showReader
        ReaderUI.showReader = function(self, file, provider, seamless, is_provider_forced, after_open_callback)
            if M.is_enabled and file and Env.is_legado_browser_book(file) then
                if parent_ref.openFile then parent_ref:openFile(file) end
            else
                return orig_ReaderUI_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
            end
        end
    end

    if ReadHistory._legado_wrapped == nil then
        ReadHistory._legado_wrapped = true

        local orig_ReadHistory_addItem = ReadHistory.addItem
        ReadHistory.addItem = function(self, file, ts, no_flush)
            if M.is_enabled and (Env.is_legado_path(file) or Env.is_legado_browser_book(file)) then
                return
            end
            return orig_ReadHistory_addItem(self, file, ts, no_flush)
        end

        local orig_ReadHistory_updateLastBookTime = ReadHistory.updateLastBookTime
        ReadHistory.updateLastBookTime = function(self, no_flush)
            if not M.is_enabled or (self.hist and self.hist[1] ~= nil) then
                return orig_ReadHistory_updateLastBookTime(self, no_flush)
            end
        end
    end

    if filemanagerutil._legado_wrapped == nil then
        filemanagerutil._legado_wrapped = true

        local orig_filemanagerutil_genBookCoverButton = filemanagerutil.genBookCoverButton
        -- Note: genBookCoverButton does not take a `self` argument.
        filemanagerutil.genBookCoverButton = function(file, book_props, caller_callback, button_disabled)
            if M.is_enabled and file and Env.is_legado_browser_book(file) then
                return {
                    text = "legado 选项",
                    enabled = true,
                    callback = function()
                        if caller_callback then caller_callback() end
                        if parent_ref and parent_ref.openBrowserMenu then parent_ref:openBrowserMenu(file) end
                    end
                }
            else
                return orig_filemanagerutil_genBookCoverButton(file, book_props, caller_callback, button_disabled)
            end
        end
    end
end

M.uninstall = function()
    M.is_enabled = false
    if ReaderUI then ReaderUI._legado_wrapped = nil end
    if FileManager then FileManager._legado_wrapped = nil end
    if filemanagerutil then filemanagerutil._legado_wrapped = nil end
    if ReadHistory then ReadHistory._legado_wrapped = nil end
    local ui = ReaderUI.instance or FileManager.instance
    if ui then ui._ref_legado_wrapped = nil end
end

return M
