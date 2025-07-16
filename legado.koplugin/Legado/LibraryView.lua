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
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local LibraryView = {
    disk_available = nil,
    -- record the current reading items
    selected_item = nil,
    book_toc = nil,
    ui_refresh_time = os.time(),
    displayed_chapter = nil,
    readerui_is_showing = nil,
    chapter_call_event = nil,
    -- menu mode
    book_menu = nil,
    -- file browser mode
    book_browser = nil,
    book_browser_homedir = nil
}

function LibraryView:init()
    if LibraryView.instance then
        return
    end
    self.book_browser_homedir = self:getBrowserHomeDir(true)
    self:backupDbWithPreCheck()
    LibraryView.instance = self
end

function LibraryView:backupDbWithPreCheck()
    local temp_dir = H.getTempDirectory()
    local last_backup_db = H.joinPath(temp_dir, "bookinfo.db.bak")
    local bookinfo_db_path = H.joinPath(temp_dir, "bookinfo.db")

    -- 防御性编码,koreader又又崩了
    local status, err = pcall(function()
        Backend:getBookShelfCache()
    end)
    if status then
        local setting_data = Backend:getSettings()
        local last_backup_time = setting_data.last_backup_time
        if not last_backup_time or os.time() - last_backup_time > 86400 then
            if util.fileExists(last_backup_db) then
                util.removeFile(last_backup_db)
            end
            H.copyFileFromTo(bookinfo_db_path, last_backup_db)
            logger.info("legado plugin: backup successful")
            setting_data.last_backup_time = os.time()
            Backend:saveSettings(setting_data)
        end
    else
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
                    self:closeMenu()
                    MessageBox:info(string.format("缓存文件损坏已%s，请重试打开",
                        has_backup and "还原" or "清除"))
                else
                    UIManager:restartKOReader()
                end
            end, {
                ok_text = has_backup and "还原" or "清除",
                cancel_text = "取消"
            })
    end
end

function LibraryView:fetchAndShow()
    local library_view = LibraryView.instance or self:getInstance()
    local is_first = not LibraryView.instance
    local use_browser = not self:isDisableBrowserMode() and is_first and self:browserViewHasLnk()
    local widget = use_browser and self:getBrowserWidget() or self:getMenuWidget()
    if widget then
        widget:show_view()
        widget:refreshItems()
    end
    return self
end

function LibraryView:isDisableBrowserMode()
    local settings = Backend:getSettings()
    return settings and settings.disable_browser == true
end
function LibraryView:browserViewHasLnk()
    local browser_homedir = self:getBrowserHomeDir(true)
    return browser_homedir and util.directoryExists(browser_homedir) and not util.isEmptyDir(browser_homedir)
end

function LibraryView:addBkShortcut(bookinfo, always_add)
    if not always_add and self:isDisableBrowserMode() then
        return
    end
    local browser = self:getBrowserWidget()
    if browser then
        browser:addBookShortcut(bookinfo)
    end
end

function LibraryView:onRefreshLibrary()
    if self.book_menu then
        self.book_menu:onRefreshLibrary()
    end
end

function LibraryView:closeMenu()
    if self.book_menu then
        self.book_menu:onClose()
    end
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
        -- only display the last 3 lines
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
                if not self.book_menu then
                    return true
                end
                self.book_menu.item_table = self.book_menu:generateEmptyViewItemTable()
                self.book_menu.multilines_show_more_text = true
                self.book_menu.items_per_page = 1
                self.book_menu:updateItems()
                self.book_menu:onRefreshLibrary()
                return true
            end, function(err_msg)
                MessageBox:notice('设置失败：' .. tostring(err_msg))
                return false
            end)
        end
        MessageBox:notice('输入为空')
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

function LibraryView:openBrowserMenu(file)
    self:getInstance()
    self:getBrowserWidget()
    local dialog
    local buttons = {{{
        text = "清空书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("是否清除所有书籍快捷方式?", function(result)
                if result then
                    local browser_homedir = self:getBrowserHomeDir(true)
                    if self:deleteFile(browser_homedir) then
                        MessageBox:notice("已清除")
                    end
                end
            end, {
                ok_text = "清除",
                cancel_text = "取消"
            })
        end
    }}, {{
        text = "修复书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            self.book_browser:verifyBooksMetadata()
        end
    }}, {{
        text = "更换书籍封面",
        callback = function()
            local ui = FileManager.instance or ReaderUI.instance
            if file and ui and ui.bookinfo then
                UIManager:close(dialog)
                local custom_book_cover = DocSettings:findCustomCoverFile(file)
                if custom_book_cover and util.fileExists(custom_book_cover) then
                    util.removeFile(custom_book_cover)
                end

                local DocumentRegistry = require("document/documentregistry")
                local PathChooser = require("ui/widget/pathchooser")
                local path_chooser = PathChooser:new{
                    select_directory = false,
                    path = H.getHomeDir(),
                    file_filter = function(filename)
                        return DocumentRegistry:isImageFile(filename)
                    end,
                    onConfirm = function(image_file)
                        if DocSettings:flushCustomCover(file, image_file) then
                            self.book_browser:emitMetadataChanged(file)
                        end
                    end
                }
                UIManager:show(path_chooser)
            else
                MessageBox:notice("操作失败: 仅能在文件浏览器下操作")
            end
        end
    }}, {{
        text = "更多设置",
        callback = function()
            UIManager:close(dialog)
            self:openMenu()
        end
    }}}

    dialog = require("ui/widget/buttondialog"):new{
        title = "Legado 设置",
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons
    }

    UIManager:show(dialog)
end

function LibraryView:openMenu()
    local dialog
    self:getInstance()
    local settings = Backend:getSettings()
    local buttons = {{{
        text = Icons.FA_GLOBE .. " Legado WEB地址",
        callback = function()
            UIManager:close(dialog)
            self:openInstalledReadSource()
        end
    }}, {{
        text = string.format("%s 流式漫画模式 %s", Icons.FA_BOOK,
            (settings.stream_image_view and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "当前模式: %s \r\n \r\n缓存模式: 边看边下载。\n缺点：占空间。\n优点：预加载后相对流畅。\r\n \r\n流式：不下载到磁盘。\n缺点：对网络要求较高且画质缺少优化，需要下载任一章节后才能开启（建议服务端开启图片代理）。\n优点：不占空间。",
                (settings.stream_image_view and '[流式]' or '[缓存]')), function(result)
                if result then
                    settings.stream_image_view = not settings.stream_image_view or nil
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice("设置成功")
                        self:closeMenu()
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
        text = string.format("%s 自动生成快捷方式 %s", Icons.FA_FOLDER,
            (settings.disable_browser and Icons.UNICODE_STAR_OUTLINE or Icons.UNICODE_STAR)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "自动生成快捷方式：%s \r\n \r\n 打开书籍目录时自动在文件浏览器 Home 目录中生成对应书籍快捷方式，支持封面显示, 关闭后可在书架菜单手动生成",
                (settings.disable_browser and '[关闭]' or '[开启]')), function(result)
                if result then
                    local ok_msg = "设置已开启"
                    settings.disable_browser = not settings.disable_browser or nil
                    if settings.disable_browser then
                        ok_msg = "设置已关闭，请手动删除目录"
                    end
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice(ok_msg)
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
        text = string.format("%s Clear all caches", Icons.FA_TIMES),
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
                                    MessageBox:notice("已清除")
                                    self:closeMenu()
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
        text = Icons.FA_QUESTION_CIRCLE .. ' ' .. "关于/更新",
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
            local legado_update = require("Legado.Update")
            local curren_version = legado_update:getCurrentPluginVersion() or ""
            about_txt = T(about_txt, Icons.FA_DOWNLOAD, Icons.FA_CHECK_CIRCLE, Icons.FA_THUMB_TACK, curren_version)
            MessageBox:custom({
                text = about_txt,
                alignment = "left"
            })

            UIManager:nextTick(function()
                Backend:checkOta(true)
            end)
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

function LibraryView:openSearchBooksDialog(def_search_input)
    require("Legado/BookSourceResults"):searchAndShow(function()
        self:onRefreshLibrary()
    end, def_search_input)
end

-- exit readerUI,  closing the at readerUI、FileManager the same time app will exit
-- readerUI -> ReturnLegadoChapterListing event -> show ChapterListing -> close ->show LibraryView ->close -> ? 
function LibraryView:openLegadoFolder(path, focused_file, selected_files, done_callback)
    UIManager:nextTick(function()
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
            self.readerui_is_showing = false
        end
        if FileManager.instance then
            FileManager.instance:reinit(path, focused_file, selected_files)
        else
            FileManager:showFiles(path, focused_file, selected_files)
        end
        if FileManager.instance and path then
            FileManager.instance:updateTitleBarPath(path)
        end
        if H.is_func(done_callback) then
            done_callback()
        end
    end)
end

function LibraryView:loadAndRenderChapter(chapter)

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)

    if (H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath)) then
        self:showReaderUI(cache_chapter)
    else
        Backend:closeDbManager()
        return MessageBox:loading("正在下载正文", function()
            return Backend:downloadChapter(chapter)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    if not H.is_tbl(data) or not H.is_str(data.cacheFilePath) then
                        MessageBox:error('下载失败')
                        return
                    end
                    self:showReaderUI(data)
                end, function(err_msg)
                    Backend:show_notice("请检查并刷新书架")
                    MessageBox:error(err_msg or '错误')
                end)
            end

        end)
    end
end

function LibraryView:ReaderUIEventCallback(chapter_call_event)
    if not (H.is_str(chapter_call_event) and H.is_tbl(self.displayed_chapter)) then
        return
    end
    local chapter = self.displayed_chapter
    self.chapter_call_event = chapter_call_event
    chapter.call_event = chapter_call_event

    local nextChapter = Backend:findNextChapter({
        chapters_index = chapter.chapters_index,
        call_event = chapter.call_event,
        book_cache_id = chapter.book_cache_id,
        totalChapterNum = chapter.totalChapterNum
    })

    if H.is_tbl(nextChapter) then
        nextChapter.call_event = chapter.call_event
        self:loadAndRenderChapter(nextChapter)
    else
        self:openLegadoFolder(nil, nil, nil, function()
            if self.book_toc then
                UIManager:show(self.book_toc)
            end
        end)
    end
end

function LibraryView:showReaderUI(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then
        return
    end
    self.displayed_chapter = chapter
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    if self.book_toc then
        UIManager:close(self.book_toc)
    end
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(book_path, true)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(book_path, nil, true)
    end
    Backend:after_reader_chapter_show(chapter)
end

function LibraryView:initializeRegisterEvent(parent_ref)
    local DocSettings = require("docsettings")
    local FileManager = require("apps/filemanager/filemanager")
    local util = require("util")
    local logger = require("logger")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local ChapterListing = require("Legado/ChapterListing")
    local Backend = require("Legado/Backend")
    local H = require("Legado/Helper")

    local library_view_ref = self

    local is_legado_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find('/cache/legado.cache/', 1, true) or false
    end
    local is_legado_browser_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:find("/Legado\u{200B}书目/", 1, true) or false
    end
    local get_chapter_event = function()
        if library_view_ref.instance then
            return library_view_ref.instance.chapter_call_event
        end
    end

    function parent_ref:onShowLegadoLibraryView()
        -- FileManager menu only
        if not (self.ui and self.ui.document) then
            self:openLibraryView()
        end
        return true
    end

    function parent_ref:openLastReadChapter(book_cache_id)
        local last_read_chapter = Backend:getLastReadChapter(book_cache_id)
        library_view_ref:getInstance()
        if not library_view_ref.instance then
            logger.warn("openLastReadChapter LibraryView instance not loaded")
            return
        end
        if H.is_num(last_read_chapter) then
            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
                -- no sync
                self:onShowLegadoLibraryView()
                MessageBox:notice("书籍不存在于书架,请刷新同步")
                return
            end

            local chapters_index = last_read_chapter - 1
            if chapters_index < 0 then
                chapters_index = 0
            end
            local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
            if H.is_tbl(chapter) then
                if not library_view_ref.instance.book_toc then
                    library_view_ref.instance.book_toc = ChapterListing:fetchAndShow({
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
                    end, function(chapter)
                        library_view_ref.instance:loadAndRenderChapter(chapter)
                    end, true, true)
                end
                chapter.call_event = "next"
                library_view_ref.instance:loadAndRenderChapter(chapter)
                return true
            end
        end

        local dir = library_view_ref.instance:getBrowserHomeDir()
        self:onShowLegadoToc(book_cache_id, function()
            -- Sometimes LibraryView instance may not start
            library_view_ref:openLegadoFolder(dir)
        end)
    end

    function parent_ref:onShowLegadoToc(book_cache_id, onReturnCallBack)
        library_view_ref:getInstance()
        if not library_view_ref.instance then
            logger.warn("ShowLegadoToc LibraryView instance not loaded")
            return true
        end
        if not book_cache_id then
            if library_view_ref.instance.displayed_chapter then
                book_cache_id = library_view_ref.instance.displayed_chapter.book_cache_id
            elseif library_view_ref.instance.selected_item then
                book_cache_id = library_view_ref.instance.selected_item.cache_id
            end
        end
        if not book_cache_id then
            logger.warn("ShowLegadoToc book_cache_id not obtained")
            return true
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            MessageBox:error('书籍不存在于当前 Legado 书库或已被删除, 请检查并同步书库')
            return
        end

        if not H.is_func(onReturnCallBack) then
            onReturnCallBack = function()
                self:openLibraryView()
            end
        end

        local fetch_show_chapter = function()
            library_view_ref.instance.book_toc = ChapterListing:fetchAndShow({
                cache_id = bookinfo.cache_id,
                bookUrl = bookinfo.bookUrl,
                durChapterIndex = bookinfo.durChapterIndex,
                name = bookinfo.name,
                author = bookinfo.author,
                cacheExt = bookinfo.cacheExt,
                origin = bookinfo.origin,
                originName = bookinfo.originName,
                originOrder = bookinfo.originOrder
            }, onReturnCallBack, function(chapter)
                library_view_ref.instance:loadAndRenderChapter(chapter)
            end, true)
        end

        -- If under ReaderUI, exit it first.
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI and ReaderUI.instance then
            library_view_ref:openLegadoFolder(nil, nil, nil, fetch_show_chapter)
        else
            fetch_show_chapter()
        end
        return true
    end

    local calculate_goto_page = function(chapter_call_event, page_count)
        if chapter_call_event == "next" then
            return 1
        elseif page_count and chapter_call_event == "pre" then
            return page_count
        end
    end
    function parent_ref:onDocSettingsLoad(doc_settings, document)
        if not (doc_settings and doc_settings.data and document) then
            return
        end
        if is_legado_path(document.file) then

            local directory, file_name = util.splitFilePathName(document.file)
            local _, extension = util.splitFileNameSuffix(file_name or "")
            if not (directory and file_name and directory ~= "" and file_name ~= "") then
                return
            end

            local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
            -- document.is_new = nil ? at readerui
            local document_is_new = (document.is_new == true) or doc_settings:readSetting("doc_props") == nil
            if document_is_new then
                doc_settings:saveSetting("legado_doc_is_new", true)
            end

            if util.fileExists(book_defaults_path) then
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                if book_defaults and H.is_tbl(book_defaults.data) then
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
            end

            -- statistics.koplugin
            if document then
                document.is_pic = true
            end
            -- Does it affect the future ？
            --[=[
                    if document_is_new then  
                        local bookinfo = library_view_ref.instance.book_toc.bookinfo
                        doc_settings.data.doc_props = doc_settings.data.doc_props or {}
                        doc_settings.data.doc_props.title = bookinfo.name or "N/A"
                        doc_settings.data.doc_props.authors = bookinfo.author or "N/A"
                    end
                ]=]

            -- current_page == nil
            -- self.ui.document:getPageCount() unreliable, sometimes equal to 0
            local chapter_call_event = get_chapter_event()
            local page_count = doc_settings:readSetting("doc_pages") or 99999
            -- koreader some cases is goto last_page
            local page_number = calculate_goto_page(chapter_call_event, page_count)
            if H.is_num(page_number) then
                doc_settings.data.last_page = page_number
            end

        elseif is_legado_browser_path(document.file) and doc_settings.data then
            doc_settings.data.provider = "legado"
        end
    end
    -- or UIManager:flushSettings() --onFlushSettings
    function parent_ref:onSaveSettings()
        if not (self.ui and self.ui.doc_settings) then
            return
        end
        local filepath = self.ui.document and self.ui.document.file or self.ui.doc_settings:readSetting("doc_path")
        if is_legado_path(filepath) then

            local directory, file_name = util.splitFilePathName(filepath)
            if not is_legado_path(directory) then
                return
            end
            -- logger.dbg("Legado: Saving reader settings...")
            if self.ui.doc_settings and type(self.ui.doc_settings.data) == 'table' then
                local persisted_settings_keys = require("Legado/BookMetaData")
                local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                local doc_settings_data = util.tableDeepCopy(self.ui.doc_settings.data)
                local is_updated

                for k, v in pairs(doc_settings_data) do
                    if persisted_settings_keys[k] and not H.deep_equal(book_defaults.data[k], v) then
                        book_defaults.data[k] = v
                        is_updated = true
                        -- logger.info("onSaveSettings save k v", k, v)
                    end
                end
                if is_updated == true then
                    book_defaults:flush()
                end
            end
        elseif is_legado_browser_path(nil, self.ui) and self.ui.doc_settings then
            self.ui.doc_settings.data.provider = "legado"
        end
    end

    -- .cbz call twice ?
    function parent_ref:onReaderReady(doc_settings)
        -- logger.dbg("document.is_pic",self.ui.document.is_pic)
        -- logger.dbg(doc_settings.data.summary.status)
        if not (doc_settings and doc_settings.data and self.ui) then
            return
        end

        if not is_legado_path(nil, self.ui) then
            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = false
            end
            return
        elseif self.ui.link and self.ui.document then

            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = true
            end

            local chapter_call_event = get_chapter_event()
            if not chapter_call_event then
                return
            end

            local document_is_new =
                (self.ui.document.is_new == true) or doc_settings:readSetting("legado_doc_is_new") == true
            doc_settings:delSetting("legado_doc_is_new")
            if document_is_new and chapter_call_event == "next" then
                return
            end

            local function make_pages_continuous(chapter_event)
                local current_page = self.ui:getCurrentPage()
                if not current_page or current_page == 0 then
                    -- fallback to another method if current_page is unavailable
                    -- self.ui.document.info.has_pages == self.ui.paging
                    if self.ui.paging or (self.ui.document.info and self.ui.document.info.has_pages) then
                        current_page = self.view.state.page
                    else
                        current_page = self.ui.document:getXPointer()
                        current_page = self.ui.document:getPageFromXPointer(current_page)
                    end
                end

                local page_count = self.ui.document:getPageCount()
                if not (H.is_num(page_count) and page_count > 0) then
                    page_count = doc_settings:readSetting("doc_pages")
                end

                local page_number = calculate_goto_page(chapter_event, page_count)

                if H.is_num(page_number) and current_page ~= page_number then
                    self.ui.link:addCurrentLocationToStack()
                    self.ui:handleEvent(Event:new("GotoPage", page_number))
                end
            end
            make_pages_continuous(chapter_call_event)
        end
    end

    function parent_ref:onCloseDocument()
        if is_legado_path(nil, self.ui) then
            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = false
            end
            if not self.patches_ok then
                require("readhistory"):removeItemByPath(self.document.file)
            end
        end
    end

    function parent_ref:onShowLegadoSearch()
        local def_search_input
        if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
            local doc_props = self.ui.doc_settings.data.doc_props
            def_search_input = doc_props.authors or doc_props.title
        end

        require("Legado/BookSourceResults"):searchAndShow(function()
            self:openLibraryView()
        end, def_search_input)

        return true
    end

    function parent_ref:onEndOfBook()
        if is_legado_path(nil, self.ui) then
            library_view_ref:getInstance()
            if library_view_ref.instance then
                local chapter_call_event = "next"
                library_view_ref.instance:ReaderUIEventCallback(chapter_call_event)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onStartOfBook()
        if is_legado_path(nil, self.ui) then
            library_view_ref:getInstance()
            if library_view_ref.instance then
                local chapter_call_event = "pre"
                library_view_ref.instance:ReaderUIEventCallback(chapter_call_event)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onShowLegadoBrowserOption(file)
        -- logger.info("Received ShowLegadoBrowserOption event", file)
        library_view_ref:getInstance()
        if FileManager.instance and library_view_ref.instance then
            library_view_ref.instance:openBrowserMenu(file)
        end
    end

    function parent_ref:onSuspend()
        Backend:closeDbManager()
    end

    table.insert(parent_ref.ui, 3, parent_ref)

    function parent_ref:openFile(file)
        if not H.is_str(file) then
            return
        end
        local function open_regular_file(file)
            local ReaderUI = require("apps/reader/readerui")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(file, nil, true)
        end
        if not (is_legado_browser_path(file) and file:find("\u{200B}.html", 1, true)) then
            open_regular_file(file)
            return
        end
        -- prioritize using custom matedata book_cache_id
        local doc_settings = DocSettings:open(file)
        local book_cache_id = doc_settings:readSetting("book_cache_id")

        if not book_cache_id then
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_config then
                book_cache_id = lnk_config:readSetting("book_cache_id")
            end
        end
        if book_cache_id then
            local ok, err = pcall(function()
                return self:openLastReadChapter(book_cache_id)
            end)
            if not ok then
                logger.err("fail to open file:", err)
            end
            return true
        else
            open_regular_file(file)
        end
    end
end

local function init_book_browser(parent)
    if parent.book_browser then
        return parent.book_browser
    end

    local book_browser = {
        parent = parent
    }

    function book_browser:show_view(focused_file, selected_files)
        local homedir = self.parent:getBrowserHomeDir()
        if not homedir then
            return
        end
        local current_dir = self.parent:getBrowserCurrentDir()
        if current_dir and current_dir == homedir then
            if not self.parent.book_menu then
                self.parent.book_menu = self.parent:getMenuWidget()
            end
            self.parent.book_menu:show_view()
            self.parent.book_menu:refreshItems(true)
            return
        end
        self.parent:openLegadoFolder(homedir, focused_file, selected_files)
    end

    function book_browser:goHome()
        if FileManager.instance then
            FileManager.instance:goHome()
        end
    end

    function book_browser:refreshItems()
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end

    function book_browser:deleteFile(file, is_file)
        self.parent:deleteFile(file, is_file)
    end
    function book_browser:verifyBooksMetadata()
        -- possible cover name change
        local browser_homedir = self.parent:getBrowserHomeDir()
        if not util.directoryExists(browser_homedir) then
            return
        end

        local function is_valid_book_file(fullpath, name)
            return util.fileExists(fullpath) and H.is_str(name) and name:find("\u{200B}.html", 1, true)
        end

        local function get_book_id(fullpath)
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, fullpath)
            if ok and H.is_tbl(lnk_config) and lnk_config.readSetting then
                return lnk_config:readSetting("book_cache_id")
            end
            local doc_settings = DocSettings:open(fullpath)
            return doc_settings:readSetting("book_cache_id")
        end

        util.findFiles(browser_homedir, function(fullpath, name)
            if not is_valid_book_file(fullpath, name) then
                goto continue
            end

            local book_cache_id = get_book_id(fullpath)
            if not book_cache_id then
                self:deleteFile(fullpath, true)
                goto continue
            end

            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                goto continue
            end

            self:refreshBookMetadata(nil, fullpath, bookinfo)
            ::continue::
        end, true)
    end

    function book_browser:wirteLnk(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("book_browser.wirteLnk: parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local book_name = bookinfo.name
        local book_author = bookinfo.author or "未知作者"

        local book_lnk_name = string.format("%s-%s\u{200B}.html", book_name, book_author)
        book_lnk_name = util.getSafeFilename(book_lnk_name)
        if not book_lnk_name then
            logger.err("book_browser.wirteLnk: getSafeFilename error")
            return
        end
        local book_lnk_path = H.joinPath(home_dir, book_lnk_name)
        if book_lnk_path and util.fileExists(book_lnk_path) then
            return book_lnk_path, book_lnk_name
        end

        local book_lnk_config = Backend:getLuaConfig(book_lnk_path)
        book_lnk_config:saveSetting("book_cache_id", book_cache_id):flush()

        return book_lnk_path, book_lnk_name
    end

    function book_browser:getCustomMateData(filepath)
        local custom_metadata_file = DocSettings:findCustomMetadataFile(filepath)
        return custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
    end

    function book_browser:addBookShortcut(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id and bookinfo.coverUrl) then
            logger.err("addBookShortcut: parameter error")
            return
        end

        local book_lnk_path, book_lnk_name = self:wirteLnk(bookinfo)
        if not (book_lnk_path and util.fileExists(book_lnk_path)) then
            logger.err("addBookShortcut: failed to create lnk")
            return
        end

        if not self:getCustomMateData(book_lnk_path) then
            self:refreshBookMetadata(book_lnk_name, book_lnk_path, bookinfo)
        else
            self:bind_provider(book_lnk_path)
        end

        if DocSettings:findCustomCoverFile(book_lnk_path) then
            return
        end

        if not NetworkMgr:isConnected() then
            return
        end
        local book_cache_id = bookinfo.cache_id
        local cover_url = bookinfo.coverUrl
        if cover_url then
            Backend:runTaskWithRetry(function()
                if DocSettings:findCustomCoverFile(book_lnk_path) then
                    self:emitMetadataChanged(book_lnk_path)
                    return true
                end
            end, 12000, 2000)
            Backend:launchProcess(function()
                local cover_path, cover_name = Backend:download_cover_img(book_cache_id, cover_url)
                if cover_path and util.fileExists(cover_path) then
                    DocSettings:flushCustomCover(book_lnk_path, cover_path)
                end
            end)
        end
    end

    function book_browser:emitMetadataChanged(path)
        --[[
        local prop_updated = {
            filepath = file,
            doc_props = book_props,
            metadata_key_updated = prop_updated,
            metadata_value_old = prop_value_old,
        }
        ]]
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end

    function book_browser:bind_provider(file)
        local doc_settings = DocSettings:open(file)
        local provider = doc_settings:readSetting("provider")
        if provider ~= "legado" then
            doc_settings:saveSetting("provider", "legado"):flush()
        end
        return doc_settings
    end

    function book_browser:refreshBookMetadata(lnk_name, lnk_path, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_tbl(bookinfo) and bookinfo.cache_id and
            bookinfo.name) then
            logger.err("browser.refreshBookMetadata parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            doc_settings:saveSetting("custom_props", {
                authors = bookinfo.author,
                title = bookinfo.name,
                description = bookinfo.intro
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("doc_props", {
                pages = 1
            }):flushCustomMetadata(lnk_path)
        end

        self:emitMetadataChanged(lnk_path)
    end

    parent.book_browser = book_browser
    return book_browser
end

local function init_book_menu(parent)
    if parent.book_menu then
        return parent.book_menu
    end
    local book_menu = Menu:new{
        name = "library_view",
        is_enable_shortcut = false,
        is_popout = false,
        title = "书架",
        with_context_menu = true,
        align_baselines = true,
        covers_fullscreen = true,
        title_bar_left_icon = "appbar.menu",
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        onLeftButtonTap = function()
            parent:openMenu()
        end,
        close_callback = function()
            Backend:closeDbManager()
        end,
        show_search_item = nil,
        parent_ref = parent
    }

    if Device:hasKeys({"Home"}) or Device:hasDPad() then
        book_menu.key_events.Close = {{Device.input.group.Back}}
        book_menu.key_events.RefreshLibrary = {{"Home"}}
        book_menu.key_events.FocusRight = {{"Right"}}
    end

    function book_menu:onFocusRight()
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
    function book_menu:onSwipe(arg, ges_ev)
        local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
        if direction == "south" then
            self:onRefreshLibrary()
            return
        end
        Menu.onSwipe(self, arg, ges_ev)
    end

    function book_menu:refreshItems(no_recalculate_dimen)
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
        self:updateItems(nil, no_recalculate_dimen)
    end

    function book_menu:onPrimaryMenuChoice(item)
        if not item.cache_id then
            self.parent_ref:openSearchBooksDialog()
            return
        end
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        self.parent_ref.selected_item = item
        self.parent_ref.onReturnCallback = function()
            self:show_view()
            self:refreshItems(true)
        end
        self.parent_ref.book_toc = ChapterListing:fetchAndShow({
            cache_id = bookinfo.cache_id,
            bookUrl = bookinfo.bookUrl,
            durChapterIndex = bookinfo.durChapterIndex,
            name = bookinfo.name,
            author = bookinfo.author,
            cacheExt = bookinfo.cacheExt,
            origin = bookinfo.origin,
            originName = bookinfo.originName,
            originOrder = bookinfo.originOrder
        }, self.parent_ref.onReturnCallback, function(chapter)
            self.parent_ref.instance:loadAndRenderChapter(chapter)
        end, true)
        UIManager:nextTick(function()
            self.parent_ref:addBkShortcut(bookinfo)
        end)
        self:onClose()
    end

    function book_menu:onRefreshLibrary()
        NetworkMgr:runWhenOnline(function()
            Backend:closeDbManager()
            MessageBox:loading("Refreshing Library", function()
                return Backend:refreshLibraryCache(parent.ui_refresh_time)
            end, function(state, response)
                if state == true then
                    Backend:HandleResponse(response, function(data)
                        MessageBox:notice('同步成功')
                        self.show_search_item = true
                        self:refreshItems()
                        self.parent_ref.ui_refresh_time = os.time()
                    end, function(err_msg)
                        MessageBox:notice(response.message or '同步失败')
                    end)
                end
            end)

        end)

    end

    function book_menu:onMenuHold(item)
        if not item.cache_id then
            self.parent_ref:openSearchBooksDialog()
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
                text = (bookinfo.sortOrder > 0) and '置顶书籍' or '取消置顶',
                callback = function()
                    Backend:setBooksTopUp(item.cache_id, bookinfo.sortOrder)
                    self:refreshItems(true)
                end
            }}, {{
                text = "快捷方式",
                callback = function()
                    UIManager:nextTick(function()
                        self.parent_ref:addBkShortcut(bookinfo, true)
                    end)
                    MessageBox:notice("已调用生成，请到 Home 目录查看")
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
                        "是否删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复",
                        bookinfo.name), function(result)
                        if result then
                            Backend:closeDbManager()
                            MessageBox:loading("删除中...", function()
                                Backend:deleteBook(bookinfo)
                                return Backend:refreshLibraryCache()
                            end, function(state, response)
                                if state == true then
                                    Backend:HandleResponse(response, function(data)
                                        MessageBox:notice("删除成功")
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

    function book_menu:onMenuSelect(entry, pos)
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

    function book_menu:generateEmptyViewItemTable()
        return {{
            text = string.format("No books found in library. Try%s swiping down to refresh.",
                (Device:hasKeys({"Home"}) and ' Press the home button or ' or '')),
            dim = true,
            select_enabled = false
        }}
    end

    function book_menu:generateItemTableFromMangas(books)
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

    function book_menu:show_view()
        UIManager:show(self)
    end

    parent.book_menu = book_menu
    return book_menu
end

function LibraryView:getBrowserHomeDir(skip_check)
    if not self.book_browser_homedir then
        local home_dir = H.getHomeDir()
        self.book_browser_homedir = H.joinPath(home_dir, "Legado\u{200B}书目")
    end
    if not skip_check then
        local success, err = pcall(H.checkAndCreateFolder, self.book_browser_homedir)
        if not (success and util.directoryExists(self.book_browser_homedir)) then
            logger.err("LibraryView.getBrowserHomeDir: failed to create directory - " ..
                           tostring(err or "unknown error"))
            return nil
        end
    end
    return self.book_browser_homedir
end

function LibraryView:deleteFile(file, is_file)
    local exists = is_file and util.fileExists(file) or util.directoryExists(file)
    if not exists then
        return false
    end

    if FileManager.instance then
        FileManager.instance:goHome()
        FileManager.instance:deleteFile(file, is_file)
        FileManager.instance:onRefresh()
        return true
    end
    if is_file then
        return util.removeFile(file)
    else
        return pcall(ffiUtil.purgeDir, file)
    end
end

function LibraryView:getBrowserCurrentDir()
    local file_manager = FileManager.instance
    if file_manager and file_manager.file_chooser then
        return file_manager.file_chooser.path
    end
    local readerui = ReaderUI.instance
    if readerui then
        return readerui:getLastDirFile()
    end
end

function LibraryView:getInstance()
    if not LibraryView.instance then
        self:init()
    end
    return self
end

function LibraryView:getBrowserWidget()
    return init_book_browser(self)
end

function LibraryView:getMenuWidget()
    return init_book_menu(self)
end

return LibraryView
