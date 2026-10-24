local ffi=require('ffi')
if not pcall(ffi.typeof,'Dl_info') then
    ffi.cdef[[typedef struct { const char *dli_fname; void *dli_fbase;
        const char *dli_sname; void *dli_saddr; } Dl_info;]]
end
ffi.cdef[[int dladdr(const void *, Dl_info *);]]
local Backend={}
local function origin(fn)
    local ok,base,path=pcall(function()
        local info=ffi.new('Dl_info[1]')
        if ffi.C.dladdr(ffi.cast('const void *',fn),info)==0
            or info[0].dli_fbase==nil or info[0].dli_fname==nil then return nil end
        return info[0].dli_fbase,ffi.string(info[0].dli_fname)
    end)
    if not ok or not base then return nil end
    if ffi.os=='Linux' and os.getenv('IS_ANDROID') then
        local loaded,android=pcall(require,'android')
        local directory=loaded and android.nativeLibraryDir
        if type(directory)~='string' or directory=='' then return nil end
        directory=directory:gsub('/+$','')..'/'
        if path:sub(1,#directory)~=directory then return nil end
    end
    return base,path
end
function Backend.bind(library,names)
    local raw=type(library)=='table' and rawget(library,'_handle') or library
    local bound={_handle=raw}
    for _,name in ipairs(names) do
        local ok,fn=pcall(function() return library[name] end)
        if not ok or type(fn)~='cdata' then return nil end
        local base,path=origin(fn)
        if not base or bound._base and bound._base~=base then return nil end
        bound._base,bound._path=base,path
        bound[name]=fn
    end
    return bound
end
function Backend.optional(bound,name)
    local ok,fn=pcall(function() return bound._handle[name] end)
    if not ok or type(fn)~='cdata' then return nil end
    local base=origin(fn)
    if not base or base~=bound._base then return nil end
    return fn
end
function Backend.load(names)
    if type(ffi.loadlib)~='function' then pcall(require,'ffi/loadlib') end
    if type(ffi.loadlib)~='function' then return nil end
    for _,version in ipairs({'56','57','3','1.1','1.0.0',false}) do
        local ok,lib=pcall(ffi.loadlib,'crypto',version or nil)
        if ok and lib then
            local bound=Backend.bind(lib,names)
            if bound then return bound end
        end
    end
end
return Backend
