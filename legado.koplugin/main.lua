local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local H = require("Legado/Helper")
local Backend = require("Legado/Backend")
local LibraryView = require("Legado/LibraryView")
local patcher = require("Legado.patches")
local DocumentRegistry = require("document/documentregistry")
local CreDocument = require("Legado/Document")

local Legado = WidgetContainer:extend({
    name = "开源阅读插件",
    library_view = nil,
})

function Legado:init()
    -- on open FileManager or ReaderUI
    if not H.has_cache("plg:name") then
        H.set_cache("plg:name", "legado")
        if self.path then
            -- fix Android path
            local path = self.path:gsub("/+", "/")
            H.set_cache("plg:path", path)
        end
    end
    if not Backend.settings_data then
        Backend:initialize()
    end
    if self.ui then
        LibraryView:initializeRegisterEvent(self)
        if self.ui.menu then
            self.ui.menu:registerToMainMenu(self)
        end
    end
    self:registerDocumentRegistryAuxProvider()
    self:onDispatcherRegisterActions()
    CreDocument:register(DocumentRegistry)
    patcher.install(self)
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
        title = _("返回 Legado 目录"),
        reader = true,
    })
    Dispatcher:registerAction("show_legado_search", {
        category = "none",
        event = "ShowLegadoSearch",
        title = _("以书籍信息搜索 Legado 书源"),
        reader = true,
    })
    Dispatcher:registerAction("refresh_legado_chapter", {
        category = "none",
        event = "RefreshLegadoChapter",
        title = _("强制刷新 Legado 章节"),
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
    if not self.ui.document then -- FileManager menu only
        local is_low_version = H.get_cache("is_low_version")
        if is_low_version == nil then
            local ko_version = require("version"):getNormalizedCurrentVersion()
            is_low_version = (ko_version and ko_version < 202411000000)
            H.set_cache("is_low_version", is_low_version)
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
    elseif self.ui.document.file and self.ui.name == "ReaderUI" and self.initializeFromReaderUI then
        self:initializeFromReaderUI(self.ui.document, menu_items)
    end
end

function Legado:openLibraryView()
    self.library_view = LibraryView:fetchAndShow()
    UIManager:nextTick(function()
        Backend:checkOta()
    end)
end

function Legado:isCachePath(file_path, instance)
    if not (file_path and instance) then instance = self.ui end
    return patcher.is_legado_path(file_path, instance)
end

function Legado:isBrowserBook(file_path, instance)
    if not (file_path and instance) then instance = self.ui end
    return patcher.is_legado_browser_book(file_path, instance)
end

return Legado
