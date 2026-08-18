local H = require("Legado/Helper")
local utf8c = require("Legado.Helper.utf8proc")

-- 书籍过滤（options 带 name/author/origin 时精确匹配（换源)
-- 否则 is_exact_search 时按 name/author 与 search_text 精确匹配, 否则全部通过
local M = {}

function M.filter_search(book, search_text, is_exact_search, options)
    if not H.is_tbl(book) then return false end
    local has_name_filter = H.is_str(options and options.name) and options.name ~= ""
    local has_author_filter = H.is_str(options and options.author) and options.author ~= ""
    local has_origin_filter = H.is_str(options and options.origin) and options.origin ~= ""
    -- 作者匹配：≥2 汉字包含匹配（覆盖“余华著/作者：余华”等格式差异），1 字精确
    local OPT_AUTHOR = options and options.author
    local OPT_AUTHOR_LEN = H.is_str(OPT_AUTHOR) and utf8c.len(OPT_AUTHOR) or 0
    if has_name_filter or has_author_filter or has_origin_filter then
        local match_name = has_name_filter and H.is_str(book.name) and book.name == options.name
        local match_author = has_author_filter and H.is_str(book.author) and (
            (OPT_AUTHOR_LEN >= 2 and book.author:find(OPT_AUTHOR, 1, true) ~= nil)
            or (OPT_AUTHOR_LEN < 2 and book.author == OPT_AUTHOR)
        )
        local match_origin = has_origin_filter and H.is_str(book.origin) and book.origin == options.origin

        if has_name_filter and not match_name then return false end
        if has_author_filter and not match_author then return false end
        if has_origin_filter and not match_origin then return false end

        return true
    end
    if is_exact_search then
        return (H.is_str(book.name) and book.name == search_text)
            or (H.is_str(book.author) and book.author == search_text)
    end
    return true
end

return M
