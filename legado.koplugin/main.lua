local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local PlgState = require("Legado/PlgState")
local H = require("Legado/Helper")
local Backend = require("Legado/Backend")
local LibraryView = require("Legado/LibraryView")
local Patcher = require("Legado.patches")
local DocumentRegistry = require("document/documentregistry")
local CreDocument = require("Legado/Document")
local EventHandlers = require("Legado.EventHandlers")


local Legado = WidgetContainer:extend({
    name = "开源阅读插件",
    library_view = nil,
})

function Legado:init()
    if self.path then
        -- fix Android path
        self.path = self.path:gsub("/+", "/")
    end
    PlgState.ctx = self
    if not PlgState.plg_name then
        PlgState.plg_name = "legado"
        PlgState.plg_path = self.path
    end
    if not Backend.settings_data then
        Backend:initialize()
    end
    if self.ui then
        EventHandlers:register(self)
        if self.ui.menu then
            self.ui.menu:registerToMainMenu(self)
        end
    end
    self:registerDocumentRegistryAuxProvider()
    self:onDispatcherRegisterActions()
    CreDocument:register(DocumentRegistry)
    Patcher.install(self)
end

function Legado:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_legado_libraryview", {
        category = "none",
        event = "ShowLegadoLibraryView",
        title = _("Legado 书目"),
        filemanager = true,
    })
    Dispatcher:registerAction("return_legado_chapterlisting", {
        category = "none",
        event = "ShowLegadoToc",
        title = _("Legado：返回目录"),
        reader = true,
    })
    Dispatcher:registerAction("show_legado_search", {
        category = "none",
        event = "ShowLegadoSearch",
        title = _("Legado：以书籍信息搜索"),
        reader = true,
    })
    Dispatcher:registerAction("refresh_legado_chapter", {
        category = "none",
        event = "RefreshLegadoChapter",
        title = _("Legado：强制刷新章节"),
        reader = true,
    })
end

function Legado:isFileTypeSupported(file)
    return self:isBrowserBook(file)
end

function Legado:registerDocumentRegistryAuxProvider()
    DocumentRegistry:addAuxProvider({
        provider_name = "开源阅读",
        provider = "legado",
        order = 50, -- order in OpenWith dialog
        disable_file = true,
        disable_type = true,
    })
end

function Legado:addToMainMenu(menu_items)
    if not (self.ui and menu_items) then return end
    if not PlgState:getDocument() then -- FileManager menu only
        local is_low_version = PlgState.is_low_version
        if is_low_version == nil then
            local ko_version = require("version"):getNormalizedCurrentVersion()
            is_low_version = (ko_version and ko_version < 202411000000)
            PlgState.is_low_version = is_low_version
        end
        local main_menu = {
            text = "Legado 书目(Koreader 版本低，建议升级)",
            sorting_hint = "search",
            help_txt = "本插件仅支持 2024.11 以上",
            callback = function() end,
        }
        if not is_low_version and self.genMainMenuItems then
            main_menu = self:genMainMenuItems(self.ui)
        end
        menu_items.Legado_main = main_menu
    elseif PlgState:isReaderOpen() and PlgState:getDocument().file and self.initializeFromReaderUI then
        self:initializeFromReaderUI(PlgState:getDocument(), menu_items)
    end
end

function Legado:openLibraryView()
    self.library_view = LibraryView:fetchAndShow()
    UIManager:nextTick(function()
        Backend:backupDbWithPreCheck()
        Backend:checkOta()
    end)
end

function Legado:isCachePath(file_path, instance)
    if not (file_path and instance) then instance = PlgState:getUI() end
    return Patcher.is_legado_path(file_path, instance)
end

function Legado:isBrowserBook(file_path, instance)
    if not (file_path and instance) then instance = PlgState:getUI() end
    return Patcher.is_legado_browser_book(file_path, instance)
end

return Legado
