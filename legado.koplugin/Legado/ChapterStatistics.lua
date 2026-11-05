local logger = require("logger")
local M = {}

local function pause(ui)
    local stats = ui.statistics
    if stats._legado_chapter_stats then return end
    if type(stats.initData) ~= "function" or type(stats.onPageUpdate) ~= "function"
            or type(stats.insertDB) ~= "function" then
        logger.warn("Legado cannot pause unrecognized chapter statistics instance")
        return
    end
    local function freeze(self)
        self.is_doc = false
        self.is_doc_not_frozen = false
        self.id_curr_book = nil
    end
    local function ignore() end
    stats.initData, stats.onPageUpdate, stats.insertDB = freeze, ignore, ignore
    freeze(stats)
    stats._legado_chapter_stats_paused = true
    logger.warn("Legado statistics aggregation unavailable; current chapter statistics paused")
end

local function install(ui, state)
    local stats = ui.statistics
    if type(stats.getIdBookDB) ~= "function" or type(stats.insertDB) ~= "function"
            or type(stats.getBookStat) ~= "function" then return end
    local path = ui.document and ui.document.file
    local book_id = path:match("/([^/]+)%.sdr/[^/]+$")
    local chapter_index = tonumber(path:match("%-(%d+)%.[^%.]+$"))
    if not book_id or not chapter_index then return end
    local Backend = require("Legado/Backend")
    local book = Backend:getBookInfoCache(book_id)
    if not book or not book.name then return end
    local chapters = Backend:getReadableChapters(book_id) or {}
    local ordinal
    for i, chapter in ipairs(chapters) do
        if chapter.chapters_index == chapter_index then ordinal = i; break end
    end
    if not ordinal then return end
    local _ = require("gettext")
    local CHAPTER_SPAN = 100
    local identity = { title = book.name, authors = book.author or "N/A",
        md5 = "legado-chapters-pages-" .. book_id, ordinal = ordinal, total = #chapters }
    local function virtualPage(page)
        return (ordinal - 1) * CHAPTER_SPAN + math.min(math.max(page, 1), CHAPTER_SPAN)
    end
    local needs_alignment = false
    local failed = false
    local function stop(err)
        if not failed then
            failed = true
            stats.is_doc_not_frozen = false
            logger.warn("Legado chapter statistics disabled for current document:", err)
        end
    end
    local original_id = stats.getIdBookDB
    local original_insert = stats.insertDB
    local function get_id(self)
        if not state.is_enabled or failed then return end
        local data = self.data
        if type(data) ~= "table" then stop("unexpected statistics data"); return end
        local title, authors, md5, pages = data.title, data.authors, self.doc_md5, data.pages
        local db
        local ok, id = pcall(function()
            data.title, data.authors = identity.title, identity.authors
            self.doc_md5 = identity.md5
            local total = identity.total * CHAPTER_SPAN
            data.pages = total
            local id = original_id(self)
            if id then
                local SQ3 = require("lua-ljsqlite3/init")
                local DataStorage = require("datastorage")
                db = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
                local previous = tonumber(db:rowexec("SELECT pages FROM book WHERE id = " .. id .. ";")) or total
                identity.total = math.ceil(math.max(total, previous) / CHAPTER_SPAN)
                needs_alignment = previous ~= identity.total * CHAPTER_SPAN
            end
            return id
        end)
        self.data, data.pages = data, pages
        if db then
            local closed, err = pcall(function() db:close() end)
            if not closed then stop(err) end
        end
        if not ok or failed then
            data.title, data.authors, self.doc_md5 = title, authors, md5
            if not ok then stop(id) end
            return
        end
        return id
    end
    local function insert(self, updated_pagecount)
        if not state.is_enabled or failed then return end
        local data = self.data
        if type(data) ~= "table" then stop("unexpected statistics data"); return end
        local real_page, real_pages, pending = self.curr_page, data.pages, self.page_stat
        local db
        local ok, seed = pcall(function()
            if not self.settings.is_enabled then return end
            if not (self.id_curr_book and self.is_doc_not_frozen) then
                original_insert(self, updated_pagecount)
                return
            end
            if type(pending) ~= "table" or type(real_pages) ~= "number" or real_pages <= 0 then
                error("unexpected statistics page state")
            end
            if needs_alignment then
                local SQ3 = require("lua-ljsqlite3/init")
                local DataStorage = require("datastorage")
                db = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
                local total = identity.total * CHAPTER_SPAN
                local stmt = db:prepare("UPDATE page_stat_data SET total_pages = ? WHERE id_book = ? AND total_pages <> ?;")
                stmt:bind(total, self.id_curr_book, total):step()
                stmt:close()
                needs_alignment = false
            end
            local mapped = {}
            for page, tuples in pairs(pending) do
                local target = virtualPage(page)
                mapped[target] = mapped[target] or {}
                for _, tuple in ipairs(tuples) do
                    mapped[target][#mapped[target] + 1] = tuple
                end
            end
            self.curr_page = real_page and virtualPage(real_page)
            local current = pending[real_page]
            local seed = current and current[#current]
            if seed and seed[2] == 0 then
                local tuples = mapped[self.curr_page]
                for i, tuple in ipairs(tuples) do
                    if tuple == seed then table.remove(tuples, i); break end
                end
                tuples[#tuples + 1] = seed
            end
            self.page_stat = mapped
            self.data.pages = identity.total * CHAPTER_SPAN
            original_insert(self, self.data.pages)
            if type(self.page_stat) ~= "table" then error("unexpected statistics seed") end
            local seed = self.page_stat[self.curr_page]
            if real_page and (type(seed) ~= "table" or type(seed[1]) ~= "table"
                    or type(seed[1][1]) ~= "number" or seed[1][2] ~= 0) then
                error("unexpected statistics seed")
            end
            return seed
        end)
        self.curr_page, self.data, data.pages = real_page, data, real_pages
        if db then
            local closed, err = pcall(function() db:close() end)
            if not closed then stop(err) end
        end
        if not ok or failed then
            self.page_stat = pending
            if not ok then stop(seed) end
            return
        end
        if self.page_stat ~= pending then
            self.page_stat = {}
            if real_page and seed then self.page_stat[real_page] = seed end
        end
    end
    local function current(self)
        if state.is_enabled and not failed then
            local ok, result = pcall(function()
                self:insertDB()
                if not failed then return self:getBookStat(self.id_curr_book) end
            end)
            if ok and not failed and type(result) == "table" then return result end
            if not ok then stop(result) else stop("statistics summary unavailable") end
        end
        return { { _("Statistics"), _("Unavailable for this document") } }
    end
    stats.getIdBookDB, stats.insertDB, stats.getCurrentStat = get_id, insert, current
    stats._legado_chapter_stats = true
end

function M.install(ui, state)
    local ok, err = pcall(install, ui, state)
    if not ok then logger.warn("Legado chapter statistics unavailable:", err) end
    pause(ui)
end

return M
