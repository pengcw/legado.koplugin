local Chinese={}; Chinese.__index=Chinese
local MAX_INPUT,MAX_OUTPUT=64*1024,256*1024
local modules={t2s='Legado.spore.local.providers.chinese_data.t2s',
    s2t='Legado.spore.local.providers.chinese_data.s2t'}
local function fail(kind,message) return nil,{kind=kind,message=message} end
local function width_at(text,index)
    local first=text:byte(index)
    if first<128 then return 1 end
    local width=first>=194 and first<=223 and 2 or first>=224 and first<=239 and 3
        or first>=240 and first<=244 and 4 or nil
    if not width or index+width-1>#text then return nil end
    for position=index+1,index+width-1 do
        local byte=text:byte(position)
        if byte<128 or byte>191 then return nil end
    end
    local second=text:byte(index+1)
    if first==224 and second<160 or first==237 and second>159
        or first==240 and second<144 or first==244 and second>143 then return nil end
    return width
end
function Chinese.new() return setmetatable({maps={},failed={}},Chinese) end
function Chinese:mapping(direction)
    if self.maps[direction] then return self.maps[direction] end
    if self.failed[direction] then return nil end
    local ok,data=pcall(require,modules[direction])
    if not ok or type(data)~='string' then self.failed[direction]=true;return nil end
    local mapping={}
    for line in data:gmatch('[^\r\n]+') do
        local from,to=line:match('^(%S+)%s+(%S+)')
        if not from or not to or mapping[from] then self.failed[direction]=true;return nil end
        mapping[from]=to
    end
    if not next(mapping) then self.failed[direction]=true;return nil end
    self.maps[direction]=mapping
    return mapping
end
function Chinese:convert(args)
    if type(args)~='table' or not modules[args.direction] or type(args.text)~='string' then
        return fail('invalid_argument','invalid Chinese conversion request')
    end
    local text=args.text
    if #text>MAX_INPUT then return fail('limit_exceeded','Chinese text input too large') end
    local index=1
    while index<=#text do
        local width=width_at(text,index)
        if not width then return fail('invalid_argument','Chinese text must be UTF-8') end
        index=index+width
    end
    if text=='' then return '' end
    local mapping=self:mapping(args.direction)
    if not mapping then return fail('unavailable','Chinese conversion data unavailable') end
    local output,total={},0;index=1
    while index<=#text do
        local width=width_at(text,index)
        local char=text:sub(index,index+width-1)
        local converted=mapping[char] or char
        total=total+#converted
        if total>MAX_OUTPUT then return fail('limit_exceeded','Chinese text output too large') end
        output[#output+1]=converted;index=index+width
    end
    return table.concat(output)
end
function Chinese:handlers()
    return {['text.chinese.convert']=function(args) return self:convert(args) end}
end
return Chinese
