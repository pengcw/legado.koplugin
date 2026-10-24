local lfs=require('libs/libkoreader-lfs')
local ffi=require('ffi')
local ffiUtil=require('ffi/util')
local sha=require('ffi/sha2')
ffi.cdef[[int mkstemp(char *);]]
local Cache={};Cache.__index=Cache
local MAX_VALUE,MAX_FILE=256*1024,2*1024*1024
local MAX_ENTRIES,MAX_TOTAL=64,16*1024*1024
local function fail(kind,message) return nil,{kind=kind,message=message} end
local function directory(path,create)
    local attr=lfs.symlinkattributes(path)
    if not attr and create then lfs.mkdir(path);attr=lfs.symlinkattributes(path) end
    return attr and attr.mode=='directory'
end
function Cache.new(options)
    options=options or {}
    return setmetatable({root=options.root,clock=options.clock or os.time,
        json=options.json or require('rapidjson')},Cache)
end
function Cache:folder(namespace,create)
    if not self.root then
        local base=require('datastorage'):getDataDir()
        if not directory(base,false) then return nil end
        local cache=base..'/cache'
        if not directory(cache,create) then return nil end
        local plugin_cache=cache..'/'..require('Legado.Helper.Env').getPluginName()..'.cache'
        if not directory(plugin_cache,create) then return nil end
        self.root=plugin_cache..'/source-js'
    end
    if not directory(self.root,create) then return nil end
    local folder=self.root..'/'..sha.sha256(namespace)
    if not directory(folder,create) then return nil end
    return folder
end
local function validate(args)
    return type(args)=='table' and type(args.namespace)=='string' and #args.namespace>0
        and #args.namespace<=8192 and type(args.key)=='string' and #args.key<=1024
end
function Cache:read(path)
    local attr=lfs.symlinkattributes(path)
    if not attr then return nil end
    if attr.mode~='file' then return fail('permission_denied','cache entry must be a regular file') end
    if attr.size>MAX_FILE then return fail('limit_exceeded','cache entry too large') end
    local file=io.open(path,'rb')
    if not file then return fail('operation_failed','cache read failed') end
    local raw=file:read(MAX_FILE+1);file:close()
    if not raw then return fail('operation_failed','invalid cache entry') end
    if #raw>MAX_FILE then return fail('limit_exceeded','cache entry too large') end
    local ok,entry=pcall(self.json.decode,raw)
    if not ok or type(entry)~='table' or entry.version~=1 or type(entry.value)~='string'
        or #entry.value>MAX_VALUE or type(entry.expires)~='number'
        or entry.expires<0 or entry.expires%1~=0 then
        return fail('operation_failed','invalid cache entry')
    end
    if entry.expires>0 and entry.expires<=self.clock() then return nil end
    return entry.value
end
function Cache:existing_folder(namespace)
    local folder=self:folder(namespace,false)
    if not folder then
        if self.root and lfs.symlinkattributes(self.root) then
            if not directory(self.root,false) then return fail('permission_denied','invalid cache directory') end
            local entry=lfs.symlinkattributes(self.root..'/'..sha.sha256(namespace))
            if entry and entry.mode~='directory' then return fail('permission_denied','invalid cache directory') end
        end
        return nil
    end
    return folder
end
function Cache:clear(namespace)
    if type(namespace)~='string' or namespace=='' then return fail('invalid_argument','invalid cache namespace') end
    local folder,err=self:existing_folder(namespace)
    if not folder then
        if err then return nil,err end
        return true
    end
    local lock=lfs.lock_dir(folder,300)
    if not lock then return fail('cache_busy','cache directory is busy') end
    local ok,result,operation_error=pcall(function()
        for name in lfs.dir(folder) do
            if name:match('^[0-9a-f]+%.json$') or name:match('^[0-9a-f]+%.json%.tmp%-') then
                local path=folder..'/'..name
                if lfs.symlinkattributes(path,'mode')~='file' then return fail('permission_denied','invalid cache entry') end
                if not os.remove(path) then return fail('operation_failed','cache delete failed') end
            end
        end
        if ffiUtil.fsyncDirectory(folder)~=true then return fail('operation_failed','cache delete sync failed') end
        return true
    end)
    lock:free()
    if not ok then return fail('operation_failed','cache clear failed') end
    return result,operation_error
end

function Cache:get(args)
    if not validate(args) then return fail('invalid_argument','invalid cache key or namespace') end
    local folder,err=self:existing_folder(args.namespace)
    if not folder then return nil,err end
    return self:read(folder..'/'..sha.sha256(args.key)..'.json')
end
function Cache:delete(args)
    if not validate(args) then return fail('invalid_argument','invalid cache key or namespace') end
    local folder,err=self:existing_folder(args.namespace)
    if not folder then
        if err then return nil,err end
        return true
    end
    local lock=lfs.lock_dir(folder,300)
    if not lock then return fail('cache_busy','cache directory is busy') end
    local ok,result,operation_error=pcall(function()
        local path=folder..'/'..sha.sha256(args.key)..'.json'
        local attr=lfs.symlinkattributes(path)
        if not attr then return true end
        if attr.mode~='file' then return fail('permission_denied','invalid cache entry') end
        if not os.remove(path) then return fail('operation_failed','cache delete failed') end
        if ffiUtil.fsyncDirectory(folder)~=true then return fail('operation_failed','cache delete sync failed') end
        return true
    end)
    lock:free()
    if not ok then return fail('operation_failed','cache delete failed') end
    return result,operation_error
end
local function atomic_write(path,payload)
    local template=path..'.tmp-XXXXXX'
    local name=ffi.new('char[?]',#template+1);ffi.copy(name,template,#template)
    local fd=ffi.C.mkstemp(name)
    if fd<0 then return false end
    local temporary=ffi.string(name)
    local success,ok=pcall(function()
        local buffer=ffi.new('char[?]',#payload+1);ffi.copy(buffer,payload,#payload)
        local position=0
        while position<#payload do
            local written=tonumber(ffi.C.write(fd,buffer+position,#payload-position))
            if written<=0 then return false end
            position=position+written
        end
        return ffiUtil.fsyncOpenedFile(fd,true)==true
    end)
    local closed=ffi.C.close(fd)==0
    ok=success and ok and closed
    if ok then ok=os.rename(temporary,path)==true end
    if not ok then os.remove(temporary);return false end
    if ffiUtil.fsyncDirectory(path)~=true then return false end
    return true
end
function Cache:put(args)
    if not validate(args) or type(args.value)~='string' or type(args.saveTime)~='number'
        or args.saveTime%1~=0 or args.saveTime < -2147483648 or args.saveTime>2147483647 then
        return fail('invalid_argument','invalid cache write request')
    end
    if #args.value>MAX_VALUE then return fail('limit_exceeded','cache value too large') end
    local folder=self:folder(args.namespace,true)
    if not folder then return fail('permission_denied','invalid cache directory') end
    local lock=lfs.lock_dir(folder,300)
    if not lock then return fail('cache_busy','cache directory is busy') end
    local ok,result,err=pcall(function()
        local path=folder..'/'..sha.sha256(args.key)..'.json'
        local attr=lfs.symlinkattributes(path)
        if attr and attr.mode~='file' then return fail('permission_denied','invalid cache entry') end
        local encoded_ok,payload=pcall(self.json.encode,{version=1,value=args.value,
            expires=args.saveTime>0 and self.clock()+args.saveTime or 0})
        if not encoded_ok or type(payload)~='string' then return fail('invalid_argument','cache text encoding failed') end
        if #payload>MAX_FILE then return fail('limit_exceeded','cache payload too large') end
        local count,total=0,0
        for name in lfs.dir(folder) do
            local child=folder..'/'..name
            local info=lfs.symlinkattributes(child)
            if name:match('^[0-9a-f]+%.json$') then
                if not info or info.mode~='file' then return fail('permission_denied','invalid cache entry') end
                local value,read_error=self:read(child)
                if value==nil and not read_error then
                    if not os.remove(child) then return fail('operation_failed','cache cleanup failed') end
                else
                    count=count+1;total=total+info.size
                end
            elseif name:match('^[0-9a-f]+%.json%.tmp%-') and info and info.mode=='file' then
                if not os.remove(child) then return fail('operation_failed','cache cleanup failed') end
            end
        end
        attr=lfs.symlinkattributes(path)
        if count+(attr and 0 or 1)>MAX_ENTRIES or total-(attr and attr.size or 0)+#payload>MAX_TOTAL then
            return fail('limit_exceeded','cache namespace quota exceeded')
        end
        if not atomic_write(path,payload) then return fail('operation_failed','cache write failed') end
        return true
    end)
    lock:free()
    if not ok then return fail('operation_failed','cache operation failed') end
    return result,err
end
function Cache:invoke(action,args,context)
    if not validate(args) or type(context)~='table' or type(context.source_json)~='string' then
        return fail('permission_denied','file cache requires a trusted source context')
    end
    local ok,source=pcall(self.json.decode,context.source_json)
    if not ok or type(source)~='table' or source.bookSourceUrl~=args.namespace then
        return fail('permission_denied','cache source namespace mismatch')
    end
    if action=='get' then return self:get(args) end
    if action=='delete' then return self:delete(args) end
    if action=='put' then return self:put(args) end
    return fail('invalid_argument','invalid cache operation')
end
function Cache:handlers()
    return {['cache.file.get']=function(args,context) return self:invoke('get',args,context) end,
        ['cache.file.put']=function(args,context) return self:invoke('put',args,context) end,
        ['cache.file.delete']=function(args,context) return self:invoke('delete',args,context) end}
end
return Cache
