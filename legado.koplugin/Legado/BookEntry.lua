local DocSettings = require("docsettings")
local FS = require("Legado.Helper.FS")
local util = require("util")
local logger = require("logger")

local M = {}
local MARK = "\u{200B}"

function M.identify(path)
    if type(path) ~= "string" then return end
    local extension = path:sub(-5):lower()
    if extension ~= ".html" and extension ~= ".epub" then return end
    local kind = extension:sub(2)
    if path:sub(-8, -6) == MARK then return kind end
    if not DocSettings:hasSidecarFile(path) then return end
    local ds = DocSettings:open(path)
    if ds:readSetting("legado_entry") == kind
            or (kind == "epub" and ds:readSetting("is_skeleton_epub") == true) then
        return kind, ds
    end
end

function M.metadata(path, book, kind)
    local ds = DocSettings:open(path)
    local values = {
        provider = "legado", legado_entry = kind, book_cache_id = book.cache_id,
        title = book.name, authors = book.author or "未知作者", description = book.intro or "",
    }
    if kind == "epub" then
        values.is_skeleton_epub = true
    elseif kind == "html" then
        values.partial_md5_checksum = "legado-chapters-pages-" .. book.cache_id
    end
    local changed = false
    for key, value in pairs(values) do
        if ds:readSetting(key) ~= value then ds:saveSetting(key, value); changed = true end
    end
    if changed then ds:flush() end
    return changed
end

function M.resolve(path, readonly, kind, ds)
    if not kind then kind, ds = M.identify(path) end
    if not kind then return end
    ds = ds or DocSettings:open(path)
    local id = ds:readSetting("book_cache_id")
    if type(id) ~= "string" or id == "" then
        if kind == "epub" then
            local epub = require("Legado.Skeleton.Epub")
            if readonly then
                local metadata = epub.readSkeletonMetadata(path)
                id = metadata and metadata.book_cache_id
            elseif epub.restoreDocSettings(path) then
                ds = DocSettings:open(path)
                id = ds:readSetting("book_cache_id")
            end
        else
            local file = io.open(path, "rb")
            local header = file and file:read(8192)
            if file then file:close() end
            if header then
                id = header:match('<meta name="legado:book_cache_id" content="([%w_%-]+)"')
                if not id and (header:match("^%s*%-%-") or header:match("^%s*return%s")) then
                    local config = require("luasettings"):open(path)
                    if type(config.data) == "table" then id = config:readSetting("book_cache_id") end
                end
            end
        end
    end
    if type(id) ~= "string" or id == "" or id:find("[/\\]") then
        return nil, "无法恢复快捷入口的书籍 ID"
    end
    if readonly then return { path = path, kind = kind, book_cache_id = id } end
    local changed = false
    for key, value in pairs({ provider = "legado", legado_entry = kind, book_cache_id = id }) do
        if ds:readSetting(key) ~= value then ds:saveSetting(key, value); changed = true end
    end
    if changed then ds:flush() end
    return { path = path, kind = kind, book_cache_id = id }
end

function M.repair(entry)
    local path, kind = entry.path, entry.kind
    local suffix = MARK .. "." .. kind
    if path:sub(-#suffix):lower() == suffix then return path end
    local destination = path:sub(1, -(#kind + 2)) .. suffix
    if util.pathExists(destination) or not FS.moveFile(path, destination) then
        return path, "无法补回快捷文件标识，保留原名称继续打开"
    end
    DocSettings.updateLocation(path, destination)
    require("readhistory"):updateItem(path, destination)
    require("readcollection"):updateItem(path, destination)
    entry.path = destination
    return destination
end

function M.isEpubInDirectory(epub_path, output_dir)
    if not epub_path or type(output_dir) ~= "string" or output_dir == "" then return false end
    local realpath = require("ffi/util").realpath
    local directory = realpath(output_dir)
    return directory ~= nil and realpath(util.splitFilePathName(epub_path)) == directory
end

function M.ensureHtml(book, output_dir, epub_path)
    if type(output_dir) ~= "string" or output_dir == "" or not util.directoryExists(output_dir) then
        return nil, "请先设置有效的书架目标目录"
    end
    local id = book and book.cache_id
    if type(id) ~= "string" or id == "" or id:find("[^%w_%-]") then
        return nil, "快捷入口书籍 ID 无效"
    end
    if M.isEpubInDirectory(epub_path, output_dir) then return false end
    local filename_author = type(book.author) == "string" and book.author ~= "" and book.author or "未知作者"
    local name = FS.getSafeFilename(string.format("%s-%s", book.name or "", filename_author), nil, nil, 0)
    local path = FS.joinPath(output_dir, name .. MARK .. ".html")
    local epub = require("Legado/EpubHelper")
    local escape = epub.escape_xml
    local title, author = escape(book.name or ""), escape(book.author or "未知作者")
    local html = '<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n'
        .. '<meta name="legado:book_cache_id" content="' .. id .. '">\n'
        .. '<meta name="author" content="' .. epub.escape_xml_attr(book.author or "未知作者", '"') .. '">\n'
        .. '<title>' .. title .. '</title></head><body><h1>' .. title .. '</h1><p>' .. author
        .. '</p></body></html>\n'
    local changed = false
    if not util.fileExists(path) or util.readFromFile(path) ~= html then
        if not util.writeToFile(html, path, true) then return nil, "快捷 HTML 写入失败" end
        changed = true
    end
    changed = M.metadata(path, book, "html") or changed
    return path, changed
end

function M.mapCachedBooks(backend)
    local settings = backend:getSettings()
    local result = { mapped = 0, skipped = 0, failed = 0 }
    if settings.virtual_bookshelf_enabled ~= true then return result end
    local output_dir = settings.virtual_bookshelf_dir
    if not (type(output_dir) == "string" and output_dir ~= "" and util.directoryExists(output_dir)) then
        return nil, "请先设置有效的目标目录"
    end
    for _, book in ipairs(backend:getBookShelfCache()) do
        for _, path in ipairs(backend.dbManager:getChapterCachePaths(book.cache_id)) do
            if not path:lower():match("%.epub$") and FS.getFileSize(path) > 0 then
                local ok, entry_path = pcall(function()
                    local epub_path = require("Legado.Skeleton.BookStore"):location(book.cache_id)
                    local path, changed = M.ensureHtml(book, output_dir, epub_path)
                    if path == nil then error(changed) end
                    if changed then backend:emitMetadataChanged(path) end
                    return path
                end)
                if ok then
                    if entry_path then result.mapped = result.mapped + 1
                    else result.skipped = result.skipped + 1 end
                else
                    result.failed = result.failed + 1
                    logger.warn("书架映射失败:", book.cache_id, tostring(entry_path))
                end
                break
            end
        end
    end
    return result
end

return M
