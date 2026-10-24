local util = require("util")
local logger = require("logger")
local ffi = require("ffi")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")
local httpReq = require("Legado.Helper.Http")
local image_meta = require("Legado.Helper.image_meta")

local LEGADO_ERR_PREFIX = '{"isSuccess":false'
local function detect_server_error(data)
    if type(data) ~= "string" or #data < 4 then return nil end
    if #data >= #LEGADO_ERR_PREFIX
            and data:sub(1, #LEGADO_ERR_PREFIX) == LEGADO_ERR_PREFIX then
        return data:match('"errorMsg"%s*:%s*"([^"]*)"') or "legado 代理返回错误响应"
    end
    local head = data:sub(1, 128):lower()
    if head:find("<!doctype html", 1, true) or head:find("<html", 1, true) then
        return "服务器返回 HTML 页面（非图片）"
    end
    if head:find("404", 1, true) and head:find("not found", 1, true) then
        return "服务器返回 404 文本（非图片）"
    end
    return nil
end

local M = {}

local LOCAL_DEBUG_SAVE_INVALID = false

local function debug_save_invalid(data, reason, url)
    if not LOCAL_DEBUG_SAVE_INVALID then return end
    if type(data) ~= "string" or #data == 0 then return end
    local ok = pcall(function()
        local dir = Env.getTempDirectory()
        FS.checkAndCreateFolder(FS.joinPath(dir, "invalid_covers"))
        local name = string.format("%s_%s.raw", reason, H.md5(url or tostring(#data)))
        local path = FS.joinPath(FS.joinPath(dir, "invalid_covers"), name)
        util.writeToFile(data, path, true)
        logger.warn("download_image: 无效图片数据已保留供分析 ->", path,
            "size=", #data, "url=", tostring(url))
    end)
    if not ok then
        logger.warn("download_image: 无效图片数据保留失败")
    end
end

if not pcall(ffi.typeof, "z_stream") then
    ffi.cdef[[
        typedef void *(*z_alloc_func)(void *opaque, unsigned int items, unsigned int size);
        typedef void (*z_free_func)(void *opaque, void *address);
        typedef struct z_stream_s {
            const unsigned char *next_in;
            unsigned int avail_in;
            unsigned long total_in;
            unsigned char *next_out;
            unsigned int avail_out;
            unsigned long total_out;
            const char *msg;
            void *state;
            z_alloc_func zalloc;
            z_free_func zfree;
            void *opaque;
            int data_type;
            unsigned long adler;
            unsigned long reserved;
        } z_stream;
    ]]
end
pcall(ffi.cdef, "const char *zlibVersion(void);")
pcall(ffi.cdef, "int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);")
pcall(ffi.cdef, "int inflate(z_stream *strm, int flush);")
pcall(ffi.cdef, "int inflateEnd(z_stream *strm);")
local libz
if pcall(ffi.typeof, "z_stream") then
    local ok, lib = pcall(function() return ffi.loadlib("z", 1) end)
    if not (ok and lib) then
        ok, lib = pcall(ffi.load, "z")
    end
    libz = ok and lib or nil
end

local Z_NO_FLUSH = 0
local Z_OK = 0
local Z_STREAM_END = 1
local GUNZIP_CHUNK_SIZE = 32 * 1024
local MAX_GUNZIP_OUTPUT = 64 * 1024 * 1024

local function get_zlib_version()
    if not libz then return nil end
    local ok, version = pcall(function()
        return ffi.string(libz.zlibVersion())
    end)
    return ok and version or nil
end

function M.gunzip(data, options)
    local max_output = options and options.max_output or MAX_GUNZIP_OUTPUT
    if type(max_output) ~= "number" or max_output % 1 ~= 0
        or max_output < 1 or max_output > MAX_GUNZIP_OUTPUT then
        return nil, "invalid inflate output limit"
    end
    if type(data) ~= "string" or data:sub(1, 2) ~= "\x1f\x8b" then
        return nil, "not gzip"
    end
    if not libz then return nil, "zlib unavailable" end

    local version = get_zlib_version()
    if not version then return nil, "zlib version unavailable" end

    local strm = ffi.new("z_stream")
    strm.next_in = ffi.cast("const unsigned char*", data)
    strm.avail_in = #data

    local ret = libz.inflateInit2_(strm, 31, version, ffi.sizeof("z_stream"))
    if ret ~= Z_OK then
        return nil, "inflateInit2 failed: " .. tostring(ret)
    end

    local chunks = {}
    local total = 0
    while true do
        local out = ffi.new("unsigned char[?]", GUNZIP_CHUNK_SIZE)
        strm.next_out = out
        strm.avail_out = GUNZIP_CHUNK_SIZE

        ret = libz.inflate(strm, Z_NO_FLUSH)
        local produced = GUNZIP_CHUNK_SIZE - tonumber(strm.avail_out)
        if produced > 0 then
            total = total + produced
            if total > max_output then
                libz.inflateEnd(strm)
                return nil, "inflate output too large"
            end
            chunks[#chunks + 1] = ffi.string(out, produced)
        end

        if ret == Z_STREAM_END then
            if options and options.strict and strm.avail_in ~= 0 then
                libz.inflateEnd(strm)
                return nil, "trailing gzip data"
            end
            break
        end
        if ret ~= Z_OK then
            local err = strm.msg ~= nil and ffi.string(strm.msg) or tostring(ret)
            libz.inflateEnd(strm)
            return nil, "inflate failed: " .. err
        end
    end

    libz.inflateEnd(strm)
    return table.concat(chunks)
end

local function save_processed(data, output_path)
    local ok = util.writeToFile(data, output_path, true)
    return ok and true or false
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
    local extensions = image_meta.IMAGE_EXTENSIONS
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

function M.download_cover(book_cache_id, img_src, is_force, opts)
    if not (H.is_str(book_cache_id) and book_cache_id ~= ""
            and H.is_str(img_src) and img_src ~= "") then
        logger.err("download_cover: invalid parameter", book_cache_id, img_src)
        return nil, nil
    end

    if not is_force then
        local cover_full_path = M.get_default_cover_cache(book_cache_id)
        if H.is_str(cover_full_path) then
            local _, image_filename = util.splitFilePathName(cover_full_path)
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
    local imgdata, ext_or_err = M.download_image(img_src, opts)
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

    local extensions = image_meta.IMAGE_EXTENSIONS
    for _, old_ext in ipairs(extensions) do
        local old_path = string.format("%s.%s", cover_path_no_ext, old_ext)
        if util.fileExists(old_path) then util.removeFile(old_path) end
    end

    local ok_rename, err_rename = os.rename(lock_path, final_img_path)    if not ok_rename then
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
    local ext = image_meta.get_image_ext(filename)
    return ext or "", filename
end

function M.download_image(url, opts)
    if type(url) ~= "string" or url == "" then
        return nil, "invalid image url"
    end
    opts = opts or {}

    local ok, resp = httpReq({
        url = url,
        timeout = opts.timeout or 60,
        headers = opts.headers,
        is_pic = true,
    }, true)
    if not ok or type(resp) ~= "table" or not resp['data'] then
        return nil, (type(resp) == "string" and resp) or "image download failed"
    end

    local data = resp['data']
    if data:sub(1, 2) == "\x1f\x8b" then
        local raw, gerr = M.gunzip(data)
        if not raw then
            return nil, "gunzip failed: " .. tostring(gerr)
        end
        data = raw
    end

    local ext = image_meta.sniff_format(data)
    if not image_meta.is_valid_image(data) then
        local srv_err = detect_server_error(data)
        if srv_err then
            logger.warn("download_image: 服务器错误响应 ->", srv_err, "url=", tostring(url))
            debug_save_invalid(data, "server", url)
            return nil, "server error: " .. srv_err
        end
        if ext ~= nil then
            debug_save_invalid(data, "struct", url)
            return nil, "invalid image data"
        end
        local ok2, bb = pcall(function()
            local RenderImage = require("ui/renderimage")
            return RenderImage:renderImageData(data, #data)
        end)
        if not ok2 or not bb then
            debug_save_invalid(data, "mupdf", url)
            return nil, "invalid image data"
        end
        ext = "img"
    end
    return data, ext
end

return M
