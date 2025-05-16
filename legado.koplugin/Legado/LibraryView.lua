local BD = require("ui/bidi")
local Font = require("ui/font")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Menu = require("ui/widget/menu")
local Device = require("device")
local T = ffiUtil.template
local _ = require("gettext")

local ChapterListing = require("Legado/ChapterListing")
local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local LibraryView = Menu:extend{
    name = "library_view",
    is_enable_shortcut = false,
    is_popout = false,
    title = "Library",
    with_context_menu = true,
    align_baselines = true,
    disk_available = nil,
    selected_item = nil,
    chapter_listing = nil,
    show_search_item = nil,
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
    local status, err = pcall(self.refreshItems, self)
    if not status then

        local last_backup_db = string.format("%s/%s", H.getTempDirectory(), "bookinfo.db.bak")
        local bookinfo_db_path = string.format("%s/%s", H.getTempDirectory(), "bookinfo.db")
        local has_backup = util.fileExists(last_backup_db)
        logger.err('legado plugin err:', H.errorHandler(err))

        MessageBox:confirm(string.format(
            "初始化失败\n疑似缓存文件损坏，如果多次重试失败，请执行还原或者清理！"),
            function(result)
                if result then
                    util.removeFile(bookinfo_db_path)
                    if util.fileExists(last_backup_db) then
                        H.copyFileFromTo(last_backup_db, bookinfo_db_path)
                        util.removeFile(last_backup_db)
                    end
                    self:onClose()
                    MessageBox:info(string.format("缓存文件损坏已%s，请重试打开",
                        has_backup and "还原" or "清除"))
                end
            end, {
                ok_text = has_backup and "还原" or "清除",
                cancel_text = "取消"
            })
    else
        local setting_data = Backend:getSettings()
        local last_backup_time = setting_data.last_backup_time
        if not last_backup_time or os.time() - last_backup_time > 86400 then
            local last_backup_db = string.format("%s/%s", H.getTempDirectory(), "bookinfo.db.bak")
            local bookinfo_db_path = string.format("%s/%s", H.getTempDirectory(), "bookinfo.db")
            if util.fileExists(last_backup_db) then
                util.removeFile(last_backup_db)
            end
            H.copyFileFromTo(bookinfo_db_path, last_backup_db)
            logger.info("legado plugin: backup successful")
            setting_data.last_backup_time = os.time()
            Backend:saveSettings(setting_data)
        end
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

function LibraryView:refreshItems(no_recalculate_dimen)

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
                    self.show_search_item = true
                    self:refreshItems()
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
    if self.show_search_item == true then
        item_table[1] = {
            text = string.format('%s Search...', Icons.FA_MAGNIFYING_GLASS),
            mandatory = "[Go]"
        }
        self.show_search_item = nil
    end

    for _, bookinfo in ipairs(books) do

        local show_book_title = ("%s (%s)[%s]"):format(bookinfo.name or "未命名书籍",
            bookinfo.author or "未知作者", bookinfo.originName)

        table.insert(item_table, {
            cache_id = bookinfo.cache_id,
            text = show_book_title,
            mandatory = Icons.FA_ELLIPSIS_VERTICAL
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
    if not item.cache_id then
        self:openSearchBooksDialog()
        return
    end
    local bookinfo = Backend:getBookInfoCache(item.cache_id)
    self.selected_item = item
    LibraryView.onReturnCallback = function()
        self:refreshItems(true)
        UIManager:show(self)
    end
    self.chapter_listing = ChapterListing:fetchAndShow({
        cache_id = bookinfo.cache_id,
        bookUrl = bookinfo.bookUrl,
        durChapterIndex = bookinfo.durChapterIndex,
        name = bookinfo.name,
        author = bookinfo.author,
        cacheExt = bookinfo.cacheExt,
        origin = bookinfo.origin,
        originName = bookinfo.originName,
        originOrder = bookinfo.originOrder
    }, LibraryView.onReturnCallback, true)

    self:onClose(self)

end

function LibraryView:onMenuHold(item)
    if not item.cache_id then
        self:openSearchBooksDialog()
        return
    end
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
                self:refreshItems(true)
            end
        }}, {{
            text = '换源',
            callback = function()
                NetworkMgr:runWhenOnline(function()
                    require("Legado/BookSourceResults"):fetchAndShow(bookinfo, function()
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
                                        self:refreshItems(true)
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
    local history_lines = setting_data.servers_history or {}
    local setting_url = tostring(setting_data.setting_url)
    if not history_lines[1] then
        history_lines = {}
    end

    local description = [[
        (书架与接口地址关联，设置格式符合 RFC3986，认证信息如有特殊字符需要 URL 编码，服务器版本必须加 /reader3)  示例:
        → 手机APP     http://127.0.0.1:1122
        → 服务器版    http://127.0.0.1:1122/reader3
        → 带认证服务  https://username:password@127.0.0.1:1122/reader3
    ]]

    local dialog
    local reset_callback
    local history_cur = 0
    local history_lines_len = #history_lines
    if history_lines_len > 0 then
        -- 只展示最后3行
        local servers_history_str = table.concat(history_lines, '\n', math.max(1, #history_lines - 2))
        description = description .. string.format("\n历史记录(%s)：\n%s", history_lines_len, servers_history_str)

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
        text = Icons.FA_BOOK .. " 漫画模式 " .. (settings.stream_image_view and '[流式]' or '[缓存]'),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "当前模式: %s \r\n \r\n缓存模式: 边看边下载。\n缺点：占空间。\n优点：预加载后相对流畅。\r\n \r\n流式：不下载到磁盘。\n缺点：对网络要求较高且画质缺少优化，需要下载任一章节后才能开启（建议服务端开启图片代理）。\n优点：不占空间。",
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
            MessageBox:confirm(
                "是否清空本地书架所有已缓存章节与阅读记录？\r\n（刷新会重新下载）",
                function(result)
                    if result then
                        Backend:closeDbManager()
                        MessageBox:loading("清除中", function()
                            return Backend:cleanAllBookCaches()
                        end, function(state, response)
                            if state == true then
                                Backend:HandleResponse(response, function(data)
                                    settings.servers_history = {}
                                    Backend:saveSettings(settings)
                                    Backend:show_notice("已清除")
                                    self:onClose()
                                end, function(err_msg)
                                    MessageBox:error('操作失败：', tostring(err_msg))
                                end)
                            end
                        end)
                    end
                end, {
                    ok_text = "清空",
                    cancel_text = "取消"
                })
        end
    }}, {{
        text = Icons.FA_QUESTION_CIRCLE .. ' ' .. "关于",
        callback = function()
            UIManager:close(dialog)
            local about_txt = [[
-- 清风不识字，何故乱翻书 --

简介：
一个在 KOReader 中阅读 Legado 书库的插件，适配阅读 3.0，支持手机 APP 和服务器版本。初衷是 Kindle 的浏览器体验不佳，目的是部分替代受限设备的浏览器，实现流畅的网文阅读，提升老设备体验。

操作：
列表支持下拉或 Home 键刷新，右键列表菜单 / Menu 键左上角菜单，阅读界面下拉菜单有返回选项，书架和目录可绑定手势使用。

章节页面图标说明:
%1 可下载  %2 已阅读  %3 阅读进度

帮助改进：
请到 Github：pengcw/legado.koplugin 反馈 issues

版本: ver_%4]]

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

    if not Device:isTouchDevice() then
        table.insert(buttons, 4, {{
            text = Icons.FA_EXCLAMATION_CIRCLE .. ' ' .. " 同步书架",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshLibrary()
            end
        }})
    end

    if not self.disk_available then
        local cache_dir = H.getTempDirectory()
        local disk_use = util.diskUsage(cache_dir)
        if disk_use and disk_use.available then
            self.disk_available = disk_use.available / 1073741824
        end
    end

    dialog = require("ui/widget/buttondialog"):new{
        title = string.format(Icons.FA_DATABASE .. " 剩余空间: %.1f G", self.disk_available or -1),
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }

    UIManager:show(dialog)
end

function LibraryView:openSearchBooksDialog()
    require("Legado/BookSourceResults"):searchAndShow(function()
        self:onRefreshLibrary()
    end)
end

function LibraryView:onMenuSelect(entry, pos)
    if entry.select_enabled == false then
        return true
    end
    local selected_context_menu = pos ~= nil and pos.x > 0.8
    if selected_context_menu then
        self:onMenuHold(entry, pos)
    else
        self:onPrimaryMenuChoice(entry, pos)
    end
end

function LibraryView:onClose()
    Backend:closeDbManager()
    Menu.onClose(self)
end

function LibraryView:onCloseWidget()
    Backend:closeDbManager()
    Menu.onCloseWidget(self)
end

local BookReader = require("Legado/BookReader")
local ReaderUI = require("apps/reader/readerui")
local LuaSettings = require("luasettings")
function LibraryView:initializeRegisterEvent(legado_main)

    function legado_main:onShowLegadoLibraryView()
        -- FileManager menu only
        if not (self.ui and self.ui.document) then
            if LibraryView.instance then
                LibraryView.instance:refreshItems(true)
                UIManager:show(LibraryView.instance)
            else
                self:openLibraryView()
            end
        end
        return true
    end

    function legado_main:onShowLegadoToc()
        -- 在阅读界面有些设置会重载 ReaderUI , 重载后 BookReader:getIsShowing() ~= true
        if not (self.ui and self.ui.name == "ReaderUI" and LibraryView.instance and type(BookReader.getIsShowing) ==
            'function' and type(LibraryView.instance.selected_item) == 'table') then
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
            chapter_listing:refreshItems(true)
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
                cacheExt = bookinfo.cacheExt,
                origin = bookinfo.origin,
                originName = bookinfo.originName,
                originOrder = bookinfo.originOrder
            }, function()
                self:onShowLegadoLibraryView()
            end, true)
        end
        return true
    end

    function legado_main:onDocSettingsLoad(doc_settings, document)
        if doc_settings and doc_settings.data and type(doc_settings.readSetting) == 'function' and document and
            type(document.file) == 'string' and document.file:find('/legado.cache/', 1, true) then
            local directory, file_name = util.splitFilePathName(document.file)
            local _, extension = util.splitFileNameSuffix(file_name or "")
            if not (type(directory) == "string" or type(file_name) == 'string' and directory ~= "" and file_name ~= "") then
                return
            end

            local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
            local document_is_new = doc_settings:readSetting("doc_props") == nil

            -- document.is_new = nil ?
            if util.fileExists(book_defaults_path) then
                local book_defaults = LuaSettings:open(book_defaults_path)
                if document_is_new == true and type(book_defaults.data) == 'table' then
                    local summary = doc_settings.data.summary -- keep status
                    local book_defaults_data = util.tableDeepCopy(book_defaults.data)
                    for k, v in pairs(book_defaults_data) do
                        doc_settings.data[k] = v
                    end
                    doc_settings.data.doc_path = document.file
                    doc_settings.data.summary = doc_settings.data.summary or summary
                end
            end

            if extension == 'txt' then
                doc_settings.data.txt_preformatted = 0
                doc_settings.data.style_tweaks = doc_settings.data.style_tweaks or {}
                doc_settings.data.style_tweaks.paragraph_whitespace_half = true
                doc_settings.data.style_tweaks.paragraphs_indent = true
                doc_settings.data.css = "./data/fb2.css"
            elseif extension == 'cbz' then
                doc_settings.data.flipping_zoom_mode = "page"
            end

            if LibraryView.instance and LibraryView.instance.chapter_listing and
                LibraryView.instance.chapter_listing.bookinfo then
                -- statistics.koplugin
                if document then
                    document.is_pic = true
                end
                -- 是否影响后续 ？
                --[=[
                    if document_is_new then  
                        local bookinfo = LibraryView.instance.chapter_listing.bookinfo
                        doc_settings.data.doc_props = doc_settings.data.doc_props or {}
                        doc_settings.data.doc_props.title = bookinfo.name or "N/A"
                        doc_settings.data.doc_props.authors = bookinfo.author or "N/A"
                    end
                ]=]

            end

        end
    end
    -- or UIManager:flushSettings() --onFlushSettings
    function legado_main:onSaveSettings()
        local is_valid_reader_ui = self.ui and self.ui.name == "ReaderUI" and type(self.ui.doc_settings) == "table" and
                                       type(self.ui.doc_settings.readSetting) == "function"

        local is_library_visible = LibraryView.instance and type(LibraryView.instance.selected_item) == "table" and
                                       type(BookReader.getIsShowing) == "function" and BookReader:getIsShowing()

        if not (is_valid_reader_ui and is_library_visible) then
            return
        end

        local filepath = self.ui.doc_settings:readSetting("doc_path") or ""
        local directory, file_name = util.splitFilePathName(filepath)
        if not (type(directory) == "string" and directory:find('/legado.cache/', 1, true)) then
            return
        end

        -- logger.dbg("Legado: Saving reader settings...")
        if self.ui.doc_settings and type(self.ui.doc_settings.data) == 'table' then
            local persisted_settings_keys = require("Legado/BookMetaData")
            local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
            local book_defaults = LuaSettings:open(book_defaults_path)
            local doc_settings_data = util.tableDeepCopy(self.ui.doc_settings.data)
            for k, v in pairs(doc_settings_data) do
                if persisted_settings_keys[k] then
                    book_defaults.data[k] = v
                end
            end
            book_defaults:flush()
        end
    end

    function legado_main:onReaderReady(doc_settings)
        -- logger.dbg("document.is_pic",self.ui.document.is_pic)
        -- logger.dbg(doc_settings.data.summary.status)
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

    function legado_main:onCloseDocument()
        if not (self.ui and self.ui.name == "ReaderUI" and self.ui.rolling and self.ui.rolling.c8eeb679f ~= true and
            self.ui.document and type(self.ui.document.file) == 'string' and
            self.ui.document.file:find('/legado.cache/', 1, true)) then
            return
        end
        require("readhistory"):removeItemByPath(self.document.file)
    end

    table.insert(legado_main.ui, 3, legado_main)

end

return LibraryView
