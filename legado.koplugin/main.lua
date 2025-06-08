local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local H = require("Legado/Helper") -- need to load first 
local Backend = require("Legado/Backend") -- two
local BookReader = require("Legado/BookReader")
local LibraryView = require("Legado/LibraryView")
local verify_patched = require("patches.core").verifyPatched

local Legado = WidgetContainer:extend({
    name = "开源阅读插件",
    patches_ok = nil
})

function Legado:init()
    -- on open FileManager or ReaderUI
    self.patches_ok = verify_patched()
    if not H.plugin_path then
        H.initialize("legado", self.path)
    end
    if not Backend.settings_data then
        Backend:initialize()
    end
    if self.ui then
        BookReader:initializeFromReaderUI(self.ui, self.patches_ok)
        LibraryView:initializeRegisterEvent(self)
        if  self.ui.menu then
            self.ui.menu:registerToMainMenu(self)
        end
    end
    self:onDispatcherRegisterActions()
end

function Legado:openLibraryView()
    LibraryView:fetchAndShow()
    UIManager:nextTick(function()
        if not self.patches_ok then
            Backend:installPatches()
        end
        Backend:checkOta()
    end)
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
    Dispatcher:registerAction("show_legado_search", {
        category = "none",
        event = "ShowLegadoSearch",
        title = _("以书籍信息搜索 Legado 书源"),
        reader = true
    })
end

local is_low_version
function Legado:addToMainMenu(menu_items)
    if not self.ui.document then -- FileManager menu only
        if is_low_version == nil then
            local ko_version = require("version"):getNormalizedCurrentVersion()
            is_low_version = (ko_version and ko_version < 202411000000)
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

return Legado
