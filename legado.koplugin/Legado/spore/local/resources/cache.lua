local lfs = require("libs/libkoreader-lfs")
local ffi = require("ffi")
require("ffi/posix_h")
local sha = require("ffi/sha2")
local url = require("socket.url")
local image_meta = require("Legado.Helper.image_meta")
ffi.cdef[[int mkstemp(char *);]]

local Cache = {}
Cache.__index = Cache
local MAX_ITEM, MAX_TOTAL, MAX_META, MAX_AGE = 4*1024*1024, 48*1024*1024, 16384, 86400

local function failure(kind, message)
    return nil, {kind = kind, message = message}
end

local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function digest(s)
    return type(s) == "string" and #s == 64 and s:match("^[0-9a-f]+$") ~= nil
end

local function directory(path, create)
    local info = lfs.symlinkattributes(path)
    if not info and create then
        lfs.mkdir(path)
        info = lfs.symlinkattributes(path)
    end
    return info and info.mode == "directory"
end

local function read_file(path, limit)
    local info = lfs.symlinkattributes(path)
    if not info or info.mode ~= "file" or info.size > limit then return end
    local file = io.open(path, "rb")
    if not file then return end
    local data = file:read(limit + 1)
    file:close()
    if data and #data <= limit then return data end
end

local function atomic_write(path, data)
    local template = path .. ".tmp-XXXXXX"
    local name = ffi.new("char[?]", #template + 1)
    ffi.copy(name, template, #template)
    local fd = ffi.C.mkstemp(name)
    if fd < 0 then return false end
    local temporary = ffi.string(name)
    local pointer, position = ffi.cast("const char *", data), 0
    while position < #data do
        local written = tonumber(ffi.C.write(fd, pointer + position, #data - position))
        if written <= 0 then break end
        position = position + written
    end
    local closed = ffi.C.close(fd) == 0
    if position == #data and closed and os.rename(temporary, path) then return true end
    os.remove(temporary)
    return false
end

local function with_lock(dir, operation)
    local lock = lfs.lock_dir(dir, 300)
    if not lock then return failure("cache_busy", "resource cache is busy") end
    local ok, result, err = pcall(operation)
    lock:free()
    if not ok then return failure("cache_unavailable", "resource cache operation failed") end
    return result, err
end

local months = {Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
    Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12}
local function http_date(value)
    if type(value) ~= "string" then return end
    local day, month, year, hour, minute, second =
        value:match("^%a%a%a, (%d%d?) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT$")
    if not day or not months[month] then return end
    local parts = {year=tonumber(year), month=months[month], day=tonumber(day),
        hour=tonumber(hour), min=tonumber(minute), sec=tonumber(second), isdst=false}
    if parts.day < 1 or parts.day > 31 or parts.hour > 23 or parts.min > 59 or parts.sec > 59 then return end
    local stamp = os.time(parts)
    if not stamp then return end
    local utc = os.date("!*t", stamp)
    utc.isdst = false
    return stamp + os.difftime(stamp, os.time(utc))
end

local function headers_lower(headers)
    local result = {}
    for name, value in pairs(headers or {}) do
        if type(name) == "string" and type(value) == "string" then
            result[name:lower()] = value
        end
    end
    return result
end

local function ttl(headers, current)
    local max_age
    for part in (headers["cache-control"] or ""):gmatch("[^,]+") do
        local name, amount = part:match("^%s*([^=]+)=%s*(.-)%s*$")
        if name and name:gsub("%s+$", ""):lower() == "max-age" then
            amount = amount:match('^"?(%d+)"?$')
            local seconds = amount and tonumber(amount)
            if finite(seconds) then max_age = math.min(max_age or seconds, seconds) end
        end
    end
    local response_date = http_date(headers.date)
    local expiry = http_date(headers.expires)
    local lifetime = max_age
    if not lifetime and expiry then lifetime = math.max(0, expiry - (response_date or current)) end
    lifetime = lifetime or MAX_AGE
    local age = tonumber(headers.age) or 0
    if not finite(age) or age < 0 then age = 0 end
    local elapsed = math.max(age, response_date and math.max(0, current-response_date) or 0)
    if not max_age and expiry and not response_date then elapsed = 0 end
    return math.max(0, math.min(MAX_AGE, lifetime-elapsed))
end

local function resolve(reference, base)
    local raw = reference:match("^%s*(.-)%s*$")
    if raw:sub(1, 1) == "#" or raw:lower():match("^data:") then
        return nil, nil, raw
    end
    if raw == "" or #raw > 8192 or raw:find("[%c%s]") then return end
    local absolute = url.absolute(base or "", raw)
    local parsed = absolute and url.parse(absolute)
    if not parsed then return end
    parsed.scheme = parsed.scheme and parsed.scheme:lower()
    if (parsed.scheme ~= "http" and parsed.scheme ~= "https")
        or not parsed.host or parsed.host == "" or parsed.userinfo
        or parsed.user or parsed.password then return end
    local fragment = parsed.fragment
    parsed.fragment = nil
    parsed.host = parsed.host:lower()
    if not parsed.path or parsed.path == "" then parsed.path = "/" end
    return url.build(parsed), fragment
end

local function filename(kind, hash, format)
    if kind == "css" then return "raw-css-" .. hash .. ".body" end
    if image_meta.FORMAT_EXTENSION[format] then return "image-" .. hash .. "." .. format end
end

local function result_for(entry, dir, data)
    return {filename = entry.filename, path = dir .. "/" .. entry.filename,
        final_url = entry.final_url, kind = entry.kind, data = entry.kind == "css" and data or nil}
end

local function display(result, fragment)
    local copy = {}
    for key, value in pairs(result) do copy[key] = value end
    copy.fragment = fragment
    copy.reference = result.filename .. (fragment ~= nil and "#" .. fragment or "")
    return copy
end

function Cache.new(options)
    options = options or {}
    local root = options.root
    assert(type(root) == "string" and root:sub(1, 1) == "/" and not root:find("%c"), "trusted absolute root required")
    for part in root:gmatch("[^/]+") do assert(part ~= "..", "invalid root") end
    root = root:gsub("/+$", "")
    return setmetatable({root = root ~= "" and root or "/", download = options.download,
        clock = options.clock or os.time, json = options.json or require("rapidjson"),
        limits = options.limits, requests = 0, bytes = 0, results = {}}, Cache)
end

function Cache:_directory(create)
    if not directory(self.root, false) then return end
    local parent = self.root:gsub("/+$", "") .. "/resources"
    if not directory(parent, create) then return end
    local dir = parent .. "/preview"
    if directory(dir, create) then return dir end
end

function Cache:_read(dir, address, kind)
    local encoded = read_file(dir .. "/resource-" .. sha.sha256(address) .. ".meta", MAX_META)
    if not encoded then return end
    local ok, entry = pcall(self.json.decode, encoded)
    if not ok or type(entry) ~= "table" or entry.version ~= 1
        or entry.url ~= address or entry.kind ~= kind or not digest(entry.hash)
        or not finite(entry.size) or entry.size < 0 or entry.size % 1 ~= 0 or entry.size > MAX_ITEM
        or not finite(entry.fetched_at) or not finite(entry.expires_at)
        or entry.expires_at < entry.fetched_at or entry.expires_at-entry.fetched_at > MAX_AGE
        or entry.expires_at <= self.clock()
        or type(entry.final_url) ~= "string" then return end
    local final = resolve(entry.final_url)
    local expected = filename(kind, entry.hash, entry.format)
    if not final or not expected or expected ~= entry.filename then return end
    local data = read_file(dir .. "/" .. expected, entry.size)
    if not data or #data ~= entry.size or sha.sha256(data) ~= entry.hash then return end
    return result_for(entry, dir, data)
end

function Cache:_publish(address, final_url, kind, data, headers, format)
    local current, hash = self.clock(), sha.sha256(data)
    local entry = {version=1, url=address, final_url=final_url, kind=kind, hash=hash,
        size=#data, fetched_at=current, expires_at=current+ttl(headers, current), format=format}
    entry.filename = filename(kind, hash, format)
    local encoded = self.json.encode(entry)
    if #encoded > MAX_META then return failure("limit_exceeded", "resource metadata too large") end
    local path, err = self:_store(entry.filename, data, "resource-" .. sha.sha256(address) .. ".meta", encoded)
    if not path then return nil, err end
    return result_for(entry, path:match("^(.*)/[^/]+$"), data)
end

function Cache:_store(name, data, meta_name, encoded)
    local dir = self:_directory(true)
    if not dir then return failure("cache_unavailable", "resource directory unavailable") end
    return with_lock(dir, function()
        local target = dir .. "/" .. name
        local existing = read_file(target, MAX_ITEM)
        local write_body = existing ~= data
        if not write_body and not encoded then return target end
        local total = 0
        for name in lfs.dir(dir) do
            local info = lfs.symlinkattributes(dir .. "/" .. name)
            if info and info.mode == "file" then total = total + info.size end
        end
        if total + (write_body and #data or 0) + (encoded and #encoded or 0) > MAX_TOTAL then
            return failure("limit_exceeded", "resource directory quota exceeded")
        end
        if write_body and not atomic_write(target, data) then
            return failure("cache_unavailable", "resource body write failed")
        end
        if encoded and not atomic_write(dir .. "/" .. meta_name, encoded) then
            return failure("cache_unavailable", "resource metadata write failed")
        end
        return target
    end)
end

function Cache:store_css(data)
    if type(data) ~= "string" then return failure("invalid_argument", "CSS bytes required") end
    if #data > MAX_ITEM then return failure("limit_exceeded", "derived CSS too large") end
    local name = "css-" .. sha.sha256(data) .. ".css"
    local path, err = self:_store(name, data)
    if not path then return nil, err end
    return {filename=name, reference=name, path=path, kind="css", data=data}
end

function Cache:_fetch(address, kind)
    local dir = self:_directory(false)
    if dir then
        local hit = with_lock(dir, function() return self:_read(dir, address, kind) end)
        if hit then return hit end
    end
    local limits = self.limits
    if limits == false then
        self.requests, self.bytes = 0, 0
        limits = {max_requests = 6, max_bytes = MAX_ITEM, deadline = self.clock() + 30}
    end
    if type(self.download) ~= "function" then return failure("unavailable", "resource downloader unavailable") end
    if type(limits) ~= "table" or not finite(limits.max_requests)
        or limits.max_requests < 1 or limits.max_requests % 1 ~= 0
        or not finite(limits.max_bytes) or limits.max_bytes < 1 or limits.max_bytes % 1 ~= 0
        or not finite(limits.deadline) then
        return failure("invalid_budget", "resource download limits required")
    end
    if self.requests >= limits.max_requests or self.bytes >= limits.max_bytes
        or self.clock() >= limits.deadline then
        return failure("limit_exceeded", "resource preparation budget exhausted")
    end
    local allowance = math.min(MAX_ITEM, limits.max_bytes-self.bytes)
    self.requests = self.requests + 1
    local ok, response, err = pcall(self.download, address, kind,
        {max_bytes=allowance, deadline=limits.deadline,
            max_requests=limits.max_requests-self.requests+1})
    local data = ok and type(response) == "table" and response.data
    local accounting=ok and (type(response)=="table" and response or type(err)=="table" and err)
    local request_count=accounting and accounting.requests
    if finite(request_count) and request_count>=0 and request_count%1==0 then
        self.requests=self.requests+request_count-1
    end
    local received=accounting and accounting.bytes_received
    if received==nil then received=type(data)=="string" and #data end
    if type(data)=="string" and finite(received) then received=math.max(received,#data) end
    if not finite(received) or received < 0 then received = allowance end
    self.bytes = self.bytes + received
    if not ok or type(data) ~= "string" or response.complete == false then
        local kind=ok and type(err)=="table" and err.kind=="limit_exceeded" and "limit_exceeded" or "download_failed"
        return failure(kind, "resource download failed")
    end
    if #data > allowance or self.bytes > limits.max_bytes or self.requests > limits.max_requests
        or self.clock() >= limits.deadline then
        return failure("limit_exceeded", "resource download exceeded preparation budget")
    end
    if type(response.final_url) ~= "string" or type(response.headers) ~= "table" then
        return failure("invalid_response", "complete resource response required")
    end
    local final_url = resolve(response.final_url)
    if not final_url then return failure("invalid_response", "invalid final resource URL") end
    local headers = headers_lower(response.headers)
    local mime = (headers["content-type"] or ""):lower():match("^%s*([^;%s]+)") or ""
    local format
    if kind == "image" then
        if mime ~= "" and mime ~= "application/octet-stream" and mime:sub(1, 6) ~= "image/" then
            return failure("invalid_response", "resource is not an image")
        end
        format = image_meta.sniff_format(data)
        if not format or not image_meta.is_valid_image(data) then
            if mime == "image/svg+xml" and data:sub(1, 1024):match("<svg[%s>]") then
                format = "svg"
            else
                return failure("invalid_response", "invalid image bytes")
            end
        end
    elseif mime ~= "" and mime ~= "text/css" and mime ~= "application/octet-stream" then
        return failure("invalid_response", "resource is not a stylesheet")
    end
    return self:_publish(address, final_url, kind, data, headers, format)
end

function Cache:fetch(reference, base_url, kind)
    if type(reference) ~= "string" or (kind ~= "image" and kind ~= "css") then
        return failure("invalid_argument", "resource reference and kind required")
    end
    local ok, address, fragment, passthrough = pcall(resolve, reference, base_url)
    if not ok then return failure("invalid_argument", "invalid resource URL") end
    if passthrough then return {reference=passthrough, passthrough=true, kind=kind} end
    if not address then return failure("invalid_argument", "only HTTP(S) resources are supported") end
    local key = kind .. ":" .. address
    local saved = self.results[key]
    if not saved then
        local success, resource, err = pcall(self._fetch, self, address, kind)
        if not success then resource, err = failure("cache_unavailable", "resource preparation failed") end
        saved = {resource=resource, error=err}
        self.results[key] = saved
    end
    if saved.resource then return display(saved.resource, fragment) end
    return nil, saved.error
end

return Cache
