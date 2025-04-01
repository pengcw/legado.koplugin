local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local dbg = require("dbg")
local Device = require("device")
local util = require("util")
local md5 = require("ffi/sha2").md5
local H = require("libs/Helper")
local custom_type_variable = {}
local M = {
    dbPath = nil,
    db_conn = nil,
    isConnected = false,
    dbCreated = false,
    in_transaction = false
}

local function custom_concat(tbl, sep)
    sep = sep or ""
    local result = {}

    for i, v in ipairs(tbl) do
        if v == nil then
            result[i] = "nil"
        elseif type(v) == "table" then

            result[i] = "{" .. custom_concat(v, ",") .. "}"
        else
            result[i] = tostring(v)
        end
    end

    return table.concat(result, sep)
end

local BOOKINFO_DB_VERSION = 20250320

local BOOKINFO_DB_SCHEMA = [[

CREATE TABLE IF NOT EXISTS books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,      
    bookShelfId TEXT NOT NULL,                  
    bookCacheId TEXT NOT NULL,                  
    name TEXT NOT NULL,                         
    author TEXT NOT NULL,                       
    bookUrl TEXT NOT NULL,                      
    origin TEXT NOT NULL,                       
    originName TEXT NOT NULL,                   
    originOrder INTEGER DEFAULT 0,              

    
    durChapterIndex INTEGER DEFAULT 0,          
    durChapterPos INTEGER DEFAULT 0,            
    durChapterTime INTEGER DEFAULT 0,           
    durChapterTitle TEXT DEFAULT '',            

    
    intro TEXT,                                 
    kind TEXT,                                   
    totalChapterNum INTEGER DEFAULT 0,          
    btype INTEGER NOT NULL DEFAULT 0,            
    wordCount TEXT,                              
    coverUrl TEXT,                              

    
    cacheExt TEXT DEFAULT NULL,                              
    sortOrder INTEGER DEFAULT 1,                
    isEnabled INTEGER DEFAULT 1,
    lastUpdated INTEGER DEFAULT (strftime('%s', 'now')),
    UNIQUE (bookShelfId, bookCacheId) 
);


CREATE TABLE IF NOT EXISTS chapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,       
    bookCacheId TEXT NOT NULL,                    
    chapterIndex INTEGER NOT NULL,    
    title TEXT DEFAULT '',             
    
    isVolume INTEGER, 
    
    
    isRead INTEGER DEFAULT 0,       
    cacheFilePath TEXT DEFAULT NUll,   
    content TEXT DEFAULT NUll,          
    lastUpdated INTEGER DEFAULT (strftime('%s', 'now')), 

    
    UNIQUE (bookCacheId, chapterIndex)
);



CREATE INDEX IF NOT EXISTS idx_book_main ON books (bookShelfId, bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_books_bookcacheid ON books (bookCacheId);
CREATE INDEX IF NOT EXISTS idx_books_bookCacheId_isenabled ON books (bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_chapter_basic ON chapters (bookCacheId, chapterIndex);
CREATE INDEX IF NOT EXISTS idx_chapters_book_cacheid_chapterindex_desc ON chapters (bookCacheId, chapterIndex DESC);
CREATE INDEX IF NOT EXISTS idx_chapters_book_cacheid_chapterindex_asc ON chapters (bookCacheId, chapterIndex ASC);
CREATE INDEX IF NOT EXISTS idx_book_sortorder ON books ( sortOrder ASC );
CREATE INDEX IF NOT EXISTS idx_chapter_lastupdated ON chapters (lastUpdated DESC);
CREATE INDEX IF NOT EXISTS idx_chapters_chapterindex ON chapters (chapterIndex);
CREATE INDEX IF NOT EXISTS idx_chapters_cachefilepath ON chapters (cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_chapters_content_cache ON chapters(content, cacheFilePath);



CREATE TRIGGER IF NOT EXISTS update_books_timestamp
AFTER UPDATE ON books
FOR EACH ROW
WHEN NEW.totalChapterNum IS NOT OLD.totalChapterNum
BEGIN
    UPDATE books
    SET lastUpdated = strftime('%s', 'now')
    WHERE id = OLD.id;
END;
]]

function M:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o.init then
        o:init()
    end
    return o
end

function M:init()
    self:_createDB()
end

function M:nil_object()
    return setmetatable({
        __type_ext = 'nil',
        [1] = 'nil'

    }, {
        __tostring = function()
            return "nil"
        end
    })
end

function M:blob_object(byte_array, size)
    return setmetatable({
        __type_ext = 'blob',
        __ext_size = size,
        [1] = byte_array
    }, {
        __tostring = function()
            return "blob"
        end
    })
end

function M:_setJournalMode()
    local mode = Device:canUseWAL() and "WAL" or "TRUNCATE"
    local success, err = pcall(function()
        self.db:exec("PRAGMA journal_mode=" .. mode .. ";")
    end)
    if success then
        dbg.v("Database journal mode set to: " .. mode)
    else
        dbg.log("Failed to set journal mode. Error: " .. tostring(err))
    end

end

function M:_openDB()
    if self.isConnected and self.db then

        return self.db
    end
    if not self.dbPath then
        error('Variable not set db path!')
    end
    local success, db = pcall(function()
        return SQ3.open(self.dbPath)
    end)
    if not success or not db then
        dbg.log("Failed to open database at: " .. self.dbPath)
        error("Failed to open database at: " .. self.dbPath)
        return nil
    end

    self.db = db
    self.isConnected = true
    self.in_transaction = false

    self.db:set_busy_timeout(15000)

    dbg.v("Database opened successfully at: " .. self.dbPath)

    self:_setJournalMode()

    return self.db
end

function M:_createDB()
    local db = self:_openDB()

    local success, rc = pcall(function()
        db:exec(string.format("PRAGMA user_version=%d;", BOOKINFO_DB_VERSION))
        return db:exec(BOOKINFO_DB_SCHEMA)
    end)
    if success and rc == SQ3.OK then
        dbg.v("Database schema initialized successfully.")
        self.dbCreated = true
        self:closeDB()
    else
        dbg.log("Failed to initialize database schema. Return code: " .. tostring(rc))
    end
end

function M:closeDB()
    if not self.isConnected or not self.db then
        dbg.log("Database is not connected, skipping close.")
        return
    end

    local success, err = pcall(function()
        self.db:close()
    end)
    if success then
        dbg.v("Database closed successfully.")
    else
        dbg.log("Error closing database: " .. tostring(err))
    end
    self.db = nil
    self.isConnected = false
end

function M:getDB()

    if not util.fileExists(self.dbPath) then
        self:_createDB()
    end
    if not self.isConnected or not self.db then
        return self:_openDB()
    end
    return self.db
end

function M:transaction(write_func, opts)
    return function(...)
        local conn = self:getDB()
        opts = opts or {}
        local savepoint_name
        local use_savepoint = opts.enable_savepoint and self.in_transaction

        if use_savepoint then
            savepoint_name = string.format("sp_%08x", math.random(0x7fffffff))
            local savepoint_sql = string.format("SAVEPOINT %s", savepoint_name)
            conn:exec(savepoint_sql)
        else

            local txn_type = opts.transaction_type or "IMMEDIATE"
            conn:exec(string.format("BEGIN %s TRANSACTION", txn_type))
            self.in_transaction = true
        end

        local ok, result = xpcall(function(...)
            return write_func(...)
        end, function(err)

            return debug.traceback(tostring(err), 2)
        end, ...)

        if use_savepoint then
            if ok then
                local release_sql = string.format("RELEASE %s", savepoint_name)
                conn:exec(release_sql)
            else
                local rollback_sql = string.format("ROLLBACK TO %s", savepoint_name)
                pcall(conn.exec, conn, rollback_sql)

            end
        else
            if ok then
                pcall(conn.exec, conn, "COMMIT")

            else
                pcall(conn.exec, conn, "ROLLBACK")

            end
            self.in_transaction = false
        end

        if not ok then
            error(result, 0)

        end
        return result
    end
end

local function bool_to_number(bool_value)

    return bool_value and 1 or 0
end

local function validate_data_list(data_list)
    if type(data_list) ~= "table" or #data_list == 0 then
        error("The data list must be a non-empty array")
    end
end

local function adapt_value(v)
    if type(v) == "boolean" then
        return bool_to_number(v)
    elseif type(v) == "table" and v.__type_ext == 'blob' then
        return SQ3.blob(v[1], v.__ext_size)
    elseif type(v) == "table" and v.__type_ext == 'nil' then
        return nil
    end
    return v
end

local function validate_param_type(v, pos)
    local t = type(v)
    if not (t == "nil" or t == "number" or t == "string" or t == 'boolean' or (t == "table" and v.__type_ext)) then
        error(string.format("Illegal parameter type %s (position %d)", t, pos))
    end
end

function M:batch_insert(sql_template, data_list, batch_size)
    batch_size = batch_size or 500
    validate_data_list(data_list)

    local function process_batch(batch_data)
        return self:transaction(function()
            local stmt = self:getDB():prepare(sql_template)

            local param_count = select(2, sql_template:gsub("%?", "%?"))

            for _, params in ipairs(batch_data) do
                if #params ~= param_count then
                    error(string.format(
                        "The number of parameters does not match (requires %d, actual %d, parameter %s)", param_count,
                        #params, custom_concat(params, ", ")))
                end

                for i, v in ipairs(params) do
                    validate_param_type(v, i)

                    stmt:bind1(i, adapt_value(v))

                end

                local step_ok, step_err = pcall(stmt.step, stmt)
                if not step_ok then
                    error(string.format("Step execution failed:%s\n Parameters:%s", step_err,
                        custom_concat(params, ", ")))
                end
                stmt:reset()
            end

            stmt:clearbind():close()
        end, {
            enable_savepoint = false
        })()
    end

    if batch_size <= 0 or #data_list <= batch_size then
        return process_batch(data_list)
    end

    local total = #data_list
    for i = 1, total, batch_size do
        local batch = {}
        for j = i, math.min(i + batch_size - 1, total) do
            table.insert(batch, data_list[j])
        end
        process_batch(batch)
    end
end

local _write_ops = {
    INSERT = true,
    UPDATE = true,
    DELETE = true,
    REPLACE = true,
    ALTER = true,
    DROP = true
}

function M:execute(sql, params, options)

    params = params or {}
    options = options or {}
    if type(params) ~= "table" then
        params = {params}
    end

    local op = sql:match("^%s*(%w+)") or "UNKNOWN"

    op = op:upper()
    local is_write = _write_ops[op]

    local placeholder_count = select(2, sql:gsub("%?", "%?"))
    if placeholder_count ~= #params then
        error(string.format(
            "The number of parameters does not match (SQL has %d placeholders, %d parameters are passed in, parameter %s)",
            placeholder_count, #params, custom_concat(params, ", ")))
    end

    local conn = self:getDB()

    if not conn then
        error("Database not connected")
    end

    local stmt, err = conn:prepare(sql)
    if not stmt then
        error("SQL预处理失败: " .. tostring(err))
    end

    for i, v in ipairs(params) do
        validate_param_type(v, i)

        stmt:bind1(i, adapt_value(v))

    end

    if options.return_stmt then
        return stmt
    end

    local ok, ret = pcall(function()
        if is_write then
            stmt:step()

            return {
                last_insert_rowid = conn:rowexec("SELECT last_insert_rowid() AS id") or 0,
                changes = conn:rowexec("SELECT changes() AS count") or 0
            }
        else

            local result = {}
            local row = {}

            local i = 1
            for row in stmt:rows() do

                if row == nil then
                    break
                end

                result[i] = row
                i = i + 1

            end

            return result
        end
    end)

    stmt:clearbind():reset()

    if not ok then
        error(string.format("SQL Execution failed\nStatement: %s\nError: %s", sql, ret))
    else

        return ret
    end
end

function M:safe_rows(sql, params, fetch_size)
    fetch_size = fetch_size or 100
    local stmt = self:execute(sql, params, {
        return_stmt = true
    })

    return function()
        local batch = {}
        for _ = 1, fetch_size do
            local row = stmt:step()
            if not row then
                break
            end
            table.insert(batch, row)
        end

        if #batch == 0 then
            stmt:clearbind():reset()
            return nil
        end
        stmt:clearbind():reset()
        return batch
    end
end

function M:upsertBooks(bookShelfId, legado_data)
    if not H.is_str(bookShelfId) or not H.is_tbl(legado_data) then
        dbg.log('BookInfoDB:upsertBooks Incorrect input parameters')
        return false
    end

    local bookData = {}

    for index, item in ipairs(legado_data) do

        if not H.is_str(item.name) or not H.is_str(item.author) or not H.is_str(item.bookUrl) then
            goto continue
        end

        item.name = util.trim(item.name)
        item.author = util.trim(item.author)

        if item.name == '' or item.author == '' then
            goto continue
        end

        local show_book_title = ("%s (%s)"):format(item.name, item.author)
        item.cache_id = tostring(md5(show_book_title))

        table.insert(bookData, item)
        ::continue::
    end

    local sql_stmt = [[
    INSERT INTO books (
    bookShelfId, bookCacheId, name, author, bookUrl, origin, originName, originOrder, 
    durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, wordCount, 
    coverUrl, intro, totalChapterNum, btype, isEnabled, kind
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(bookShelfId, bookCacheId) DO UPDATE SET
    name = CASE WHEN excluded.name != books.name THEN excluded.name ELSE books.name END,
    author = CASE WHEN excluded.author != books.author THEN excluded.author ELSE books.author END,
    bookUrl = CASE WHEN excluded.bookUrl != books.bookUrl THEN excluded.bookUrl ELSE books.bookUrl END,
    origin = CASE WHEN excluded.origin != books.origin THEN excluded.origin ELSE books.origin END,
    originName = CASE WHEN excluded.originName != books.originName THEN excluded.originName ELSE books.originName END,
    originOrder = CASE WHEN excluded.originOrder != books.originOrder THEN excluded.originOrder ELSE books.originOrder END,
    durChapterIndex = CASE WHEN excluded.durChapterIndex != books.durChapterIndex THEN excluded.durChapterIndex ELSE books.durChapterIndex END,
    durChapterPos = CASE WHEN excluded.durChapterPos != books.durChapterPos THEN excluded.durChapterPos ELSE books.durChapterPos END,
    durChapterTime = CASE WHEN excluded.durChapterTime != books.durChapterTime THEN excluded.durChapterTime ELSE books.durChapterTime END,
    durChapterTitle = CASE WHEN excluded.durChapterTitle != books.durChapterTitle THEN excluded.durChapterTitle ELSE books.durChapterTitle END,
    wordCount = CASE WHEN excluded.wordCount != books.wordCount THEN excluded.wordCount ELSE books.wordCount END,
    coverUrl = CASE WHEN excluded.coverUrl != books.coverUrl THEN excluded.coverUrl ELSE books.coverUrl END,
    intro = CASE WHEN excluded.intro != books.intro THEN excluded.intro ELSE books.intro END,
    totalChapterNum = CASE WHEN excluded.totalChapterNum != books.totalChapterNum THEN excluded.totalChapterNum ELSE books.totalChapterNum END,
    btype = CASE WHEN excluded.btype != books.btype THEN excluded.btype ELSE books.btype END,
    isEnabled = CASE WHEN excluded.isEnabled != books.isEnabled THEN excluded.isEnabled ELSE books.isEnabled END,
    kind = CASE WHEN excluded.kind != books.kind THEN excluded.kind ELSE books.kind END;    
    ]]

    local batch_data = {}
    for index, book in ipairs(bookData) do
        batch_data[index] = {bookShelfId, book.cache_id, book.name, book.author, book.bookUrl, book.origin or "",
                             book.originName or "", book.originOrder or 0, book.durChapterIndex or 0,
                             book.durChapterPos or 0, book.durChapterTime or 0, book.durChapterTitle or "",
                             book.wordCount or 0, book.coverUrl or "", book.intro or "", book.totalChapterNum or 0,
                             book.type or 0, 1, book.kind or ''}
    end

    if batch_data and #batch_data > 0 then

        self:getDB():exec("UPDATE books SET isEnabled = 0;")

        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true

end

function M:getAllBooks(bookShelfId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, bookUrl, origin, originName, 
    originOrder, durChapterIndex, durChapterPos FROM books WHERE isEnabled = 1 AND bookShelfId = ?;
    ]]
    local result = self:execute(sql_stmt, {bookShelfId})
    local books = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            books[i] = {
                book_self_id = bookShelfId,

                cache_id = row[1],

                name = row[2],
                author = row[3],
                bookUrl = row[4],
                origin = row[5],
                originName = row[6],
                originOrder = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterPos = row[9]
            }
        end
    end

    return books
end

function M:getAllBooksByUI(bookShelfId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, originName FROM books WHERE isEnabled = 1 AND bookShelfId = ? ORDER BY sortOrder ASC;
    ]]
    local result = self:execute(sql_stmt, {bookShelfId})
    local books = {}
    if result and #result > 0 then
        for i = 1, #result, 1 do
            local row = result[i]
            books[i] = {
                cache_id = row[1],
                name = row[2],
                author = row[3],
                originName = row[4]
            }
        end
    end

    return books
end

function M:getBookinfo(bookShelfId, bookCacheId)
    if bookShelfId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT bookCacheId, name, author, bookUrl, origin, originName, 
    originOrder, durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, 
    wordCount, intro, totalChapterNum, kind FROM books WHERE isEnabled = 1 AND bookShelfId = ? AND bookCacheId =? ;
    ]]
    local result = self:execute(sql_stmt, {bookShelfId, bookCacheId})
    local book = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            book[i] = {
                book_self_id = bookShelfId,

                cache_id = row[1],

                name = row[2],
                author = row[3],
                bookUrl = row[4],
                origin = row[5],
                originName = row[6],
                originOrder = tonumber(row[7]),
                durChapterIndex = tonumber(row[8]),
                durChapterPos = tonumber(row[9]),
                durChapterTime = row[10],
                durChapterTitle = row[11],
                wordCount = row[12],
                intro = row[13],
                totalChapterNum = tonumber(row[14]),
                kind = row[15]
            }
        end
    end

    if type(book[1]) ~= 'table' then
        return {}
    end

    return book[1]
end

function M:upsertChapters(bookCacheId, chapters)
    if not H.is_str(bookCacheId) or not H.is_tbl(chapters) then
        dbg.log('BookInfoDB:upsertChapters Incorrect input parameters')
        return false
    end

    local sql_stmt = [[
        INSERT INTO chapters (bookCacheId, chapterIndex, title, isVolume)
VALUES (?, ?, ?, ?)
ON CONFLICT(bookCacheId, chapterIndex) DO UPDATE SET
    title = CASE WHEN excluded.title != chapters.title THEN excluded.title ELSE chapters.title END,
    isVolume = CASE WHEN excluded.isVolume != chapters.isVolume THEN excluded.isVolume ELSE chapters.isVolume END;
    ]]

    local batch_data = {}
    for _, chapter in pairs(chapters) do
        if chapter.index ~= nil then

            if not H.is_str(chapter.title) or chapter.title == '' then
                chapter.title = string.format('第%s章', chapter.index)
            end
            table.insert(batch_data, {bookCacheId, chapter.index, chapter.title, chapter.isVolume})

        end
    end

    if #batch_data > 0 then

        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true
end

function M:getAllChapters(bookCacheId)
    if bookCacheId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT 
    c.chapterIndex, 
    c.title, 
    c.isRead,
    c.cacheFilePath,
    b.name,
    b.author,
    b.bookUrl,
    b.durChapterIndex,
    b.durChapterTime,
    b.totalChapterNum 
FROM chapters AS c
INNER JOIN books AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? 
ORDER BY c.chapterIndex ASC;
    ]]

    local result = self:execute(sql_stmt, bookCacheId)
    local chapters = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            chapters[i] = {
                book_cache_id = bookCacheId,

                index = tonumber(row[1]),
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                bookUrl = row[7],
                durChapterIndex = tonumber(row[8]),
                durChapterTime = row[9],
                totalChapterNum = tonumber(row[10]),
                chapters_index = tonumber(row[1])
            }
        end
    end

    return chapters
end

function M:getAllChaptersByUI(bookCacheId, is_desc_sort)
    if bookCacheId == nil then
        return {}
    end
    local sql_stmt = [[
    SELECT
    c.chapterIndex, 
    c.title, 
    c.isRead, 
    c.cacheFilePath,
    b.durChapterIndex,
    strftime('%s', 'now') - b.lastUpdated AS updateIntervalTime 
FROM chapters AS c
INNER JOIN books AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? 
ORDER BY c.chapterIndex ]]

    if is_desc_sort == true then
        sql_stmt = sql_stmt .. ' DESC;'
    else
        sql_stmt = sql_stmt .. ' ASC;'
    end
    local result = self:execute(sql_stmt, bookCacheId)
    local chapters = {}
    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]
            local chapters_index = tonumber(row[1])

            chapters[i] = {

                index = chapters_index,

                title = row[2],
                isRead = row[3] == 1,
                isDownLoaded = not not row[4],
                durChapterIndex = tonumber(row[5]),
                chapters_index = chapters_index,
                cacheFilePath = row[4],
                updateIntervalTime = row[6]
            }
        end
    end

    return chapters
end

function M:getChapterCount(bookCacheId)
    local sql_stmt = "SELECT count(*) as total_num FROM chapters WHERE  bookCacheId = '%s';"
    sql_stmt = string.format(sql_stmt, bookCacheId)
    local totalChapterNum = self:getDB():rowexec(sql_stmt)
    return tonumber(totalChapterNum)
end

function M:getBookSelfLastUpdateTime(bookShelfId)
    local sql_stmt = "SELECT MAX(lastUpdated) AS max_last_updated FROM books WHERE bookShelfId = '%s';"
    sql_stmt = string.format(sql_stmt, bookShelfId)
    local lastUpdated = self:getDB():rowexec(sql_stmt)
    return tonumber(lastUpdated)
end

function M:getBookLastUpdateTime(bookShelfId, bookCacheId)
    local sql_stmt = "SELECT lastUpdated FROM books WHERE bookShelfId = '%s' AND bookCacheId = '%s';"
    sql_stmt = string.format(sql_stmt, bookShelfId, bookCacheId)
    local ok, ret = pcall(function()
        self:getDB():rowexec(sql_stmt)
    end)

    local lastUpdated = ret

    if not ok then
        lastUpdated = time.now()
    end

    return tonumber(lastUpdated)
end

function M:getChapterLastUpdateTime(bookCacheId)
    local sql_stmt = "SELECT lastUpdated FROM books WHERE isEnabled = 1 AND bookCacheId = '%s';"
    sql_stmt = string.format(sql_stmt, bookCacheId)

    local ok, ret = pcall(function()
        self:getDB():rowexec(sql_stmt)
    end)

    local lastUpdated = ret

    if not ok then
        lastUpdated = time.now()
    end
    return tonumber(lastUpdated)
end

function M:getChapterInfo(bookCacheId, chapterIndex)
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        dbg.log('getChapterInfo Incorrect input parameters')
        return {}
    end

    local sql_stmt = [[
    SELECT 
    c.chapterIndex, 
    c.title, 
    c.isRead, 
    c.cacheFilePath,
    b.name,
    b.author,
    b.bookUrl,
    b.durChapterIndex,
    b.durChapterTime,
    b.totalChapterNum,
    b.cacheExt
FROM chapters AS c
INNER JOIN books AS b
    ON c.bookCacheId = b.bookCacheId 
WHERE 
    b.isEnabled = 1 AND c.bookCacheId = ? AND c.chapterIndex = ?;
    ]]

    local result = self:execute(sql_stmt, {bookCacheId, chapterIndex})
    local chapter = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local chapterIndex = tonumber(row[1])
            local totalChapterNum = tonumber(row[10])
            local durChapterIndex = tonumber(row[8])

            chapter[i] = {
                book_cache_id = bookCacheId,

                index = chapterIndex,
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                bookUrl = row[7],
                durChapterIndex = durChapterIndex,
                durChapterTime = row[9],
                totalChapterNum = totalChapterNum,

                chapters_index = chapterIndex,
                cacheExt = row[11]
            }
        end
    end

    if not H.is_tbl(chapter[1]) then
        return {}
    end

    return chapter[1]
end

function M:getcompleteReadAheadChapters(current_chapter)

    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log('getcompleteReadAheadChapters:', current_chapter)
        return 0
    end

    local bookCacheId = current_chapter.book_cache_id
    local current_chapters_index = current_chapter.chapters_index
    local call_event_type = current_chapter.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = ''
    if call_event_type == 'next' then
        sql_stmt = [[
SELECT COUNT(*) AS continuous_count
FROM chapters AS c
WHERE 
  c.chapterIndex > %d        
  AND c.cacheFilePath IS NOT NULL 
  AND c.bookCacheId = '%s'   
  AND c.chapterIndex < COALESCE(
      (SELECT MIN(chapterIndex) 
       FROM chapters 
       WHERE chapterIndex > %d  
         AND cacheFilePath IS NULL 
         AND bookCacheId = '%s'   
      ),
      (SELECT MAX(chapterIndex) + 1 
       FROM chapters 
       WHERE bookCacheId = '%s'  
      )
  )
  AND EXISTS (
      SELECT 1 FROM books AS b 
      WHERE b.bookCacheId = c.bookCacheId 
        AND b.isEnabled = 1
  );
  ]]

        sql_stmt = string.format(sql_stmt, current_chapters_index, bookCacheId, current_chapters_index, bookCacheId,
            bookCacheId)
    else

        sql_stmt = [[
                    SELECT COUNT(*) AS continuous_count
FROM chapters AS c
WHERE 
  c.chapterIndex < %d       
  AND c.cacheFilePath IS NOT NULL 
  AND c.bookCacheId = '%s'   
  AND c.chapterIndex > COALESCE(
      (SELECT MAX(chapterIndex) 
       FROM chapters 
       WHERE chapterIndex < %d 
         AND cacheFilePath IS NULL 
         AND bookCacheId = '%s'
      ),
      (SELECT MIN(chapterIndex) - 1 
       FROM chapters 
       WHERE bookCacheId = '%s'
      )
  )
  AND EXISTS (
      SELECT 1 FROM books AS b 
      WHERE b.bookCacheId = c.bookCacheId 
        AND b.isEnabled = 1
  );

    ]]
        sql_stmt = string.format(sql_stmt, current_chapters_index, bookCacheId, current_chapters_index, bookCacheId,
            bookCacheId)
    end
    local continuous_count = self:getDB():rowexec(sql_stmt)
    return tonumber(continuous_count)

end

function M:findChapterNotDownLoadLittle(current_chapter, count)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log('findChapterNotDownLoadLittle:', current_chapter)
        return {}
    end

    if not H.is_num(count) or count < 1 then
        count = 1
    end

    local bookCacheId = current_chapter.book_cache_id
    local current_chapters_index = current_chapter.chapters_index
    local call_event_type = current_chapter.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = [[
        SELECT 
        c.chapterIndex, 
        c.title, 
        b.bookUrl
    FROM chapters AS c
    INNER JOIN books AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
         c.bookCacheId = ? AND b.isEnabled = 1 AND c.isRead = 0 AND c.cacheFilePath IS NULL
         ]]

    local suffix = "  AND c.chapterIndex > ?  ORDER BY c.chapterIndex ASC LIMIT "

    if call_event_type ~= 'next' then
        suffix = "  AND c.chapterIndex < ? ORDER BY c.chapterIndex DESC LIMIT "
    end

    sql_stmt = table.concat({sql_stmt, suffix, count, ';'})

    local result = self:execute(sql_stmt, {bookCacheId, current_chapters_index})

    local chapters = {}
    if result and #result > 0 then
        for i = 1, #result, 1 do
            local row = result[i]
            local chapterIndex = tonumber(row[1])
            chapters[i] = {
                book_cache_id = bookCacheId,
                index = chapterIndex,
                title = row[2],
                bookUrl = row[3],
                chapters_index = chapterIndex

            }
        end
    end

    if not H.is_tbl(chapters[1]) then
        return {}
    end

    return chapters

end

function M:findNextChapterInfo(current_chapter, is_downloaded)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        dbg.log('findNextChapterInfo:', current_chapter)
        return {}
    end

    local bookCacheId = current_chapter.book_cache_id
    local current_chapters_index = current_chapter.chapters_index
    local call_event_type = current_chapter.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = [[
        SELECT 
        c.chapterIndex, 
        c.title, 
        c.isRead, 
        c.cacheFilePath,
        b.name,
        b.author,
        b.bookUrl,
        b.durChapterIndex,
        b.durChapterTime,
        b.totalChapterNum,
        b.cacheExt
    FROM chapters AS c
    INNER JOIN books AS b
        ON c.bookCacheId = b.bookCacheId 
    WHERE 
         c.bookCacheId = ? AND b.isEnabled = 1 ]]

    if is_downloaded == false then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NULL '
    elseif is_downloaded == true then
        sql_stmt = sql_stmt .. ' AND c.cacheFilePath IS NOT NULL '
    end

    local suffix = "  AND c.chapterIndex > ?  ORDER BY c.chapterIndex ASC LIMIT 1;"
    if call_event_type ~= 'next' then

        suffix = "  AND c.chapterIndex < ? ORDER BY c.chapterIndex DESC LIMIT 1;"
    end

    sql_stmt = sql_stmt .. suffix

    local result = self:execute(sql_stmt, {bookCacheId, current_chapters_index})

    local chapter = {}

    if result and #result > 0 then

        for i = 1, #result, 1 do
            local row = result[i]

            local chapterIndex = tonumber(row[1])
            local totalChapterNum = tonumber(row[10])
            local durChapterIndex = tonumber(row[8])

            chapter[i] = {
                book_cache_id = bookCacheId,

                index = chapterIndex,
                title = row[2],
                isRead = row[3] == 1,
                cacheFilePath = row[4],
                isDownLoaded = not not row[4],
                name = row[5],
                author = row[6],
                bookUrl = row[7],
                durChapterIndex = durChapterIndex,
                durChapterTime = row[9],
                totalChapterNum = totalChapterNum,
                chapters_index = chapterIndex,
                cacheExt = row[11]
            }
        end
    end

    if not H.is_tbl(chapter[1]) then
        return {}
    end

    return chapter[1]
end

function M:updateIsRead(chapter, isRead)
    local bookCacheId = chapter.book_cache_id
    local chapterIndex = chapter.chapters_index
    chapter.isRead = isRead

    local sql_stmt = "UPDATE chapters SET isRead = ? WHERE bookCacheId = ? AND chapterIndex = ? ;"

    local params = {isRead, bookCacheId, chapterIndex}
    return self:execute(sql_stmt, params)
end

function M:updateDownloadState(chapter, is_downloaded)
    local content = ''
    if is_downloaded == true then
        content = 'downloaded'
    elseif is_downloaded == nil or is_downloaded == false then
        content = self.nil_object()
    else
        content = is_downloaded
    end

    return self:dynamicUpdateChapters(chapter, {
        content = content
    })
end

function M:updateCacheFilePath(chapter, cacheFilePath)

    local cacheFilePath_add = ''
    if type(cacheFilePath) == 'string' then
        cacheFilePath_add = cacheFilePath
    else
        cacheFilePath_add = self.nil_object()
    end

    return self:dynamicUpdateChapters(chapter, {
        cacheFilePath = cacheFilePath_add
    })
end

function M:isDownloaded(bookCacheId, chapterIndex)
    local sql_stmt = [[
        SELECT 1 
        FROM chapters
        WHERE bookCacheId = '%s'
          AND chapterIndex = %d AND cacheFilePath IS NOT NULL;
    ]]

    sql_stmt = string.format(sql_stmt, bookCacheId, chapterIndex)

    local ok, ret = pcall(function()
        self:getDB():rowexec(sql_stmt)
    end)
    local is_downed = ret == 1
    if not ok then
        is_downed = false
    end
    return is_downed
end

function M:cleanDownloading()
    local sql_stmt = [[
    UPDATE chapters 
SET content = NULL 
WHERE 
  content = 'downloading_' AND
  cacheFilePath IS NULL;
    ]]
    return self:getDB():exec(sql_stmt)
end

function M:isDownloading(bookCacheId, chapterIndex)
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        dbg.log('Db isDownloading Error parameters')
        return true
    end

    local sql_stmt = [[
        SELECT  1 
        FROM chapters
        WHERE bookCacheId = '%s'
          AND chapterIndex = %d AND content = 'downloading_';
    ]]

    sql_stmt = string.format(sql_stmt, bookCacheId, chapterIndex)
    local ok, ret = pcall(function()
        self:getDB():rowexec(sql_stmt)
    end)
    local is_downing = ret == 1

    if not ok then
        is_downing = true
    end
    return is_downing
end

function M:clearBooks(bookShelfId)
    if not H.is_str(bookShelfId) then
        dbg.log('DB clearBooks error')
        return false
    end

    self:dynamicUpdate('books', {
        isEnabled = 0
    }, {
        bookShelfId = bookShelfId
    })
    return true
end

function M:clearBook(bookShelfId, book_cache_id)

    if not H.is_str(bookShelfId) or not H.is_str(book_cache_id) then
        dbg.log('DB clearBook error')
        return false
    end

    self:dynamicUpdate('books', {
        isEnabled = 0
    }, {
        bookShelfId = bookShelfId,
        bookCacheId = book_cache_id
    })

    self:dynamicUpdate('chapters', {
        cacheFilePath = self.nil_object(),
        content = self.nil_object()

    }, {
        bookCacheId = book_cache_id
    })

    return true
end

function M:dynamicUpdateChapters(chapter, updateData)
    if not H.is_tbl(updateData) or not H.is_tbl(chapter) then
        dbg.log('dynamicUpdateChapters Required parameter error')
        return
    end

    local bookCacheId = chapter.book_cache_id
    local chapterIndex = chapter.chapters_index

    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        dbg.log('dynamicUpdateChapters Required parameter error')
        error('dynamicUpdateChapters Required parameter error')
        return
    end

    return self:dynamicUpdate('chapters', updateData, {
        bookCacheId = bookCacheId,
        chapterIndex = chapterIndex
    })

end

function M:dynamicUpdateBooks(book, updateData)
    if not H.is_tbl(updateData) or not H.is_tbl(book) then
        dbg.log('dynamicUpdateBooks An error occurred when calling the parameter')
        return
    end

    local bookCacheId = book.book_cache_id
    local bookShelfId = book.bookShelfId

    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        dbg.log('dynamicUpdateBooks Error parameters')
        error('dynamicUpdateBooks Error parameters')
        return
    end

    return self:dynamicUpdate('books', updateData, {
        bookCacheId = bookCacheId,
        bookShelfId = bookShelfId
    })
end

function M:setBooksTopUp(bookShelfId, bookCacheId)

    self:dynamicUpdate('books', {
        sortOrder = 1
    }, {
        bookShelfId = bookShelfId
    })

    self:dynamicUpdate('books', {
        sortOrder = 0
    }, {
        bookCacheId = bookCacheId,
        bookShelfId = bookShelfId
    })
    return true
end

function M:dynamicUpdate(tableName, updateData, conditions)
    if not H.is_tbl(updateData) or not H.is_str(tableName) then
        error('Error entering necessary parameters')
        return
    end

    local set_clause = {}
    local params = {}
    local param_count = 0

    for key, value in pairs(updateData) do

        table.insert(set_clause, key .. " = ?")

        if value == '_NULL' then

            value = self.nil_object()
        end

        table.insert(params, value)
        param_count = param_count + 1
    end

    if param_count < 1 then
        return
    end

    local where_clause = ""
    if H.is_tbl(conditions) then
        local where_parts = {}
        for field, value in pairs(conditions) do
            if value == '_NULL' then
                table.insert(where_parts, string.format("%s IS NULL", field))
            elseif H.is_tbl(value) and not H.is_str(value._where) then

                table.insert(where_parts, value._where)
            else
                table.insert(where_parts, string.format("%s = ?", field))
                table.insert(params, value)
            end
        end

        if #where_parts > 0 then
            where_clause = " WHERE " .. table.concat(where_parts, " AND ")
        end

    end

    local sql_stmt = table.concat({"UPDATE ", tableName, " SET ", table.concat(set_clause, ", "), where_clause})

    return self:execute(sql_stmt, params)
end

function M:getDownloadProgress(bookCacheId, target_indexes)

    local sql_template =
        "SELECT COUNT(*) AS total_count FROM chapters WHERE content = 'downloaded' AND chapterIndex IN (%s) AND bookCacheId='%s';"

    local function generate_placeholders(arr)
        local validated = {}
        for _, v in ipairs(arr) do
            table.insert(validated, tostring(v))
        end
        return table.concat(validated, ",")
    end

    local query = string.format(sql_template, generate_placeholders(target_indexes), bookCacheId)

    local ret = self:getDB():rowexec(query)
    ret = tonumber(ret)

    return ret
end

return M
