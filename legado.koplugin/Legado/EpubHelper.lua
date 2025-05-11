local util = require("util")
local H = require("Legado/Helper")
local logger = require("logger")

local M = {}
local mianCss = string.format("%s/%s", H.getPluginDirectory(), "Legado/main.css.lua")
local resCss = "resources/legado.css"

local function split_title_advanced(title)

    if type(title) ~= 'string' or title == "" then
        return nil, nil
    end
    local words = util.splitToChars(title)

    if not H.is_tbl(words) or #words == 0 then
        return nil, nil
    end

    -- 查找隔断符号的位置
    local count = 0
    -- 第一卷 笼中雀 第六章 下签

    local segmentation = {
        ["\u{0020}"] = true,
        ["\u{00A0}"] = true,
        ["\u{3000}"] = true, 
        ["\u{2000}"] = true,
        ["\u{2001}"] = true,
        ["\u{2002}"] = true,
        ["\u{2003}"] = true,
        ["\u{2004}"] = true,
        ["\u{2005}"] = true,
        ["\u{2006}"] = true,
        ["\u{2007}"] = true,
        ["\u{2008}"] = true,
        ["\u{2009}"] = true,
        ["\u{200A}"] = true,
        ["\u{202F}"] = true,
        ["\u{205F}"] = true,
        ["、"] = true,
        ["："] = true,
        ["》"] = true,
        ["——"] = true
    }
    local need_clean ={
        ["、"] = true,
        ["："] = true,
        ["》"] = true,
        ["——"] = true,
    }
    local is_need_clean
    for i, v in ipairs(words) do
        if i > 1 and segmentation[v] == true then
            if need_clean[v] then
                 is_need_clean = true
            end
            break
        end
        count = count + 1
    end

    local words_len = #words
    if count == 0 or count == words_len then
        return "", title
    end

    local part_end = count
    local subpart_start = count + 1
    -- 跳过字符
    if is_need_clean == true then 
        subpart_start = subpart_start + 1
        if subpart_start > words_len then 
            -- 去掉结尾字符
            return "", table.concat(words, "", 1, words_len - 1)
        end
    end
    local part = table.concat(words, "", 1, part_end)
    local subpart = table.concat(words, "", subpart_start)
    --logger.info(part, subpart)
    return part, subpart
end


M.addCssRes = function(book_cache_id)
    local book_cache_path = H.getBookCachePath(book_cache_id)
    local book_css_path = string.format("%s/%s", book_cache_path, resCss)

    if not util.fileExists(book_css_path) then
        H.copyFileFromTo(mianCss, book_css_path)
    end
    return book_css_path
end

M.addchapterT = function(title, content)
    title = title or ""
    content = content or ""
    local html = [=[
<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title><link href="%s" type="text/css" rel="stylesheet"/><style>p + p {margin-top: 0.5em;}</style>
</head><body><h2 class="head"><span class="chapter-sequence-number">%s</span><br />%s</h2>
<div>%s</div></body></html>]=]
    local part, subpart = split_title_advanced(title)
    return string.format(html, title, resCss, part or "", subpart or "", content)
end

M.introT = function()
    local html = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN">
<head>
    <title>内容简介</title>
    <link href="%s" type="text/css" rel="stylesheet" />
</head>
<body>
<h1 class="head" style="margin-bottom:2em;">内容简介</h1><p>%s</p></body>
</html>
end
]]
end

M.coverT = function()
    local html = [=[
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>Cover</title>
    <style type="text/css">
		.pic {
			margin: 50% 30% 0 30%;
			padding: 2px 2px;
			border: 1px solid #f5f5dc;
			background-color: rgba(250,250,250, 0);
			border-radius: 1px;
		}
    </style>
</head>
<body style="text-align: center;">
<div class="pic"><img src="../Images/cover.jpg" style="width: 100%; height: auto;"/></div>
<h1 style="margin-top: 5%; font-size: 110%;">{name}</h1>
<div class="author" style="margin-top: 0;"><b>{author}</b> <span style="font-size: smaller;">/ 著</span></div>
</body>
</html>    
]=]
    return html
end
M.createMiscFiles = function()
end
M.createIndexHTM = function()
end
M.createNCX = function()
end
M.createOPF = function()
end
M.build = function()
end
return M
