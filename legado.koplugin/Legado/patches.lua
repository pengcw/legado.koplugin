
local Event = require("ui/event")
local logger = require("logger")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local ReadHistory = require("readhistory")
local Env = require("Legado.Helper.Env")
local BookEntry = require("Legado/BookEntry")

local M = {
    is_enabled = false,
}

local function installReviewStyle(ui)
    local styletweak = ui.styletweak
    if not styletweak or styletweak._legado_review_style_installed then return end
    local original = styletweak.getCssText
    styletweak.getCssText = function(self, ...)
        local css = original(self, ...)
        if not M.is_enabled then return css end
        local review_css, err = require("Legado/EpubHelper").getReviewCss()
        if not review_css then
            logger.warn("Legado review stylesheet unavailable:", err)
            return css
        end
        return css and css ~= "" and (review_css .. "\n" .. css) or review_css
    end
    styletweak._legado_review_style_installed = true
end

M.readui_starting = function(read_ui)
    if not read_ui then return end
    local ui = read_ui.name == "ReaderUI" and read_ui or read_ui.ui
    if not ui or ui.name ~= "ReaderUI" then return end
    local stats = ui.statistics
    if M.is_enabled and stats and stats.settings and stats.settings.is_enabled
            and not stats._legado_chapter_stats and not stats._legado_chapter_stats_paused
            and Env.is_legado_chapter_cache(nil, ui) then
        require("Legado/ChapterStatistics").install(ui, M)
    end
    if M.is_enabled then installReviewStyle(ui) end
    if ui._ref_legado_wrapped_s == true then return end
    ui._ref_legado_wrapped_s = true

    if ui.rolling then
        local orig_rolling_onReadSettings = ui.rolling.onReadSettings
        ui.rolling.onReadSettings = function(self, _config)
            local view = self.ui and self.ui.view
            if not view or not view.recalculate then
                return orig_rolling_onReadSettings(self, _config)
            end
            local orig_recalculate = view.recalculate
            view.recalculate = function() return true end
            local ret = orig_rolling_onReadSettings(self, _config)
            view.recalculate = orig_recalculate
            self._wrapped_gotoXPointer = function(r, target_xpointer, marker_xpointer)
                if not target_xpointer then return false end
                if r.xpointer == target_xpointer then
                    if r.ui and r.ui.view and r.ui.view.recalculate then r.ui.view:recalculate() end
                elseif r.onGotoXPointer then
                    r:onGotoXPointer(target_xpointer, marker_xpointer)
                end
            end
            return ret
        end
    end
   if ui.paging then
        local orig_paging_onReadSettings = ui.paging.onReadSettings
        ui.paging.onReadSettings = function(self, _config)
            local view = self.ui and self.ui.view
            if not view or not view.recalculate then
                return orig_paging_onReadSettings(self, _config)
            end
            local orig_recalculate = view.recalculate
            view.recalculate = function() return true end
            local ret = orig_paging_onReadSettings(self, _config)
            view.recalculate = orig_recalculate
            self._wrapped_gotoPage = function(p, target_page)
                if p.current_page == target_page then
                    if p.ui and p.ui.view and p.ui.view.recalculate then p.ui.view:recalculate() end
                else
                    if p._gotoPage then
                        p:_gotoPage(target_page)
                    elseif p.onGotoPage then
                        p:onGotoPage(target_page)
                    else
                        return false
                    end
                end
                return true
            end
            return ret
        end
    end
end

M.readui_runtime = function(read_ui)
    if not read_ui then return end
    local ui = read_ui.name == "ReaderUI" and read_ui or read_ui.ui
    if not ui or ui.name ~= "ReaderUI" then return end
    if ui._ref_legado_wrapped == true then return end

    ui._ref_legado_wrapped = true

    if ui.link then
        local original = ui.link.onGotoLink
        ui.link.onGotoLink = function(self, link, ...)
            if M.is_enabled and (Env.is_legado_chapter_cache(nil, self.ui)
                    or Env.is_legado_skeleton_book(nil, self.ui)) then
                local href = type(link) == "table" and (link.xpointer or link.uri)
                local doc_settings = self.ui.doc_settings
                local book = doc_settings and doc_settings:readSetting("book_cache_id")
                local file = self.ui.document and self.ui.document.file
                if type(file) == "string" then book = file:match("/([%w]+)%.sdr/[^/]+$") or book end
                local ReviewLink = require("Legado.Helper.ReviewLink")
                local target = ReviewLink.from_href(href, {book_cache_id = book})
                if not target and ReviewLink.EPUB_FALLBACK_ENABLED
                        and Env.is_legado_skeleton_book(nil, self.ui) then
                    local candidate = ReviewLink.from_epub_href(href, {book_cache_id = book, chapters_index = 0})
                    if not candidate and type(link) == "table" and link.a_xpointer
                            and self.ui.document and self.ui.document.getHTMLFromXPointer then
                        local source_html = self.ui.document:getHTMLFromXPointer(link.a_xpointer, 0, false)
                        local source_href = type(source_html) == "string" and source_html:match('<a%s[^>]-href="([^"]+)"')
                        candidate = ReviewLink.from_epub_href(source_href, {book_cache_id = book, chapters_index = 0})
                        if not candidate and type(source_html) == "string" then
                            local anchor = source_html:match('<a%s[^>]-id="([^"]+)"')
                            local chapter, id
                            if anchor then
                                chapter, id = anchor:match("^lr(%d+)%-(%d+)$")
                                if not chapter then chapter, id = anchor:match("^_doc_fragment_%d+_%s*lr(%d+)%-(%d+)$") end
                            end
                            local target_chapter, target_id
                            if source_href then target_chapter, target_id = source_href:match("^#_doc_fragment_%d+_%s*c(%d+)%-(%d+)$") end
                            if chapter and target_chapter == chapter and target_id == id then
                                candidate = ReviewLink.from_epub_href("r.xhtml#c" .. chapter .. "-" .. id, {book_cache_id = book, chapters_index = 0})
                            end
                        end
                    end
                    if candidate and type(file) == "string" then
                        local metadata = require("Legado.Skeleton.Epub").readSkeletonMetadata(file)
                        if metadata and metadata.review_links_version == 1 and metadata.book_cache_id == book then
                            local Backend = require("Legado/Backend")
                            local chapter = Backend.dbManager:getChapterInfo(book, candidate.chapters_index)
                            chapter = chapter and Backend:getCacheChapterFilePath(chapter, true)
                            local cached = chapter and chapter.cacheFilePath and io.open(chapter.cacheFilePath, "rb")
                            if cached then
                                local html = cached:read(16 * 1024 * 1024 + 1)
                                cached:close()
                                if html and #html <= 16 * 1024 * 1024 and ReviewLink.read_action(html, candidate.id, candidate) then
                                    target = candidate
                                end
                            end
                        end
                    end
                end
                if target then
                    self.ui:handleEvent(Event:new("LegadoReview", target))
                    return true
                end
            end
            return original(self, link, ...)
        end
    end

    local function atPageStart(document, page)
        if not document or type(page) ~= "number" or page < 1 then return false end
        if type(document.getPrevPage) == "function" then
            return document:getPrevPage(page) == 0
        end
        return page == 1
    end

    if ui.rolling then
        local original = ui.rolling.onGotoViewRel
        ui.rolling.onGotoViewRel = function(self, diff, ...)
            if M.is_enabled and diff < 0 and Env.is_legado_chapter_cache(nil, self.ui) then
                local mode = self.view.view_mode
                if (mode == "page" or (mode == "scroll" and self.current_pos == 0))
                        and atPageStart(self.ui.document, self.current_page) then
                    self.ui:handleEvent(Event:new("StartOfBook"))
                    return true
                end
            end
            return original(self, diff, ...)
        end
    end

    if ui.paging then
        local original = ui.paging.onGotoViewRel
        ui.paging.onGotoViewRel = function(self, diff, no_page_turn, ...)
            if M.is_enabled and diff < 0 and no_page_turn ~= true
                    and Env.is_legado_chapter_cache(nil, self.ui) then
                local scroll = self.view.page_scroll
                local ready = not scroll or (self.view.page_states and self.view.page_states[1])
                if ready and atPageStart(self.ui.document, self:getTopPage())
                        and (not scroll or self:getTopPosition() <= 0) then
                    self.ui:handleEvent(Event:new("StartOfBook"))
                    return true
                end
            end
            return original(self, diff, no_page_turn, ...)
        end
    end

    if ui.view and ui.view.footer then
        local orig_footer_getBookProgress = ui.view.footer.getBookProgress
        ui.view.footer.getBookProgress = function(self)
            if not M.is_enabled or (self.ui and self.ui.document) then
                return orig_footer_getBookProgress(self)
            else
                local pageno = self.pageno or 0
                local pages = self.pages or 1
                if pages == 0 then pages = 1 end
                return pageno / pages
            end
        end

        local orig_footer_updateFooterPage = ui.view.footer.updateFooterPage
        ui.view.footer.updateFooterPage = function(self, force_repaint, full_repaint)
            if not M.is_enabled or (self.ui and self.ui.document) then
                return orig_footer_updateFooterPage(self, force_repaint, full_repaint)
            end
        end
    end

    return true
end

local function installReaderEventGate(ui, rules)
    if not ui or ui.name ~= "ReaderUI" or not rules then return end
    if ui._legado_event_gate then return end
    ui._legado_event_gate = true
    local original = ui.handleEvent
    ui.handleEvent = function(self, event)
        local rule = rules[event.handler]
        if not M.is_enabled or not rule then return original(self, event) end
        local ok_match, matched = pcall(rule.matches, self, event)
        if not ok_match then
            logger.err("Legado event gate match failed:", event.handler, matched)
        end
        if not ok_match or not matched then return original(self, event) end
        local result
        if rule.mode == "after" then
            result = original(self, event)
        end
        local ok, err = pcall(rule.run, self, event)
        if not ok then
            logger.err("Legado event gate failed:", event.handler, err)
            error(err, 0)
        end
        if rule.mode == "after" then return result end
        if rule.mode == "before" then return original(self, event) end
        return true
    end
end

M.install = function(parent_ref, rules)
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["legado"] == true then
            return
        end
    end
    if not parent_ref then return end

    M.is_enabled = true
    installReaderEventGate(parent_ref.ui, rules)

    if ReaderUI._legado_wrapped == nil then
        local orig_ReaderUI_showReader = ReaderUI.showReader
        ReaderUI._legado_wrapped = orig_ReaderUI_showReader
        ReaderUI.showReader = function(self, file, provider, seamless, is_provider_forced, after_open_callback)
            if M.is_enabled then
                local kind, settings = BookEntry.identify(file)
                if kind and parent_ref.openFile then return parent_ref:openFile(file, kind, settings) end
            end
            return orig_ReaderUI_showReader(self, file, provider, seamless, is_provider_forced, after_open_callback)
        end
    end

    if ReadHistory._legado_wrapped == nil then
        ReadHistory._legado_wrapped = true

        local orig_ReadHistory_addItem = ReadHistory.addItem
        ReadHistory.addItem = function(self, file, ts, no_flush)
            if M.is_enabled and Env.is_legado_chapter_cache(file) then
                return
            end
            return orig_ReadHistory_addItem(self, file, ts, no_flush)
        end

        local orig_ReadHistory_updateLastBookTime = ReadHistory.updateLastBookTime
        ReadHistory.updateLastBookTime = function(self, no_flush)
            if not M.is_enabled or (self.hist and self.hist[1] ~= nil) then
                return orig_ReadHistory_updateLastBookTime(self, no_flush)
            end
        end
    end

    if FileManager._legado_wrapped == nil then
        FileManager._legado_wrapped = true
        local orig_FileManager_showOpenWithDialog = FileManager.showOpenWithDialog
        FileManager.showOpenWithDialog = function(self, file)
            if M.is_enabled and file and Env.is_legado_skeleton_epub(file) then
                self:handleEvent(Event:new("ShowLegadoLibraryView"))
            else
                return orig_FileManager_showOpenWithDialog(self, file)
            end
        end
    end
end

M.uninstall = function()
    M.is_enabled = false
    if ReaderUI then ReaderUI._legado_wrapped = nil end
    if FileManager then FileManager._legado_wrapped = nil end
    if ReadHistory then ReadHistory._legado_wrapped = nil end
    local ui = ReaderUI.instance or FileManager.instance
    if ui then
        ui._ref_legado_wrapped = nil
        ui._ref_legado_wrapped_s = nil
    end
end

return M
