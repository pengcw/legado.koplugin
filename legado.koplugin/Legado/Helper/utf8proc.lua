--[[
  UTF-8 模块 (utf8proc)
  用途说明：
  1. 深度清理全角空格 (U+3000) 和特殊空白符，保障文本洗稿和排版整洁。
  2. 提供安全的 UTF-8 字符级遍历，防止多字节中文字符被截断产生乱码。
  3. 为高级排版（如首字下沉、智能段落合并）提供精准的字符边界及标点识别。
]]

local ffi = require("ffi")

local M = {}

local UTF8_WHITESPACE_CODEPOINTS = {
    [0x00A0]=true, [0x1680]=true, [0x2000]=true, [0x2001]=true, [0x2002]=true, [0x2003]=true,
    [0x2004]=true, [0x2005]=true, [0x2006]=true, [0x2007]=true, [0x2008]=true, [0x2009]=true,
    [0x200A]=true, [0x200B]=true, [0x202F]=true, [0x205F]=true, [0x3000]=true, [0x0009]=true,
    [0x000A]=true, [0x000B]=true, [0x000C]=true, [0x000D]=true, [0x0020]=true
}

local libutf8proc
local libutf8proc_available = false
local Utf8Proc_module
local shared_codepoint

do
    pcall(function()
        Utf8Proc_module = require("ffi/utf8proc")
        
        local function find_lib(func)
            if type(func) ~= "function" then return nil end
            for i = 1, 30 do
                local name, val = debug.getupvalue(func, i)
                if not name then break end
                if name == "libutf8proc" then
                    return val
                end
            end
            return nil
        end
        
        -- 版本兼容,旧版本只有 lowercase
        libutf8proc = find_lib(Utf8Proc_module.count) 
                   or find_lib(Utf8Proc_module.lowercase_NFKC_Casefold) 
                   or find_lib(Utf8Proc_module.lowercase)
                   
        if libutf8proc then
            libutf8proc_available = true
            shared_codepoint = ffi.new("utf8proc_int32_t[1]")
        end
    end)
end

local native_utf8_chars

if not libutf8proc_available then
    native_utf8_chars = function(str, reverse)
    local str_len = #str
    local pos = reverse and (str_len + 1) or 0

    return function()
        while true do
            pos = reverse and (pos - 1) or (pos + 1)
            if (reverse and pos < 1) or (not reverse and pos > str_len) then
                return nil
            end

            if reverse then
                while pos > 1 do
                    local b = str:byte(pos)
                    if b >= 0x80 and b <= 0xBF then
                        pos = pos - 1
                    else
                        break
                    end
                end
            end

            local byte = str:byte(pos)
            if not byte then return nil end

            local bytes = 1
            local codepoint = byte

            if byte < 0x80 then
                bytes = 1
                codepoint = byte
            elseif byte >= 0xC0 and byte <= 0xDF then
                bytes = 2
                if pos + 1 <= str_len then
                    local b2 = str:byte(pos + 1)
                    if b2 and b2 >= 0x80 and b2 <= 0xBF then
                        codepoint = (byte - 0xC0) * 64 + (b2 - 0x80)
                    end
                end
            elseif byte >= 0xE0 and byte <= 0xEF then
                bytes = 3
                if pos + 2 <= str_len then
                    local b2, b3 = str:byte(pos + 1), str:byte(pos + 2)
                    if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                        codepoint = (byte - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
                    end
                end
            elseif byte >= 0xF0 and byte <= 0xF7 then
                bytes = 4
                if pos + 3 <= str_len then
                    local b2, b3, b4 = str:byte(pos + 1), str:byte(pos + 2), str:byte(pos + 3)
                    if b2 and b3 and b4 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF then
                        codepoint = (byte - 0xF0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
                    end
                end
            end

            local start_pos = pos
            if start_pos >= 1 and start_pos + bytes - 1 <= str_len then
                local char = str:sub(start_pos, start_pos + bytes - 1)
                local ret_pos = start_pos
                pos = reverse and start_pos or (start_pos + bytes - 1)
                return ret_pos, codepoint, char
            end
        end
    end
    end
end

function M.utf8_chars(str, reverse)
    if not libutf8proc_available then
        return native_utf8_chars(str, reverse)
    end

    local str_len = #str
    local pos = reverse and (str_len + 1) or 0
    local str_p = ffi.cast("const utf8proc_uint8_t*", str)
    local codepoint = shared_codepoint or ffi.new("utf8proc_int32_t[1]")

    return function()
        while true do
            pos = reverse and (pos - 1) or (pos + 1)
            if (reverse and pos < 1) or (not reverse and pos > str_len) then
                return nil
            end

            local remaining = reverse and pos or (str_len - pos + 1)
            local bytes = tonumber(libutf8proc.utf8proc_iterate(str_p + pos - 1, remaining, codepoint))

            if bytes > 0 then
                local char = ffi.string(str_p + pos - 1, bytes)
                local ret_pos = tonumber(pos)
                pos = reverse and (pos - bytes + 1) or (pos + bytes - 1)
                return ret_pos, tonumber(codepoint[0]), char
            elseif bytes < 0 then
                if reverse then
                    pos = pos - 1
                end
            end
        end
    end
end

function M.count(str)
    if Utf8Proc_module and Utf8Proc_module.count then
        return Utf8Proc_module.count(str)
    end

    if type(str) ~= "string" or str == "" then return 0, true end
    
    if not libutf8proc_available then
        local count = 0
        for _ in native_utf8_chars(str) do
            count = count + 1
        end
        return count, true
    end

    local str_p = ffi.cast("const utf8proc_uint8_t *", str)
    local codepoint = shared_codepoint or ffi.new("utf8proc_int32_t[1]")
    local count = 0
    local pos = 0
    local str_len = #str
    while pos < str_len do
        local bytes = tonumber(libutf8proc.utf8proc_iterate(str_p + pos, -1, codepoint))
        if bytes > 0 then
            count = count + 1
            pos = pos + bytes
        else
            return count, false
        end
    end
    return count, true
end

function M.utf8_trim(str)
    if type(str) ~= "string" or str == "" then return "" end

    str = str:match("^%s*(.-)%s*$")
    if str == "" then return "" end

    local str_len = #str

    if not libutf8proc_available then
        local start_pos = 1
        local found = false
        for pos, cp, _ in native_utf8_chars(str) do
            if not UTF8_WHITESPACE_CODEPOINTS[cp] then
                start_pos = pos
                found = true
                break
            end
        end
        if not found then return "" end

        local finish_pos = str_len
        for pos, cp, char in native_utf8_chars(str, true) do
            if not UTF8_WHITESPACE_CODEPOINTS[cp] then
                finish_pos = pos + #char - 1
                break
            end
        end
        return (start_pos <= finish_pos) and str:sub(start_pos, finish_pos) or ""
    end

    local str_p = ffi.cast("const utf8proc_uint8_t *", str)
    local start_pos = nil
    local pos = 0
    while pos < str_len do
        local bytes = tonumber(libutf8proc.utf8proc_iterate(str_p + pos, str_len - pos, shared_codepoint))
        if bytes > 0 then
            if not UTF8_WHITESPACE_CODEPOINTS[tonumber(shared_codepoint[0])] then
                start_pos = pos + 1
                break
            end
            pos = pos + bytes
        else
            pos = pos + 1
        end
    end
    if not start_pos then return "" end

    local finish_pos = str_len
    pos = str_len
    while pos > 0 do
        local c_start = pos
        while c_start > 1 do
            local b = str:byte(c_start)
            if b >= 0x80 and b <= 0xBF then
                c_start = c_start - 1
            else
                break
            end
        end
        
        local bytes = tonumber(libutf8proc.utf8proc_iterate(str_p + c_start - 1, str_len - c_start + 1, shared_codepoint))
        if bytes > 0 then
            if not UTF8_WHITESPACE_CODEPOINTS[tonumber(shared_codepoint[0])] then
                finish_pos = c_start + bytes - 1
                break
            end
        end
        pos = c_start - 1
    end

    if start_pos == 1 and finish_pos == str_len then
        return str
    end
    return str:sub(start_pos, finish_pos)
end

return M
