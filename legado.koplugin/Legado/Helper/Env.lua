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
    return type(path) == "string"
            and path:find(REGEX_LEGADO_BOOK_DIR, 1, true) ~= nil
            and path:find(LEGADO_EXT, 1, true) ~= nil
end

M.is_legado_cache_file = function(file_path, instance)
    local path = get_file_path(file_path, instance)
    if not M.is_legado_path(path) then return false end
    local extension = path:match("%.([^%.]+)$")
    if not extension then return false end
    local valid_extensions = {htm=true, html=true, xhtml=true, txt=true}
    return valid_extensions[extension:lower()]
end

M.getUserSettingsPath = function()
    return FS.joinPath(DataStorage:getSettingsDir(), PlgState.plg_name .. '.lua')
end

M.getKoreaderDirectory = function()
    return DataStorage:getDataDir()
end

M.getTempDirectory = function()
    local plg_cache_dir = PlgState.plg_name .. '.cache'
    local plg_cache_path = FS.joinPath(DataStorage:getDataDir(), 'cache/' .. plg_cache_dir)
    return FS.checkAndCreateFolder(plg_cache_path)
end

M.getPluginName =function()
    return PlgState.plg_name
end

M.getPluginDirectory = function()
    local plg_path_alt = table.concat({DataStorage:getDataDir(), "/plugins/", PlgState.plg_name, '.koplugin'})
    return PlgState.plg_path or plg_path_alt
end

M.getBookCachePath = function(book_cache_id)
    assert(type(book_cache_id) == "string", "Error: The variable is not a string.")
    local plg_cache_path = M.getTempDirectory()
    local book_cache_path = FS.joinPath(plg_cache_path, book_cache_id)
    FS.checkAndCreateFolder(book_cache_path)
    FS.checkAndCreateFolder(FS.joinPath(book_cache_path, "resources"))
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
