local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Backend = require("Backend")
local BookReader = require("BookReader")
local LibraryView = require("LibraryView")

local Legado = WidgetContainer:extend({
    name = "开源阅读插件"
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

function Legado:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        menu_items.Legado = {
            text = _("Legado 书目"),
            sorting_hint = "search",
            callback = function()
                self:openLibraryView()
            end
        }
    end
end

function Legado:openLibraryView()
    LibraryView:fetchAndShow()
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

return Legado
