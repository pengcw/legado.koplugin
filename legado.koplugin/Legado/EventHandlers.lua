-- Legado/EventHandlers.lua
local logger = require("logger")
local util = require("util")
local time = require("ui/time")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local DocSettings = require("docsettings")
local FileManager = require("apps/filemanager/filemanager")
local MessageBox = require("Legado/MessageBox")
local Backend = require("Legado/Backend")
local H = require("Legado/Helper")
local Patcher = require("Legado.patches")
local PlgState = require("Legado/PlgState")

local Handlers = {}

local function switch_sync_reading(settings)
    settings = H.is_tbl(settings) and settings or Backend:getSettings()
    local ok_msg = settings.sync_reading and "关闭" or "开启"
    settings.sync_reading = not settings.sync_reading or nil
    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
        MessageBox:info(string.format("设置已%s", ok_msg))
    end, function(err_msg)
        MessageBox:error('设置失败:', err_msg)
    end)
    return settings
end

function Handlers:register(parent_ref)
    local LibraryView = require("Legado/LibraryView")

    function parent_ref:onShowLegadoLibraryView()
        if not (self.ui and self.ui.document) then
            self:openLibraryView()
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
            self:openLibraryView()
        end, def_search_input)

        return true
    end

    function parent_ref:onSuspend()
        Backend:closeDbManager()
    end

    function parent_ref:onScreenResize(dimen)
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
        local function open_regular_file(file)
            local ReaderUI = require("apps/reader/readerui")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(file, nil, true)
        end
        if not parent_ref:isBrowserBook(file) then
            open_regular_file(file)
            return
        end
        local ok, err = pcall(function() 
            self:_loadBookFromManager(file, open_regular_file)
        end)
        if not ok then
            logger.err("fail to open file:", err)
        end
        return true
    end

    function parent_ref:genMainMenuItems(ui)
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
                    sub_item_table = {
                        {
                            text = "WEB 地址配置",
                            callback = function()
                                require("Legado/WebConfigDialog"):openWebConfigManager()
                            end,
                        }, {
                            text = "自动上传进度",
                            help_text = "阅读时，自动上传阅读进度",
                            checked_func = function()
                                return Backend:getSettings().sync_reading == true
                            end,
                            callback = function()
                                switch_sync_reading(Backend:getSettings())
                            end,
                        }, {
                            text = "自动云端书籍链接",
                            help_text = "在文件管理器内显示书籍",
                            checked_func = function()
                                return Backend:getSettings().disable_browser ~= true
                            end,
                            callback = function()
                                local settings = Backend:getSettings()
                                local ok_msg = settings.disable_browser and "设置已开启" or "设置已关闭，请手动删除目录"
                                settings.disable_browser = not settings.disable_browser or nil
                                Backend:HandleResponse(Backend:saveSettings(settings), function()
                                    MessageBox:notice(ok_msg)
                                end, function(err_msg)
                                    MessageBox:error("设置失败:", err_msg)
                                end)
                            end,
                        }, {
                            text = "书架显示封面",
                            help_text = "开启后，书架将尝试加载并显示书籍封面",
                            checked_func = function()
                                return Backend:getSettings().show_cover == true
                            end,
                            callback = function(menu_def)
                                local settings = Backend:getSettings()
                                local new_state = not settings.show_cover
                                
                                local function save_and_notify()
                                    settings.show_cover = new_state
                                    local msg = new_state and "已开启封面显示" or "已关闭封面显示"
                                    Backend:HandleResponse(Backend:saveSettings(settings), function()
                                        MessageBox:notice(msg)
                                        if menu_def and menu_def.updateItems then menu_def:updateItems() end
                                    end, function(err_msg)
                                        MessageBox:error("设置失败:", err_msg)
                                    end)
                                end

                                if new_state then
                                    local current_items = settings.items_per_page or G_reader_settings:readSetting("items_per_page") or 14
                                    if current_items > 10 then
                                        MessageBox:confirm("开启封面后，建议每页显示不超过 10 条，是否自动调整？", function(is_ok)
                                            if is_ok then
                                                settings.items_per_page = 10
                                            end
                                            save_and_notify()
                                        end)
                                        return
                                    end
                                end
                                save_and_notify()
                            end,
                        }, {
                            text_func = function()
                                local settings = Backend:getSettings()
                                local default_items = settings.show_cover and 10 or (G_reader_settings:readSetting("items_per_page") or 14)
                                local current = settings.items_per_page or default_items
                                return string.format("书架每页项数: %d", current)
                            end,
                            callback = function()
                                local settings = Backend:getSettings()
                                local default_items = settings.show_cover and 10 or (G_reader_settings:readSetting("items_per_page") or 14)
                                local thread_spin = require("ui/widget/spinwidget"):new{
                                    value = settings.items_per_page or default_items,
                                    value_min = 4,
                                    value_max = 15,
                                    value_step = 1,
                                    value_hold_step = 3,
                                    ok_text = "确定",
                                    title_text = "书架每页项数",
                                    info_text = "设置书架每页显示书籍数量",
                                    default_value = default_items,
                                    default_text = tostring(default_items),
                                    callback = function(spin)
                                        settings.items_per_page = spin.value
                                        Backend:HandleResponse(Backend:saveSettings(settings), function()
                                            MessageBox:notice(string.format("每页项数已设置为: %d", spin.value))
                                        end, function(err_msg)
                                            MessageBox:error("设置失败：", tostring(err_msg))
                                        end)
                                    end,
                                }
                                UIManager:show(thread_spin)
                            end,
                        }, {
                            text_func = function()
                                return string.format("预下载章数: %d", Backend:getSettings().preload_chapters or 3)
                            end,
                            callback = function()
                                local settings = Backend:getSettings()
                                local thread_spin = require("ui/widget/spinwidget"):new{
                                    value = settings.preload_chapters or 3,
                                    value_min = 0,
                                    value_max = 40,
                                    value_step = 1,
                                    value_hold_step = 5,
                                    ok_text = "确定",
                                    title_text = "预下载章节数",
                                    info_text = "阅读时, 向后预缓存正文",
                                    default_value = 3,
                                    default_text = "3",
                                    callback = function(spin)
                                        settings.preload_chapters = spin.value
                                        Backend:HandleResponse(Backend:saveSettings(settings), function()
                                            MessageBox:notice(string.format("预缓存章节数已设置为: %d", spin.value))
                                        end, function(err_msg)
                                            MessageBox:error("设置失败：", tostring(err_msg))
                                        end)
                                    end,
                                }
                                UIManager:show(thread_spin)
                            end,
                        }, {
                            text_func = function()
                                return string.format("同时下载数: %d", Backend:getSettings().download_threads or 2)
                            end,
                            callback = function()
                                local settings = Backend:getSettings()
                                local thread_spin = require("ui/widget/spinwidget"):new{
                                    value = settings.download_threads or 2,
                                    value_min = 1,
                                    value_max = 12,
                                    value_step = 1,
                                    value_hold_step = 2,
                                    ok_text = "确定",
                                    title_text = "同时下载进程数",
                                    info_text = "建议根据机器配置选择 1–4 进程\n（如下载异常，可尝试调为 1）",
                                    default_value = 2,
                                    default_text = "2",
                                }
                                UIManager:show(thread_spin)
                            end,
                        },
                }}, {
                    text = "清理与维护",
                    sub_item_table = {
                        {
                            text = "压缩数据库",
                            keep_menu_open = true,
                            callback = function()
                                local old_size = Backend:getDBFileSize()
                                local formatted_old = H.formatFileSize(old_size)
                                MessageBox:confirm(
                                    string.format("当前数据库大小为：%s\n\n是否确认压缩数据库？", formatted_old),
                                    function(result)
                                        if result then
                                            MessageBox:loading("压缩中...", function()
                                                return Backend:vacuumDatabase()
                                            end, function(state, response)
                                                if state == true then
                                                    Backend:HandleResponse(response, function(data)
                                                        local old_str = H.formatFileSize(data.old_size)
                                                        local new_str = H.formatFileSize(data.new_size)
                                                        MessageBox:info(string.format("数据库压缩完成！\n压缩前: %s\n压缩后: %s", old_str, new_str))
                                                    end, function(err_msg)
                                                        MessageBox:error("压缩失败：", tostring(err_msg))
                                                    end)
                                                end
                                            end)
                                        end
                                    end
                                )
                            end,
                        },
                        {
                            text = "清空缓存",
                            keep_menu_open = true,
                            callback = function()
                                MessageBox:confirm(
                                    "是否清空本地书架所有已缓存章节与阅读记录？\n（刷新会重新下载）",
                                    function(result)
                                        if result then
                                            Backend:closeDbManager()
                                            MessageBox:loading("清除中", function()
                                                return Backend:cleanAllBookCaches()
                                            end, function(state, response)
                                                if state == true then
                                                    Backend:HandleResponse(response, function()
                                                        local s = Backend:getSettings()
                                                        s.servers_history = {}
                                                        Backend:saveSettings(s)
                                                        MessageBox:notice("已清除")
                                                    end, function(err_msg)
                                                        MessageBox:error("操作失败：", tostring(err_msg))
                                                    end)
                                                end
                                            end)
                                        end
                                    end, { ok_text = "清空", cancel_text = "取消" })
                            end,
                        },
                        {
                            text = "清除认证状态",
                            keep_menu_open = true,
                            callback = function()
                                if Backend.apiClient and Backend.apiClient.tokenManager then
                                    Backend.apiClient.tokenManager:clear()
                                    MessageBox:success("当前服务端的登录状态已清除！")
                                else
                                    MessageBox:notice("当前服务端无需清理登录 Token")
                                end
                            end,
                        },
                    },
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
                        local legado_update = require("Legado.Update")
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

    if not (parent_ref.ui and parent_ref.ui.document) then
        function parent_ref:openBrowserMenu(file)
            if file and parent_ref:isBrowserBook(file) then
                local library_obj = LibraryView:getInstance()
                if FileManager.instance and library_obj then
                    UIManager:nextTick(function()
                        library_obj:openBrowserMenu(file)
                    end)
                end
            end
        end
    end

    if parent_ref.ui and parent_ref.ui.name == "ReaderUI" then

        function parent_ref:initializeFromReaderUI(document, menu_items)
            if not (document and menu_items and parent_ref:isCachePath(document.file)) then 
                return 
            end
            local settings = Backend:getSettings()

            menu_items.Legado_reader_ui_menu = {
                text = "Legado 选项",
                sorting_hint = "search",
                sub_item_table = {{
                    text = "流式漫画模式",
                    keep_menu_open = true,
                    checked_func = function()
                        local library_obj = LibraryView:getInstance()
                        local book_cache_id = library_obj:getReadingBookId()
                        if book_cache_id then
                            local extras_settings = Backend:getBookExtras(book_cache_id)
                            return H.is_tbl(extras_settings.data) and extras_settings.data.stream_image_view == true
                        end
                        return false
                    end,
                    callback = function()  
                        MessageBox:info("不缓存在线获取内容\n <长按切换选项>")
                    end, 
                    hold_callback = function() 
                        local library_obj = LibraryView:getInstance()
                        local reading_chapter = PlgState:readingChapter()
                        local toc_obj = library_obj:getBookTocWidget()
                        if reading_chapter and toc_obj then
                            local stream_mode_item = toc_obj:getStreamModeItem(nil, function()
                                library_obj:loadAndRenderChapter(reading_chapter)
                            end)
                            if H.is_tbl(stream_mode_item) and H.is_tbl(stream_mode_item[1]) and H.is_func(stream_mode_item[1].callback) then
                                stream_mode_item[1].callback()
                            else
                                return MessageBox:error("当前阅读不是漫画类型, 设置无效")
                            end
                        end
                    end,
                }, {
                    text = "强制刷新本章",
                    separator = true,
                    callback = function()
                        self:onRefreshLegadoChapter()
                    end,
                }, {
                    text = "自动上传阅读进度",
                    keep_menu_open = true,
                    help_text = "阅读时，自动上传阅读进度",
                    checked_func = function() return settings.sync_reading == true end,
                    hold_callback = function(menu_def) 
                        switch_sync_reading(settings)
                        if menu_def and menu_def.updateItems then menu_def:updateItems() end
                    end,
                    callback = function()  
                        MessageBox:info("阅读时，自动上传阅读进度\n <长按切换选项>")
                    end,
                }, {
                    text = "立即上传阅读进度",
                    callback = function()
                        local library_obj = LibraryView:getInstance()
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
                }},
            }
        end

        function parent_ref:onRefreshLegadoChapter()
            local library_obj = LibraryView:getInstance()
            if not library_obj then
                logger.warn("RefreshLegadoChapter LibraryView instance not loaded")
                return true
            end
            if PlgState:readerUiVisible() ~= true then
                MessageBox:error("操作失败: 仅支持 Legado 章节")
                return true
            end
            local reading_chapter = PlgState:readingChapter()
            if reading_chapter then
                reading_chapter.isDownLoaded = true
                Backend:HandleResponse(Backend:ChangeChapterCache(reading_chapter), function(data)
                    MessageBox:notice("刷新成功")
                        UIManager:nextTick(function()
                            library_obj:loadAndRenderChapter(reading_chapter)
                        end)
                    end, function(err_msg)
                        MessageBox:error('操作失败:', tostring(err_msg))
                end)
            else
                MessageBox:error("操作失败: 没有获取到当前章节")
            end
            return true
        end

        function parent_ref:onDocSettingsLoad(doc_settings, document)
            if not (doc_settings and doc_settings.data and document) then
                return
            end
            if parent_ref:isCachePath(document.file) then

                local directory, file_name = util.splitFilePathName(document.file)
                local _, extension = util.splitFileNameSuffix(file_name or "")
                if not (directory and file_name and directory ~= "" and file_name ~= "") then
                    return
                end

                local document_is_new = (document.is_new == true) or doc_settings:readSetting("doc_props") == nil
                if document_is_new then
                    doc_settings:saveSetting("legado_doc_is_new", true)
                end

                local library_obj = LibraryView:getInstance()
                local shared_meta_data = library_obj:getSharedMetaData(directory)

                if H.is_tbl(shared_meta_data) and H.is_tbl(shared_meta_data.data) then
                    local summary = doc_settings.data.summary 
                     local persisted_settings_keys = require("Legado.res.metadata")
                    local book_defaults_data = util.tableDeepCopy(shared_meta_data.data)
                    for k, v in pairs(book_defaults_data) do
                        if persisted_settings_keys[k]  then
                            doc_settings.data[k] = v
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
            elseif parent_ref:isBrowserBook(document.file) and doc_settings.data then
                doc_settings.data.provider = "legado"
            end
        end

        function parent_ref:onSaveSettings()
            if not (self.ui and self.ui.doc_settings) then return end
            local filepath = self.ui.document and self.ui.document.file or self.ui.doc_settings:readSetting("doc_path")
            
            if parent_ref:isCachePath(filepath) then
                local directory, file_name = util.splitFilePathName(filepath)
                if not parent_ref:isCachePath(directory) then return end
                
                if self.ui.doc_settings and type(self.ui.doc_settings.data) == 'table' then
                    local persisted_settings_keys = require("Legado.res.metadata")
                    local library_obj = LibraryView:getInstance()
                    local shared_meta_data = library_obj:getSharedMetaData(directory)
                
                    if H.is_tbl(shared_meta_data) and H.is_tbl(shared_meta_data.data) then
                        local is_updated
                        local doc_settings_data = util.tableDeepCopy(self.ui.doc_settings.data)
                        for k, v in pairs(doc_settings_data) do
                            if persisted_settings_keys[k] and not H.deep_equal(shared_meta_data.data[k], v) then
                                shared_meta_data.data[k] = v
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
            elseif parent_ref:isBrowserBook(nil, self.ui) and self.ui.doc_settings then
                self.ui.doc_settings.data.provider = "legado"
            end
        end
        
        function parent_ref:onReaderReady(doc_settings)
            if not (doc_settings and doc_settings.data and self.ui and self.view) then return end
            
            if not parent_ref:isCachePath(nil, self.ui) then
                PlgState:readerUiVisible(false)
                return
            elseif self.ui.link and self.ui.document then
                Patcher.readui_runtime(self.ui)
                if Backend:enforceRateLimit(PlgState.last_reader_ready_time, 80) then return end
                PlgState.last_reader_ready_time = time.now()
                PlgState:readerUiVisible(true)
                
                local chapter_direction = PlgState:chapterDirection()
                if not chapter_direction then return end

                local document_is_new = (self.ui.document.is_new == true) or doc_settings:readSetting("legado_doc_is_new") == true
                if document_is_new then 
                    doc_settings:delSetting("legado_doc_is_new")
                    if chapter_direction == "next" then return end
                end

                local calculate_goto_page = function(chapter_direction, page_count)
                    if chapter_direction == "next" then return 1
                    elseif page_count and chapter_direction == "prev" then return page_count end
                end

                local make_pages_continuous = function(chapter_event)
                    local current_page = self.ui:getCurrentPage()
                    local is_paging = true
                    if not H.is_num(current_page) or current_page == 0 then
                        if self.ui.paging or (self.ui.document.info and self.ui.document.info.has_pages) then
                            current_page = self.view.state.page
                        else
                            is_paging = false
                            local xpointer = self.ui.document:getXPointer()
                            current_page = self.ui.document:getPageFromXPointer(tostring(xpointer))
                        end
                    end
                    
                    local page_count = self.ui.document:getPageCount()
                    if not (H.is_num(page_count) and page_count > 0) then
                        page_count = doc_settings:readSetting("doc_pages")
                    end
                    
                    local page_number = calculate_goto_page(chapter_event, page_count)
                    if H.is_num(page_number) and page_number ~= tonumber(current_page) then
                        self.ui.link:addCurrentLocationToStack()
                        self.ui:handleEvent(Event:new("GotoPage", page_number))
                        if is_paging == true then
                            if not doc_settings.data.last_page or doc_settings.data.last_page ~= page_number then
                                doc_settings:saveSetting("last_page", page_number)
                            end
                        else
                            local page_xpointer = self.ui.document:getPageXPointer(page_number) or self.document:getXPointer()
                            doc_settings:saveSetting("last_xpointer", tostring(page_xpointer))
                        end
                    end
                end

                make_pages_continuous(chapter_direction)
            end
        end

        function parent_ref:registerReaderUiHookWithPriority(ui)
            local WidgetContainer = require("ui/widget/container/widgetcontainer")
            self.eventListener = WidgetContainer:new({})
            
            self.eventListener.onCloseWidget = function()
                if parent_ref:isCachePath(nil, self.ui) then
                    PlgState:readerUiVisible(false)
                end
            end

            self.eventListener.onStartOfBook = function()
                if parent_ref:isCachePath(nil, self.ui) then
                    local library_obj = LibraryView:getInstance()
                    if library_obj then
                        if Backend:enforceRateLimit(PlgState.last_page_turn_time, 80) then return true end
                        PlgState.last_page_turn_time = time.now()
                        UIManager:nextTick(function()
                            local chapter_direction = "prev"
                            library_obj:ReaderUIEventCallback(chapter_direction, self.ui)
                        end)
                    else
                        parent_ref:openLibraryView()
                    end
                    return true
                end
            end

            self.eventListener.onCloseDocument = function()
                if parent_ref:isCachePath(nil, self.ui) then
                    PlgState:readerUiVisible(false)
                    if not (parent_ref.ui and parent_ref.ui._ref_legado_wrapped) then
                        require("readhistory"):removeItemByPath(self.document.file)
                    end
                end
            end

            self.eventListener.onEndOfBook = function()
                if parent_ref:isCachePath(nil, self.ui) then
                    local library_obj = LibraryView:getInstance()
                    if library_obj then
                        if Backend:enforceRateLimit(PlgState.last_page_turn_time, 80) then return true end
                        PlgState.last_page_turn_time = time.now()
                        UIManager:nextTick(function()
                            local chapter_direction = "next"
                            library_obj:ReaderUIEventCallback(chapter_direction, self.ui)
                        end)
                    else
                        UIManager:nextTick(function()
                            parent_ref:openLibraryView()
                        end)
                    end
                    return true
                end
            end

            table.insert(self.ui, 2, self.eventListener)
        end

        function parent_ref:afterReaderReady()
            if parent_ref:isCachePath(nil, self.ui)  then
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
        end

        parent_ref.ui:registerPostInitCallback(function()
            parent_ref:registerReaderUiHookWithPriority(parent_ref.ui)
        end)
        if H.is_func(parent_ref.ui.registerPostReaderReadyCallback) then
            parent_ref.ui:registerPostReaderReadyCallback(function()
                parent_ref:afterReaderReady()
            end)
        elseif H.is_func(parent_ref.ui.registerPostReadyCallback) then
            parent_ref.ui:registerPostReadyCallback(function()
                parent_ref:afterReaderReady()
            end)
        end
    end
end

return Handlers