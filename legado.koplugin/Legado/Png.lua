local ffi = require("ffi")
require("ffi/lodepng_h")

local lodepng = ffi.loadlib("lodepng")

local Png = {}

function Png.toGrayscale(pixels, w, h, ncomp)

    local data = ffi.cast("uint8_t*", pixels)
    local width, height = w, h
    local ncomp = ncomp or 8

    local gray_data = ffi.new("uint8_t[?]", width * height)

    local width_ncomp = width * ncomp

    for y = 0, height - 1 do
        local row_offset = y * width_ncomp
        local gray_offset = y * width
        for x = 0, width - 1 do
            local index = row_offset + x * ncomp
            local r = data[index]
            local g = data[index + 1]
            local b = data[index + 2]

            local gray = 0.299 * r + 0.587 * g + 0.114 * b
            gray_data[gray_offset + x] = gray
        end
    end
    return gray_data
end

function Png.processImage(func, image_data, req_n)
    local fdata = image_data
    local ptr = ffi.new("unsigned char*[1]")
    local width, height = ffi.new("int[1]"), ffi.new("int[1]")
    local state = ffi.new("LodePNGState[1]")

    lodepng.lodepng_state_init(state)
    state[0].info_raw.bitdepth = 8

    local err = lodepng.lodepng_inspect(width, height, state, ffi.cast("const unsigned char*", fdata), #fdata)
    if err ~= 0 then
        lodepng.lodepng_state_cleanup(state)
        return false, ffi.string(lodepng.lodepng_error_text(err))
    end

    local colortype = state[0].info_png.color.colortype
    local palettesize = state[0].info_png.color.palettesize
    local out_n = req_n

    if req_n == 1 or req_n == 2 then
        if colortype == lodepng.LCT_GREY or colortype == lodepng.LCT_GREY_ALPHA or
            (colortype == lodepng.LCT_PALETTE and palettesize <= 16) then
            state[0].info_raw.colortype = req_n == 1 and lodepng.LCT_GREY or lodepng.LCT_GREY_ALPHA
        else
            state[0].info_raw.colortype = req_n == 1 and lodepng.LCT_RGB or lodepng.LCT_RGBA
            out_n = req_n == 1 and 3 or 4
        end
    elseif req_n == 3 then
        state[0].info_raw.colortype = lodepng.LCT_RGB
    elseif req_n == 4 then
        state[0].info_raw.colortype = lodepng.LCT_RGBA
    else
        lodepng.lodepng_state_cleanup(state)
        return false, "Invalid number of color components requested"
    end

    err = lodepng.lodepng_decode(ptr, width, height, state, ffi.cast("const unsigned char*", fdata), #fdata)
    if err ~= 0 then
        if ptr[0] ~= nil then
            ffi.C.free(ptr[0])

            ptr[0] = nil
        end
        lodepng.lodepng_state_cleanup(state)
        return false, ffi.string(lodepng.lodepng_error_text(err))
    end

    local status, result = pcall(func, ptr[0], width[0], height[0], out_n)

    if not status or not result then

        if ptr[0] ~= nil then
            ffi.C.free(ptr[0])

            ptr[0] = nil
        end
        lodepng.lodepng_state_cleanup(state)
        return false, "Callback function error: " .. result
    end

    local png_size = ffi.new("size_t[1]")
    err = lodepng.lodepng_encode(ptr, png_size, result, width[0], height[0], state)
    if err ~= 0 then
        lodepng.lodepng_state_cleanup(state)
        return false, "LodePNG encode error: " .. ffi.string(lodepng.lodepng_error_text(err))
    end

    local png_data = ffi.string(ptr[0], png_size[0])

    if ptr[0] ~= nil then
        ffi.C.free(ptr[0])

        ptr[0] = nil
    end

    lodepng.lodepng_state_cleanup(state)

    return true, {
        data = png_data,
        png_size = png_size[0]
    }
end

return Png
