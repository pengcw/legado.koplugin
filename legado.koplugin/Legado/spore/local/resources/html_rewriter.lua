local M = {}
local MAX_HTML, MAX_TAGS = 16*1024*1024, 5000
local raw_text = {style=true, script=true, textarea=true, title=true, xmp=true,
    iframe=true, noembed=true, noframes=true}

local function failure(kind, message)
    return nil,{kind=kind,message=message}
end

local function space(html, i)
    while i <= #html and html:sub(i,i):match("%s") do i=i+1 end
    return i
end

local function tag_end(html, i)
    while i <= #html do
        local c=html:sub(i,i)
        if c == '"' or c == "'" then
            local last=html:find(c,i+1,true)
            if not last then return end
            i=last+1
        elseif c == ">" then return i
        else i=i+1 end
    end
end

local function opening(html, first, name_end, name)
    local boundary=html:sub(name_end+1,name_end+1)
    if boundary ~= ">" and boundary ~= "/" and not boundary:match("%s") then return end
    local node={name=name:lower(),first=first,attributes={}}
    local i=name_end+1
    while i <= #html do
        i=space(html,i)
        local c=html:sub(i,i)
        if c == ">" or html:sub(i,i+1) == "/>" then
            node.last=c == ">" and i or i+1
            return node
        end
        local start,last,key=html:find("([^%s=/>%z]+)",i)
        if start ~= i or key:find("[<'\"\x60]") then return end
        i=space(html,last+1)
        local attribute={}
        if html:sub(i,i) == "=" then
            i=space(html,i+1)
            local quote=html:sub(i,i)
            attribute.first=i
            if quote == '"' or quote == "'" then
                last=html:find(quote,i+1,true)
                if not last then return end
                attribute.value=html:sub(i+1,last-1)
                attribute.last=last
                i=last+1
            else
                start,last=html:find("[^%s>]+",i)
                if start ~= i then return end
                attribute.value=html:sub(i,last)
                if attribute.value:find("[<'\"\x60]") then return end
                attribute.last=last
                i=last+1
            end
        end
        key=key:lower()
        if not node.attributes[key] then node.attributes[key]=attribute end
    end
end

function M.scan(html)
    if #html > MAX_HTML then return failure("limit_exceeded","HTML too large") end
    local nodes, i, lower={}, 1, html:lower()
    while i <= #html do
        local first=html:find("<",i,true)
        if not first then break end
        if html:sub(first,first+3) == "<!--" then
            local last=html:find("-->",first+4,true)
            i=last and last+3 or #html+1
        elseif html:sub(first,first+8) == "<![CDATA[" then
            local last=html:find("]]>",first+9,true)
            i=last and last+3 or #html+1
        else
            local start,name_end,name=html:find("<([%a][%w:_%-]*)",first)
            if start ~= first then
                local c=html:sub(first+1,first+1)
                if c == "!" or c == "?" or c == "/" then
                    local last=tag_end(html,first+2)
                    i=last and last+1 or #html+1
                else i=first+1 end
            else
                if #nodes >= MAX_TAGS then return failure("limit_exceeded","too many HTML tags") end
                local node=opening(html,first,name_end,name)
                if not node then return failure("invalid_html","unsupported or incomplete HTML tag") end
                nodes[#nodes+1]=node
                i=node.last+1
                if node.name == "plaintext" then break end
                if raw_text[node.name] then
                    local close_start,close_end=lower:find("</"..node.name.."%s*>",i)
                    node.content_first=i
                    node.content_last=close_start and close_start-1 or #html
                    i=close_end and close_end+1 or #html+1
                end
            end
        end
    end
    return nodes
end

function M.escape_attribute(value)
    return '"'..value:gsub("&","&amp;"):gsub('"',"&quot;")
        :gsub("<","&lt;"):gsub(">","&gt;")..'"'
end

function M.apply(html, patches)
    table.sort(patches,function(a,b) return a.first < b.first end)
    local parts, position, size={},1,0
    for _,patch in ipairs(patches) do
        if patch.first < position or patch.last < patch.first or patch.last > #html then
            return failure("invalid_html","overlapping HTML replacements")
        end
        size=size+patch.first-position+#patch.value
        if size > MAX_HTML then return failure("limit_exceeded","localized HTML too large") end
        parts[#parts+1]=html:sub(position,patch.first-1)
        parts[#parts+1]=patch.value
        position=patch.last+1
    end
    if size+#html-position+1 > MAX_HTML then return failure("limit_exceeded","localized HTML too large") end
    parts[#parts+1]=html:sub(position)
    return table.concat(parts)
end

return M
