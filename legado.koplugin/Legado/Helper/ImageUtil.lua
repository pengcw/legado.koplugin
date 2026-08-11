local util = require("util")
local logger = require("logger")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")
local httpReq = require("Legado.Helper.Http")

local M = {}

local function save_processed(data, output_path, ext)
    local RenderImage = require("ui/renderimage")
    local bb = RenderImage:renderImageData(data, #data, false, nil, nil)
    local final_success = false

    if bb and bb.writeToFile then
        local ok, write_ok = pcall(bb.writeToFile, bb, output_path, ext, nil, nil)
        final_success = ok and write_ok and true or false
    else
        util.writeToFile(data, output_path, true)
        local DocumentRegistry = require("document/documentregistry")
        local temp_doc = DocumentRegistry:openDocument(output_path)
        if temp_doc then
            local status, cover_bb = pcall(temp_doc.getCoverPageImage, temp_doc)
            if status and cover_bb and type(cover_bb.getWidth) == "function" then
                bb = cover_bb
                local write_ok, write_err = pcall(bb.writeToFile, bb, output_path, ext, nil, nil)
                final_success = write_ok and write_err and true or false
            end
            temp_doc:close()
        end
    end

    if bb and bb.free then
        bb:free()
    end
    return final_success
end

function M.findCustomCoverFileInDir(cover_path_no_ext)
    if not H.is_str(cover_path_no_ext) then return nil end
    local dir, image_filename = util.splitFilePathName(cover_path_no_ext)
    if not (dir and image_filename) then
        logger.err(string.format("findCustomCoverFileInDir: invalid name (%s, %s)", tostring(dir),
            tostring(image_filename)))
        return nil
    end
    if not util.pathExists(dir) then return nil end
    local extensions = { "jpg", "jpeg", "png", "webp", "bmp", "tiff" }
    for _, ext in ipairs(extensions) do
        local cover_full_path = string.format("%s.%s", cover_path_no_ext, ext)
        if util.fileExists(cover_full_path) then
            return cover_full_path, string.format("%s.%s", image_filename, ext)
        end
    end
    return nil
end

function M.get_default_cover_cache(book_cache_id)
    if not (H.is_str(book_cache_id) and book_cache_id ~= "") then
        return nil
    end
    local cover_path_no_ext = Env.getCoverCacheFilePath(book_cache_id)
    return M.findCustomCoverFileInDir(cover_path_no_ext)
end

-- Function called frequently; keep logs minimal
function M.download_cover(book_cache_id, img_src, is_force)
    if not (H.is_str(book_cache_id) and book_cache_id ~= ""
            and H.is_str(img_src) and img_src ~= "") then
        logger.err("download_cover: invalid parameter", book_cache_id, img_src)
        return nil, nil
    end

    if not is_force then
        local cover_full_path = M.get_default_cover_cache(book_cache_id)
        if H.is_str(cover_full_path) then
            local dir, image_filename = util.splitFilePathName(cover_full_path)
            return cover_full_path, image_filename
        end
    end

    local cover_path_no_ext = Env.getCoverCacheFilePath(book_cache_id)
    local lock_path = cover_path_no_ext .. ".downloading"

    if util.fileExists(lock_path) then
        if not FS.isFileOlderThan(lock_path, 60) then
            logger.warn("download_cover: Cover download already in progress", book_cache_id)
            return nil, nil
        else
            util.removeFile(lock_path)
        end
    end

    local dir = util.splitFilePathName(cover_path_no_ext)
    FS.checkAndCreateFolder(dir)
    util.writeToFile("", lock_path)
    local imgdata, ext_or_err = M.download_image(img_src)
    if not imgdata then
        util.removeFile(lock_path)
        logger.dbg("download_cover: failed", img_src, ext_or_err)
        return nil, nil
    end
    local ext = ext_or_err

    if #imgdata < 1024 then
        util.removeFile(lock_path)
        logger.dbg("download_cover: Image size is less than 1KB, discarding", #imgdata)
        return nil, nil
    end

    local final_img_path = string.format("%s.%s", cover_path_no_ext, ext)

    local is_success = save_processed(imgdata, lock_path, ext)
    if not is_success then
        util.removeFile(lock_path)
        logger.dbg("download_cover: Invalid cover image data")
        return nil, nil
    end

    local extensions = { "jpg", "jpeg", "png", "webp", "bmp", "tiff" }
    for _, old_ext in ipairs(extensions) do
        local old_path = string.format("%s.%s", cover_path_no_ext, old_ext)
        if util.fileExists(old_path) then util.removeFile(old_path) end
    end

    local ok_rename, err_rename = os.rename(lock_path, final_img_path)
    if not ok_rename then
        logger.err("download_cover: rename failed", err_rename)
        return nil, nil
    end

    local _, image_filename = util.splitFilePathName(final_img_path)
    return final_img_path, image_filename
end
function M.convertToGrayscale(image_data)
    local Png = require("Legado/Png")
    return Png.processImage(Png.toGrayscale, image_data, 1)
end

function M.extract_urls_from_html(content, proxy_resolver_func)
    if type(content) ~= "string" then
        return {}
    end

    local img_sources = {}
    local img_pattern = '<img[^>]-src%s*=%s*["\']?([^"\'>%s]+)["\']?[^>]*>'

    for src in content:gmatch(img_pattern) do
        if src and src ~= "" then
            if type(proxy_resolver_func) == "function" then
                src = proxy_resolver_func(src)
            end
            table.insert(img_sources, src)
        end
    end

    return img_sources
end

function M.get_url_extension(url)
    local socket_url = require("socket.url")
    if type(url) ~= "string" or url == "" then
        return ""
    end
    local parsed = socket_url.parse(url)
    local path = parsed and parsed.path
    if not path or path == "" then
        return ""
    end
    path = socket_url.unescape(path):gsub("/+$", "")

    local filename = path:match("([^/]+)$") or ""
    local ext = filename:match("%.([%w]+)$")
    return ext and ext:lower() or "", filename
end

-- success: data, ext | fail: nil, err
-- opts: timeout(15), maxtime(60), headers
function M.download_image(url, opts)
    if type(url) ~= "string" or url == "" then
        return nil, "invalid image url"
    end
    opts = opts or {}

    local ok, resp = httpReq({
        url = url,
        timeout = opts.timeout or 15,
        maxtime = opts.maxtime or 60,
        headers = opts.headers,
        is_pic = true,
    }, true)
    if not ok or type(resp) ~= "table" or not resp['data'] then
        return nil, (type(resp) == "string" and resp) or "image download failed"
    end

    local ext = resp.ext
    if not ext or ext == "" then
        ext = M.get_url_extension(url)
    end
    if not ext or ext == "" then
        ext = "png"
    end
    return resp['data'], ext
end

return M