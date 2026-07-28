local DataStorage = require("datastorage")
local PlgState = require("Legado/PlgState")
local FS = require("Legado.Helper.FS")

local M = {}

M.getUserSettingsPath = function()
    return FS.joinPath(DataStorage:getSettingsDir(), PlgState.plg_name .. '.lua')
end

M.getUserPatchesDirectory = function()
    local patches_dir = FS.joinPath(DataStorage:getDataDir(), 'patches')
    return FS.checkAndCreateFolder(patches_dir)
end

M.getKoreaderDirectory = function()
    return DataStorage:getDataDir()
end

M.getTempDirectory = function()
    local plg_cache_dir = PlgState.plg_name .. '.cache'
    local plg_cache_path = FS.joinPath(DataStorage:getDataDir(), 'cache/' .. plg_cache_dir)
    return FS.checkAndCreateFolder(plg_cache_path)
end

M.getPluginDirectory = function()
    local plg_path_alt = table.concat({DataStorage:getDataDir(), "/plugins/", PlgState.plg_name, '.koplugin'})
    return PlgState.plg_path or plg_path_alt
end

M.getBookCachePath = function(book_cache_id)
    assert(type(book_cache_id) == "string", "Error: The variable is not a string.")
    local plg_cache_path = M.getTempDirectory()
    local book_cache_path = FS.joinPath(plg_cache_path, book_cache_id .. '.sdr')
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

return M
