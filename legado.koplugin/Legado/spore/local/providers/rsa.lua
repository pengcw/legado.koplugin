local ffi = require('ffi')
ffi.cdef[[
struct evp_pkey_st; struct rsa_st; struct pkcs8_priv_key_info_st;
struct evp_pkey_st *d2i_PUBKEY(struct evp_pkey_st **, const unsigned char **, long);
struct pkcs8_priv_key_info_st *d2i_PKCS8_PRIV_KEY_INFO(struct pkcs8_priv_key_info_st **, const unsigned char **, long);
struct evp_pkey_st *EVP_PKCS82PKEY(const struct pkcs8_priv_key_info_st *);
void PKCS8_PRIV_KEY_INFO_free(struct pkcs8_priv_key_info_st *);
void EVP_PKEY_free(struct evp_pkey_st *);
struct rsa_st *EVP_PKEY_get1_RSA(struct evp_pkey_st *);
int RSA_size(const struct rsa_st *);
int RSA_bits(const struct rsa_st *);
void RSA_free(struct rsa_st *);
int RSA_public_encrypt(int, const unsigned char *, unsigned char *, struct rsa_st *, int);
int RSA_private_decrypt(int, const unsigned char *, unsigned char *, struct rsa_st *, int);
]]
local Backend=require('Legado.spore.local.providers.crypto_backend')
local RSA = {}; RSA.__index = RSA
local MAX_INPUT, MAX_PLAIN, MAX_KEY = 16384, 14336, 16384
local required = {'d2i_PUBKEY','d2i_PKCS8_PRIV_KEY_INFO','EVP_PKCS82PKEY',
    'PKCS8_PRIV_KEY_INFO_free','EVP_PKEY_free','EVP_PKEY_get1_RSA',
    'RSA_size','RSA_bits','RSA_free','RSA_public_encrypt','RSA_private_decrypt'}
local function fail(kind,message) return nil,{kind=kind,message=message} end
local function load_library() return Backend.load(required) end
local function bytes(value,limit)
    if type(value) ~= 'table' or #value > limit then return nil end
    local count,parts = 0,{}
    for i,b in pairs(value) do
        if type(i)~='number' or i%1~=0 or i<1 or i>#value
            or type(b)~='number' or b%1~=0 or b<0 or b>255 then return nil end
        count=count+1
    end
    if count~=#value then return nil end
    for i,b in ipairs(value) do parts[i]=string.char(b) end
    return table.concat(parts)
end
local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local base64_values = {}
for i=1,#alphabet do base64_values[alphabet:sub(i,i)]=i-1 end
local function pem_der(value,private)
    local label = private and 'PRIVATE KEY' or 'PUBLIC KEY'
    local body = value:match('^%s*%-%-%-%-%-BEGIN '..label..'%-%-%-%-%-%s*(.-)%s*%-%-%-%-%-END '..label..'%-%-%-%-%-%s*$')
    if not body then return nil end
    body=body:gsub('%s','')
    if #body==0 or #body%4~=0 or body:find('[^A-Za-z0-9+/=]') then return nil end
    local output={}
    for i=1,#body,4 do
        local a,b,c,d=body:sub(i,i),body:sub(i+1,i+1),body:sub(i+2,i+2),body:sub(i+3,i+3)
        if not base64_values[a] or not base64_values[b] or (c=='=' and d~='=')
            or ((c=='=' or d=='=') and i+3~=#body)
            or (c~='=' and not base64_values[c]) or (d~='=' and not base64_values[d]) then return nil end
        local n=base64_values[a]*262144+base64_values[b]*4096+(base64_values[c] or 0)*64+(base64_values[d] or 0)
        output[#output+1]=string.char(math.floor(n/65536)%256)
        if c~='=' then output[#output+1]=string.char(math.floor(n/256)%256) end
        if d~='=' then output[#output+1]=string.char(n%256) end
    end
    return table.concat(output)
end
local function read_key(lib,der,private)
    local buffer=ffi.new('unsigned char[?]',#der+1); ffi.copy(buffer,der,#der)
    local cursor=ffi.new('const unsigned char *[1]',buffer)
    local pkey
    if private then
        local info=lib.d2i_PKCS8_PRIV_KEY_INFO(nil,cursor,#der)
        if info~=nil then pkey=lib.EVP_PKCS82PKEY(info); lib.PKCS8_PRIV_KEY_INFO_free(info) end
    else pkey=lib.d2i_PUBKEY(nil,cursor,#der) end
    local consumed=cursor[0]==buffer+#der
    ffi.fill(buffer,#der+1,0)
    if pkey==nil then return nil end
    local rsa=consumed and lib.EVP_PKEY_get1_RSA(pkey) or nil
    lib.EVP_PKEY_free(pkey)
    return rsa
end
local function transform(lib,der,input,decrypt)
    local rsa=read_key(lib,der,decrypt)
    if rsa==nil then return fail('invalid_argument','invalid RSA key (SPKI public or PKCS8 private required)') end
    rsa=ffi.gc(rsa,lib.RSA_free)
    local bits,size=tonumber(lib.RSA_bits(rsa)),tonumber(lib.RSA_size(rsa))
    local function done(value,err)
        ffi.gc(rsa,nil); lib.RSA_free(rsa); return value,err
    end
    if bits<1024 or bits>4096 or size<128 or size>512 then
        local _,err=fail('invalid_argument','RSA key size must be 1024..4096 bits'); return done(nil,err)
    end
    if decrypt and (#input==0 or #input%size~=0) then
        local _,err=fail('invalid_argument','RSA ciphertext must contain complete key blocks'); return done(nil,err)
    end
    local step=decrypt and size or size-11
    local output={}
    for position=1,math.max(1,#input),step do
        local length=math.min(step,#input-position+1)
        local buffer=ffi.new('unsigned char[?]',length+1)
        ffi.copy(buffer,input:sub(position,position+length-1),length)
        local result=ffi.new('unsigned char[?]',size)
        local written
        if decrypt then written=lib.RSA_private_decrypt(length,buffer,result,rsa,1)
        else written=lib.RSA_public_encrypt(length,buffer,result,rsa,1) end
        ffi.fill(buffer,length+1,0)
        if written<0 or written>size then
            ffi.fill(result,size,0)
            local _,err=fail('operation_failed','RSA operation failed'); return done(nil,err)
        end
        output[#output+1]=ffi.string(result,written)
        ffi.fill(result,size,0)
    end
    return done(table.concat(output))
end
function RSA.new(loader) return setmetatable({loader=loader or load_library},RSA) end
function RSA:discover()
    if self.checked then return end
    self.checked=true
    local loaded,lib=pcall(self.loader)
    if not loaded or not lib then return end
    lib=Backend.bind(lib,required)
    if not lib then return end
    local fixture=require('Legado.spore.local.providers.rsa_selftest')
    local ok,result=pcall(function()
        local encrypted=transform(lib,pem_der(fixture.public,false),'reader RSA self-test',false)
        if not encrypted then return false end
        return transform(lib,pem_der(fixture.private,true),encrypted,true)=='reader RSA self-test'
    end)
    if ok and result then self.library=lib end
end
function RSA:capabilities()
    self:discover()
    return {protocol=1,available=self.library~=nil,transformation='RSA/ECB/PKCS1PADDING',
        minKeyBits=1024,maxKeyBits=4096,maxInputBytes=MAX_INPUT,maxEncryptBytes=MAX_PLAIN,maxOutputBytes=MAX_INPUT,
        publicEncrypt=true,privateDecrypt=true,publicDecrypt=false,privateEncrypt=false}
end
function RSA:asymmetric(args)
    if type(args)~='table' or (args.action~='encrypt' and args.action~='decrypt') then return fail('invalid_argument','invalid RSA request') end
    if args.transformation~='RSA/ECB/PKCS1PADDING' then return fail('unsupported','unsupported RSA transformation') end
    if type(args.usePublicKey)~='boolean' then return fail('invalid_argument','RSA key selection is required') end
    local decrypt=args.action=='decrypt'
    if args.usePublicKey==decrypt then return fail('unsupported','only public encryption and private decryption are supported') end
    local der
    if type(args.key)=='string' and #args.key<=MAX_KEY then der=pem_der(args.key,decrypt)
    else der=bytes(args.key,MAX_KEY) end
    local input=bytes(args.data,decrypt and MAX_INPUT or MAX_PLAIN)
    if not der or #der==0 or #der>MAX_KEY or not input then return fail('invalid_argument','invalid RSA key or byte data') end
    self:discover()
    if not self.library then return fail('unsupported','RSA is not available on this device') end
    local ok,result,err=pcall(transform,self.library,der,input,decrypt)
    if not ok then return fail('operation_failed','RSA operation failed') end
    if not result then return nil,err end
    local output={}
    for i=1,#result do output[i]=result:byte(i) end
    return output
end

function RSA:handlers()
    return {['crypto.rsa.capabilities']=function() return self:capabilities() end,
        ['crypto.asymmetric']=function(args) return self:asymmetric(args) end}
end
return RSA
