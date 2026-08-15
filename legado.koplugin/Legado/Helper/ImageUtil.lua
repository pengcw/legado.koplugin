local util = require("util")
local logger = require("logger")
local ffi = require("ffi")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")
local httpReq = require("Legado.Helper.Http")
local IMG = require("Legado.Helper.image_meta")

local M = {}


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
        int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
        int inflate(z_stream *strm, int flush);
        int inflateEnd(z_stream *strm);
    ]]
end
local libz
if pcall(ffi.typeof, "z_stream") then
    local ok, lib = pcall(ffi.load, "z")
    libz = ok and lib or nil
end

function M.gunzip(data)
    if type(data) ~= "string" or data:sub(1, 2) ~= "\x1f\x8b" then
        return nil, "not gzip"
    end
    if not libz then return nil, "zlib unavailable" end
    -- gzip 尾部 ISIZE（原始大小 mod 2^32）仅作初始缓冲大小提示。
    -- qyd /proxypng 会在 gzip 流末尾追加额外字节（实测多 2B "{}"），
    -- 导致尾部 ISIZE 读成巨大伪造值；此时不能直接拒绝（inflate 本身会忽略流外多余字节），
    -- 回退到保守初始缓冲，由下方渐进扩容兜底。OOM 防护由 MAX_GUNZIP_OUT 封顶保证。
    local MAX_GUNZIP_OUT = 64 * 1024 * 1024
    local isize = 0
    if #data >= 4 then
        isize = string.byte(data, #data - 3)
            + string.byte(data, #data - 2) * 256
            + string.byte(data, #data - 1) * 65536
            + string.byte(data, #data) * 16777216
    end
    local out_size
    if isize > 0 and isize <= MAX_GUNZIP_OUT then
        out_size = math.max(isize + 64, #data * 8 + 64)
    else
        out_size = math.min(#data * 8 + 64, MAX_GUNZIP_OUT)
    end
    while true do
        local out = ffi.new("unsigned char[?]", out_size)
        local strm = ffi.new("z_stream")
        strm.next_in = ffi.cast("const unsigned char*", data)
        strm.avail_in = #data
        strm.next_out = out
        strm.avail_out = out_size
        local ret = libz.inflateInit2_(strm, 15 + 32, "1.2.11", ffi.sizeof("z_stream"))
        if ret ~= 0 then return nil, "inflateInit2 failed" end
        ret = libz.inflate(strm, 4) -- Z_FINISH
        libz.inflateEnd(strm)
        if ret == 1 then
            return ffi.string(out, strm.total_out)
        end
        if ret ~= -5 then -- -5 = Z_BUF_ERROR（缓冲不足，扩大重试）
            return nil, "inflate failed: " .. tostring(strm.msg or ret)
        end
        if out_size >= MAX_GUNZIP_OUT then
            return nil, "inflate output too large"
        end
        out_size = math.min(out_size * 2, MAX_GUNZIP_OUT)
    end
end

local function save_processed(data, output_path, ext)
    local ok, err = util.writeToFile(data, output_path, true)
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
    local extensions = IMG.IMAGE_EXTENSIONS
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
function M.download_cover(book_cache_id, img_src, is_force, opts)
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

    local extensions = IMG.IMAGE_EXTENSIONS
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
-- opts: timeout(总超时, 默认 60), headers
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
    -- qread 服务器不遵守请求头, 会透传 gzip 压缩
    if data:sub(1, 2) == "\x1f\x8b" then
        local raw, gerr = M.gunzip(data)
        if not raw then
            return nil, "gunzip failed: " .. tostring(gerr)
        end
        data = raw
    end

    -- 合法性校验
    -- （如 JPEG2000 等 mupdf 支持的冷门格式）交给 RenderImage 全解码兜底，
    -- 能解码即视为合法图片——renderimage 避免误杀 sniff 覆盖外的合法图。
    local ext = IMG.sniff_format(data)
    if not IMG.is_valid_image(data) then
        if ext ~= nil then
            -- 7 格式内结构损坏/尺寸异常：丢弃（不兜底，避免放行伪造魔数的垃圾）
            return nil, "invalid image data"
        end
        -- sniff 不识别：RenderImage 兜底验证
        local ok2, bb = pcall(function()
            local RenderImage = require("ui/renderimage")
            return RenderImage:renderImageData(data, #data)
        end)
        if not ok2 or not bb then
            return nil, "invalid image data"
        end
        -- mupdf 不返回格式信息，用通用图片扩展名（渲染按内容嗅探，不受扩展名影响）
        ext = "img"
    end
    return data, ext
end

return M