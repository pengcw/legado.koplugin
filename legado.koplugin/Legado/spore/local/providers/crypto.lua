local ffi = require("ffi")
ffi.cdef[[
struct evp_cipher_ctx_st;
struct evp_cipher_st;
struct engine_st;
struct evp_cipher_ctx_st *EVP_CIPHER_CTX_new(void);
void EVP_CIPHER_CTX_free(struct evp_cipher_ctx_st *);
int EVP_CIPHER_CTX_set_padding(struct evp_cipher_ctx_st *, int);
int EVP_EncryptInit_ex(struct evp_cipher_ctx_st *, const struct evp_cipher_st *, struct engine_st *, const unsigned char *, const unsigned char *);
int EVP_DecryptInit_ex(struct evp_cipher_ctx_st *, const struct evp_cipher_st *, struct engine_st *, const unsigned char *, const unsigned char *);
int EVP_EncryptUpdate(struct evp_cipher_ctx_st *, unsigned char *, int *, const unsigned char *, int);
int EVP_DecryptUpdate(struct evp_cipher_ctx_st *, unsigned char *, int *, const unsigned char *, int);
int EVP_EncryptFinal_ex(struct evp_cipher_ctx_st *, unsigned char *, int *);
int EVP_DecryptFinal_ex(struct evp_cipher_ctx_st *, unsigned char *, int *);
const struct evp_cipher_st *EVP_des_ecb(void);
const struct evp_cipher_st *EVP_des_cbc(void);
]]
local Backend = require('Legado.spore.local.providers.crypto_backend')
local Crypto = {}
Crypto.__index = Crypto
local MAX_INPUT_BYTES = 256 * 1024
local functions = { "EVP_CIPHER_CTX_new", "EVP_CIPHER_CTX_free", "EVP_CIPHER_CTX_set_padding",
    "EVP_EncryptInit_ex", "EVP_DecryptInit_ex", "EVP_EncryptUpdate", "EVP_DecryptUpdate",
    "EVP_EncryptFinal_ex", "EVP_DecryptFinal_ex" }

local function failure(kind, message) return nil, {kind=kind, message=message} end
local function load_library() return Backend.load(functions) end
local function bytes(value, limit)
    if type(value) ~= "table" or #value > limit then return nil end
    local count, parts = 0, {}
    for index, byte in pairs(value) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #value
            or type(byte) ~= "number" or byte % 1 ~= 0 or byte < 0 or byte > 255 then return nil end
        count = count + 1
    end
    if count ~= #value then return nil end
    for index = 1, #value do parts[index] = string.char(value[index]) end
    return table.concat(parts)
end
local function transform(library, cipher, key, iv, input, decrypt, padded)
    local ctx = library.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil end
    ctx = ffi.gc(ctx, library.EVP_CIPHER_CTX_free)
    local key_buffer = ffi.new("unsigned char[?]", #key + 1)
    ffi.copy(key_buffer, key, #key)
    local iv_buffer = ffi.new("unsigned char[16]")
    if iv ~= "" then ffi.copy(iv_buffer, iv, #iv) end
    local input_buffer = ffi.new("unsigned char[?]", #input + 1)
    ffi.copy(input_buffer, input, #input)
    local output = ffi.new("unsigned char[?]", #input + 32)
    local written, final = ffi.new("int[1]"), ffi.new("int[1]")
    local init = decrypt and library.EVP_DecryptInit_ex or library.EVP_EncryptInit_ex
    local update = decrypt and library.EVP_DecryptUpdate or library.EVP_EncryptUpdate
    local finish = decrypt and library.EVP_DecryptFinal_ex or library.EVP_EncryptFinal_ex
    local ok = init(ctx,cipher,nil,key_buffer,iv_buffer) == 1
    ok = ok and library.EVP_CIPHER_CTX_set_padding(ctx,padded and 1 or 0) == 1
    ok = ok and update(ctx,output,written,input_buffer,#input) == 1
    ok = ok and finish(ctx,output+written[0],final) == 1
    local result = ok and ffi.string(output,written[0]+final[0]) or nil
    ffi.fill(key_buffer,#key,0)
    ffi.fill(iv_buffer,16,0)
    ffi.fill(input_buffer,math.max(1,#input),0)
    ffi.fill(output,#input+32,0)
    ffi.gc(ctx,nil)
    library.EVP_CIPHER_CTX_free(ctx)
    return result
end

function Crypto.new(loader)
    return setmetatable({loader=loader or load_library},Crypto)
end
function Crypto:discover()
    if self.support then return end
    self.support = {}
    local loaded, library = pcall(self.loader)
    if not loaded or not library then return end
    library = Backend.bind(library,functions)
    if not library then return end
    self.library = library
    for _, mode in ipairs({"CBC","ECB"}) do
        local getter = Backend.optional(library,"EVP_des_"..mode:lower())
        local ok, cipher = pcall(function() return getter and getter() end)
        if ok and cipher ~= nil then
            for _, padding in ipairs({"PKCS5PADDING","PKCS7PADDING","NOPADDING"}) do
                local name = "DES/"..mode.."/"..padding
                local key, iv = string.rep("\0",8), mode == "CBC" and string.rep("\0",8) or ""
                local input, padded = string.rep("\0",8), padding ~= "NOPADDING"
                local success, encrypted = pcall(transform,library,cipher,key,iv,input,false,padded)
                local decoded, plain
                if success and encrypted then decoded, plain = pcall(transform,library,cipher,key,iv,encrypted,true,padded) end
                if decoded and plain == input then
                    self.support[name..":8"] = cipher
                    self.support[name] = {keyBytes={8}}
                end
            end
        end
    end
end
function Crypto:capabilities()
    self:discover()
    local symmetric = {}
    for name, value in pairs(self.support) do
        if type(value) == "table" then symmetric[name] = {keyBytes=value.keyBytes} end
    end
    return {protocol=1,symmetric=symmetric,maxInputBytes=MAX_INPUT_BYTES}
end
function Crypto:symmetric(args)
    if type(args) ~= "table" or (args.action ~= "encrypt" and args.action ~= "decrypt")
        or type(args.transformation) ~= "string" then
        return failure("invalid_argument","invalid symmetric request")
    end
    local name = args.transformation:upper()
    local algorithm, mode, padding = name:match("^([A-Z]+)/([A-Z]+)/([A-Z0-9]+)$")
    if algorithm ~= "DES" or (mode ~= "CBC" and mode ~= "ECB") or (padding ~= "PKCS5PADDING"
        and padding ~= "PKCS7PADDING" and padding ~= "NOPADDING") then
        return failure("unsupported","unsupported symmetric transformation")
    end
    local key, iv, input = bytes(args.key,8), bytes(args.iv or {},8), bytes(args.data,MAX_INPUT_BYTES)
    local block = 8
    local valid_key = key and #key == 8
    if not valid_key or not iv or not input
        or (mode == "CBC" and #iv ~= block) or (mode == "ECB" and #iv ~= 0) then
        return failure("invalid_argument","invalid symmetric key, IV or byte data")
    end
    local padded = padding ~= "NOPADDING"
    if (not padded or args.action == "decrypt") and #input % block ~= 0
        or (padded and args.action == "decrypt" and #input == 0) then
        return failure("invalid_argument","invalid symmetric block length")
    end
    self:discover()
    local cipher = self.support[name..":"..#key]
    if not cipher then return failure("unsupported","symmetric combination is not available on this device") end
    local ok, output = pcall(transform,self.library,cipher,key,iv,input,args.action == "decrypt",padded)
    if not ok or not output then return failure("operation_failed","symmetric operation failed") end
    local result = {}
    for index=1,#output do result[index] = output:byte(index) end
    return result
end
function Crypto:handlers()
    local hmac
    return {
        ["crypto.capabilities"] = function() return self:capabilities() end,
        ["crypto.symmetric"] = function(args) return self:symmetric(args) end,
        ["crypto.hmac"] = function(args)
            if not hmac then hmac = require("Legado.spore.local.providers.hmac").new() end
            return hmac:digest(args)
        end,
    }
end
return Crypto
