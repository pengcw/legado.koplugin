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
local T = ffiUtil.template
local _ = require("gettext")

local ChapterListing = require("ChapterListing")
local Icons = require("libs/Icons")
local Backend = require("Backend")
local MessageBox = require("libs/MessageBox")
local H = require("libs/Helper")

local LibraryView = Menu:extend{
    name = "library_view",
    is_enable_shortcut = false,
    is_popout = false,
    title = "Library",
    with_context_menu = true,
    disk_available = nil,
    selected_item = nil,
    chapter_listing = nil,
    ui_refresh_time = os.time()
}

function LibraryView:init()

    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:openMenu()
    end
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()

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
        logger.err('leado plugin err:', H.errorHandler(err))
    end
    LibraryView.instance = self
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
                Backend:HandleResponse(response, function(data)
                    Backend:show_notice('同步成功')
                    self:updateItems(true)
                    self.ui_refresh_time = os.time()
                end, function(err_msg)
                    Backend:show_notice(response.message or '同步失败')
                end)
            end
        end)

    end)

end

function LibraryView:generateItemTableFromMangas(books)
    local item_table = {}
    for _, bookinfo in ipairs(books) do

        local show_book_title = ("%s (%s)[%s]"):format(bookinfo.name or "未命名书籍",
            bookinfo.author or "未知作者", bookinfo.originName)

        table.insert(item_table, {
            cache_id = bookinfo.cache_id,
            text = show_book_title
        })
    end

    return item_table
end

function LibraryView:generateEmptyViewItemTable()
    return {{
        text = string.format("No books found in library. Try%s swiping down to refresh.",
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
    self.selected_item = item
    LibraryView.onReturnCallback = function()
        self:updateItems()
        UIManager:show(self)
    end
    self.chapter_listing = ChapterListing:fetchAndShow({
        cache_id = bookinfo.cache_id,
        bookUrl = bookinfo.bookUrl,
        durChapterIndex = bookinfo.durChapterIndex,
        name = bookinfo.name,
        author = bookinfo.author,
        cacheExt = bookinfo.cacheExt
    }, LibraryView.onReturnCallback, true)

    self:onClose(self)

end

function LibraryView:onContextMenuChoice(item)

    local bookinfo = Backend:getBookInfoCache(item.cache_id)
    local msginfo = [[
        书名： <<%1>>
        作者： %2
        分类： %3
        书源： %4
        总章数：%5
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
            text = (bookinfo.sortOrder > 0) and '置顶' or '取消置顶',
            callback = function()
                Backend:setBooksTopUp(item.cache_id, bookinfo.sortOrder)
                self:updateItems(true)
            end
        }}, {{
            text = '换源',
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    require("BookSourceResults"):fetchAndShow(bookinfo, function()
                        self:onRefreshLibrary()
                    end)
                end)
            end
        }}, {{
            text = '删除',
            callback = function()
                MessageBox:confirm(string.format(
                    "是否删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复", bookinfo.name),
                    function(result)
                        if result then
                            Backend:closeDbManager()
                            MessageBox:loading("删除中...", function()
                                Backend:deleteBook(bookinfo)
                                return Backend:refreshLibraryCache()
                            end, function(state, response)
                                if state == true then
                                    Backend:HandleResponse(response, function(data)
                                        Backend:show_notice("删除成功")
                                        self:updateItems(true)
                                    end, function(err_msg)
                                        MessageBox:error('删除失败：', err_msg)
                                    end)
                                end
                            end)
                        end
                    end, {
                        ok_text = "删除",
                        cancel_text = "取消"
                    })

            end
        }}}
    })

end

function LibraryView:openInstalledReadSource()

    local setting_data = Backend:getSettings()
    local servers_history = setting_data.servers_history or {}
    local setting_url = tostring(setting_data.setting_url)
    local history_lines = {}

    for k, _ in pairs(servers_history) do
        if k ~= setting_url then
            table.insert(history_lines, tostring(k))
        end
    end
    servers_history = nil

    local description = [[
        (书架与接口地址关联，换地址原缓存信息会隐藏，建议静态IP或域名使用)
        格式符合RFC3986，服务器版本需加/reader3
        
        示例:
        → 手机APP     http://127.0.0.1:1122
        → 服务器版    http://127.0.0.1:1122/reader3
        → 带认证服务  https://username:password@127.0.0.1:1122/reader3
    ]]

    local dialog
    local reset_callback
    local history_cur = 0

    if #history_lines > 0 then

        local servers_history_str = table.concat(history_lines, '\r\n')
        description = description .. "\r\n历史记录，\r\n" .. servers_history_str

        table.insert(history_lines, tostring(setting_url))
        reset_callback = function()
            history_cur = history_cur + 1
            if history_cur > #history_lines then
                history_cur = 1
            end
            dialog.button_table:getButtonById("reset"):enable()
            dialog:refreshButtons()
            return history_lines[history_cur]
        end
    end

    local save_callback = function(input_text)
        if H.is_str(input_text) then
            local new_setting_url = util.trim(input_text)
            return Backend:HandleResponse(Backend:setEndpointUrl(new_setting_url), function(data)

                self.item_table = self:generateEmptyViewItemTable()
                self.multilines_show_more_text = true
                self.items_per_page = 1
                Menu.updateItems(self)

                self:onRefreshLibrary()

                return true
            end, function(err_msg)
                Backend:show_notice('设置失败：' .. tostring(err_msg))
                return false
            end)
        end
        Backend:show_notice('输入为空')
        return false
    end

    dialog = MessageBox:input(nil, nil, {
        title = "设置阅读 API 接口地址",
        input = setting_url,
        description = description,
        save_callback = save_callback,
        allow_newline = false,
        reset_button_text = '填入历史',
        reset_callback = reset_callback
    })

    if H.is_func(reset_callback) then
        dialog.button_table:getButtonById("reset"):enable()
        dialog:refreshButtons()
    end
end

function LibraryView:openMenu()
    local dialog
    local settings = Backend:getSettings()
    local buttons = {{{
        text = Icons.FA_MAGNIFYING_GLASS .. " Search for books",
        callback = function()
            UIManager:close(dialog)
            self:openSearchBooksDialog()
        end
    }}, {{
        text = Icons.FA_BOOK .. " 漫画模式 " .. (settings.stream_image_view and '[流式]' or '[缓存]'),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "当前模式: %s \r\n \r\n缓存模式: 边看边下载。\n缺点：占空间\n优点；预加载后相对流畅\r\n \r\n流式: 不下载到磁盘。\n缺点：对网络要求较高且画质缺少优化，需要下载任一章节后才能开启（建议服务端开启图片代理）\n优点：不占空间。",
                (settings.stream_image_view and '[流式]' or '[缓存]')), function(result)
                if result then
                    settings.stream_image_view = not settings.stream_image_view
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        Backend:show_notice("设置成功")
                        self:onClose()
                    end, function(err_msg)
                        MessageBox:error('设置失败:', err_msg)
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end
    }}, {{
        text = Icons.FA_GLOBE .. " Legado WEB地址",
        callback = function()
            UIManager:close(dialog)
            self:openInstalledReadSource()
        end
    }}, {{
        text = Icons.FA_TIMES .. ' ' .. "Clear all caches",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm('请选择要执行的操作：', nil, {
                no_ok_button = true,
                other_buttons_first = true,
                other_buttons = {{{
                    text = '清除接口历史',
                    callback = function()
                        settings.servers_history = {}
                        Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                            Backend:show_notice("清除成功")
                        end, function(err_msg)
                            MessageBox:error('操作失败：', err_msg)
                        end)
                    end
                }}, {{
                    text = '清除所有缓存',
                    callback = function()
                        Backend:closeDbManager()
                        MessageBox:loading("清除中", function()
                            return Backend:cleanAllBookCaches()
                        end, function(state, response)
                            if state == true then
                                Backend:HandleResponse(response, function(data)
                                    Backend:show_notice("已清除")
                                    self:onClose()
                                end, function(err_msg)
                                    MessageBox:error('操作失败：', tostring(err_msg))
                                end)
                            end
                        end)
                    end
                }}}
            })

        end
    }}, {{
        text = Icons.FA_QUESTION_CIRCLE .. ' ' .. "关于",
        callback = function()
            UIManager:close(dialog)

            local about_txt = [[
--清风不识字,何故乱翻书--

    简介: 一个在 KOReader 中阅读legado开源阅读书库的插件, 适配阅读3.0 web api, 支持手机app和服务器版本, 初衷是 Kindle 的浏览器体验不佳, 目的部分替代受限设备的浏览器实现流畅的在线阅读，提升老设备体验。
    功能: 前后无缝翻页，离线缓存，自动预下载章节，同步进度，碎片章节历史记录清除，支持漫画离线和在线阅读，服务器版换源搜索，其他没有的功能可在其它端操作后刷新。
    操作: 列表支持下拉或 Home 键刷新、右键列表菜单、Menu 键左上角菜单，阅读界面下拉菜单有返回按键。
    章节页面图标说明: %1 可下载 /n %2 已阅读 /n %3 阅读进度 /n 
    帮助改进请到 Github：pengcw/legado.koplugin 反馈 issues
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
                            '安装成功，扩展向前翻页和历史记录清除功能，重启KOReader后生效')
                    else
                        MessageBox:error('copy文件失败，请尝试手动安装~', 6)
                    end
                else
                    MessageBox:error('补丁已被禁用，请从设置-补丁管理中开启', 6)
                end

            end
        }})
    end

    if not Device:isTouchDevice() then
        table.insert(buttons, 4, {{
            text = Icons.FA_EXCLAMATION_CIRCLE .. ' ' .. "同步书架",
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

    dialog = require("ui/widget/buttondialog"):new{
        title = string.format("\u{F1C0} 剩余空间: %.1f G", self.disk_available or 0.01),
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }

    UIManager:show(dialog)
end

function LibraryView:openSearchBooksDialog()
    require("BookSourceResults"):searchAndShow(function()
        self:onRefreshLibrary()
    end)
end

function LibraryView:onClose()
    Backend:closeDbManager()
    Menu.onClose(self)
end

function LibraryView:onCloseWidget()
    Backend:closeDbManager()
    Menu.onCloseWidget(self)
end

local BookReader = require("BookReader")
local ReaderUI = require("apps/reader/readerui")
function LibraryView:initializeRegisterEvent(legado_main)

    function legado_main:onShowLegadoLibraryView()
        -- FileManager menu only
        if not (self.ui and self.ui.document) then
            if LibraryView.instance then
                LibraryView.instance:updateItems(true)
                UIManager:show(LibraryView.instance)
            else
                LibraryView:fetchAndShow()
            end
        end
        return true
    end

    function legado_main:onReturnLegadoChapterListing()

        if not (self.ui and self.ui.name == "ReaderUI" and LibraryView.instance and type(BookReader.getIsShowing) ==
            'function' and BookReader:getIsShowing() == true and type(LibraryView.instance.selected_item) == 'table') then
            return true
        end

        if ReaderUI and ReaderUI.instance then
            -- readerUI、FileManager同时关闭app会退出
            -- readerUI -> ReturnLegadoChapterListing event -> show ChapterListing -> close ->show LibraryView ->close -> ? 
            local FileManager = require("apps/filemanager/filemanager")

            ReaderUI.instance:onClose()
            if FileManager.instance then
                FileManager.instance:reinit()
            else
                FileManager:showFiles()
            end
        end

        local chapter_listing = LibraryView.instance.chapter_listing
        if chapter_listing then
            chapter_listing:updateItems(true)
            UIManager:show(chapter_listing)
        else

            local selected_item = LibraryView.instance.selected_item
            local bookinfo = Backend:getBookInfoCache(selected_item.cache_id)

            LibraryView.instance.chapter_listing = ChapterListing:fetchAndShow({
                cache_id = bookinfo.cache_id,
                bookUrl = bookinfo.bookUrl,
                durChapterIndex = bookinfo.durChapterIndex,
                name = bookinfo.name,
                author = bookinfo.author,
                cacheExt = bookinfo.cacheExt
            }, function()
                self:onShowLegadoLibraryView()
            end, true)
        end
        return true
    end

    function legado_main:onDocSettingsLoad(doc_settings, document)
        if doc_settings and doc_settings.data and type(doc_settings.readSetting) == 'function' then
            local filepath = doc_settings:readSetting("doc_path") or ""
            if not filepath:find('/legado.cache/', 1, true) then
                return
            end
            doc_settings.data.txt_preformatted = 0
        end
    end
    function legado_main:onReaderReady(doc_settings)

        if LibraryView.instance and LibraryView.instance.chapter_listing and
            LibraryView.instance.chapter_listing.book_reader then
            logger.dbg("test_book_reader.chapter_call_event",
                LibraryView.instance.chapter_listing.book_reader.chapter_call_event)
            logger.dbg("test_book_reader.is_showing", LibraryView.instance.chapter_listing.book_reader.is_showing)
        end
        if not (self.ui.name == "ReaderUI" and doc_settings and LibraryView.instance and
            LibraryView.instance.chapter_listing and LibraryView.instance.chapter_listing.book_reader and
            LibraryView.instance.chapter_listing.book_reader.chapter_call_event and type(BookReader.getIsShowing) ==
            'function' and BookReader:getIsShowing() == true and type(doc_settings.readSetting) == 'function') then
            return
        end

        local chapter_listing = LibraryView.instance.chapter_listing
        local chapter_call_event = chapter_listing.book_reader.chapter_call_event
        local filepath = doc_settings:readSetting("doc_path") or ""

        if not filepath:find('/legado.cache/', 1, true) then
            return
        end

        local has_doc_props = doc_settings:readSetting("doc_props") ~= nil
        local current_page = self.ui:getCurrentPage() or 0

        if not has_doc_props then
            -- new doc
            if chapter_call_event == 'pre' then
                self.ui.gotopage:onGoToEnd()
            end
        else
            local doc_pages = doc_settings:readSetting("doc_pages") or 0
            if chapter_call_event == 'next' then
                if current_page ~= 1 then
                    self.ui.gotopage:onGoToBeginning()
                end
            elseif chapter_call_event == 'pre' then
                if current_page ~= doc_pages then
                    self.ui.gotopage:onGoToEnd()
                end
            end
        end

    end

    table.insert(legado_main.ui, 3, legado_main)

end

return LibraryView
