local url = require("socket.url")
local Localizer = {}
Localizer.__index = Localizer

local function comment_end(css, i)
    local last = css:find("*/", i + 2, true)
    return last and last + 2 or #css + 1
end

local function trivia(css, i)
    while i <= #css do
        if css:sub(i, i):match("%s") then i = i + 1
        elseif css:sub(i, i+1) == "/*" then i = comment_end(css, i)
        else break end
    end
    return i
end

local function escape_end(css, i)
    local tail = css:sub(i+1, i+6):match("^%x+")
    if tail then
        i = i + 1 + #tail
        if css:sub(i,i) == "\r" and css:sub(i+1,i+1) == "\n" then return i+2 end
        return i + (css:sub(i,i):match("%s") and 1 or 0)
    end
    return i + (css:sub(i+1,i+2) == "\r\n" and 3 or 2)
end

local function quoted_end(css, i)
    local quote = css:sub(i,i)
    local j = i+1
    while j <= #css do
        local c = css:sub(j,j)
        if c == quote then return j+1, true end
        if c == "\n" or c == "\r" or c == "\f" then return j, false end
        j = c == "\\" and escape_end(css,j) or j+1
    end
    return #css+1, false
end

local function utf8(n)
    if n == 0 or n > 0x10ffff or (n >= 0xd800 and n <= 0xdfff) then n = 0xfffd end
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192+math.floor(n/64),128+n%64) end
    if n < 65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
    return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
end

local function decode(s)
    local parts, i = {}, 1
    while i <= #s do
        if s:sub(i,i) ~= "\\" then
            parts[#parts+1] = s:sub(i,i); i=i+1
        else
            if i == #s then return end
            local next_i = escape_end(s,i)
            local hex = s:sub(i+1,i+6):match("^%x+")
            if hex then parts[#parts+1] = utf8(tonumber(hex,16))
            elseif not s:sub(i+1,i+1):match("[\r\n\f]") then
                parts[#parts+1] = s:sub(i+1,i+1)
            end
            i = next_i
        end
    end
    return table.concat(parts)
end

local function quoted(s)
    return '"' .. s:gsub("\\","\\\\"):gsub('"','\\"'):gsub("[%z\1-\31\127<]",function(c)
        return string.format("\\%x ",c:byte())
    end) .. '"'
end

local function identifier_end(css, i)
    while i <= #css do
        local c = css:sub(i,i)
        if c == "\\" then i = escape_end(css,i)
        elseif c:match("[%w_%-]") or c:byte() >= 128 then i=i+1
        else break end
    end
    return i
end

local function balanced_end(css, i, opening, closing)
    local depth = 1
    i=i+1
    while i <= #css do
        local c = css:sub(i,i)
        if css:sub(i,i+1) == "/*" then i=comment_end(css,i)
        elseif c == '"' or c == "'" then i=quoted_end(css,i)
        elseif c == "\\" then i=escape_end(css,i)
        else
            if c == opening then depth=depth+1 elseif c == closing then depth=depth-1 end
            i=i+1
            if depth == 0 then return i end
        end
    end
    return #css+1
end

local function url_token(css, open)
    local finish = balanced_end(css,open,"(",")")
    local i = trivia(css,open+1)
    local c = css:sub(i,i)
    if c == '"' or c == "'" then
        local last, valid = quoted_end(css,i)
        if valid and css:sub(trivia(css,last),trivia(css,last)) == ")" then
            return finish, decode(css:sub(i+1,last-2))
        end
        return finish
    end
    local first = i
    while i <= #css do
        c=css:sub(i,i)
        if c == ")" then return i+1, decode(css:sub(first,i-1)) end
        if c:match("%s") or css:sub(i,i+1) == "/*" then
            local last=trivia(css,i)
            if css:sub(last,last) == ")" then return last+1, decode(css:sub(first,i-1)) end
            return finish
        end
        if c == "(" or c == '"' or c == "'" or c:match("[%z\1-\31\127]") then return finish end
        if c == "\\" then
            if css:sub(i+1,i+1):match("[\r\n\f]") then return finish end
            i=escape_end(css,i)
        else i=i+1 end
    end
    return finish
end

function Localizer.rewrite_css(css, callback)
    local limit = 4*1024*1024
    local function too_large()
        return nil,{kind="limit_exceeded",message="derived CSS too large"}
    end
    if #css > limit then return too_large() end
    local parts, copied, i, size, overflow = {}, 1, 1, 0, false
    local function replace(first, last, reference, kind, as_url)
        if not reference then return end
        local replacement=callback(reference,kind)
        if type(replacement) ~= "string" or replacement == reference then return end
        local token=as_url and "url("..quoted(replacement)..")" or quoted(replacement)
        size=size+first-copied+#token
        if size > limit then overflow=true; return end
        parts[#parts+1]=css:sub(copied,first-1)
        parts[#parts+1]=token
        copied=last
    end
    while i <= #css do
        local c=css:sub(i,i)
        if css:sub(i,i+1) == "/*" then i=comment_end(css,i)
        elseif c == '"' or c == "'" then i=quoted_end(css,i)
        elseif c == "@" then
            local last=identifier_end(css,i+1)
            local name=(decode(css:sub(i+1,last-1)) or ""):lower()
            if name == "font-face" then
                i=trivia(css,last)
                while i <= #css and css:sub(i,i) ~= "{" and css:sub(i,i) ~= ";" do
                    if css:sub(i,i+1) == "/*" then i=comment_end(css,i)
                    elseif css:sub(i,i) == '"' or css:sub(i,i) == "'" then i=quoted_end(css,i)
                    else i=i+1 end
                end
                i=css:sub(i,i) == "{" and balanced_end(css,i,"{","}") or i+1
            elseif name == "import" then
                i=trivia(css,last)
                local first=i
                if css:sub(i,i) == '"' or css:sub(i,i) == "'" then
                    local valid
                    i,valid=quoted_end(css,i)
                    if valid then replace(first,i,decode(css:sub(first+1,i-2)),"css",false) end
                else
                    local name_end=identifier_end(css,i)
                    if css:sub(i,name_end-1):lower() == "url" and css:sub(name_end,name_end) == "(" then
                        local reference
                        i,reference=url_token(css,name_end)
                        replace(first,i,reference,"css",true)
                    end
                end
                while i <= #css and css:sub(i,i) ~= ";" and css:sub(i,i) ~= "{" do
                    if css:sub(i,i+1) == "/*" then i=comment_end(css,i)
                    elseif css:sub(i,i) == '"' or css:sub(i,i) == "'" then i=quoted_end(css,i)
                    elseif css:sub(i,i) == "(" then i=balanced_end(css,i,"(",")")
                    else i=i+1 end
                end
            elseif last > i+1 then i=last else i=i+1 end
        elseif c:match("[%w_%-\\]") or c:byte() >= 128 then
            local last=identifier_end(css,i)
            if css:sub(i,last-1):lower() == "url" and css:sub(last,last) == "(" then
                local finish, reference=url_token(css,last)
                replace(i,finish,reference,"image",true)
                i=finish
            else i=last end
        else i=i+1 end
        if overflow then return too_large() end
    end
    if size+#css-copied+1 > limit then return too_large() end
    parts[#parts+1]=css:sub(copied)
    return table.concat(parts)
end

function Localizer.new(cache)
    return setmetatable({cache=cache, active={}},Localizer)
end

local function fallback(reference, base, for_base)
    reference=reference:match("^%s*(.-)%s*$")
    if not for_base and (reference:sub(1,1) == "#" or reference:lower():match("^data:")) then return reference end
    local ok, absolute=pcall(url.absolute,base or "",reference)
    local parsed=ok and absolute and url.parse(absolute)
    local scheme=parsed and parsed.scheme and parsed.scheme:lower()
    if parsed and parsed.host and (scheme == "http" or scheme == "https") then return absolute end
end

function Localizer:_expired()
    local cache=self.cache
    return cache.limits and cache.limits.deadline and cache.clock() >= cache.limits.deadline
end

function Localizer:_css(css, base, depth)
    local seen, directory={}
    local rewritten,err=Localizer.rewrite_css(css,function(reference,kind)
        local key=kind..":"..reference
        if seen[key] then return seen[key] end
        local resource
        if not self:_expired() then
            if kind == "image" then resource=self.cache:fetch(reference,base,kind)
            elseif depth < 3 then resource=self:_stylesheet(reference,base,depth+1) end
        end
        local replacement=resource and resource.reference or fallback(reference,base)
        if resource and resource.path then directory=resource.path:match("^(.*)/[^/]+$") end
        seen[key]=replacement
        return replacement
    end)
    return rewritten,err,rewritten and directory
end

function Localizer:_stylesheet(reference, base, depth)
    local resource, err=self.cache:fetch(reference,base,"css")
    if not resource or resource.passthrough then return resource,err end
    local address=resource.final_url
    if self.active[address] then return nil,{kind="css_cycle",message="cyclic stylesheet import"} end
    self.active[address]=true
    local ok, result, failure=pcall(function()
        local css, css_err=self:_css(resource.data,address,depth)
        if not css then return nil,css_err end
        local stored, store_err=self.cache:store_css(css)
        if stored then
            stored.final_url=address
            stored.reference=stored.filename..(resource.fragment and "#"..resource.fragment or "")
        end
        return stored,store_err
    end)
    self.active[address]=nil
    if not ok then return nil,{kind="cache_unavailable",message="stylesheet preparation failed"} end
    return result,failure
end

function Localizer:stylesheet(reference, base)
    return self:_stylesheet(reference,base,0)
end

function Localizer:localize_css(css, base)
    return self:_css(css,base,0)
end

function Localizer:prepare(preview, options)
    if type(preview) ~= "table" or type(preview.html) ~= "string" then
        return nil,{kind="invalid_argument",message="preview HTML required"}
    end
    options=options or {}
    local prepared={}
    for key,value in pairs(preview) do prepared[key]=value end
    local html=preview.html
    local Rewriter=require("Legado.spore.local.resources.html_rewriter")
    local nodes,err=Rewriter.scan(html)
    if not nodes then return prepared,err end
    local decode_entities=require("util").htmlEntitiesToUtf8
    local function decoded(attribute)
        if not attribute or attribute.value == nil then return end
        local ok,value=pcall(decode_entities,attribute.value)
        return ok and value or attribute.value
    end
    local base=preview.url
    local base_seen=false
    for _,node in ipairs(nodes) do
        local href=node.attributes.href
        if node.name == "base" and href and not base_seen then
            base_seen=true
            local reference=decoded(href)
            if reference then base=fallback(reference,base,true) or base end
        end
    end
    local patches,directory={}
    local function patch(first,last,value)
        patches[#patches+1]={first=first,last=last,value=value}
    end
    local function attribute_patch(attribute,value)
        if attribute and attribute.first and value ~= nil and value ~= decoded(attribute) then
            patch(attribute.first,attribute.last,Rewriter.escape_attribute(value))
        end
    end
    local function resource_reference(reference,kind)
        local resource
        if not self:_expired() then
            if kind == "css" then resource=self:stylesheet(reference,base)
            else resource=self.cache:fetch(reference,base,kind) end
        end
        if resource and resource.path then directory=resource.path:match("^(.*)/[^/]+$") end
        return resource and resource.reference or fallback(reference,base)
    end
    for _,node in ipairs(nodes) do
        local attributes=node.attributes
        if node.name == "base" then
            patch(node.first,node.last,"")
        else
            if node.name == "img" and not options.skip_images then
                local reference=decoded(attributes.src)
                if reference then attribute_patch(attributes.src,resource_reference(reference,"image")) end
            elseif node.name == "link" then
                local rel=(decoded(attributes.rel) or ""):lower()
                local stylesheet=false
                for token in rel:gmatch("%S+") do
                    if token == "stylesheet" then stylesheet=true end
                end
                local reference=decoded(attributes.href)
                if stylesheet and reference then
                    attribute_patch(attributes.href,resource_reference(reference,"css"))
                end
            elseif node.name == "a" then
                local reference=decoded(attributes.href)
                if reference then attribute_patch(attributes.href,fallback(reference,base)) end
            end
            local style=decoded(attributes.style)
            if style then
                local css,_,dir=self:localize_css(style,base)
                if css then
                    attribute_patch(attributes.style,css)
                    directory=dir or directory
                end
            end
            if node.name == "style" and node.content_last >= node.content_first then
                local original=html:sub(node.content_first,node.content_last)
                local css,_,dir=self:localize_css(original,base)
                if css then
                    patch(node.content_first,node.content_last,css)
                    directory=dir or directory
                end
            end
        end
    end
    local localized,apply_err=Rewriter.apply(html,patches)
    if not localized then return prepared,apply_err end
    prepared.html=localized
    if directory then prepared.resource_directory=directory end
    return prepared
end

return Localizer
