local DataStorage = require("datastorage")
local PlgState = require("Legado/PlgState")
local FS = require("Legado.Helper.FS")

local M = {}

local LEGADO_CACHE_PATH = "/cache/legado.cache/"
local LEGADO_BOOK_DIR = "Legado\u{200B}书目"
local REGEX_LEGADO_BOOK_DIR = string.format("/%s/", LEGADO_BOOK_DIR)
local LEGADO_EXT = "\u{200B}.html"

local function get_file_path(file_path, instance)
    if instance and instance.document and instance.document.file then
        return instance.document.file
    end
    return file_path
end

M.is_legado_path = function(file_path, instance)
    local path = get_file_path(file_path, instance)
    return type(path) == 'string' and path:lower():find(LEGADO_CACHE_PATH, 1, true) ~= nil
end

M.is_legado_browser_book = function(file_path, instance)
    local path = get_file_path(file_path, instance)
    if type(path) ~= "string" then return false end
    if path:find(REGEX_LEGADO_BOOK_DIR, 1, true) ~= nil then
        return true
    end
    return path:find(LEGADO_EXT, 1, true) ~= nil
end

local CHAPTER_CACHE_EXTENSIONS = {
    htm = true,
    html = true,
    xhtml = true,
    txt = true,
    cbz = true,
}

M.is_legado_chapter_cache = function(file_path, instance)
    local path = get_file_path(file_path, instance)
    if not M.is_legado_path(path) then return false end
    local extension = type(path) == "string" and path:match("%.([^%.]+)$")
    if not extension then return false end
    return CHAPTER_CACHE_EXTENSIONS[extension:lower()] == true
end
M.is_legado_cache_file = M.is_legado_chapter_cache

M.is_legado_book = function(file_path, instance)
    local path = get_file_path(file_path, instance)
    -- 1. 传统 cache 目录与旧版伪链接判断
    if M.is_legado_path(path) or M.is_legado_browser_book(path) then
        return true
    end

    -- 2. DocSettings (Layer 1)
    local doc_settings
    if instance and instance.doc_settings then
        doc_settings = instance.doc_settings
    elseif type(path) == "string" and path ~= "" then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings.open then
            doc_settings = DocSettings:open(path)
        end
    end
    if doc_settings and doc_settings.data then
        if doc_settings.data.provider == "legado" or doc_settings.data.book_cache_id or doc_settings.data.is_skeleton_epub then
            return true
        end
    end

    -- 3. EPUB OPF 自包含元数据 (Layer 2)
    if instance and instance.document then
        local doc = instance.document
        local props = (doc.getProps and doc:getProps())
            or (doc.getDocumentProps and doc:getDocumentProps())
            or (doc._document and doc._document.getDocumentProps and doc._document:getDocumentProps())
            or (doc.info and doc.info.doc_props) or {}
        local book_id = (doc.getMetadata and doc:getMetadata("identifier"))
            or props.identifier or props.description or props.keywords or props.title or (doc.info and doc.info.title)
        if type(book_id) == "string" and book_id:find("legado%-skeleton%-book") then
            local cache_id = book_id:match("legado%-skeleton%-book_([%w_]+)")
            if cache_id and doc_settings and doc_settings.saveSetting then
                doc_settings:saveSetting("provider", "legado")
                doc_settings:saveSetting("book_cache_id", cache_id)
                doc_settings:saveSetting("is_skeleton_epub", true):flush()
            end
            return true
        end
    end

    return false
end

M.is_legado_full_book = function(file_path, instance)
    if not M.is_legado_book(file_path, instance) then
        return false
    end
    local path = get_file_path(file_path, instance)
    if type(path) == "string" and path:match("%.epub$") ~= nil then
        return true
    end
    local doc_settings = (instance and instance.doc_settings) or (instance and instance.ui and instance.ui.doc_settings)
    if doc_settings and doc_settings.data and doc_settings.data.is_skeleton_epub == true then
        return true
    end
    return false
end

M.getUserSettingsPath = function()
    return FS.joinPath(DataStorage:getSettingsDir(), (PlgState.plg_name or "legado") .. '.lua')
end

M.getKoreaderDirectory = function()
    return DataStorage:getDataDir()
end

M.getTempDirectory = function()
    local plg_cache_dir = (PlgState.plg_name or "legado") .. '.cache'
    local plg_cache_path = FS.joinPath(DataStorage:getDataDir(), 'cache/' .. plg_cache_dir)
    return FS.checkAndCreateFolder(plg_cache_path)
end

M.getPluginName = function()
    return PlgState.plg_name or "legado"
end

M.getPluginDirectory = function()
    local plg_path_alt = table.concat({DataStorage:getDataDir(), "/plugins/", PlgState.plg_name or "legado", '.koplugin'})
    return PlgState.plg_path or plg_path_alt
end

M.getBookCachePath = function(book_cache_id)
    assert(type(book_cache_id) == "string", "Error: The variable is not a string.")
    local plg_cache_path = M.getTempDirectory()
    local book_cache_path = FS.joinPath(plg_cache_path, book_cache_id .. '.sdr')
    FS.checkAndCreateFolder(book_cache_path)
    return book_cache_path
end

M.getCoverCacheFilePath = function(book_cache_id)
    local book_cache_path = M.getBookCachePath(book_cache_id)
    return FS.joinPath(book_cache_path, 'cover')
end

M.getChapterCacheFilePath = function(book_cache_id, chapters_index, book_name)
    book_name = FS.getSafeFilename(book_name)
    local book_cache_path = M.getBookCachePath(book_cache_id)
    local chapter_cache_name = string.format("%s-%s", book_name or "", chapters_index)
    return FS.joinPath(book_cache_path, chapter_cache_name)
end

M.getVirtualBookEpubPath = function(book_cache_id, book_name)
    assert(type(book_cache_id) == "string", "Error: book_cache_id must be a string.")
    local book_cache_path = M.getBookCachePath(book_cache_id)
    local safe_name = (type(book_name) == "string" and book_name ~= "") and FS.getSafeFilename(book_name) or "book"
    return FS.joinPath(book_cache_path, safe_name .. ".epub")
end

M.getHomeDir = function()
    return G_reader_settings and G_reader_settings:readSetting("home_dir") or
               require("apps/filemanager/filemanagerutil").getDefaultDir()
end

M.getLinksDir = function()
    return FS.joinPath(M.getHomeDir(), LEGADO_BOOK_DIR), LEGADO_BOOK_DIR
end

function M.getLinkName(name, author)
    if type(name) ~= "string" or name == "" then return nil end
    local valid_author = (type(author) == "string" and author ~= "") and author or "未知作者"
    local book_lnk_name = string.format("%s-%s", name, valid_author)
    book_lnk_name = FS.getSafeFilename(book_lnk_name)
    if not book_lnk_name or book_lnk_name == "" then return nil end
    return book_lnk_name .. LEGADO_EXT
end

return M
