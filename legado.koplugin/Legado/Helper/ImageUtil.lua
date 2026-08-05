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

    local ok, resp = httpReq({
        url = img_src,
        timeout = 15,
        maxtime = 60,
        is_pic = true,
    }, true)
    if ok and resp and resp['data'] then
        local content_length = tonumber(resp.headers and resp.headers["content-length"]) or #resp['data']
        if content_length < 1024 then
            util.removeFile(lock_path)
            logger.dbg("download_cover: Image size is less than 1KB, discarding", content_length)
            return nil, nil
        end

        local ext = resp.ext or "jpg"
        local final_img_path = string.format("%s.%s", cover_path_no_ext, ext)

        local is_success = save_processed(resp['data'], lock_path, ext)
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
    else
        util.removeFile(lock_path)
        logger.dbg("download_cover: failed", img_src, resp)
        return nil, nil
    end
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

function M.create_cbz_from_urls(filePath, img_sources, check_running_callback)
    if not filePath or not H.is_tbl(img_sources) then
        error("Cbz param error:")
    end

    local is_convertToGrayscale = false
    local cbz_path_tmp = filePath .. '.downloading'

    if util.fileExists(cbz_path_tmp) then
        if type(check_running_callback) == "function" and check_running_callback() then
            error("Other threads downloading, cancelled")
        else
            util.removeFile(cbz_path_tmp)
        end
    end

    local cbz
    local cbz_lib
    local no_compression
    local mtime

    local ok, ZipWriter = pcall(require, "ffi/zipwriter")
    if ok and ZipWriter then
        cbz_lib = "zipwriter"
        no_compression = true
        cbz = ZipWriter:new{}
        if not cbz:open(cbz_path_tmp) then
            error('CreateCBZ cbz:open err')
        end
        cbz:add("mimetype", "application/vnd.comicbook+zip", true)
    else
        cbz_lib = "archiver"
        mtime = os.time()
        local Archiver = require("ffi/archiver").Writer
        cbz = Archiver:new{}
        if not cbz:open(cbz_path_tmp, "epub") then
            error(string.format("CreateCBZ cbz:open err: %s", tostring(cbz.err)))
        end
        cbz:setZipCompression("store")
        cbz:addFileFromMemory("mimetype", "application/vnd.comicbook+zip", mtime)
        cbz:setZipCompression("deflate")
    end

    for i, img_src in ipairs(img_sources) do
        logger.dbg('Download_Image start', i, img_src)
        local status, resp = httpReq({
                url = img_src,
                timeout = 15,
                maxtime = 60,
                is_pic = true,
        }, true)

        if status and H.is_tbl(resp) and resp['data'] then
            local imgdata = resp['data']
            local img_extension = resp['ext']
            if not img_extension or img_extension == "" then
                img_extension = M.get_url_extension(img_src)
            end
            if not img_extension or img_extension == "" then
                img_extension = "png"
            end
            local img_name = string.format("%d.%s", i, img_extension)
            if is_convertToGrayscale == true and img_extension == 'png' then
                local success, imgdata_new = M.convertToGrayscale(imgdata)
                if success == true then
                    imgdata = imgdata_new.data
                else
                    goto continue
                end
            end

            if cbz_lib == "zipwriter" then
                cbz:add(img_name, imgdata, no_compression)
            else
                cbz:addFileFromMemory(img_name, imgdata, mtime)
            end
        else
            logger.dbg('Download_Image err', tostring(resp))
        end
        ::continue::
    end

    if cbz and cbz.close then
        cbz:close()
    end
    logger.dbg('CreateCBZ cbz:close')

    if util.fileExists(filePath) ~= true then
        os.rename(cbz_path_tmp, filePath)
    else
        if util.fileExists(cbz_path_tmp) == true then
            util.removeFile(cbz_path_tmp)
        end
        error('exist target file, cancelled')
    end

    return filePath
end

return M
