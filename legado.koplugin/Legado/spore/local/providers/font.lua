local ffi=require('ffi')
local bit=require('bit')
local sha=require('ffi/sha2')
local Font={}
local MAX_BYTES,MAX_GLYPHS,MAX_POINTS,MAX_MAPPINGS=524288,8192,65536,8192
local function reject(kind,message) error({kind=kind,message=message},0) end
local function invalid(message) reject('invalid_argument',message) end
local function limit(message) reject('limit_exceeded',message) end
local function unsupported(message) reject('unsupported',message) end

local function reader(data)
    local function range(pos,n)
        if pos<0 or n<0 or pos+n>#data then invalid('font table is truncated or out of bounds') end
    end
    local function u16(pos)
        range(pos,2)
        return data:byte(pos+1)*256+data:byte(pos+2)
    end
    local function i16(pos) local n=u16(pos);return n>=32768 and n-65536 or n end
    local function u32(pos) return u16(pos)*65536+u16(pos+2) end
    return u16,i16,u32,range
end

local function metadata(data)
    local u16,_,u32,range=reader(data)
    if data:sub(1,4)~='\0\1\0\0' then unsupported('only simple TrueType SFNT fonts are supported') end
    local count=u16(4)
    if count>64 then limit('font table count exceeds limit') end
    range(0,12+16*count)
    local tables={}
    for i=0,count-1 do
        local pos=12+i*16
        local tag=data:sub(pos+1,pos+4)
        local offset,length=u32(pos+8),u32(pos+12)
        range(offset,length)
        if offset<12+16*count or tables[tag] then invalid('invalid or duplicate font table') end
        tables[tag]=data:sub(offset+1,offset+length)
    end
    local function required(tag,size)
        local value=tables[tag]
        if not value or #value<size then invalid('missing or short required font table: '..tag) end
        return value
    end
    local head=required('head',54)
    local hu16,hi16=reader(head)
    if hu16(18)==0 then invalid('invalid units per em') end
    local maxp=required('maxp',32)
    local mu16,_,mu32=reader(maxp)
    if mu32(0)~=65536 then unsupported('only TrueType maxp version 1 is supported') end
    local glyph_count=mu16(4)
    if glyph_count==0 then invalid('font has no glyphs') end
    if glyph_count>MAX_GLYPHS then limit('font glyph count exceeds limit') end
    local hhea=required('hhea',36)
    local hhu16=reader(hhea)
    local metric_count=hhu16(34)
    if metric_count<1 or metric_count>glyph_count then invalid('invalid horizontal metric count') end
    local hmtx=required('hmtx',metric_count*4+(glyph_count-metric_count)*2)
    local _,hmi16=reader(hmtx)
    local format=hi16(50)
    if format~=0 and format~=1 then invalid('invalid loca format') end
    local width=format==0 and 2 or 4
    local loca=required('loca',(glyph_count+1)*width)
    local lu16,_,lu32=reader(loca)
    local glyf=required('glyf',0)
    local gu16,gi16,_,grange=reader(glyf)
    local offsets={}
    for i=0,glyph_count do
        local offset=format==0 and lu16(i*2)*2 or lu32(i*4)
        if offset>#glyf or i>0 and offset<offsets[i-1] then invalid('invalid glyph offsets') end
        offsets[i]=offset
    end
    local glyphs,total={},0
    for gid=0,glyph_count-1 do
        local first,last=offsets[gid],offsets[gid+1]
        if first~=last then
            if last-first<10 then invalid('short glyph header') end
            local contours=gi16(first)
            if contours<0 then unsupported('compound glyphs are not supported by the limited font provider') end
            if contours>1024 then limit('font contour count exceeds limit') end
            if contours>mu16(8) then invalid('glyph contour count exceeds maxp') end
            if contours>0 then
                if 12+contours*2>last-first then invalid('short glyph contour table') end
                local previous=-1
                for index=0,contours-1 do
                    local endpoint=gu16(first+10+index*2)
                    if endpoint<=previous then invalid('invalid contour endpoints') end
                    previous=endpoint
                end
                local points=previous+1
                total=total+points
                if points>4096 or total>MAX_POINTS then limit('font outline point budget exceeded') end
                local instructions=gu16(first+10+contours*2)
                if 12+contours*2+instructions>last-first then invalid('short glyph instructions') end
                grange(first,last-first)
                local metric_offset=gid<metric_count and gid*4+2 or metric_count*4+(gid-metric_count)*2
                glyphs[gid]={points=points,contours=contours,shift=hmi16(metric_offset)-gi16(first+2)}
            end
        end
    end
    local cmap=required('cmap',4)
    local cu16,_,cu32,crange=reader(cmap)
    local records=cu16(2)
    if records>16 then limit('font cmap record budget exceeded') end
    crange(0,4+8*records)
    local mapping,seen,expansions={}, {},0
    local function put(cp,gid)
        expansions=expansions+1
        if expansions>65536 then limit('font cmap expansion budget exceeded') end
        if gid>=glyph_count or gid<0 then invalid('cmap glyph outside font') end
        if gid>0 then mapping[cp]=gid end
    end
    for index=0,records-1 do
        local offset=cu32(4+index*8+4)
        if not seen[offset] then
            seen[offset]=true
            local fmt=cu16(offset)
            if fmt~=0 and fmt~=4 and fmt~=6 then unsupported('unsupported cmap format') end
            local length=cu16(offset+2)
            crange(offset,length)
            if length<6 then invalid('short cmap subtable') end
            local sub=cmap:sub(offset+1,offset+length)
            local su16,si16,_,srange=reader(sub)
            if fmt==0 then
                if length~=262 then invalid('invalid cmap format 0') end
                for cp=0,255 do put(cp,sub:byte(7+cp)) end
            elseif fmt==6 then
                local first,n=su16(6),su16(8)
                srange(10,n*2)
                if first+n>65536 then invalid('invalid cmap format 6 range') end
                for i=0,n-1 do put(first+i,su16(10+i*2)) end
            else
                local segment_bytes=su16(6)
                local n=segment_bytes/2
                if n<1 or n%1~=0 then invalid('invalid cmap segment count') end
                if n>8192 then limit('font cmap segment budget exceeded') end
                srange(0,16+8*n)
                for i=0,n-1 do
                    local last=su16(14+i*2)
                    local first=su16(16+2*n+i*2)
                    local delta=si16(16+4*n+i*2)
                    local range_pos=16+6*n+i*2
                    local offset_delta=su16(range_pos)
                    if first>last then invalid('invalid cmap segment range') end
                    for cp=first,last do
                        local gid
                        if offset_delta==0 then gid=(cp+delta)%65536
                        else
                            local stored=su16(range_pos+offset_delta+2*(cp-first))
                            gid=stored==0 and 0 or (stored+delta)%65536
                        end
                        put(cp,gid)
                    end
                end
            end
        end
    end
    local codes={}
    for cp in pairs(mapping) do codes[#codes+1]=cp end
    if #codes>MAX_MAPPINGS then limit('font mapping count exceeds limit') end
    table.sort(codes)
    return {glyphs=glyphs,count=glyph_count,mapping=mapping,codes=codes}
end

local function input_bytes(value)
    if type(value)~='table' then invalid('font bytes must be an array') end
    if #value>MAX_BYTES then limit('font byte input exceeds limit') end
    local count,parts=0,{}
    for i,byte in pairs(value) do
        if type(i)~='number' or i%1~=0 or i<1 or i>#value or type(byte)~='number'
            or byte%1~=0 or byte<0 or byte>255 then invalid('invalid font byte array') end
        count=count+1
    end
    if count~=#value then invalid('sparse font byte array') end
    for i=1,#value do parts[i]=string.char(value[i]) end
    return table.concat(parts)
end

local function load_outline_map(data,meta)
    local FT=require('ffi/freetype')
    local ft=ffi.loadlib('freetype','6')
    require('ffi/posix_h')
    ffi.cdef[[int mkstemp(char *);]]
    local folder=require('Legado.Helper.Env').getTempDirectory()
    local lfs=require('libs/libkoreader-lfs')
    if type(folder)~='string' or lfs.symlinkattributes(folder,'mode')~='directory' then
        reject('permission_denied','invalid trusted font temporary directory')
    end
    local template=folder..'/font-XXXXXX'
    local name=ffi.new('char[?]',#template+1)
    ffi.copy(name,template,#template)
    local fd=ffi.C.mkstemp(name)
    if fd<0 then reject('operation_failed','font temporary file creation failed') end
    local path=ffi.string(name)
    local size
    local ok,result=pcall(function()
        local position=0
        while position<#data do
            local written=tonumber(ffi.C.write(fd,data:sub(position+1),#data-position))
            if written<=0 then reject('operation_failed','font temporary write failed') end
            position=position+written
        end
        if ffi.C.close(fd)~=0 then fd=-1;reject('operation_failed','font temporary close failed') end
        fd=-1
        size=FT.newFaceSize(path,16,0)
        if not os.remove(path) then reject('operation_failed','font temporary unlink failed') end
        local face=size.face
        if tonumber(face.num_glyphs)~=meta.count then invalid('inconsistent font glyph count') end
        local flags=bit.bor(ft.FT_LOAD_NO_SCALE,ft.FT_LOAD_NO_HINTING,ft.FT_LOAD_NO_AUTOHINT,
            ft.FT_LOAD_NO_BITMAP,ft.FT_LOAD_IGNORE_TRANSFORM)
        local hashes={}
        for gid,glyph in pairs(meta.glyphs) do
            if ft.FT_Load_Glyph(face,gid,flags)~=0 then invalid('FreeType rejected font glyph') end
            local outline=face.glyph.outline
            if tonumber(outline.n_points)~=glyph.points or tonumber(outline.n_contours)~=glyph.contours then
                unsupported('FreeType outline is not compatible with simple glyph metadata')
            end
            local parts,last_x,last_y={},glyph.shift,0
            for i=0,glyph.points-1 do
                local x,y=tonumber(outline.points[i].x),tonumber(outline.points[i].y)
                parts[#parts+1]=(x-last_x)..','..(y-last_y)
                last_x,last_y=x,y
            end
            hashes[gid]=sha.sha256(table.concat(parts,'|'))
        end
        local entries=require('rapidjson').array({})
        for _,cp in ipairs(meta.codes) do
            local gid=meta.mapping[cp]
            entries[#entries+1]={cp,gid,hashes[gid] or false}
        end
        return {version=1,entries=entries}
    end)
    if fd>=0 then ffi.C.close(fd) end
    os.remove(path)
    if size then size:done() end
    if not ok then error(result,0) end
    return result
end

function Font.parse(args)
    if type(args)~='table' then return nil,{kind='invalid_argument',message='invalid font request'} end
    local ok,result=pcall(function()
        local data=input_bytes(args.data)
        return load_outline_map(data,metadata(data))
    end)
    if ok then return result end
    if type(result)=='table' and result.kind then return nil,result end
    return nil,{kind='operation_failed',message='font parsing failed'}
end
return Font
