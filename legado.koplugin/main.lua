local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")
local util = require("util")

local MessageBox = require("MessageBox")
local Backend = require("Backend")
local ChapterListing = require("ChapterListing")
local LibraryView = require("LibraryView")
local BookReader = require("BookReader")

local Legado = WidgetContainer:extend({
    name = "开源阅读插件"
})

function Legado:init()
    if self.ui.name == "ReaderUI" then
        BookReader:initializeFromReaderUI(self.ui)
    else
        self.ui.menu:registerToMainMenu(self)
    end
end

function Legado:addToMainMenu(menu_items)
    menu_items.Legado = {
        text = _("legado书目"),
        sorting_hint = "search",
        callback = function()

            self:openLibraryView()
        end
    }
end

function Legado:openLibraryView()

    LibraryView:fetchAndShow()
end

function Legado:onReaderReady(doc_settings)
    local filepath = doc_settings:readSetting("doc_path")
    if filepath and filepath:lower():find('/legado.cache/') then
        ChapterListing:onMainReaderReady(self.ui, doc_settings)
    end
end

Backend:initialize()

return Legado
