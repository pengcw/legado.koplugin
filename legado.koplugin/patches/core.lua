local util = require("util")
local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local ReadHistory = require("readhistory")
local logger = require("logger")

local M = {
    _wrappers = {},
}

local LEGADO_CACHE_PATH = "/cache/legado.cache/"
local LEGADO_BOOK_DIR = "/Legado\u{200B}书目/"
local LEGADO_EXT = "\u{200B}.html"

local function get_file_path(file_path, instance)
    if instance and instance.document and instance.document.file then
        return instance.document.file
    end
    return file_path
end

local function is_legado_path(file_path, instance)
    local path = get_file_path(file_path, instance)
    return type(path) == 'string' and path:lower():find(LEGADO_CACHE_PATH, 1, true) ~= nil
end

local function is_legado_browser_book(file_path, instance)
    local path = get_file_path(file_path, instance)
    return type(path) == "string"
            and path:find(LEGADO_BOOK_DIR, 1, true) ~= nil
            and path:find(LEGADO_EXT, 1, true) ~= nil
end

M.readui_runtime = function(parent_ref)
    if not parent_ref then return end
    local ui = parent_ref.name == "ReaderUI" and parent_ref or parent_ref.ui
    if not ui or ui.name ~= "ReaderUI" then return end
    if ui._ref_legado_wrapped == true then return end

    ui._ref_legado_wrapped = true
    if ui.rolling then
        table.insert(M._wrappers, util.wrapMethod(
            ui.rolling,  
            "onGotoViewRel",  
            function(self, diff)
                local scroll_mode = self.view.view_mode == "scroll"
                local old_pos = scroll_mode and self.current_pos or self.current_page
                self.onGotoViewRel:raw_method_call(diff)
                local new_pos = scroll_mode and self.current_pos or self.current_page
                -- local beginning_page = self.ui.document:getNextPage(0)
                -- old_pos cannot be equal to 1, otherwise it won't work in scroll mode.
                if diff < 0 and old_pos == new_pos and is_legado_path(nil, self.ui) then
                    self.ui:handleEvent(Event:new("StartOfBook"))
                end
                return true
            end  
        ))  
    end
    if ui.paging then
        -- In scroll mode, one screen may have multiple pages
        table.insert(M._wrappers, util.wrapMethod(  
            ui.paging,  
            "onGotoViewRel",  
            function(self, diff)  
                local old_pos = self:getTopPage()
                self.onGotoViewRel:raw_method_call(diff)
                local new_pos = self:getTopPage()
                -- require("logger").info("ReaderPaging:onGotoViewRel scroll_mode old_pos new_pos diff ",scroll_mode,old_pos,new_pos,diff)
                if diff < 0 and old_pos == 1 and old_pos == new_pos and is_legado_path(nil, self.ui) then
                    self.ui:handleEvent(Event:new("StartOfBook"))
                end
                return true
            end  
        ))  
    end
    if ui.status then
        table.insert(M._wrappers, util.wrapMethod(  
            ui.status,  
            "addToMainMenu",  
            function(self, menu_items)  
                if not is_legado_path(nil, self.ui) then
                    self.addToMainMenu:raw_method_call(menu_items)
                end
            end  
        ))
    end
    if ui.toc then
        table.insert(M._wrappers, util.wrapMethod(  
            ui.toc,  
            "onShowToc",  
            function(self)  
                if is_legado_path(nil, self.ui) then
                    self.ui:handleEvent(Event:new("ShowLegadoToc"))
                    return true
                else
                    return self.onShowToc:raw_method_call()
                end
            end  
        )) 
    end
    -- hook footer (fix koreader .cbz next chapter crash)
    if ui.view and ui.view.footer then
        table.insert(M._wrappers, util.wrapMethod(  
            ui.view.footer,  
            "getBookProgress",  
            function(self)  
                if self.ui and self.ui.document then
                    return self.getBookProgress:raw_method_call()
                else
                    local pageno = self.pageno or 0
                    local pages = self.pages or 1
                    if pages == 0 then pages = 1 end
                    return pageno / pages
                end
            end  
        ))
        table.insert(M._wrappers, util.wrapMethod(  
            ui.view.footer,  
            "updateFooterPage",  
            function(self, force_repaint, full_repaint)  
                if self.ui and self.ui.document then
                    return self.updateFooterPage:raw_method_call(force_repaint, full_repaint)
                end
            end  
        )) 
    end
    if ui.bookinfo and ui.bookinfo.addToMainMenu then
        table.insert(M._wrappers, util.wrapMethod(  
            ui.bookinfo,  
            "addToMainMenu",  
            function(self, menu_items)  
                if not is_legado_path(nil, self.ui) then  
                    self.addToMainMenu:raw_method_call(menu_items)
                end  
            end  
        ))
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

    if FileManager._legado_wrapped == nil then
        FileManager._legado_wrapped = true
        
        table.insert(M._wrappers, util.wrapMethod(  
            FileManager,  
            "showOpenWithDialog",  
            function(self, file)  
                if file and is_legado_browser_book(file) then  
                    self:handleEvent(Event:new("ShowLegadoLibraryView"))  
                else  
                    self.showOpenWithDialog:raw_call(self, file)
                end  
            end  
        ))
        
        table.insert(M._wrappers, util.wrapMethod(  
            FileManager,  
            "showFiles",  
            function(self, path, focused_file, selected_files)  
                if is_legado_path(path) then  
                    local home_dir = G_reader_settings:readSetting("home_dir") or  
                                        require("apps/filemanager/filemanagerutil").getDefaultDir()  
                    if home_dir then  
                        local legado_homedir = home_dir .. LEGADO_BOOK_DIR  
                        if util.fileExists(legado_homedir) then  
                            path = legado_homedir  
                        else  
                            path = home_dir  
                        end  
                    end  
                end  
                self.showFiles:raw_method_call(path, focused_file, selected_files)  
            end  
        ))
    end

    -- fix simpleui.koplugin
    if ReaderUI._legado_wrapped == nil then
        ReaderUI._legado_wrapped = true
        table.insert(M._wrappers, util.wrapMethod(  
            ReaderUI,  
            "showReader",  
            function(self, file, provider, seamless, is_provider_forced, after_open_callback)  
                if file and is_legado_browser_book(file) then
                    if parent_ref.openFile then parent_ref:openFile(file) end
                else
                    self.showReader:raw_method_call(file, provider, seamless, is_provider_forced, after_open_callback)
                end
            end  
        ))
    end

    -- self.ui.history not add history
    if ReadHistory._legado_wrapped == nil then
        ReadHistory._legado_wrapped = true
        table.insert(M._wrappers, util.wrapMethod(  
            ReadHistory,  
            "addItem",  
            function(self, file, ts, no_flush)
                if is_legado_path(file) or is_legado_browser_book(file) then
                    return
                end
                return self.addItem:raw_method_call(file, ts, no_flush)
            end  
        ))
        table.insert(M._wrappers, util.wrapMethod(  
            ReadHistory,  
            "updateLastBookTime",  
            function(self, no_flush)
                if self.hist and self.hist[1] ~= nil then
                    self.updateLastBookTime:raw_method_call(no_flush)
                end
            end  
        ))  
    end

    if filemanagerutil._legado_wrapped == nil then
        filemanagerutil._legado_wrapped = true
        table.insert(M._wrappers, util.wrapMethod(
            filemanagerutil,
            "genBookCoverButton",
            function(file, book_props, caller_callback, button_disabled)
                if file and is_legado_browser_book(file) then
                    return {
                        text = "legado 选项",
                        enabled = true,
                        callback = function()
                            local file = file
                            if caller_callback then caller_callback() end
                            if parent_ref.openBrowserMenu then parent_ref:openBrowserMenu(file) end
                        end
                    }
                else
                    return filemanagerutil.genBookCoverButton:raw_call(file, book_props, caller_callback, button_disabled)
                end
            end
        ))
    end
end

M.uninstall = function()
    if M._wrappers then
        for _, wrapper in ipairs(M._wrappers) do
            if wrapper.revert then wrapper:revert() end
        end
        M._wrappers = {}
    end
    if ReaderUI then ReaderUI._legado_wrapped = nil end
    if FileManager then FileManager._legado_wrapped = nil end
    if filemanagerutil then filemanagerutil._legado_wrapped = nil end
    if ReadHistory then ReadHistory._legado_wrapped  =nil end
    local ui = ReaderUI.instance or FileManager.instance
    if ui then ui._ref_legado_wrapped = nil end
end

return M