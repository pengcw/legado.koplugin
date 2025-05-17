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

local function testPatches()
    return not not require("apps/reader/modules/readerrolling").c8eeb679f
end

function Legado:init()
    self.patches_ok = testPatches()
    if self.ui.name == "ReaderUI" then
        BookReader:initializeFromReaderUI(self.ui, self.patches_ok)
    else
        self.ui.menu:registerToMainMenu(self)
    end
    LibraryView:initializeRegisterEvent(self)
    self:onDispatcherRegisterActions()
end

function Legado:openLibraryView()
    LibraryView:fetchAndShow()
    if not self.patches_ok then
        Backend:installPatches()
    end
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
        event = "ShowLegadoToc",
        title = _("返回 Legado 目录"),
        reader = true
    })
end

local is_low_version
function Legado:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        if is_low_version == nil then
            local ko_version = require("version"):getNormalizedCurrentVersion()
            is_low_version = (ko_version < 202411000000)
        end
        menu_items.Legado = {
            text = is_low_version and "Legado 书目(低版环境)" or "Legado 书目",
            sorting_hint = "search",
            help_text = "连接 Legado 书库" .. (is_low_version and "，Koreader 版本低，建议升级" or ""),
            callback = function()
                self:openLibraryView()
            end
        }
    end
end

Backend:initialize()
return Legado
