local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Backend = require("Legado/Backend")
local BookReader = require("Legado/BookReader")
local LibraryView = require("Legado/LibraryView")
local util = require("util")
local H = require("Legado/Helper")

local Legado = WidgetContainer:extend({
    name = "开源阅读插件",
    patches_ok = nil
})

function Legado:init()
    Backend:initialize()
    if self.ui.name == "ReaderUI" then
        BookReader:initializeFromReaderUI(self.ui)
    else
        self.ui.menu:registerToMainMenu(self)
    end
    LibraryView:initializeRegisterEvent(self)
    self:onDispatcherRegisterActions()
end

local ko_version = G_reader_settings and G_reader_settings:readSetting("quickstart_shown_version") or
                       require("version"):getNormalizedCurrentVersion()
function Legado:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        menu_items.Legado = {
            text = (ko_version < 202411000000) and "Legado 书目(版本过低)" or "Legado 书目",
            sorting_hint = "search",
            callback = function()
                self:openLibraryView()
            end
        }
    end
end

function Legado:openLibraryView()
    LibraryView:fetchAndShow()
    self:checkEnv()
end

function Legado:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_legado_libraryview", {
        category = "none",
        event = "ShowLegadoLibraryView",
        title = _("Legado 书目"),
        filemanager = true
    })
    Dispatcher:registerAction("return_legado_chapterlisting", {
        category = "none",
        event = "ReturnLegadoChapterListing",
        title = _("返回 Legado 目录"),
        reader = true
    })
end

function Legado:checkEnv()
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    if not ReaderRolling.c8eeb679e and not self.patches_ok then
        local patches_file_path = H.joinPath(H.getUserPatchesDirectory(), '2-legado_plugin_func.lua')
        local source_patches = H.joinPath(H.getPluginDirectory(), 'patches/2-legado_plugin_func.lua')
        local disabled_patches = patches_file_path .. '.disabled'
        for _, file in ipairs({patches_file_path, disabled_patches}) do
            if util.fileExists(file) then
                util.removeFile(file)
            end
        end
        H.copyFileFromTo(source_patches, patches_file_path)
        self.patches_ok = true
        UIManager:restartKOReader()
    else
        self.patches_ok = true
    end
end

return Legado
