local BD = require("ui/bidi")
local Font = require("ui/font")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Menu = require("libs/Menu")
local Device = require("device")
local ButtonDialog = require("ui/widget/buttondialog")
local T = ffiUtil.template
local Screen = Device.screen

local Icons = require("libs/Icons")
local Backend = require("Backend")
local MessageBox = require("MessageBox")
local ChapterListing = require("ChapterListing")
local H = require("libs/Helper")

local LibraryView = Menu:extend{
    name = "library_view",
    is_enable_shortcut = false,
    is_popout = false,
    title = "Library",
    with_context_menu = true,
    disk_available = nil,
    ui_refresh_time=os.time()
}

function LibraryView:init()

    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:openMenu()
    end
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()

    Menu.init(self)

    if Device:hasKeys({"Home"}) or Device:hasDPad() then
        self.key_events.Close = {{Device.input.group.Back}}
        self.key_events.RefreshLibrary = {{"Home"}}
        self.key_events.FocusRight = {{"Right"}}
    end

    -- 防御性编码,koreader又又崩了
    local status, err = pcall(self.updateItems, self)
    if not status then
        MessageBox.error('初始化失败')
        logger.err('leado plugin err:', err)
    end
end

function LibraryView:onFocusRight()
    local focused_widget = Menu.getFocusItem(self)
    if focused_widget then

        local point = focused_widget.dimen:copy()
        point.x = point.x + point.w
        point.y = point.y + point.h / 2
        point.w = 0
        point.h = 0
        UIManager:sendEvent(Event:new("Gesture", {
            ges = "tap",
            pos = point
        }))
        return true
    end

end

function LibraryView:onSwipe(arg, ges_ev)
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "south" then
        self:onRefreshLibrary()

        return
    end

    Menu.onSwipe(self, arg, ges_ev)
end

function LibraryView:updateItems(no_recalculate_dimen)

    local books_cache_data = Backend:getBookShelfCache()
    if H.is_tbl(books_cache_data) and #books_cache_data > 0 then
        self.item_table = self:generateItemTableFromMangas(books_cache_data)
        self.multilines_show_more_text = false
        self.items_per_page = nil
    else
        self.item_table = self:generateEmptyViewItemTable()
        self.multilines_show_more_text = true
        self.items_per_page = 1
    end
    Menu.updateItems(self, nil, no_recalculate_dimen)
end

function LibraryView:onRefreshLibrary()
    NetworkMgr:runWhenOnline(function()
        Backend:closeDbManager()
        MessageBox:loading("Refreshing Library", function()
            return Backend:refreshLibraryCache(self.ui_refresh_time)
        end, function(state, response)
            if state == true then

                if response and response.type == 'ERROR' then
                    Backend:show_notice(response.message or '刷新失败')
                else
                    Backend:show_notice('刷新成功')
                    self:updateItems(true)
                    self.ui_refresh_time = os.time()
                end
            end
        end)

    end)

end

function LibraryView:generateItemTableFromMangas(books)
    local item_table = {}
    for _, bookinfo in ipairs(books) do

        local show_book_title =
            ("%s (%s)"):format(bookinfo.name or "未命名书籍", bookinfo.author or "未知作者")

        table.insert(item_table, {
            cache_id = bookinfo.cache_id,
            text = show_book_title .. " (" .. bookinfo.originName .. ")"
        })
    end

    return item_table
end

function LibraryView:generateEmptyViewItemTable()
    return {{
        text = string.format("No books found in library. Try%s swiping down to refresh.!",
            (Device:hasKeys({"Home"}) and ' Press the home button or ' or '')),
        dim = true,
        select_enabled = false
    }}
end

function LibraryView:fetchAndShow()
    UIManager:show(LibraryView:new{
        covers_fullscreen = true,
        title = "书架"
    })
end

function LibraryView:onPrimaryMenuChoice(item)

    local bookinfo = Backend:getBookInfoCache(item.cache_id)

    local onReturnCallback = function()
        self:fetchAndShow()
    end

    ChapterListing:fetchAndShow({
        cache_id = bookinfo.cache_id,
        bookUrl = bookinfo.bookUrl,
        durChapterIndex = bookinfo.durChapterIndex,
        name = bookinfo.name,
        author = bookinfo.author
    }, onReturnCallback, true)

    self:onClose(self)

end

function LibraryView:onContextMenuChoice(item)

    local bookinfo = Backend:getBookInfoCache(item.cache_id)
    local msginfo = [[
        书名: <<%1>>
        作者: %2
        分类: %3
        书源名称: %4
        总章数:%5
        总字数：%6
        简介：%7
    ]]

    msginfo = T(msginfo, bookinfo.name or '', bookinfo.author or '', bookinfo.kind or '', bookinfo.originName or '',
        bookinfo.totalChapterNum or '', bookinfo.wordCount or '', bookinfo.intro or '')

    MessageBox:confirm(msginfo, nil, {
        icon = "notice-info",
        no_ok_button = true,
        other_buttons_first = true,
        other_buttons = {{{
            text = '置顶',
            callback = function()
                Backend:setBooksTopUp(item.cache_id)
                self:updateItems(true)
            end
        }}}
    })

end

function LibraryView:openInstalledReadSource()

    local setting_data = Backend:getSettings()

    MessageBox:input(nil, function(input_text)
        if input_text then
            local new_setting_url = util.trim(input_text)
            Backend:HandleResponse(Backend:setEndpointUrl(new_setting_url), function(data)
                self:updateItems(true)
                self:onRefreshLibrary()
            end, function(err_msg)
                MessageBox:error('设置失败:', err_msg)
            end)
        end
    end, {
        title = "设置阅读api接口地址",
        input = tostring(setting_data.setting_url),
        description = [[
(书架与接口地址关联,换地址原缓存信息会隐藏,建议静态IP或域名使用)
格式符合RFC3986,服务器版本需加/reader3
例:手机app http://127.0.0.1:1122
服务器版 http://127.0.0.1:1122/reader3
服务器版有账号 
https://username:password@127.0.0.1:1122/reader3
]]
    })
end

function LibraryView:openMenu()
    local dialog

    local buttons = {{{
        text = Icons.FA_MAGNIFYING_GLASS .. " Search for books",
        callback = function()
            UIManager:close(dialog)
            MessageBox:info('暂不支持')
        end
    }}, {{
        text = Icons.FA_GLOBE .. " legado web地址",
        callback = function()
            UIManager:close(dialog)
            self:openInstalledReadSource()
        end
    }}, {{
        text = Icons.FA_TIMES .. ' ' .. "Clear All caches",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm('确认清空所有缓存书籍?', function(result)
                if result then
                    Backend:closeDbManager()
                    MessageBox:loading("清除中", function()
                        return Backend:cleanAllBookCaches()
                    end, function(state, response)
                        if state == true then
                            Backend:HandleResponse(response, function(data)
                                Backend:show_notice("已清除")
                                self:onClose()
                            end,function(err_msg)
                                    MessageBox:error('操作失败:', tostring(err_msg))
                            end)
                        end
                    end)
                end
            end, {
                ok_text = "清空",
                cancel_text = "取消",
                timeout = 5
            })
        end
    }}, {{
        text = Icons.FA_QUESTION_CIRCLE .. ' ' .. "关于",
        callback = function()
            UIManager:close(dialog)

            local about_txt = [[
-昨日邻家乞新火，晓窗分与读书灯-

    简介: 一个在 KOReader 中阅读legado开源阅读书库的插件, 适配阅读3.0 web api, 支持手机app和服务器版本, 初衷是kindle的浏览器体验不佳, 目的部分替代受限设备的浏览器实现流畅的在线阅读，提升老设备体验。
    功能: 前后无缝翻页,离线缓存,自动预下载章节,同步进度,碎片章节历史记录清除,支持漫画，其他没有的功能可在服务端操作。
    操作: 列表支持下拉或Home键刷新、右键列表菜单、Menu键左上角菜单,阅读界面下拉菜单有返回按键。
 章节页面图标说明: %1 可下载 %2 已阅读 %3 服务器阅读进度
 帮助改进请到pengcw/legado.koplugin反馈
 版本: ver_%4
              ]]

            local version = ''
            local ok, config_or_err = pcall(dofile, H.getPluginDirectory() .. "/_meta.lua")
            if ok then
                version = config_or_err.version
            end
            about_txt = T(about_txt, Icons.FA_DOWNLOAD, Icons.FA_CHECK_CIRCLE, Icons.FA_THUMB_TACK, version)
            MessageBox:custom({
                text = about_txt,
                alignment = "left"
            })
        end
    }}}

    local patches_file_path = ffiUtil.joinPath(H.getUserPatchesDirectory(), '2-legado_plugin_func.lua')

    local ReaderRolling = require("apps/reader/modules/readerrolling")
    if ReaderRolling.c8eeb679b ~= true then
        table.insert(buttons, 1, {{
            text = Icons.FA_EXCLAMATION_CIRCLE .. ' 碎片历史记录清除[未开启]',
            callback = function()
                UIManager:close(dialog)
                local source_patches_file_path = ffiUtil.joinPath(H.getPluginDirectory(),
                    'patches/2-legado_plugin_func.lua')
                if not util.fileExists(patches_file_path .. '.disabled') then

                    if H.copyFileFromTo(source_patches_file_path, patches_file_path) then
                        MessageBox:success(
                            '安装成功,扩展向前翻页和历史记录清除功能,重启koreader后生效')
                    else
                        MessageBox:error('copy文件失败,请尝试手动安装~', 6)
                    end
                else
                    MessageBox:error('补丁已被禁用,请从设置-补丁管理中开启', 6)
                end

            end
        }})
    end

    if not Device:isTouchDevice() then
        table.insert(buttons, 4, {{
            text = Icons.FA_EXCLAMATION_CIRCLE .. ' ' .. "刷新书架",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshLibrary()
            end
        }})
    end

    if H.is_nil(self.disk_available) then
        local cache_dir = H.getTempDirectory()
        local disk_use = util.diskUsage(cache_dir)
        if disk_use and disk_use.available then
            self.disk_available = disk_use.available / 1073741824
        end
    end

    dialog = ButtonDialog:new{
        title = string.format("\u{F1C0} 剩余空间: %.1f G", self.disk_available or 0.01),
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }

    UIManager:show(dialog)
end

function LibraryView:openSearchBooksDialog()
    MessageBox:input("键入要搜索的书籍名称", function(input_text)
        if input_text then
            self:searchBooks(input_text)
        end
    end, {
        title = '搜索书源',
        input_hint = "剑来"
    })

end

function LibraryView:searchBooks(search_text)

    local onReturnCallback = function()
        self:fetchAndShow()
    end
    self:onClose()

end

function LibraryView:onClose()
    Backend:closeDbManager()
    Menu.onClose(self)
end

function LibraryView:onCloseWidget()
    Backend:closeDbManager()
    Menu.onCloseWidget(self)
end

return LibraryView
