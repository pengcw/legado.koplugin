local Compression={}; Compression.__index=Compression
local MAX_INPUT,MAX_OUTPUT=512*1024,256*1024
local function fail(kind,message) return nil,{kind=kind,message=message} end
local function bytes(value)
    if type(value)~='table' or #value>MAX_INPUT then return nil end
    local count,parts=0,{}
    for i,b in pairs(value) do
        if type(i)~='number' or i%1~=0 or i<1 or i>#value or type(b)~='number'
            or b%1~=0 or b<0 or b>255 then return nil end
        count=count+1
    end
    if count~=#value then return nil end
    for i,b in ipairs(value) do parts[i]=string.char(b) end
    return table.concat(parts)
end
local function array(s) local r={}; for i=1,#s do r[i]=s:byte(i) end; return r end
function Compression.new() return setmetatable({},Compression) end
function Compression:zip_module()
    if not self.zip_checked then
        self.zip_checked=true
        local ok,mod=pcall(require,'Legado.Helper.ZipUtil')
        if ok and type(mod)=='table' and type(mod.readMemoryEntry)=='function' then self.zip=mod end
    end
    return self.zip
end
function Compression:capabilities()
    local zip=self:zip_module()
    local zip_ok=false
    if zip then
        local ok,_,err=pcall(zip.readMemoryEntry,'PK\5\6'..string.rep('\0',18),'probe')
        zip_ok=ok and err=='entry not found'
    end
    return {protocol=1,zip=zip_ok,maxInputBytes=MAX_INPUT,maxOutputBytes=MAX_OUTPUT}
end
function Compression:read_zip(args)
    if type(args)~='table' or type(args.path)~='string' then return fail('invalid_argument','invalid ZIP request') end
    local input=bytes(args.data)
    if not input then return fail('invalid_argument','invalid ZIP byte input') end
    local mod=self:zip_module()
    if not mod then return fail('unsupported','memory ZIP reader unavailable') end
    local result,err=mod.readMemoryEntry(input,args.path)
    if err=='entry not found' then return nil end
    if not result then
        local kind=err and err:find('too large',1,true) and 'limit_exceeded' or 'operation_failed'
        if err and err:find('unavailable',1,true) then kind='unsupported' end
        if err=='invalid entry path' then kind='invalid_argument' end
        return fail(kind,err or 'memory ZIP operation failed')
    end
    return array(result)
end
function Compression:handlers()
    return {['compression.capabilities']=function() return self:capabilities() end,
        ['compression.zip.read']=function(args) return self:read_zip(args) end}
end
return Compression
