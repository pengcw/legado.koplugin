local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local Device = require("device")
local util = require("util")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local BookSourceLogin = require("Legado.Helper.BookSourceLogin")
local rapidjson = require("rapidjson")

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

local BOOKINFO_DB_VERSION = 20261012

local function encode_variable(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    if type(value) ~= "table" then return nil end
    local ok, encoded = pcall(rapidjson.encode, value)
    return ok and type(encoded) == "string" and encoded or nil
end

local BOOKINFO_DB_EXTENDED_SCHEMA = [[
CREATE TABLE IF NOT EXISTS book_sources (
    bookShelfId TEXT NOT NULL DEFAULT 'local',
    bookSourceUrl TEXT NOT NULL,
    bookSourceName TEXT NOT NULL,
    bookSourceGroup TEXT DEFAULT NULL,
    bookSourceType INTEGER DEFAULT 0,
    customOrder INTEGER DEFAULT 0,
    weight INTEGER DEFAULT 0,
    enabled INTEGER DEFAULT 1,
    enabledExplore INTEGER DEFAULT 1,
    lastUpdateTime INTEGER DEFAULT 0,
    dynamicHeader TEXT DEFAULT NULL,
    dynamicVariables TEXT DEFAULT NULL,
    loginData TEXT DEFAULT NULL,
    session TEXT DEFAULT NULL,
    concurrentRate TEXT DEFAULT NULL,
    enabledCookieJar INTEGER DEFAULT 0,
    enabledReview INTEGER DEFAULT 0,
    respondTime INTEGER DEFAULT 0,
    bookUrlPattern TEXT DEFAULT NULL,
    header TEXT DEFAULT NULL,
    loginUrl TEXT DEFAULT NULL,
    loginCheckJs TEXT DEFAULT NULL,
    jsLib TEXT DEFAULT NULL,
    ext1 TEXT DEFAULT NULL,
    ext2 TEXT DEFAULT NULL,
    rawJson TEXT NOT NULL,
    summaryJson TEXT DEFAULT NULL,
    PRIMARY KEY (bookShelfId, bookSourceUrl)
);

CREATE TABLE IF NOT EXISTS text_transform_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bookShelfId TEXT NOT NULL DEFAULT 'local',
    ruleKey TEXT NOT NULL,
    name TEXT NOT NULL,
    groupName TEXT DEFAULT NULL,
    pattern TEXT NOT NULL,
    replacement TEXT NOT NULL DEFAULT '',
    scope TEXT DEFAULT NULL,
    excludeScope TEXT DEFAULT NULL,
    scopeTitle INTEGER DEFAULT NULL,
    scopeContent INTEGER DEFAULT NULL,
    isEnabled INTEGER NOT NULL DEFAULT 1,
    isRegex INTEGER NOT NULL,
    timeoutMs INTEGER DEFAULT NULL,
    orderIndex INTEGER NOT NULL DEFAULT 0,
    rawJson TEXT DEFAULT NULL,
    UNIQUE (bookShelfId, ruleKey)
);

CREATE TABLE IF NOT EXISTS sync_records (
    scopeType TEXT NOT NULL DEFAULT 'bookshelf',
    scopeId TEXT NOT NULL,
    resourceType TEXT NOT NULL,
    resourceKey TEXT NOT NULL DEFAULT '',
    lastAttemptAt INTEGER NOT NULL DEFAULT 0,
    lastSuccessAt INTEGER NOT NULL DEFAULT 0,
    lastItemCount INTEGER NOT NULL DEFAULT 0,
    lastError TEXT DEFAULT NULL,
    extraJson TEXT DEFAULT NULL,
    PRIMARY KEY (scopeType, scopeId, resourceType, resourceKey)
);

CREATE INDEX IF NOT EXISTS idx_book_sources_shelf ON book_sources (bookShelfId, enabled, customOrder);
CREATE INDEX IF NOT EXISTS idx_text_transform_rules_shelf ON text_transform_rules (bookShelfId, isEnabled, orderIndex);
CREATE INDEX IF NOT EXISTS idx_sync_records_scope ON sync_records (scopeType, scopeId, resourceType, lastSuccessAt);
]]

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
    variable TEXT DEFAULT NULL,
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


CREATE TABLE IF NOT EXISTS task_locks (
    lock_name TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL DEFAULT 'main',
    acquire_time INTEGER DEFAULT (CAST(strftime('%s', 'now') AS INTEGER)),
    expire_time INTEGER NOT NULL
);


CREATE TABLE IF NOT EXISTS chapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,       
    bookCacheId TEXT NOT NULL,                    
    chapterIndex INTEGER NOT NULL,    
    title TEXT DEFAULT '',             
    chapterUrl TEXT DEFAULT NULL,
    variable TEXT DEFAULT NULL,
    isVolume INTEGER DEFAULT 0, 
    
    
    isRead INTEGER DEFAULT 0,       
    cacheFilePath TEXT DEFAULT NUll,   
    content TEXT DEFAULT NUll,          
    lastUpdated INTEGER DEFAULT 0, 

    
    UNIQUE (bookCacheId, chapterIndex)
);

CREATE INDEX IF NOT EXISTS idx_book_main ON books (bookShelfId, bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_books_bookCacheId_isenabled ON books (bookCacheId, isEnabled);
CREATE INDEX IF NOT EXISTS idx_chapter_basic ON chapters (bookCacheId, chapterIndex);
CREATE INDEX IF NOT EXISTS idx_book_sortorder_Lastread ON books ( sortOrder );
CREATE INDEX IF NOT EXISTS idx_books_bookshelfid_isenabled_sortorder ON books (bookShelfId, isEnabled, sortOrder);
CREATE INDEX IF NOT EXISTS idx_chapters_chapterindex ON chapters (chapterIndex);
CREATE INDEX IF NOT EXISTS idx_chapters_cachefilepath ON chapters (cacheFilePath);
CREATE INDEX IF NOT EXISTS idx_chapters_bookcacheid_lastupdated ON chapters (bookCacheId, lastUpdated);
CREATE INDEX IF NOT EXISTS idx_task_locks_expire ON task_locks (expire_time);
]] .. BOOKINFO_DB_EXTENDED_SCHEMA

local COLS_BOOK_FULL = "bookCacheId, name, author, bookUrl, origin, originName, originOrder, durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, wordCount, intro, totalChapterNum, kind, sortOrder, cacheExt, coverUrl, btype, variable"
local COLS_BOOK_INFO = COLS_BOOK_FULL .. ", bs.concurrentRate, bs.respondTime"
local function _mapBookRow(row, bookShelfId)
    if not row then return nil end
    return {
        book_self_id = bookShelfId,
        cache_id = row[1],
        name = row[2],
        author = row[3],
        bookUrl = row[4],
        origin = row[5],
        originName = row[6],
        originOrder = tonumber(row[7]) or 0,
        durChapterIndex = tonumber(row[8]) or 0,
        durChapterPos = tonumber(row[9]) or 0,
        durChapterTime = tonumber(row[10]) or 0,
        durChapterTitle = row[11] or "",
        wordCount = row[12] or "",
        intro = row[13] or "",
        totalChapterNum = tonumber(row[14]) or 0,
        kind = row[15] or "",
        sortOrder = tonumber(row[16]) or 0,
        cacheExt = row[17],
        coverUrl = row[18],
        btype = tonumber(row[19]),
        variable = row[20]
    }
end

local function _mapBookInfoRow(row, bookShelfId)
    local book = _mapBookRow(row, bookShelfId)
    if book then
        book.concurrentRate = row[21]
        book.respondTime = tonumber(row[22]) or 0
    end
    return book
end

local COLS_CHAPTER_FULL = "c.chapterIndex, c.title, c.isRead, c.cacheFilePath, b.name, b.author, b.bookUrl, b.durChapterIndex, b.durChapterTime, b.totalChapterNum, b.cacheExt, b.origin, c.chapterUrl, c.isVolume, c.variable, b.variable"
local function _mapChapterRow(row, bookCacheId)
    if not row then return nil end
    return {
        book_cache_id = bookCacheId,
        chapters_index = tonumber(row[1]) or 0,
        title = row[2] or "",
        isRead = row[3] == 1,
        cacheFilePath = row[4],
        isDownLoaded = not not row[4],
        name = row[5],
        author = row[6],
        bookUrl = row[7],
        durChapterIndex = tonumber(row[8]) or 0,
        durChapterTime = tonumber(row[9]) or 0,
        totalChapterNum = tonumber(row[10]) or 0,
        cacheExt = row[11],
        origin = row[12],
        url = row[13],
        chapterUrl = row[13],
        isVolume = row[14] == 1,
        variable = row[15],
        bookVariable = row[16]
    }
end

local COLS_BOOK_UI = "bookCacheId, name, author, originName, coverUrl"
local function _mapBookRowUI(row)
    if not row then return nil end
    return {
        cache_id = row[1],
        name = row[2],
        author = row[3],
        originName = row[4],
        cover = row[5],
    }
end

local COLS_CHAPTER_UI = "c.chapterIndex, c.title, c.isRead, c.cacheFilePath, b.durChapterIndex, c.isVolume"
local function _mapChapterRowUI(row)
    if not row then return nil end
    return {
        chapters_index = tonumber(row[1]) or 0,
        title = row[2] or "",
        isRead = row[3] == 1,
        isDownLoaded = not not row[4],
        durChapterIndex = tonumber(row[5]) or 0,
        cacheFilePath = row[4],
        isVolume = row[6] == 1
    }
end

local COLS_CHAPTER_NOT_DOWNLOADED = "c.chapterIndex, c.title, b.bookUrl, b.name, b.origin, c.chapterUrl, c.variable, b.variable"
local function _mapChapterNotDownloadedRow(row, bookCacheId)
    if not row then return nil end
    return {
        book_cache_id = bookCacheId,
        chapters_index = tonumber(row[1]) or 0,
        title = row[2],
        bookUrl = row[3],
        name = row[4],
        origin = row[5],
        url = row[6],
        chapterUrl = row[6],
        variable = row[7],
        bookVariable = row[8],
    }
end

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
    if not util.fileExists(self.dbPath) then
        self:_initDB()
    end
end

function M.nil_object()
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
        logger.dbg("Database journal mode set to: " .. mode)
    else
        logger.dbg("Failed to set journal mode. Error: " .. tostring(err))
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
        logger.dbg("Failed to open database at: " .. self.dbPath)
        error("Failed to open database at: " .. self.dbPath)
        return nil
    end

    self.db = db
    self.isConnected = true
    self.in_transaction = false

    self.db:set_busy_timeout(5000)

    logger.dbg("Database opened successfully at: " .. self.dbPath)

    self:_setJournalMode()

    return self.db
end

function M:initializeSchema()
    self:getDB():exec(BOOKINFO_DB_SCHEMA)
end

local MIGRATION_COLUMNS = {
    books = { "variable TEXT DEFAULT NULL" },
    chapters = { "chapterUrl TEXT DEFAULT NULL", "variable TEXT DEFAULT NULL" },
    book_sources = {
        "concurrentRate TEXT DEFAULT NULL", "enabledCookieJar INTEGER DEFAULT 0",
        "enabledReview INTEGER DEFAULT 0", "respondTime INTEGER DEFAULT 0",
        "bookUrlPattern TEXT DEFAULT NULL", "header TEXT DEFAULT NULL",
        "loginUrl TEXT DEFAULT NULL", "loginCheckJs TEXT DEFAULT NULL",
        "jsLib TEXT DEFAULT NULL", "ext1 TEXT DEFAULT NULL", "ext2 TEXT DEFAULT NULL",
        "session TEXT DEFAULT NULL", "summaryJson TEXT DEFAULT NULL",
    },
}

local function _migrate_stage(conn, version, apply)
    local cur = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if cur >= version then return end
    conn:exec("BEGIN IMMEDIATE;")
    local ok, err = pcall(function()
        local locked_cur = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
        if locked_cur >= version then return end
        apply()
        conn:exec("PRAGMA user_version=" .. version .. ";")
    end)
    if ok then
        ok, err = pcall(function() conn:exec("COMMIT;") end)
    end
    if not ok then
        pcall(function() conn:exec("ROLLBACK;") end)
        error(err, 0)
    end
end

function M:_migrateDB()
    local conn = (self.getDB and self:getDB()) or self.db
    if not conn then return end
    local current_ver = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if current_ver >= BOOKINFO_DB_VERSION then return end

    _migrate_stage(conn, 20261010, function()
        self:initializeSchema()
        for table_name, definitions in pairs(MIGRATION_COLUMNS) do
            local existing = {}
            local stmt = conn:prepare("PRAGMA table_info(" .. table_name .. ");")
            for row in stmt:rows() do existing[row[2]] = true end
            stmt:close()
            for _, definition in ipairs(definitions) do
                local col_name = definition:match("^(%S+)")
                if col_name and not existing[col_name] then
                    conn:exec("ALTER TABLE " .. table_name .. " ADD COLUMN " .. definition .. ";")
                end
            end
        end
    end)

    _migrate_stage(conn, 20261011, function()
        while true do
            local rows = self:execute([[SELECT bookShelfId, bookSourceUrl, rawJson
                FROM book_sources WHERE summaryJson IS NULL LIMIT 32]])
            if not rows or #rows == 0 then break end
            for _, row in ipairs(rows) do
                local decoded, source = pcall(rapidjson.decode, row[3])
                local summary = "null"
                if decoded and type(source) == "table" then
                    summary = rapidjson.encode({
                        exploreUrl = source.exploreUrl, loginUi = source.loginUi, loginUrl = source.loginUrl,
                        session = BookSourceLogin.hasNonemptyValue(source.session) and 1 or nil,
                        loginData = BookSourceLogin.hasNonemptyValue(source.loginData) and 1 or nil,
                    })
                end
                self:execute([[UPDATE book_sources SET summaryJson = ?
                    WHERE bookShelfId = ? AND bookSourceUrl = ?]], { summary, row[1], row[2] })
            end
        end
    end)

    _migrate_stage(conn, 20261012, function()
        conn:exec([[
            UPDATE books SET
                durChapterIndex = (SELECT chapterIndex FROM chapters
                    WHERE bookCacheId = books.bookCacheId AND isRead = 1
                    ORDER BY lastUpdated DESC, chapterIndex DESC LIMIT 1),
                durChapterTitle = (SELECT title FROM chapters
                    WHERE bookCacheId = books.bookCacheId AND isRead = 1
                    ORDER BY lastUpdated DESC, chapterIndex DESC LIMIT 1),
                durChapterTime = (SELECT COALESCE(lastUpdated, 0) * 1000 FROM chapters
                    WHERE bookCacheId = books.bookCacheId AND isRead = 1
                    ORDER BY lastUpdated DESC, chapterIndex DESC LIMIT 1)
            WHERE COALESCE(durChapterTime, 0) = 0 AND COALESCE(durChapterIndex, 0) = 0
                AND EXISTS (SELECT 1 FROM chapters WHERE bookCacheId = books.bookCacheId AND isRead = 1);
        ]])
    end)
end

local function _is_corrupt_error(err)
    if not err then return false end
    local s = tostring(err):lower()
    return s:find("not a database", 1, true) ~= nil
        or s:find("malformed", 1, true) ~= nil
        or s:find("corrupt", 1, true) ~= nil
        or s:find("unsupported file format", 1, true) ~= nil
end

function M:_initDB(is_repair)
    local db
    local success, rc = pcall(function()
        db = self:_openDB()
        db:exec(BOOKINFO_DB_SCHEMA)
        return db:exec("PRAGMA user_version=" .. BOOKINFO_DB_VERSION .. ";")
    end)
    if success then
        logger.dbg("Database schema initialized successfully.")
        self.dbCreated = true
        self:closeDB()
    else
        logger.dbg("Failed to initialize database schema. Return code: " .. tostring(rc))
        self:closeDB()
        local last_backup_db = self.dbPath .. ".bak"
        local has_backup = util.fileExists(last_backup_db)
        if has_backup then
            FS.copyFileFromTo(last_backup_db, self.dbPath)
            util.removeFile(last_backup_db)
            if util.fileExists(self.dbPath .. "-wal") then util.removeFile(self.dbPath .. "-wal") end
            if util.fileExists(self.dbPath .. "-shm") then util.removeFile(self.dbPath .. "-shm") end
            logger.dbg("The backup database has been restored")
        else
            if util.fileExists(self.dbPath) then
                util.removeFile(self.dbPath)
                if util.fileExists(self.dbPath .. "-wal") then util.removeFile(self.dbPath .. "-wal") end
                if util.fileExists(self.dbPath .. "-shm") then util.removeFile(self.dbPath .. "-shm") end
                logger.dbg("Removed corrupt database file")
            end
            if not is_repair then
                self:_initDB(true)
            end
        end
    end
end

function M:closeDB()
    if not self.isConnected or not self.db then
        return
    end

    local success = pcall(function()
        return self.db:close()
    end)
    if not success then
    end
    self.db = nil
    self.isConnected = nil
end

function M:getDB()
    if self.is_closing or self._suppress_db then
        return nil
    end
    if not util.fileExists(self.dbPath) then
        self:_initDB()
    end
    if not self.isConnected or not self.db then
        local ok, db_or_err = pcall(function()
            local d = self:_openDB()
            self:_migrateDB()
            return d
        end)
        if not ok then
            local err_str = tostring(db_or_err)
            if not self._in_repair and _is_corrupt_error(err_str) then
                logger.warn("BookInfoDB: detected corrupt database, triggering repair:", err_str)
                self._in_repair = true
                self:closeDB()
                self:_initDB()
                if not util.fileExists(self.dbPath) then
                    self:_initDB()
                end
                self._in_repair = nil
                local clean_db = self:_openDB()
                self:_migrateDB()
                return clean_db
            end
            error(db_or_err, 0)
        end
        return db_or_err
    end
    return self.db
end

function M:transaction(write_func, opts)
    return function(...)
        local conn = self:getDB()
        if not (conn and self.isConnected) then
            error("Database connection not available", 0)
        end
        local depth = self._txn_depth or 0
        self._txn_depth = depth
        local nested = depth > 0 or self.in_transaction == true
        local savepoint = nested and string.format("sp_%08x", math.random(0x7fffffff))
        local begin = nested and ("SAVEPOINT " .. savepoint)
            or ("BEGIN " .. ((opts and opts.transaction_type) or "IMMEDIATE") .. " TRANSACTION")

        conn:exec(begin)
        self._txn_depth = depth + 1
        self.in_transaction = true
        local ok, result = xpcall(function(...)
            return write_func(...)
        end, function(err)
            return debug.traceback(tostring(err), 2)
        end, ...)

        if ok then
            local finished, finish_err = pcall(function()
                conn:exec(nested and ("RELEASE " .. savepoint) or "COMMIT")
            end)
            if not finished then ok, result = false, finish_err end
        end
        if not ok then
            local cleaned, cleanup_err = pcall(function()
                if nested then
                    conn:exec("ROLLBACK TO " .. savepoint)
                    conn:exec("RELEASE " .. savepoint)
                else
                    conn:exec("ROLLBACK")
                end
            end)
            if not cleaned then
                self:closeDB()
                self._txn_depth = 0
                self.in_transaction = false
                error(tostring(result) .. "\nRollback failed: " .. tostring(cleanup_err), 0)
            end
        end
        self._txn_depth = depth
        self.in_transaction = nested
        if not ok then error(result, 0) end
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

    local _, param_count = sql_template:gsub("%?", "")

    local function process_batch(batch_data)
        return self:transaction(function()
            local stmt = self:getDB():prepare(sql_template)

            for _, params in ipairs(batch_data) do
                for i = 1, param_count do
                    stmt:bind1(i, adapt_value(params[i]))
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
            enable_savepoint = true
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

function M:upsertBooks(bookShelfId, legado_data, isUpdate)
    if not H.is_str(bookShelfId) or not H.is_tbl(legado_data) then
        logger.dbg('BookInfoDB:upsertBooks Incorrect input parameters')
        return false
    end

    local sql_stmt = [[
    INSERT INTO books (
    bookShelfId, bookCacheId, name, author, bookUrl, origin, originName, originOrder, 
    durChapterIndex, durChapterPos, durChapterTime, durChapterTitle, wordCount, 
    coverUrl, intro, totalChapterNum, btype, isEnabled, kind, variable
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(bookShelfId, bookCacheId) DO UPDATE SET
    name = CASE WHEN excluded.name != books.name THEN excluded.name ELSE books.name END,
    author = CASE WHEN excluded.author != books.author THEN excluded.author ELSE books.author END,
    bookUrl = CASE WHEN excluded.bookUrl != books.bookUrl THEN excluded.bookUrl ELSE books.bookUrl END,
    origin = CASE WHEN excluded.origin != books.origin THEN excluded.origin ELSE books.origin END,
    originName = CASE WHEN excluded.originName != books.originName THEN excluded.originName ELSE books.originName END,
    originOrder = CASE WHEN excluded.originOrder != books.originOrder THEN excluded.originOrder ELSE books.originOrder END,
    durChapterIndex = CASE WHEN COALESCE(excluded.durChapterTime, 0) >= COALESCE(books.durChapterTime, 0) THEN excluded.durChapterIndex ELSE books.durChapterIndex END,
    durChapterPos = CASE WHEN COALESCE(excluded.durChapterTime, 0) >= COALESCE(books.durChapterTime, 0) THEN excluded.durChapterPos ELSE books.durChapterPos END,
    durChapterTime = CASE WHEN COALESCE(excluded.durChapterTime, 0) >= COALESCE(books.durChapterTime, 0) THEN excluded.durChapterTime ELSE books.durChapterTime END,
    durChapterTitle = CASE WHEN COALESCE(excluded.durChapterTime, 0) >= COALESCE(books.durChapterTime, 0) THEN excluded.durChapterTitle ELSE books.durChapterTitle END,
    wordCount = CASE WHEN excluded.wordCount != books.wordCount THEN excluded.wordCount ELSE books.wordCount END,
    coverUrl = CASE WHEN excluded.coverUrl != books.coverUrl THEN excluded.coverUrl ELSE books.coverUrl END,
    intro = CASE WHEN excluded.intro != books.intro THEN excluded.intro ELSE books.intro END,
    totalChapterNum = CASE WHEN excluded.totalChapterNum != books.totalChapterNum THEN excluded.totalChapterNum ELSE books.totalChapterNum END,
    btype = CASE WHEN excluded.btype >= 0 AND excluded.btype != books.btype THEN excluded.btype ELSE books.btype END,
    isEnabled = CASE WHEN excluded.isEnabled != books.isEnabled THEN excluded.isEnabled ELSE books.isEnabled END,
    kind = CASE WHEN excluded.kind != books.kind THEN excluded.kind ELSE books.kind END,
    variable = CASE
        WHEN excluded.origin != books.origin THEN excluded.variable
        WHEN excluded.variable IS NOT NULL AND excluded.variable != '' THEN excluded.variable
        ELSE books.variable
    END,
    lastUpdated = CASE WHEN (
    excluded.bookUrl != books.bookUrl OR
    excluded.wordCount != books.wordCount
) THEN strftime('%s', 'now') ELSE books.lastUpdated END
    ]]

    local batch_data = {}
    for _, item in ipairs(legado_data) do
        local name = H.is_str(item.name) and util.trim(item.name) or ""
        local author = tostring(item.author)
        local bookUrl = item.bookUrl

        if name ~= "" and H.is_str(bookUrl) then
            local show_book_title = ("%s (%s)"):format(name, author)
            item.cache_id = tostring(H.md5(show_book_title))

            table.insert(batch_data, {
                bookShelfId, item.cache_id, name, author, bookUrl, item.origin or "",
                item.originName or "", item.originOrder or 0, item.durChapterIndex or 0,
                item.durChapterPos or 0, item.durChapterTime or 0, item.durChapterTitle or "",
                item.wordCount or "", item.coverUrl or "", item.intro or "", item.totalChapterNum or 0,
                item.type ~= nil and item.type or (item.btype ~= nil and item.btype or -1), 1, item.kind or '',
                encode_variable(item.variable)
            })
        end
    end

    if #batch_data > 0 then
        if isUpdate ~= true then
            self:disableAllBookShelves()
        end
        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true
end

function M:getAllBooks(bookShelfId)
    if not H.is_str(bookShelfId) then
        return {}
    end
    local sql_stmt = string.format("SELECT %s FROM books WHERE isEnabled = 1 AND bookShelfId = ?;", COLS_BOOK_FULL)
    local result = self:execute(sql_stmt, {bookShelfId})
    local books = {}
    if result then
        for i = 1, #result do
            books[i] = _mapBookRow(result[i], bookShelfId)
        end
    end

    return books
end

function M:getAllBooksByUI(bookShelfId)
    if not H.is_str(bookShelfId) then
        return {}
    end
    local sql_stmt = string.format("SELECT %s FROM books WHERE isEnabled = 1 AND bookShelfId = ? ORDER BY sortOrder = 0 DESC, sortOrder DESC;", COLS_BOOK_UI)
    local result = self:execute(sql_stmt, {bookShelfId})
    local books = {}
    if result then
        for i = 1, #result do
            books[i] = _mapBookRowUI(result[i])
        end
    end

    return books
end

function M:getBookinfo(bookShelfId, bookCacheId)
    if not H.is_str(bookShelfId) or not H.is_str(bookCacheId) then
        return {}
    end
    local sql_stmt = string.format([[
        SELECT %s
        FROM books AS b
        LEFT JOIN book_sources AS bs
            ON bs.bookShelfId = b.bookShelfId AND bs.bookSourceUrl = b.origin
        WHERE b.isEnabled = 1 AND b.bookShelfId = ? AND b.bookCacheId = ?;
    ]], COLS_BOOK_INFO)
    local result = self:execute(sql_stmt, {bookShelfId, bookCacheId})

    if result and #result > 0 then
        return _mapBookInfoRow(result[1], bookShelfId)
    end

    return {}
end

function M:getAllBookCacheInfo()
    local infos = {}
    local book_rows = self:execute([[
        SELECT bookCacheId, name, author, totalChapterNum
        FROM books
        ORDER BY isEnabled DESC, id DESC;
    ]])
    for _, row in ipairs(book_rows or {}) do
        local cache_id = row[1]
        if H.is_str(cache_id) and not infos[cache_id] then
            infos[cache_id] = {
                cache_id = cache_id,
                name = row[2],
                author = row[3],
                total_count = tonumber(row[4]) or 0,
            }
        end
    end

    local chapter_rows = self:execute([[
        SELECT bookCacheId, COUNT(*)
        FROM chapters
        GROUP BY bookCacheId;
    ]])
    for _, row in ipairs(chapter_rows or {}) do
        local cache_id = row[1]
        if H.is_str(cache_id) then
            local info = infos[cache_id] or {
                cache_id = cache_id,
                total_count = 0,
            }
            info.total_count = math.max(info.total_count, tonumber(row[2]) or 0)
            infos[cache_id] = info
        end
    end
    return infos
end

function M:getChapterCachePaths(bookCacheId)
    if not H.is_str(bookCacheId) then return {} end
    local rows = self:execute([[
        SELECT cacheFilePath
        FROM chapters
        WHERE bookCacheId = ? AND cacheFilePath IS NOT NULL;
    ]], { bookCacheId })
    local paths = {}
    for _, row in ipairs(rows or {}) do
        if H.is_str(row[1]) then table.insert(paths, row[1]) end
    end
    return paths
end

function M:clearChapterCachePaths(bookCacheId)
    if not H.is_str(bookCacheId) then return false end
    self:execute([[
        UPDATE chapters SET cacheFilePath = NULL WHERE bookCacheId = ?;
    ]], { bookCacheId })
    return true
end

function M:upsertChapters(bookCacheId, chapters)
    if not H.is_str(bookCacheId) or not H.is_tbl(chapters) then
        logger.dbg('BookInfoDB:upsertChapters Incorrect input parameters')
        return false, 0
    end

    local sql_stmt = [[
        INSERT INTO chapters (bookCacheId, chapterIndex, title, isVolume, chapterUrl, variable)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(bookCacheId, chapterIndex) DO UPDATE SET
    title = CASE WHEN excluded.title != chapters.title THEN excluded.title ELSE chapters.title END,
    isVolume = CASE WHEN excluded.isVolume != chapters.isVolume THEN excluded.isVolume ELSE chapters.isVolume END,
    chapterUrl = CASE WHEN excluded.chapterUrl IS NOT NULL AND excluded.chapterUrl != '' THEN excluded.chapterUrl ELSE chapters.chapterUrl END,
    variable = excluded.variable;
    ]]

    local batch_data = {}
    for _, chapter in pairs(chapters) do
        if type(chapter) == "table" and chapter.index ~= nil then

            if not H.is_str(chapter.title) or chapter.title == '' then
                chapter.title = string.format('第%s章', chapter.index)
            end
            table.insert(batch_data, {
                bookCacheId, chapter.index, chapter.title, chapter.isVolume and 1 or 0,
                chapter.url or chapter.chapterUrl, encode_variable(chapter.variable)
            })

        end
    end

    if #batch_data > 0 then

        self:batch_insert(sql_stmt, batch_data, 0)
    end

    return true, #batch_data
end

function M:getAllChapters(bookCacheId, readable_only)
    if not H.is_str(bookCacheId) then
        return {}
    end
    local filter = (readable_only == true) and " AND (c.isVolume IS NULL OR c.isVolume = 0) " or ""
    local sql_stmt = string.format([[
    SELECT %s 
    FROM chapters AS c INNER JOIN books AS b ON c.bookCacheId = b.bookCacheId
    WHERE b.isEnabled = 1 AND c.bookCacheId = ? %s
    ORDER BY c.chapterIndex ASC;
    ]], COLS_CHAPTER_FULL, filter)

    local result = self:execute(sql_stmt, bookCacheId)
    local chapters = {}
    if result then
        for i = 1, #result do
            chapters[i] = _mapChapterRow(result[i], bookCacheId)
        end
    end

    return chapters
end

function M:getReadableChapters(bookCacheId)
    return self:getAllChapters(bookCacheId, true)
end

function M:getAllChaptersByUI(bookCacheId, is_desc_sort)
    if not H.is_str(bookCacheId) then
        return {}
    end
    local sql_stmt = string.format([[
    SELECT %s 
    FROM chapters AS c INNER JOIN books AS b ON c.bookCacheId = b.bookCacheId 
    WHERE b.isEnabled = 1 AND c.bookCacheId = ? 
    ORDER BY c.chapterIndex ]], COLS_CHAPTER_UI) .. (is_desc_sort and "DESC;" or "ASC;")

    local result = self:execute(sql_stmt, bookCacheId)
    local chapters = {}
    if result then
        for i = 1, #result do
            chapters[i] = _mapChapterRowUI(result[i])
        end
    end

    return chapters
end

function M:getChapterCount(bookCacheId, readable_only)
    if not H.is_str(bookCacheId) then
        return 0
    end
    local filter = (readable_only == true) and " AND (isVolume IS NULL OR isVolume = 0) " or ""
    local sql_stmt = string.format("SELECT count(*) as total_num FROM chapters WHERE bookCacheId = ? %s;", filter)
    local result = self:execute(sql_stmt, {bookCacheId})
    if result and result[1] and result[1][1] then
        return tonumber(result[1][1])
    end
    return 0
end

function M:getLastReadChapter(bookCacheId)
    if not H.is_str(bookCacheId) then return 0 end
    local rows = self:execute([[
        SELECT COALESCE(durChapterIndex, 0) FROM books
        WHERE bookCacheId = ? ORDER BY durChapterTime DESC LIMIT 1
    ]], { bookCacheId })
    return rows[1] and tonumber(rows[1][1]) or 0
end

function M:getChapterLastUpdateTime(bookCacheId)
    if not H.is_str(bookCacheId) then
        return os.time()
    end
    local sql_stmt = "SELECT lastUpdated FROM books WHERE isEnabled = 1 AND bookCacheId = ?;"
    local result = self:execute(sql_stmt, {bookCacheId})

    if result and result[1] and result[1][1] then
        return tonumber(result[1][1])
    else
        return os.time()
    end
end

function M:getChapterInfo(bookCacheId, chapterIndex)
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        logger.dbg('getChapterInfo Incorrect input parameters')
        return {}
    end

    local sql_stmt = string.format([[
    SELECT %s 
    FROM chapters AS c INNER JOIN books AS b ON c.bookCacheId = b.bookCacheId
    WHERE b.isEnabled = 1 AND c.bookCacheId = ? AND c.chapterIndex = ?;
    ]], COLS_CHAPTER_FULL)

    local result = self:execute(sql_stmt, {bookCacheId, chapterIndex})

    if result and #result > 0 then
        return _mapChapterRow(result[1], bookCacheId)
    end

    return {}
end

function M:getcompleteReadAheadChapters(current_chapter)

    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        logger.dbg('getcompleteReadAheadChapters:', current_chapter)
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
  c.chapterIndex > ?
  AND c.cacheFilePath IS NOT NULL
  AND c.bookCacheId = ?
  AND (c.isVolume IS NULL OR c.isVolume = 0)
  AND c.chapterIndex < COALESCE(
      (SELECT MIN(chapterIndex)
       FROM chapters
       WHERE chapterIndex > ?
         AND cacheFilePath IS NULL
         AND (isVolume IS NULL OR isVolume = 0)
         AND bookCacheId = ?
      ),
      (SELECT MAX(chapterIndex) + 1
       FROM chapters
       WHERE bookCacheId = ?
      )
  )
  AND EXISTS (
      SELECT 1 FROM books AS b
      WHERE b.bookCacheId = c.bookCacheId
        AND b.isEnabled = 1
  );
  ]]
    else
        sql_stmt = [[
SELECT COUNT(*) AS continuous_count
FROM chapters AS c
WHERE
  c.chapterIndex < ?
  AND c.cacheFilePath IS NOT NULL
  AND c.bookCacheId = ?
  AND (c.isVolume IS NULL OR c.isVolume = 0)
  AND c.chapterIndex > COALESCE(
      (SELECT MAX(chapterIndex)
       FROM chapters
       WHERE chapterIndex < ?
         AND cacheFilePath IS NULL
         AND (isVolume IS NULL OR isVolume = 0)
         AND bookCacheId = ?
      ),
      (SELECT MIN(chapterIndex) - 1
       FROM chapters
       WHERE bookCacheId = ?
      )
  )
  AND EXISTS (
      SELECT 1 FROM books AS b
      WHERE b.bookCacheId = c.bookCacheId
        AND b.isEnabled = 1
  );
    ]]
    end
    local params = {current_chapters_index, bookCacheId, current_chapters_index, bookCacheId, bookCacheId}
    local result = self:execute(sql_stmt, params)

    if result and result[1] and result[1][1] then
        return tonumber(result[1][1])
    end
    return 0
end

function M:getReadableAheadIndexes(current_chapter, count)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        return {}
    end

    count = math.max(0, math.floor(tonumber(count) or 0))
    if count == 0 then return {} end

    local bookCacheId = current_chapter.book_cache_id
    local current_chapters_index = current_chapter.chapters_index
    local call_event_type = current_chapter.call_event or 'next'
    local comparator = call_event_type == 'next' and '>' or '<'
    local order = call_event_type == 'next' and 'ASC' or 'DESC'
    local sql_stmt = string.format([[
        SELECT c.chapterIndex
        FROM chapters AS c
        INNER JOIN books AS b ON c.bookCacheId = b.bookCacheId
        WHERE c.bookCacheId = ?
          AND b.isEnabled = 1
          AND (c.isVolume IS NULL OR c.isVolume = 0)
          AND c.chapterIndex %s ?
        ORDER BY c.chapterIndex %s
        LIMIT %d;
    ]], comparator, order, count)

    local result = self:execute(sql_stmt, {bookCacheId, current_chapters_index})
    if not result then return nil end

    local indexes = {}
    for i = 1, #result do
        indexes[i] = tonumber(result[i][1])
    end
    return indexes
end

function M:findChapterNotDownLoadLittle(current_chapter, count, include_read)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        logger.dbg('findChapterNotDownLoadLittle:', current_chapter)
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

    local read_filter = include_read == true and "" or "AND c.isRead = 0"
    local sql_stmt = string.format([[
        SELECT %s
        FROM chapters AS c
        INNER JOIN books AS b
            ON c.bookCacheId = b.bookCacheId
        WHERE
             c.bookCacheId = ? AND b.isEnabled = 1 %s AND (c.isVolume IS NULL OR c.isVolume = 0) AND c.cacheFilePath IS NULL
             ]], COLS_CHAPTER_NOT_DOWNLOADED, read_filter)

    local suffix = "  AND c.chapterIndex > ?  ORDER BY c.chapterIndex ASC LIMIT "

    if call_event_type ~= 'next' then
        suffix = "  AND c.chapterIndex < ? ORDER BY c.chapterIndex DESC LIMIT "
    end

    sql_stmt = table.concat({sql_stmt, suffix, count, ';'})

    local result = self:execute(sql_stmt, {bookCacheId, current_chapters_index})

    local chapters = {}
    if result then
        for i = 1, #result do
            chapters[i] = _mapChapterNotDownloadedRow(result[i], bookCacheId)
        end
    end

    return chapters

end

function M:findNextChapterInfo(current_chapter, is_downloaded)
    if not H.is_tbl(current_chapter) or current_chapter.book_cache_id == nil or current_chapter.chapters_index == nil then
        logger.dbg('findNextChapterInfo:', current_chapter)
        return {}
    end

    local bookCacheId = current_chapter.book_cache_id
    local current_chapters_index = current_chapter.chapters_index
    local call_event_type = current_chapter.call_event
    if call_event_type == nil then
        call_event_type = 'next'
    end

    local sql_stmt = string.format([[
        SELECT %s 
        FROM chapters AS c INNER JOIN books AS b ON c.bookCacheId = b.bookCacheId
        WHERE c.bookCacheId = ? AND b.isEnabled = 1 AND (c.isVolume IS NULL OR c.isVolume = 0) ]], COLS_CHAPTER_FULL)

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

    if result and #result > 0 then
        return _mapChapterRow(result[1], bookCacheId)
    end

    return {}
end

function M:updateIsRead(chapter, isRead, is_update_timestamp)
    local bookCacheId = chapter.book_cache_id
    local chapterIndex = chapter.chapters_index
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        return
    end
    chapter.isRead = isRead
    local update_state = {}
    update_state.isRead = isRead
    if is_update_timestamp == true then
        update_state.lastUpdated = {
            _set = "= strftime('%s', 'now')"
        }
    end
    return self:dynamicUpdateChapters(chapter, update_state)
end

function M:updateReadingProgress(bookShelfId, bookCacheId, chapterIndex, chapterTitle, durChapterPos)
    if not (H.is_str(bookCacheId) and H.is_num(chapterIndex)) then
        return false
    end
    local now_ms = os.time() * 1000
    local conditions = {
        bookCacheId = bookCacheId,
    }
    if H.is_str(bookShelfId) then
        conditions.bookShelfId = bookShelfId
    end
    local update = {
        durChapterIndex = chapterIndex,
        durChapterTitle = chapterTitle or "",
        durChapterPos = durChapterPos or 0,
        durChapterTime = now_ms,
        sortOrder = now_ms,
    }
    if conditions.bookShelfId then
        local result = self:dynamicUpdate('books', update, conditions)
        if result and tonumber(result.changes) > 0 then return result end
    end
    local matches = self:execute("SELECT bookShelfId FROM books WHERE bookCacheId = ? LIMIT 2", { bookCacheId })
    if #matches ~= 1 then return false end
    conditions.bookShelfId = matches[1][1]
    local result = self:dynamicUpdate('books', update, conditions)
    if result and tonumber(result.changes) > 0 then return result end
    return false
end

function M:updateChapterReadDownLoad(bookCacheId, chapterIndex, isRead, _)
    if not (H.is_str(bookCacheId) and H.is_num(chapterIndex)) then
        return false
    end
    local chapter = {
        book_cache_id = bookCacheId,
        chapters_index = chapterIndex,
    }
    return self:updateIsRead(chapter, isRead == true, true)
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
    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        return false
    end
    local sql_stmt = [[
        SELECT 1 
        FROM chapters
        WHERE bookCacheId = ?
          AND chapterIndex = ? AND cacheFilePath IS NOT NULL;
    ]]
    local result = self:execute(sql_stmt, {bookCacheId, chapterIndex})
    return result and #result > 0 and result[1][1] == 1
end

function M:disableBookShelf(bookShelfId)
    if not H.is_str(bookShelfId) then
        logger.dbg('DB disableBookShelf error')
        return false
    end

    self:dynamicUpdate('books', {
        isEnabled = 0
    }, {
        bookShelfId = bookShelfId
    })
    return true
end

function M:clearBook(bookShelfId, bookCacheId)

    if not H.is_str(bookShelfId) or not H.is_str(bookCacheId) then
        logger.dbg('DB clearBook error')
        return false
    end

    local del_chapters_sql = "DELETE FROM chapters WHERE bookCacheId = ?"
    return self:transaction(function()
        self:execute(del_chapters_sql, {bookCacheId})
        return true
    end, {
        enable_savepoint = false
    })()
end

function M:dynamicUpdateChapters(chapter, updateData)
    if not H.is_tbl(updateData) or not H.is_tbl(chapter) then
        logger.dbg('dynamicUpdateChapters Required parameter error')
        return
    end

    local bookCacheId = chapter.book_cache_id
    local chapterIndex = chapter.chapters_index

    if not H.is_str(bookCacheId) or not H.is_num(chapterIndex) then
        logger.dbg('dynamicUpdateChapters Required parameter error')
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
        logger.dbg('dynamicUpdateBooks An error occurred when calling the parameter')
        return
    end

    local bookCacheId = book.book_cache_id
    local bookShelfId = book.bookShelfId

    if not H.is_str(bookCacheId) or not H.is_str(bookShelfId) then
        logger.dbg('dynamicUpdateBooks Error parameters')
        error('dynamicUpdateBooks Error parameters')
        return
    end

    return self:dynamicUpdate('books', updateData, {
        bookCacheId = bookCacheId,
        bookShelfId = bookShelfId
    })
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
        if value == '_NULL' then
            table.insert(set_clause, string.format("%s = ?", key))
            table.insert(params, self.nil_object())
        elseif H.is_tbl(value) and H.is_str(value._set) then
            table.insert(set_clause, table.concat({key, ' ', value._set}))
        else
            table.insert(set_clause, string.format("%s = ?", key))
            table.insert(params, value)
        end
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
            elseif H.is_tbl(value) and H.is_str(value._where) then
                table.insert(where_parts, table.concat({field, ' ', value._where}))
            else
                table.insert(where_parts, string.format("%s = ?", field))
                table.insert(params, value)
            end
        end

        if #where_parts > 0 then
            where_clause = " WHERE " .. table.concat(where_parts, " AND ")
        else
            return
        end

    end

    local sql_stmt = table.concat({"UPDATE ", tableName, " SET ", table.concat(set_clause, ", "), where_clause})

    return self:execute(sql_stmt, params)
end

function M:resortBooksByLastRead(bookShelfId)
    if not H.is_str(bookShelfId) then
        logger.dbg('DB resortBooksByLastRead error: invalid bookShelfId')
        return false
    end
    local sql_stmt = [[
        UPDATE books
        SET sortOrder = durChapterTime
        WHERE bookShelfId = ? AND sortOrder != 0 AND isEnabled = 1 AND durChapterTime > 1000000000;
    ]]
    return self:execute(sql_stmt, {bookShelfId})
end

function M:setBooksTopStatus(bookShelfId, book_cache_id, current_sort_order, isPinnedByTime)
    if not (H.is_str(bookShelfId) and H.is_str(book_cache_id)) then
        logger.dbg('DB setBooksTopStatus error: invalid parameters')
        return false
    end

    if current_sort_order ~= nil then
        if current_sort_order ~= 0 then
            return self:dynamicUpdate('books', {
                sortOrder = 0
            }, {
                bookCacheId = book_cache_id,
                bookShelfId = bookShelfId
            })
        else
            return self:dynamicUpdate('books', {
                sortOrder = {
                    _set = "= durChapterTime"
                }
            }, {
                bookCacheId = book_cache_id,
                bookShelfId = bookShelfId,
                sortOrder = {
                    _where = '!= durChapterTime'
                }
            })
        end
    elseif isPinnedByTime == true then
        local sql_stmt = [[
            SELECT bookCacheId FROM books 
            WHERE isEnabled = 1 AND bookShelfId = ? AND sortOrder > 0 
            ORDER BY sortOrder DESC LIMIT 1;
        ]]
        local result = self:execute(sql_stmt, {bookShelfId})
        if result and result[1] and result[1][1] and result[1][1] == book_cache_id then
            return true
        end
        return self:dynamicUpdate('books', {
            sortOrder = {
                _set = "= CAST(ROUND((julianday('now') - 2440587.5) * 86400000) AS INTEGER)"
            }
        }, {
            bookCacheId = book_cache_id,
            bookShelfId = bookShelfId
        })
    end
end

function M:disableAllBookShelves()
    return self:getDB():exec("UPDATE books SET isEnabled = 0;")
end

function M:removeBookShelf(bookShelfId)
    if not H.is_str(bookShelfId) then
        return false
    end
    local perform_delete = self:transaction(function(targetShelfId)
        local delete_chapters_sql = [[
            DELETE FROM chapters 
            WHERE bookCacheId IN (
                SELECT bookCacheId 
                FROM books 
                WHERE bookShelfId = ?
            )
        ]]
        self:execute(delete_chapters_sql, {targetShelfId})
        local delete_books_sql = "DELETE FROM books WHERE bookShelfId = ?"
        self:execute(delete_books_sql, {targetShelfId})
        return true
    end)
    return perform_delete(bookShelfId)
end

function M:tryStartSync(scope_id, resource_type, interval, resource_key)
    if not (H.is_str(scope_id) and scope_id ~= "") then return false end
    if not (H.is_str(resource_type) and resource_type ~= "") then return false end

    resource_key = resource_key or ""
    if not H.is_str(resource_key) then return false end

    interval = tonumber(interval) or 0
    if interval ~= interval or interval < 0 then interval = 0 end
    interval = math.floor(interval)

    local now = os.time()
    local allowed = false
    local ok, err = pcall(function()
        self:transaction(function()
            local rows = self:execute([[
                SELECT lastAttemptAt, lastSuccessAt
                FROM sync_records
                WHERE scopeType = ? AND scopeId = ?
                  AND resourceType = ? AND resourceKey = ?
                LIMIT 1
            ]], { "bookshelf", scope_id, resource_type, resource_key })
            if type(rows) == "table" and rows[1] then
                local last_attempt = tonumber(rows[1][1]) or 0
                local last_success = tonumber(rows[1][2]) or 0
                local last_sync = math.max(last_attempt, last_success)
                if last_sync > 0 and now - last_sync < interval then
                    return
                end
            end

            self:execute([[
                INSERT INTO sync_records
                    (scopeType, scopeId, resourceType, resourceKey, lastAttemptAt)
                VALUES (?, ?, ?, ?, CAST(strftime('%s', 'now') AS INTEGER))
                ON CONFLICT(scopeType, scopeId, resourceType, resourceKey) DO UPDATE SET
                    lastAttemptAt = CAST(strftime('%s', 'now') AS INTEGER)
            ]], { "bookshelf", scope_id, resource_type, resource_key })
            allowed = true
        end)()
    end)
    if not ok then
        logger.warn("BookInfoDB: tryStartSync failed:", tostring(err))
        return false
    end
    return allowed
end

local function record_sync_success(self, scope_id, resource_type, item_count, resource_key)
    self:execute([[
        INSERT INTO sync_records
            (scopeType, scopeId, resourceType, resourceKey,
             lastAttemptAt, lastSuccessAt, lastItemCount, lastError)
        VALUES (?, ?, ?, ?,
                CAST(strftime('%s', 'now') AS INTEGER),
                CAST(strftime('%s', 'now') AS INTEGER), ?, NULL)
        ON CONFLICT(scopeType, scopeId, resourceType, resourceKey) DO UPDATE SET
            lastAttemptAt = excluded.lastAttemptAt,
            lastSuccessAt = excluded.lastSuccessAt,
            lastItemCount = excluded.lastItemCount,
            lastError = NULL
    ]], { "bookshelf", scope_id, resource_type, resource_key or "", tonumber(item_count) or 0 })
end

local function decode_source_row(row)
    if type(row) ~= "table" then return nil end
    local ok, source = pcall(rapidjson.decode, row[1])
    if not ok or type(source) ~= "table" then return nil end
    source.customOrder = tonumber(row[2]) or 0
    source.enabled = tonumber(row[3]) == 1
    source.enabledExplore = tonumber(row[4]) == 1
    source.bookSourceGroup = row[5]

    local function apply_text(field, value)
        if value ~= nil and value ~= "" then
            source[field] = value
        end
    end
    apply_text("header", row[6])
    apply_text("dynamicHeader", row[7])
    apply_text("dynamicVariables", row[8])
    apply_text("concurrentRate", row[9])
    source.enabledCookieJar = tonumber(row[10]) == 1 or source.enabledCookieJar == true
    source.enabledReview = tonumber(row[11]) == 1 or source.enabledReview == true
    local respond_time = tonumber(row[12])
    source.respondTime = respond_time and respond_time ~= 0 and respond_time or tonumber(source.respondTime) or 0
    apply_text("bookUrlPattern", row[13])
    apply_text("loginUrl", row[14])
    apply_text("loginCheckJs", row[15])
    apply_text("jsLib", row[16])
    if type(row[17]) == "string" and row[17] ~= "" then
        local session_ok, session = pcall(rapidjson.decode, row[17])
        if session_ok and type(session) == "table" then
            source.session = session
        end
    end
    if type(row[18]) == "string" and row[18] ~= "" then
        local login_ok, login_data = pcall(rapidjson.decode, row[18])
        if login_ok and type(login_data) == "table" then
            source.loginData = login_data
        end
    end
    return source
end

local function encode_source_summary(source)
    return rapidjson.encode({
        exploreUrl = source.exploreUrl,
        loginUi = source.loginUi,
        loginUrl = source.loginUrl,
        session = BookSourceLogin.hasNonemptyValue(source.session) and 1 or nil,
        loginData = BookSourceLogin.hasNonemptyValue(source.loginData) and 1 or nil,
    }, { sort_keys = true })
end

function M:getEnabledBookSourceSummaries(bookShelfId)
    bookShelfId = bookShelfId or "local"
    local rows = self:execute([[SELECT bookSourceName, bookSourceUrl, bookSourceGroup,
        enabledExplore, loginUrl, summaryJson, session, loginData FROM book_sources
        WHERE enabled = 1 AND bookShelfId = ? ORDER BY customOrder ASC, weight DESC]], { bookShelfId })
    local summaries = {}
    for _, row in ipairs(rows) do
        local ok, source = pcall(rapidjson.decode, row[6])
        if ok and type(source) == "table" then
            source.bookSourceName, source.bookSourceUrl, source.bookSourceGroup = row[1], row[2], row[3]
            source.enabled, source.enabledExplore = true, tonumber(row[4]) == 1
            if type(row[5]) == "string" and row[5] ~= "" then source.loginUrl = row[5] end
            for index, field in pairs({ [7] = "session", [8] = "loginData" }) do
                if type(row[index]) == "string" and row[index] ~= "" then
                    local valid, value = pcall(rapidjson.decode, row[index])
                    if valid and type(value) == "table" then source[field] = value end
                end
            end
            source.hasLogin = BookSourceLogin.hasLogin(source) and true or false
            source.loginUi, source.session, source.loginData = nil, nil, nil
            summaries[#summaries + 1] = source
        end
    end
    return summaries
end

function M:importBookSources(bookShelfId, sources)
    bookShelfId = bookShelfId or "local"
    if type(sources) ~= "table" then return 0 end
    if type(sources) == "table" then
        local list = sources.bookSourceUrl and { sources } or sources
        for _, source in ipairs(list) do
            if type(source) == "table" and type(source.exploreUrl) == "boolean" then
                error("收到书源摘要而非完整书源，请重新同步完整书源", 0)
            end
        end
    end
    if not sources[1] then sources = { sources } end

    local count = 0
    local sql = [[
        INSERT INTO book_sources
        (bookShelfId, bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
         customOrder, weight, enabled, enabledExplore, lastUpdateTime, dynamicHeader,
         dynamicVariables, concurrentRate, enabledCookieJar, enabledReview, respondTime,
         bookUrlPattern, header, loginUrl, loginCheckJs, jsLib, rawJson, summaryJson)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bookShelfId, bookSourceUrl) DO UPDATE SET
            bookSourceName = excluded.bookSourceName,
            bookSourceGroup = excluded.bookSourceGroup,
            bookSourceType = excluded.bookSourceType,
            customOrder = excluded.customOrder,
            weight = excluded.weight,
            enabled = excluded.enabled,
            enabledExplore = excluded.enabledExplore,
            lastUpdateTime = excluded.lastUpdateTime,
            dynamicHeader = CASE
                WHEN excluded.dynamicHeader IS NOT NULL AND excluded.dynamicHeader != ''
                    THEN excluded.dynamicHeader
                ELSE book_sources.dynamicHeader
            END,
            dynamicVariables = CASE
                WHEN excluded.dynamicVariables IS NOT NULL AND excluded.dynamicVariables != ''
                    THEN excluded.dynamicVariables
                ELSE book_sources.dynamicVariables
            END,
            concurrentRate = excluded.concurrentRate,
            enabledCookieJar = excluded.enabledCookieJar,
            enabledReview = excluded.enabledReview,
            respondTime = excluded.respondTime,
            bookUrlPattern = excluded.bookUrlPattern,
            header = excluded.header,
            loginUrl = excluded.loginUrl,
            loginCheckJs = excluded.loginCheckJs,
            jsLib = excluded.jsLib,
            rawJson = excluded.rawJson,
            summaryJson = excluded.summaryJson
        -- 独立字段也参与比较，保证远端同步仍能纠正本地启用、排序等修改。
        WHERE (book_sources.rawJson, book_sources.summaryJson,
               book_sources.bookSourceName, book_sources.bookSourceGroup, book_sources.bookSourceType,
               book_sources.customOrder, book_sources.weight, book_sources.enabled, book_sources.enabledExplore,
               book_sources.lastUpdateTime, book_sources.concurrentRate, book_sources.enabledCookieJar,
               book_sources.enabledReview, book_sources.respondTime, book_sources.bookUrlPattern,
               book_sources.header, book_sources.loginUrl, book_sources.loginCheckJs, book_sources.jsLib)
           IS NOT (excluded.rawJson, excluded.summaryJson,
                   excluded.bookSourceName, excluded.bookSourceGroup, excluded.bookSourceType,
                   excluded.customOrder, excluded.weight, excluded.enabled, excluded.enabledExplore,
                   excluded.lastUpdateTime, excluded.concurrentRate, excluded.enabledCookieJar,
                   excluded.enabledReview, excluded.respondTime, excluded.bookUrlPattern,
                   excluded.header, excluded.loginUrl, excluded.loginCheckJs, excluded.jsLib)
           OR (excluded.dynamicHeader != '' AND book_sources.dynamicHeader IS NOT excluded.dynamicHeader)
           OR (excluded.dynamicVariables != '' AND book_sources.dynamicVariables IS NOT excluded.dynamicVariables)
    ]]
    self:transaction(function()
        for _, source in ipairs(sources) do
            if type(source) == "table" and source.bookSourceUrl and source.bookSourceName then
                local snapshot = source
                if source.session ~= nil or source.loginData ~= nil then
                    snapshot = {}
                    for key, value in pairs(source) do
                        if key ~= "session" and key ~= "loginData" then
                            snapshot[key] = value
                        end
                    end
                end
                local enc_ok, raw_json = pcall(rapidjson.encode, snapshot, { sort_keys = true })
                if enc_ok and type(raw_json) == "string" then
                    self:execute(sql, {
                        bookShelfId,
                        source.bookSourceUrl,
                        source.bookSourceName,
                        source.bookSourceGroup or "",
                        tonumber(source.bookSourceType) or 0,
                        tonumber(source.customOrder) or 0,
                        tonumber(source.weight) or 0,
                        source.enabled == false and 0 or 1,
                        source.enabledExplore == false and 0 or 1,
                        tonumber(source.lastUpdateTime) or 0,
                        source.dynamicHeader or "",
                        source.dynamicVariables or "",
                        source.concurrentRate or "",
                        source.enabledCookieJar == true and 1 or 0,
                        source.enabledReview == true and 1 or 0,
                        tonumber(source.respondTime) or 0,
                        source.bookUrlPattern or "",
                        source.header or "",
                        source.loginUrl or "",
                        source.loginCheckJs or "",
                        source.jsLib or "",
                        raw_json,
                        encode_source_summary(snapshot)
                    })
                    count = count + 1
                else
                    logger.warn("importBookSources: skip invalid source " .. tostring(source.bookSourceUrl))
                end
            end
        end
    end)()
    return count
end

function M:syncBookSources(bookShelfId, sources)
    bookShelfId = bookShelfId or "local"
    return self:transaction(function()
        local imported = self:importBookSources(bookShelfId, sources)
        if type(sources) ~= "table" then return imported end
        if not sources[1] then sources = { sources } end

        local urls = {}
        for _, source in ipairs(sources) do
            if type(source) == "table" and source.bookSourceUrl then
                urls[source.bookSourceUrl] = true
            end
        end
        local local_sources = self:execute("SELECT bookSourceUrl FROM book_sources WHERE bookShelfId = ?", { bookShelfId })
        if type(local_sources) == "table" then
            for _, row in ipairs(local_sources) do
                if not urls[row[1]] then
                    self:execute("DELETE FROM book_sources WHERE bookShelfId = ? AND bookSourceUrl = ?", { bookShelfId, row[1] })
                end
            end
        end
        record_sync_success(self, bookShelfId, "book_sources", imported)
        return imported
    end)()
end

function M:getEnabledBookSources(bookShelfId)
    bookShelfId = bookShelfId or "local"
    local sources = {}
    local sql = "SELECT rawJson, customOrder, enabled, enabledExplore, bookSourceGroup, header, dynamicHeader, dynamicVariables, concurrentRate, enabledCookieJar, enabledReview, respondTime, bookUrlPattern, loginUrl, loginCheckJs, jsLib, session, loginData FROM book_sources WHERE enabled = 1 AND bookShelfId = ? ORDER BY customOrder ASC, weight DESC"
    local results = self:execute(sql, { bookShelfId })
    if type(results) == "table" then
        for _, row in ipairs(results) do
            local source = decode_source_row(row)
            if source then sources[#sources + 1] = source end
        end
    end
    return sources
end

function M:getBookSourceByUrl(bookShelfId, bookSourceUrl, allow_fallback)
    bookShelfId = bookShelfId or "local"
    if type(bookSourceUrl) ~= "string" or bookSourceUrl == "" then return nil end
    local sql = "SELECT rawJson, customOrder, enabled, enabledExplore, bookSourceGroup, header, dynamicHeader, dynamicVariables, concurrentRate, enabledCookieJar, enabledReview, respondTime, bookUrlPattern, loginUrl, loginCheckJs, jsLib, session, loginData FROM book_sources WHERE bookShelfId = ? AND bookSourceUrl = ? LIMIT 1"
    local results = self:execute(sql, { bookShelfId, bookSourceUrl })
    if type(results) == "table" and #results > 0 then
        return decode_source_row(results[1])
    end
    if allow_fallback == true then
        local fallback_sql = "SELECT rawJson, customOrder, enabled, enabledExplore, bookSourceGroup, header, dynamicHeader, dynamicVariables, concurrentRate, enabledCookieJar, enabledReview, respondTime, bookUrlPattern, loginUrl, loginCheckJs, jsLib, session, loginData FROM book_sources WHERE bookSourceUrl = ? LIMIT 2"
        local fallback_results = self:execute(fallback_sql, { bookSourceUrl })
        if type(fallback_results) == "table" and #fallback_results > 1 then
            return nil, "该书源 URL 在多个书架存在，无法安全选择跨书架配置"
        end
        if type(fallback_results) == "table" and #fallback_results == 1 then
            return decode_source_row(fallback_results[1])
        end
    end
    return nil
end

function M:saveBookSourceSession(bookShelfId, bookSourceUrl, session)
    if type(bookShelfId) ~= "string" or type(bookSourceUrl) ~= "string" or bookSourceUrl == "" then
        return false, "invalid book source session key"
    end

    local encoded
    if session == nil then
        encoded = self.nil_object()
    else
        local ok, value = pcall(rapidjson.encode, session)
        if not ok or type(value) ~= "string" then
            return false, "failed to encode book source session"
        end
        encoded = value
    end

    local ok, err = pcall(function()
        self:execute(
            "UPDATE book_sources SET session = ? WHERE bookShelfId = ? AND bookSourceUrl = ?",
            { encoded, bookShelfId, bookSourceUrl }
        )
    end)
    if not ok then return false, tostring(err) end
    return true
end

function M:saveBookSourceLoginData(bookShelfId, bookSourceUrl, loginData)
    if type(bookShelfId) ~= "string" or type(bookSourceUrl) ~= "string" or bookSourceUrl == "" then
        return false, "invalid book source login key"
    end

    local encoded
    if loginData == nil then
        encoded = self.nil_object()
    else
        if type(loginData) ~= "table" then return false, "login data must be an object" end
        local ok, value = pcall(rapidjson.encode, loginData)
        if not ok or type(value) ~= "string" then
            return false, "failed to encode book source login data"
        end
        encoded = value
    end

    local ok, err = pcall(function()
        self:execute(
            "UPDATE book_sources SET loginData = ? WHERE bookShelfId = ? AND bookSourceUrl = ?",
            { encoded, bookShelfId, bookSourceUrl }
        )
        if tonumber(self:getDB():rowexec("SELECT changes()")) == 0 then
            error("书源不存在，未保存凭证", 0)
        end
    end)
    if not ok then return false, tostring(err) end
    return true
end

function M:clearBookSourceState(bookShelfId, url, kind)
    if kind ~= "cache" and kind ~= "cookie" then return false, "未知书源清理操作" end
    local ok, session = pcall(self:transaction(function()
        local rows = self:execute("SELECT session FROM book_sources WHERE bookShelfId = ? AND bookSourceUrl = ?", {bookShelfId, url})
        if #rows == 0 then error("书源不存在", 0) end
        local cleaned
        if type(rows[1][1]) == "string" then
            cleaned = rapidjson.decode(rows[1][1])
            if type(cleaned) ~= "table" then error("书源会话格式错误", 0) end
        end
        if cleaned then
            if kind == "cache" then
                if type(cleaned.variables) == "table" then
                    cleaned.variables.__reader_js_cache_v1 = nil
                end
            else
                cleaned.cookies, cleaned.cookieJar, cleaned.header = nil, nil, nil
                if type(cleaned.variables) == "table" then
                    cleaned.variables["userInfo_" .. url] = nil
                end
            end
        end
        local saved, err = self:saveBookSourceSession(bookShelfId, url, cleaned)
        if saved ~= true then error(err, 0) end
        if kind == "cookie" then
            saved, err = self:saveBookSourceLoginData(bookShelfId, url, nil)
            if saved ~= true then error(err, 0) end
        end
        return cleaned
    end))
    if not ok then return false, tostring(session) end
    return true, session
end

function M:getBookSourceGroupsSummary(bookShelfId)
    bookShelfId = bookShelfId or "local"
    local groups = {}
    local sql = "SELECT bookSourceGroup, COUNT(1) FROM book_sources WHERE bookShelfId = ? GROUP BY bookSourceGroup ORDER BY COUNT(1) DESC"
    local results = self:execute(sql, { bookShelfId })
    if type(results) == "table" then
        for _, row in ipairs(results) do
            groups[#groups + 1] = { group = row[1], count = tonumber(row[2]) or 0 }
        end
    end
    return groups
end

local function optional_text(value)
    return type(value) == "string" and value or nil
end

local function normalize_text_transform_rule(rule, dialect, order_index)
    if type(rule) ~= "table" or type(rule.name) ~= "string" or type(rule.pattern) ~= "string" then
        return nil
    end

    local is_reader3 = dialect == "reader3"
    local remote_id = rule.id
    local rule_key
    if remote_id ~= nil and tostring(remote_id) ~= "" then
        rule_key = "id:" .. tostring(remote_id)
    else
        rule_key = "name:" .. rule.name
    end

    local is_regex = rule.isRegex
    if is_regex == nil then is_regex = not is_reader3 end

    local scope_title, scope_content, exclude_scope, timeout_ms
    if not is_reader3 then
        scope_title = rule.scopeTitle == true and 1 or 0
        scope_content = rule.scopeContent == false and 0 or 1
        exclude_scope = rule.excludeScope or rule.exclude_scope
        timeout_ms = tonumber(rule.timeoutMillisecond or rule.timeoutMs) or 3000
    end

    local ok, raw_json = pcall(rapidjson.encode, rule)
    if not ok or type(raw_json) ~= "string" then raw_json = nil end

    return {
        ruleKey = rule_key,
        name = rule.name,
        groupName = optional_text(rule.group) or optional_text(rule.groupname) or optional_text(rule.groupName),
        pattern = rule.pattern,
        replacement = type(rule.replacement) == "string" and rule.replacement or "",
        scope = optional_text(rule.scope),
        excludeScope = optional_text(exclude_scope),
        scopeTitle = scope_title,
        scopeContent = scope_content,
        isEnabled = rule.isEnabled == false and 0 or 1,
        isRegex = is_regex == true and 1 or 0,
        timeoutMs = timeout_ms,
        orderIndex = order_index,
        rawJson = raw_json,
    }
end

function M:syncTextTransformRules(bookShelfId, rules, dialect)
    bookShelfId = bookShelfId or "local"
    if dialect ~= "reader3" and dialect ~= "legado" and dialect ~= "qread" then
        error("Unsupported text transform dialect: " .. tostring(dialect))
    end
    local valid, err = require("Legado.Helper.TextTransformRules").validateSnapshot(rules)
    if not valid then error(err) end

    local normalized, keys = {}, {}
    for index, rule in ipairs(rules) do
        local item = normalize_text_transform_rule(rule, dialect, index)
        if item then
            normalized[#normalized + 1] = item
            keys[item.ruleKey] = true
        end
    end

    local sql = [[
        INSERT INTO text_transform_rules
        (bookShelfId, ruleKey, name, groupName, pattern, replacement, scope, excludeScope,
         scopeTitle, scopeContent, isEnabled, isRegex, timeoutMs, orderIndex, rawJson)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bookShelfId, ruleKey) DO UPDATE SET
            name = excluded.name,
            groupName = excluded.groupName,
            pattern = excluded.pattern,
            replacement = excluded.replacement,
            scope = excluded.scope,
            excludeScope = excluded.excludeScope,
            scopeTitle = excluded.scopeTitle,
            scopeContent = excluded.scopeContent,
            isEnabled = excluded.isEnabled,
            isRegex = excluded.isRegex,
            timeoutMs = excluded.timeoutMs,
            orderIndex = excluded.orderIndex,
            rawJson = excluded.rawJson
    ]]

    local null = M.nil_object()
    self:transaction(function()
        for _, item in ipairs(normalized) do
            self:execute(sql, {
                bookShelfId, item.ruleKey, item.name, item.groupName or null, item.pattern, item.replacement,
                item.scope or null, item.excludeScope or null, item.scopeTitle or null, item.scopeContent or null,
                item.isEnabled, item.isRegex, item.timeoutMs or null, item.orderIndex, item.rawJson or null,
            })
        end

        local existing = self:execute(
            "SELECT ruleKey FROM text_transform_rules WHERE bookShelfId = ?",
            { bookShelfId }
        )
        if type(existing) == "table" then
            for _, row in ipairs(existing) do
                if not keys[row[1]] then
                    self:execute(
                        "DELETE FROM text_transform_rules WHERE bookShelfId = ? AND ruleKey = ?",
                        { bookShelfId, row[1] }
                    )
                end
            end
        end
        record_sync_success(self, bookShelfId, "text_transform_rules", #normalized)
    end)()

    return #normalized
end

local function text_rule_bool(value)
    if value == nil then return nil end
    return tonumber(value) == 1
end

function M:getEnabledTextTransformRules(bookShelfId)
    bookShelfId = bookShelfId or "local"
    local rules = {}
    local sql = [[
        SELECT id, ruleKey, name, groupName, pattern, replacement, scope, excludeScope,
               scopeTitle, scopeContent, isRegex, timeoutMs, orderIndex, rawJson
        FROM text_transform_rules
        WHERE isEnabled = 1 AND bookShelfId = ?
        ORDER BY orderIndex ASC, id ASC
    ]]
    local results = self:execute(sql, { bookShelfId })
    if type(results) == "table" then
        for _, row in ipairs(results) do
            rules[#rules + 1] = {
                dbId = tonumber(row[1]),
                ruleKey = row[2],
                name = row[3],
                group = row[4],
                pattern = row[5],
                replacement = row[6],
                scope = row[7],
                excludeScope = row[8],
                scopeTitle = text_rule_bool(row[9]),
                scopeContent = text_rule_bool(row[10]),
                isRegex = tonumber(row[11]) == 1,
                timeoutMs = tonumber(row[12]),
                orderIndex = tonumber(row[13]) or 0,
                rawJson = row[14],
                isEnabled = true,
            }
        end
    end
    return rules
end

function M:deleteBookSource(bookShelfId, url)
    if not url then return false end
    bookShelfId = bookShelfId or "local"
    self:execute("DELETE FROM book_sources WHERE bookShelfId = ? AND bookSourceUrl = ?", { bookShelfId, url })
    return true
end

function M:toggleBookSourceEnable(bookShelfId, url, is_enabled)
    if not url then return false end
    bookShelfId = bookShelfId or "local"
    self:execute("UPDATE book_sources SET enabled = ? WHERE bookShelfId = ? AND bookSourceUrl = ?", {
        is_enabled and 1 or 0, bookShelfId, url
    })
    return true
end

return M
