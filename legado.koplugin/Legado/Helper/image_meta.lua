
local M = {}

M.IMAGE_EXTENSIONS = { "jpg", "jpeg", "png", "webp", "bmp", "tiff", "gif", "svg", "img" }

M.IMAGE_EXTENSIONS_MAP = {
    jpg = true, jpeg = true, png = true,
    webp = true, bmp = true, tiff = true,
    gif = true, svg = true, img = true,
}

M.FORMAT_EXTENSION = {
    jpg = "jpg", png = "png", webp = "webp",
    bmp = "bmp", tiff = "tiff", gif = "gif",
    svg = "svg",
}

M.MIME_TYPES = {
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    png = "image/png",
    webp = "image/webp",
    gif = "image/gif",
    bmp = "image/bmp",
    tiff = "image/tiff",
    svg = "image/svg+xml",
    img = "application/octet-stream",
}

local MAX_IMAGE_DIM = 50000
local MAX_IMAGE_PIXELS = 50000000
M.MAX_IMAGE_DIM = MAX_IMAGE_DIM
M.MAX_IMAGE_PIXELS = MAX_IMAGE_PIXELS

local function in_bounds(data, offset, n)
    return offset >= 1 and offset + n - 1 <= #data
end

local function read_u16_le(data, offset)
    if not in_bounds(data, offset, 2) then return nil end
    return string.byte(data, offset) + string.byte(data, offset + 1) * 256
end

local function read_u16_be(data, offset)
    if not in_bounds(data, offset, 2) then return nil end
    return string.byte(data, offset) * 256 + string.byte(data, offset + 1)
end

local function read_u32_le(data, offset)
    if not in_bounds(data, offset, 4) then return nil end
    return string.byte(data, offset)
        + string.byte(data, offset + 1) * 256
        + string.byte(data, offset + 2) * 65536
        + string.byte(data, offset + 3) * 16777216
end

local function read_u32_be(data, offset)
    if not in_bounds(data, offset, 4) then return nil end
    return string.byte(data, offset) * 16777216
        + string.byte(data, offset + 1) * 65536
        + string.byte(data, offset + 2) * 256
        + string.byte(data, offset + 3)
end

local function read_i32_le(data, offset)
    local v = read_u32_le(data, offset)
    if not v then return nil end
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

local bit = require("bit")
local crc_table
local function crc32(data)
    if not crc_table then
        crc_table = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if c % 2 == 1 then
                    c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
                else
                    c = bit.rshift(c, 1)
                end
            end
            crc_table[i] = c
        end
    end
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        crc = bit.bxor(crc_table[bit.bxor(crc, string.byte(data, i)) % 256], bit.rshift(crc, 8))
    end
    crc = bit.bxor(crc, 0xFFFFFFFF)
    if crc < 0 then crc = crc + 0x100000000 end
    return crc
end

function M.sniff_format(data)
    if type(data) ~= "string" then return nil end
    local n = #data
    if n >= 3 and string.sub(data, 1, 3) == "\xFF\xD8\xFF" then return "jpg" end
    if n >= 8 and string.sub(data, 1, 8) == "\x89\x50\x4E\x47\x0D\x0A\x1A\x0A" then return "png" end
    if n >= 12 and string.sub(data, 1, 4) == "RIFF" and string.sub(data, 9, 12) == "WEBP" then return "webp" end
    if n >= 2 and string.sub(data, 1, 2) == "BM" then return "bmp" end
    if n >= 6 and string.sub(data, 1, 4) == "GIF8" then return "gif" end
    if n >= 4 and (string.sub(data, 1, 4) == "\x49\x49\x2A\x00"
            or string.sub(data, 1, 4) == "\x4D\x4D\x00\x2A") then return "tiff" end
    return nil
end

function M.parse_dimensions(data, format)
    if type(data) ~= "string" then return nil end

    if format == "png" then
        if not in_bounds(data, 9, 25) then return nil end
        if string.sub(data, 13, 16) ~= "IHDR" then return nil end
        if read_u32_be(data, 9) ~= 13 then return nil end
        local w = read_u32_be(data, 17)
        local h = read_u32_be(data, 21)
        if not w or not h then return nil end
        if in_bounds(data, 30, 4) then
            local expect = read_u32_be(data, 30)
            if expect ~= crc32(string.sub(data, 13, 29)) then return nil end
        end
        return w, h

    elseif format == "jpg" then
        local i = 3
        while i <= #data do
            if string.byte(data, i) ~= 0xFF then
                i = i + 1
            else
                local marker = string.byte(data, i + 1)
                if not marker then return nil end
                if marker == 0xD8 then
                    i = i + 2
                elseif marker == 0xFF then
                    i = i + 1
                elseif marker == 0xD9 or marker == 0x01
                        or (marker >= 0xD0 and marker <= 0xD7) then
                    if marker == 0xD9 then break end
                    i = i + 2
                else
                    local seglen = read_u16_be(data, i + 2)
                    if not seglen or seglen < 2 or not in_bounds(data, i + 2, seglen) then
                        return nil
                    end
                    if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4
                            and marker ~= 0xC8 and marker ~= 0xCC then
                        if seglen < 11 or not in_bounds(data, i + 5, 4) then return nil end
                        local h = read_u16_be(data, i + 5)
                        local w = read_u16_be(data, i + 7)
                        if not h or not w then return nil end
                        return w, h
                    end
                    i = i + 2 + seglen
                end
            end
        end
        return nil

    elseif format == "gif" then
        if #data < 24 then return nil end
        local ver = string.sub(data, 4, 6)
        if ver ~= "87a" and ver ~= "89a" then return nil end
        local marker14 = string.byte(data, 14)
        if marker14 ~= 0x2C and marker14 ~= 0x21 then return nil end
        local w = read_u16_le(data, 7)
        local h = read_u16_le(data, 9)
        if not w or not h then return nil end
        return w, h

    elseif format == "bmp" then
        if #data < 26 then return nil end
        local dib_size = read_u32_le(data, 15)
        if not dib_size or dib_size < 40 then return nil end
        if not in_bounds(data, 15, dib_size) then return nil end
        local w = read_i32_le(data, 19)
        local h = read_i32_le(data, 23)
        if not w or not h then return nil end
        if w <= 0 then return nil end
        if h < 0 then h = -h end
        return w, h

    elseif format == "webp" then
        if #data < 20 then return nil end
        local riff_size = read_u32_le(data, 5)
        if not riff_size or riff_size < 4 or 8 + riff_size > #data then return nil end
        local fourcc = string.sub(data, 13, 16)
        local chunk_size = read_u32_le(data, 17)
        if not chunk_size then return nil end
        if 20 + chunk_size > #data then return nil end
        if fourcc == "VP8 " then
            if chunk_size < 10 then return nil end
            local d = 21
            if bit.band(string.byte(data, d), 0x01) ~= 0 then return nil end
            if string.byte(data, d + 3) ~= 0x9D or string.byte(data, d + 4) ~= 0x01
                    or string.byte(data, d + 5) ~= 0x2A then return nil end
            local w = string.byte(data, d + 6) + (string.byte(data, d + 7) % 0x40) * 256
            local h = string.byte(data, d + 8) + (string.byte(data, d + 9) % 0x40) * 256
            return w, h
        elseif fourcc == "VP8L" then
            if chunk_size < 5 then return nil end
            local d = 21
            if string.byte(data, d) ~= 0x2F then return nil end
            local bits = read_u32_le(data, d + 1)
            if not bits then return nil end
            local w = (bits % 0x4000) + 1
            local h = (math.floor(bits / 0x4000) % 0x4000) + 1
            return w, h
        elseif fourcc == "VP8X" then
            if chunk_size < 10 then return nil end
            local d = 21
            local w = string.byte(data, d + 4) + string.byte(data, d + 5) * 256
                + string.byte(data, d + 6) * 65536 + 1
            local h = string.byte(data, d + 7) + string.byte(data, d + 8) * 256
                + string.byte(data, d + 9) * 65536 + 1
            return w, h
        end
        return nil

    elseif format == "tiff" then
        if #data < 8 then return nil end
        local le
        if string.sub(data, 1, 2) == "II" then
            le = true
        elseif string.sub(data, 1, 2) == "MM" then
            le = false
        else
            return nil
        end
        local magic = le and read_u16_le(data, 3) or read_u16_be(data, 3)
        if magic ~= 42 then return nil end
        local ifd_offset = le and read_u32_le(data, 5) or read_u32_be(data, 5)
        if not ifd_offset or ifd_offset < 8 or not in_bounds(data, ifd_offset + 1, 2) then
            return nil
        end
        local entry_count = le and read_u16_le(data, ifd_offset + 1) or read_u16_be(data, ifd_offset + 1)
        if not entry_count then return nil end
        if not in_bounds(data, ifd_offset + 3, entry_count * 12) then return nil end
        local w, h
        for i = 0, entry_count - 1 do
            local e = ifd_offset + 3 + i * 12
            local tag = le and read_u16_le(data, e) or read_u16_be(data, e)
            local etype = le and read_u16_le(data, e + 2) or read_u16_be(data, e + 2)
            if not tag or not etype then return nil end
            local count = le and read_u32_le(data, e + 4) or read_u32_be(data, e + 4)
            if not count then return nil end
            if (etype == 3 or etype == 4) and count == 1 then
                local val
                if etype == 3 then
                    val = le and read_u16_le(data, e + 8) or read_u16_be(data, e + 8)
                else
                    val = le and read_u32_le(data, e + 8) or read_u32_be(data, e + 8)
                end
                if val then
                    if tag == 256 then w = val
                    elseif tag == 257 then h = val end
                end
            end
        end
        if not w or not h then return nil end
        return w, h
    end
    return nil
end

function M.is_valid_image(data)
    if type(data) ~= "string" or #data < 2 then return false end
    local format = M.sniff_format(data)
    if not format then return false end
    local w, h = M.parse_dimensions(data, format)
    if not w or not h then return false end
    if w <= 0 or h <= 0 then return false end
    if w > MAX_IMAGE_DIM or h > MAX_IMAGE_DIM then return false end
    if w * h > MAX_IMAGE_PIXELS then return false end
    return true
end

function M.is_image_extension(ext)
    if type(ext) ~= "string" or ext:sub(1, 1) == "." then return false end
    return M.IMAGE_EXTENSIONS_MAP[ext:lower()] == true
end

function M.get_image_ext(filename_or_path)
    if type(filename_or_path) ~= "string" then return nil end
    local ext = filename_or_path:match("%.([^.]+)$")
    if ext and M.is_image_extension(ext) then
        return ext:lower()
    end
    return nil
end

function M.get_mime_type(ext)
    if type(ext) ~= "string" then return "image/jpeg" end
    ext = ext:gsub("^%.", ""):lower()
    return M.MIME_TYPES[ext] or "image/jpeg"
end

function M.get_extension(format)
    return M.FORMAT_EXTENSION[format]
end

return M
