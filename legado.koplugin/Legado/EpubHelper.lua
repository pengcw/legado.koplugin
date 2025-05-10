local util = require("util")
local H = require("Legado/Helper")
local logger = require("logger")

local M = {}
local mianCss = string.format("%s/%s",H.getPluginDirectory(),"Legado/main.css.lua")
local resCss = "resources/legado.css"


local function split_title_advanced(title)
    title = util.trim(title)
    local patterns = {
        "^(第[一二三四五六七八九十零]+[章部节]%s+)(.+)$",  -- 中文数字
        "^(第%d+部%s+)(.+)$",                      -- 阿拉伯数字
        "^(%d+%.%d+%s+)(.+)$",                     -- 1.1 样式
        "^(%a+%.%s*)(.+)$",                        -- A. 样式
        "^(CHAPTER%s+%d+%s*)(.+)$",                -- CHAPTER 1 样式
        "^(.*%s)(.+)$"                             -- 最后按空格拆分
    }
    
    for _, pattern in ipairs(patterns) do
        local part, subpart = title:match(pattern)
        if part and subpart then
            part = part:gsub("%s+$", "")
            subpart = subpart:gsub("^%s+", "")
            return part, subpart
        end
    end
    return "", title
end

M.addCssRes = function(book_cache_id)
    local book_cache_path = H.getBookCachePath(book_cache_id)
    local book_css_path = string.format("%s/%s",book_cache_path,resCss)

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
return string.format(html, title, resCss, part, subpart, content)
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
M.createMiscFiles =function()
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