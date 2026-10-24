local logger = require("logger")
local util = require("util")
local time = require("ui/time")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local DocSettings = require("docsettings")
local MessageBox = require("Legado/MessageBox")
local Backend = require("Legado/Backend")
local Refresh = require("Legado.Skeleton.Refresh")
local SkeletonBook = require("Legado.Skeleton.Book")
local H = require("Legado/Helper")
local Patcher = require("Legado.patches")
local PlgState = require("Legado/PlgState")
local Env = require("Legado.Helper.Env")

local Handlers = {}

local function return_to_filemanager(ui)
    local file = ui.document.file
    if Env.is_legado_chapter_cache(nil, ui) then
        ui:setLastDirForFileBrowser(Env.getHomeDir())
        file = nil
    end
    ui:onClose()
    ui:showFileManager(file)
end

function Handlers:readerEventRules(parent_ref)
    if not parent_ref.ui or parent_ref.ui.name ~= "ReaderUI" then return end
    local LibraryView = require("Legado/LibraryView")
    local reader_document = parent_ref.ui.document
    local function matches(ui)
        return Env.is_legado_chapter_cache(nil, ui)
    end
    local function legadoReader(ui)
        return Env.is_legado_chapter_cache(nil, ui)
            or Env.is_legado_skeleton_book(nil, ui)
    end
    local function boundary(ui, direction)
        local library_obj = LibraryView:getInstance()
        if library_obj then
            if Backend:enforceRateLimit(PlgState.last_page_turn_time, 80) then return end
            PlgState.last_page_turn_time = time.now()
            local document = ui.document
            UIManager:nextTick(function()
                if ui.document ~= document then return end
                library_obj:ReaderUIEventCallback(direction, ui)
            end)
        elseif direction == "prev" then
            parent_ref:openLibraryView()
        else
            UIManager:nextTick(function() parent_ref:openLibraryView() end)
        end
    end
    return {
        onHome = {
            mode = "exclusive",
            matches = matches,
            run = return_to_filemanager,
        },
        onStartOfBook = {
            mode = "exclusive",
            matches = matches,
            run = function(ui) boundary(ui, "prev") end,
        },
        onEndOfBook = {
            mode = "exclusive",
            matches = matches,
            run = function(ui) boundary(ui, "next") end,
        },
        onShowToc = {
            mode = "exclusive",
            matches = legadoReader,
            run = function() parent_ref:onShowLegadoToc() end,
        },
        onLegadoReview = {
            mode = "exclusive",
            matches = legadoReader,
            run = function(_, event)
                require("Legado.spore.local.review_viewer").show(event.args[1])
            end,
        },
        onPageUpdate = {
            mode = "after",
            matches = function(ui) return Env.is_legado_skeleton_book(nil, ui) end,
            run = function(ui, event)
                ui._legado_last_virtual_toc_idx = SkeletonBook:onPageUpdate(
                    ui, event.args[1], ui._legado_last_virtual_toc_idx)
            end,
        },
        onReaderReady = {
            mode = "after",
            matches = function() return true end,
            run = function(_, event)
                parent_ref:applyReaderReady(event.args[1])
            end,
        },
        onCloseDocument = {
            mode = "before",
            matches = legadoReader,
            run = function(ui)
                Refresh:cancelForDocument(reader_document)
                ui._legado_last_virtual_toc_idx = nil
                PlgState:entrySource(nil)
                PlgState:readerUiVisible(false)
                if not ui._ref_legado_wrapped and reader_document then
                    require("readhistory"):removeItemByPath(reader_document.file)
                end
            end,
        },
        onDocSettingsLoad = {
            mode = "after",
            matches = function(_, event)
                local document = event.args[2]
                return document and (Env.is_legado_chapter_cache(document.file)
                    or parent_ref:isSkeletonEpub(document.file))
            end,
            run = function(_, event)
                parent_ref:applyReaderDocSettings(event.args[1], event.args[2])
            end,
        },
    }
end

function Handlers:register(parent_ref)
    local LibraryView = require("Legado/LibraryView")

    function parent_ref:onShowLegadoLibraryView()
        local library_obj = LibraryView:getInstance()
        if not library_obj then return true end

        if self.ui and self.ui.document then
            library_obj:afterCloseReaderUi(function()
                library_obj:fetchAndShow()
            end)
        else
            library_obj:fetchAndShow()
        end
        return true
    end

    function parent_ref:_loadBookFromManager(file, undoFileOpen)
        local loading_msg = MessageBox:info("前往最近阅读章节...", 3)

        local doc_settings = DocSettings:open(file)
        local book_cache_id = doc_settings:readSetting("book_cache_id")

        if not book_cache_id then
            local ok, lnk_conf = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_conf then
                book_cache_id = lnk_conf:readSetting("book_cache_id")
            end
        end

        if not H.is_str(book_cache_id) then
            UIManager:close(loading_msg)
            return undoFileOpen and undoFileOpen(file)
        end

        local library_obj = LibraryView:getInstance()
        if not library_obj then
            logger.warn("loadLastReadChapter LibraryView instance not loaded")
            UIManager:close(loading_msg)
            MessageBox:error("加载书架失败")
            return
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            UIManager:close(loading_msg)
            self:onShowLegadoLibraryView()
            MessageBox:notice("书籍不存在于当前激活书架或已被删除")
            return
        end

        local onReturnCallBack = function()
        end

        PlgState:chapterDirection("nil")
        library_obj:refreshBookTocWidget(bookinfo, onReturnCallBack)
        PlgState:currentSelectedBook({cache_id = book_cache_id})

        library_obj:openLastReadChapter(bookinfo)
        UIManager:close(loading_msg)
        return true
    end

    function parent_ref:onShowLegadoToc(book_cache_id)
        local library_obj = LibraryView:getInstance()
        if not library_obj then
            logger.warn("ShowLegadoToc LibraryView instance not loaded")
            return true
        end

        if not book_cache_id then
            book_cache_id = library_obj:getReadingBookId()
        end
        if not book_cache_id then
            logger.warn("ShowLegadoToc book_cache_id not obtained")
            return true
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            MessageBox:error('书籍不存在于当前激活书架或已被删除')
            return
        end

        library_obj:showBookTocDialog(bookinfo)
        return true
    end

    function parent_ref:onShowLegadoSearch()
        local def_search_input
        if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
            local doc_props = self.ui.doc_settings.data.doc_props
            def_search_input = doc_props.authors or doc_props.title
        end

        require("Legado/BookSourceResults"):searchBookDialog(function()
            if self.library_view then self.library_view:fetchAndShow() end
        end, def_search_input)

        return true
    end

    function parent_ref:onSuspend()
        Backend:closeDbManager()
    end

    function parent_ref:onScreenResize(_)
        local library_obj = LibraryView.instance
        if library_obj then
            if library_obj.book_menu then
                LibraryView.instance.book_menu = nil
            end
            if library_obj.book_toc then
                LibraryView.instance.book_toc = nil
            end
        end
    end

    function parent_ref:openFile(file)
        if not H.is_str(file) then return end
        local function open_regular_file(file_path)
            local ReaderUI = require("apps/reader/readerui")
            local show_reader = ReaderUI._legado_wrapped or ReaderUI.showReader
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            show_reader(ReaderUI, file_path, nil, true)
        end
        if not parent_ref:isSkeletonEpub(file) then
            open_regular_file(file)
            return
        end
        local doc_settings = DocSettings:open(file)
        if not (doc_settings and doc_settings:readSetting("book_cache_id")) then
            pcall(function()
                local SkeletonEpub = require("Legado.Skeleton.Epub")
                SkeletonEpub.restoreDocSettings(file)
            end)
        end
        PlgState:entrySource("filemanager")
        local ok, err = pcall(function()
            self:_loadBookFromManager(file, open_regular_file)
        end)
        if not ok then
            logger.err("fail to open file:", err)
        end
        return true
    end

    function parent_ref:onOpenLegacyLnk(file)
        if not H.is_str(file) then return end
        local book_cache_id
        local ok, lnk_conf = pcall(Backend.getLuaConfig, Backend, file)
        if ok and H.is_tbl(lnk_conf) and lnk_conf.readSetting then
            book_cache_id = lnk_conf:readSetting("book_cache_id")
        end
        if not book_cache_id then
            local doc_settings = DocSettings:open(file)
            book_cache_id = doc_settings and doc_settings:readSetting("book_cache_id")
        end
        if not book_cache_id then
            return MessageBox:error("无法识别的链接文件")
        end
        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and bookinfo.name) then
            return MessageBox:error("旧版链接对应的书籍信息不存在")
        end
        MessageBox:notice("检测到链接文件，正在重新生成快捷 EPUB…")
        local library_obj = LibraryView:getInstance()
        local book_links = library_obj and library_obj.book_links
        SkeletonBook:ensureEpubAsync(bookinfo, nil, nil, function(epub_path)
            if book_links and book_links.refreshBookMetadata then
                book_links:refreshBookMetadata(epub_path, bookinfo)
            end
            util.removeFile(file)
            self:openFile(epub_path)
        end, function(err)
            MessageBox:error("快捷 EPUB 生成失败：" .. tostring(err))
        end)
    end

    function parent_ref:genMainMenuItems(_)
        return {
            text = "Legado",
            sorting_hint = "search",
            help_text = "连接 Legado 书库",
            sub_item_table = {
                {
                    text = "书架",
                    callback = function()
                        self:openLibraryView()
                    end,
                }, {
                    text = "设置",
                    sub_item_table_func = function()
                        return require("Legado/SettingsMenu").getItems()
                    end,
                }, {
                    text = "缓存管理",
                    sub_item_table_func = function()
                        local items = {
                            {
                                text = "书籍缓存",
                                callback = function()
                                    require("Legado/BookCacheMgr"):open()
                                end,
                            },
                            {
                                text = "清空缓存与记录",
                                keep_menu_open = true,
                                callback = function()
                                    require("Legado/BookCacheMgr"):confirmClearAll()
                                end,
                            },
                        }
                        return items
                    end,
                }, {
                    text = "检查更新",
                    keep_menu_open = true,
                    callback = function()
                        UIManager:nextTick(function()
                            Backend:checkOta(true)
                        end)
                    end
                }, {
                    text = "关于",
                    keep_menu_open = true,
                    callback = function()
                        local legado_update = require("Legado/Update")
                        local curren_version = legado_update:getCurrentVersion() or ""
                        local Icons = require("Legado.res.icons")
                        local ffiUtil = require("ffi/util")
                        local about_txt = [[
-- 清风不识字，何故乱翻书 --

简介：
一个在 KOReader 中阅读 Legado 书库的插件，适配阅读 3.0，支持手机 APP、reader3、轻阅读后端。初衷是 Kindle 的浏览器体验不佳，目的是部分替代受限设备的浏览器，实现流畅的网文阅读，提升老设备体验。

操作：
列表支持下拉或 Home 键刷新，右键列表菜单 / Menu 键左上角菜单，阅读界面下拉菜单有返回选项，书架和目录可绑定手势使用。

章节页面图标说明:
%1 可下载  %2 已阅读  %3 书签

帮助改进：
请到 Github：pengcw/legado.koplugin 反馈 issues

版本: ver_%4]]
                        about_txt = ffiUtil.template(about_txt, Icons.FA_DOWNLOAD, Icons.FA_CHECK_CIRCLE, Icons.FA_THUMB_TACK, curren_version)
                        MessageBox:custom({ text = about_txt, alignment = "left" })
                    end,
                },
            },
        }
    end

    if parent_ref.ui and parent_ref.ui.name == "ReaderUI" then

        function parent_ref:initializeFromReaderUI(document, menu_items)
            if not (document and menu_items and parent_ref:isCachePath(document.file)) then
                return
            end
            menu_items.book_status = nil
            menu_items.book_info = nil
            if menu_items.filemanager then
                menu_items.filemanager.callback = function()
                    if not (self.ui and self.ui.menu and self.ui.document) then return end
                    self.ui.menu:onTapCloseMenu()
                    return_to_filemanager(self.ui)
                end
            end
            if menu_items.table_of_contents then
                menu_items.table_of_contents.callback = function()
                    if not (self.ui and self.ui.handleEvent) then return end
                    self.ui:handleEvent(Event:new("ShowLegadoToc"))
                end
            end

            local settings = Backend:getSettings()
            local library_obj = LibraryView:getInstance()
            local book_cache_id = library_obj:getReadingBookId()
            local is_comic = book_cache_id and Backend:isBookTypeComic(book_cache_id)

            local sub_items = {}

            if is_comic then
                table.insert(sub_items, {
                    text = "漫画免缓存",
                    keep_menu_open = true,
                    checked_func = function()
                        local b_id = library_obj:getReadingBookId() or book_cache_id
                        if b_id then
                            local extras_settings = Backend:getBookExtras(b_id)
                            return H.is_tbl(extras_settings.data) and extras_settings.data.stream_image_view ~= false
                        end
                        return false
                    end,
                    callback = function()
                        MessageBox:info("不缓存在线获取内容\n <长按切换选项>")
                    end,
                    hold_callback = function(menu_def)
                        local b_id = library_obj:getReadingBookId() or book_cache_id
                        if not b_id then return end
                        local extras_settings = Backend:getBookExtras(b_id)
                        local ChapterListing = require("Legado/ChapterListing")
                        ChapterListing.switchStreamMode(extras_settings, function()
                            if menu_def and menu_def.updateItems then menu_def:updateItems() end
                            local reading_chapter = PlgState:readingChapter()
                            if reading_chapter then
                                library_obj:loadAndRenderChapter(reading_chapter)
                            end
                        end, b_id)
                    end,
                })
            end

            table.insert(sub_items, {
                text = "重新下载本章",
                separator = is_comic,
                callback = function()
                    self:onRefreshLegadoChapter()
                end,
            })

            if Backend:supportsProviderMethod("saveBookProgress") then
                table.insert(sub_items, {
                    text = "自动上传进度",
                    keep_menu_open = true,
                    help_text = "阅读时，自动上传阅读进度",
                    checked_func = function() return settings.sync_reading == true end,
                    hold_callback = function(menu_def)
                        require("Legado/SettingsMenu").toggleSyncReading(settings)
                        if menu_def and menu_def.updateItems then menu_def:updateItems() end
                    end,
                    callback = function()
                        MessageBox:info("阅读时，自动上传阅读进度\n <长按切换选项>")
                    end,
                })

                table.insert(sub_items, {
                    text = "立即上传进度",
                    callback = function()
                        local reading_chapter = PlgState:readingChapter()
                        if reading_chapter then
                            local toc_obj = library_obj:getBookTocWidget()
                            if toc_obj then
                                toc_obj:syncProgressShow(reading_chapter)
                            end
                        else
                            MessageBox:error("上传进度失败: 没有获取到当前章节")
                        end
                    end,
                })
            end

            table.insert(sub_items, {
                text = "返回书架",
                separator = true,
                callback = function()
                    local library = LibraryView:getInstance()
                    if library then library:fetchAndShow() end
                end,
            })

            menu_items.Legado_reader_ui_menu = {
                text = "Legado 选项",
                sorting_hint = "search",
                sub_item_table = sub_items,
            }
        end

        function parent_ref:onRefreshLegadoChapter()
            if PlgState:readerUiVisible() ~= true then
                MessageBox:error("操作失败: 仅支持 Legado 章节")
                return true
            end
            local ReadingFlow = require("Legado.ReadingFlow")
            return ReadingFlow:refreshCurrentChapter({
                on_success = function()
                    MessageBox:notice("本章刷新成功")
                end,
                on_error = function(err_msg)
                    MessageBox:error("刷新失败: " .. tostring(err_msg))
                end
            })
        end

        function parent_ref:applyReaderDocSettings(doc_settings, document)
            if not (doc_settings and doc_settings.data and document) then
                return
            end
            if Env.is_legado_chapter_cache(document.file) then

                local directory, file_name = util.splitFilePathName(document.file)
                local _, extension = util.splitFileNameSuffix(file_name or "")
                if not (directory and file_name and directory ~= "" and file_name ~= "") then
                    return
                end
                Patcher.readui_starting(self.ui)
                local document_is_new = (document.is_new == true) or doc_settings:readSetting("doc_props") == nil
                if document_is_new then
                    doc_settings:saveSetting("legado_doc_is_new", true)
                end

                local library_obj = LibraryView:getInstance()
                local shared_meta_data = library_obj:getSharedMetaData(directory)

                if H.is_tbl(shared_meta_data) and H.is_tbl(shared_meta_data.data) then
                    local summary = doc_settings.data.summary
                    local persisted_settings_keys = require("Legado.res.metadata")
                    local book_defaults_data = shared_meta_data.data
                    if util.fileExists(shared_meta_data.file) then
                        for k in pairs(persisted_settings_keys) do
                            doc_settings.data[k] = util.tableDeepCopy(book_defaults_data[k])
                        end
                    else
                        for k, v in pairs(book_defaults_data) do
                            if persisted_settings_keys[k] then
                                doc_settings.data[k] = util.tableDeepCopy(v)
                            end
                        end
                    end
                    doc_settings.data.doc_path = document.file
                    doc_settings.data.summary = doc_settings.data.summary or summary
                end

                if extension == 'txt' then
                    doc_settings.data.txt_preformatted = 0
                    doc_settings.data.style_tweaks = doc_settings.data.style_tweaks or {}
                    doc_settings.data.style_tweaks.paragraph_whitespace_half = true
                    doc_settings.data.style_tweaks.paragraphs_indent = true
                    doc_settings.data.css = "./data/fb2.css"
                end

                if document then
                    document.is_pic = true
                end
            elseif parent_ref:isSkeletonEpub(document.file) and doc_settings.data then
                Patcher.readui_starting(self.ui)
                local had_alternative_toc = doc_settings.data.alternative_toc == true
                doc_settings.data.provider = "legado"
                doc_settings.data.alternative_toc = false
                if had_alternative_toc and document.invalidateCacheFile then
                    document:invalidateCacheFile()
                end
            end
        end

        function parent_ref:onSaveSettings()
            if not (self.ui and self.ui.doc_settings) then return end
            local filepath = self.ui.document and self.ui.document.file or self.ui.doc_settings:readSetting("doc_path")

            if Env.is_legado_chapter_cache(filepath) then
                local directory = util.splitFilePathName(filepath)
                if not parent_ref:isCachePath(directory) then return end

                if self.ui.doc_settings and type(self.ui.doc_settings.data) == 'table' then
                    local persisted_settings_keys = require("Legado.res.metadata")
                    local library_obj = LibraryView:getInstance()
                    local shared_meta_data = library_obj:getSharedMetaData(directory)

                    if H.is_tbl(shared_meta_data) and H.is_tbl(shared_meta_data.data) then
                        local is_updated
                        local doc_settings_data = self.ui.doc_settings.data
                        for k in pairs(persisted_settings_keys) do
                            local v = doc_settings_data[k]
                            if not H.deep_equal(shared_meta_data.data[k], v) then
                                shared_meta_data.data[k] = util.tableDeepCopy(v)
                                is_updated = true
                            end
                        end
                        if H.is_tbl(shared_meta_data.data) and not H.is_tbl(shared_meta_data.data.bookinfo) then
                                local book_id = library_obj:getReadingBookId()
                                if H.is_str(book_id) then
                                    local bookinfo = Backend:getBookInfoCache(book_id)
                                    if H.is_tbl(bookinfo) then
                                        shared_meta_data.data.bookinfo = {
                                                book_cache_id = book_id,
                                                title = bookinfo.name,
                                                authors  = bookinfo.author,
                                                description = bookinfo.intro,
                                        }
                                        is_updated = true
                                    end
                                end
                        end

                        if is_updated == true and H.is_func(shared_meta_data.flush) then
                            shared_meta_data:flush()
                        end

                        local doc_props = doc_settings_data.doc_props
                        if H.is_tbl(doc_props) and not H.is_num(doc_props.chapters_index) then
                            local reading_chapter = PlgState:readingChapter()
                            if H.is_tbl(reading_chapter) and reading_chapter.chapters_index then
                                self.ui.doc_settings.data.doc_props.chapters_index = reading_chapter.chapters_index
                            end
                        end
                    end
                end
            elseif parent_ref:isSkeletonEpub(nil, self.ui) and self.ui.doc_settings then
                self.ui.doc_settings.data.provider = "legado"
            end
        end

        function parent_ref:applyReaderReady(doc_settings)
            if not (doc_settings and doc_settings.data and self.ui and self.view) then return end

            if not parent_ref:isCachePath(nil, self.ui) then
                PlgState:readerUiVisible(false)
                PlgState:readingMode(nil)
                PlgState:clearReadingRoute()
                return
            elseif self.ui.link and self.ui.document then
                local is_epub = (self.ui.document.file and self.ui.document.file:match("%.epub$") ~= nil)
                PlgState:readingMode(is_epub and "full_book" or "chapter_mode")
                Patcher.readui_runtime(self.ui)
                PlgState:readerUiVisible(true)
            end
        end

        function parent_ref:registerReaderUiHookWithPriority(_)
            local WidgetContainer = require("ui/widget/container/widgetcontainer")
            self.eventListener = WidgetContainer:new({})
            self.eventListener.onCloseWidget = function()
                if parent_ref:isCachePath(nil, self.ui) then
                    PlgState:readerUiVisible(false)
                end
            end

            table.insert(self.ui, 2, self.eventListener)
        end

        function parent_ref:afterReaderReady(ui_ref)
            local after_open = PlgState:afterReadUiOpenCallback()
            local is_chapter_open = after_open and not PlgState:isFullBookMode()
            if after_open then
                UIManager:nextTick(after_open)
                if not is_chapter_open then return end
            end

            if not is_chapter_open and not parent_ref:isCachePath(nil, ui_ref) then return end

            if Env.is_legado_skeleton_book(nil, ui_ref) then return end
            local library_obj = LibraryView:getInstance()
            if library_obj then
                local reading_chapter = PlgState:readingChapter()
                if reading_chapter then
                    UIManager:nextTick(function()
                        Backend:after_reader_chapter_show(reading_chapter)
                    end)
                end
            end
        end

        parent_ref.ui:registerPostInitCallback(function()
            parent_ref:registerReaderUiHookWithPriority(parent_ref.ui)
        end)
        if H.is_func(parent_ref.ui.registerPostReaderReadyCallback) then
            parent_ref.ui:registerPostReaderReadyCallback(function()
                parent_ref:afterReaderReady(parent_ref.ui)
            end)
        elseif H.is_func(parent_ref.ui.registerPostReadyCallback) then
            parent_ref.ui:registerPostReadyCallback(function()
                parent_ref:afterReaderReady(parent_ref.ui)
            end)
        end
    end
end

return Handlers
