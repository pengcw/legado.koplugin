local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local LibraryView = require("LibraryView")

local Legado = WidgetContainer:extend({
    name = "开源阅读插件"
})

function Legado:init()
    if self.ui.name == "ReaderUI" then
        require("BookReader"):initializeFromReaderUI(self.ui)
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

local Dispatcher = require("dispatcher")
function Legado:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_legado_libraryview", {
        category = "none",
        event = "ShowLegadoLibraryView",
        title = _("Legado 书目"),
        -- general = true,
        -- separator=true,
        filemanager = true
    })
    Dispatcher:registerAction("return_legado_chapterlisting", {
        category = "none",
        event = "ReturnLegadoChapterListing",
        title = _("返回Legado目录"),
        reader = true
    })
end

require("Backend"):initialize()
return Legado
