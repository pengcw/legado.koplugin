local M = {}
local MAX_BYTES = 100 * 1024 * 1024

local function jsonCodec()
    local ok, json = pcall(require, "rapidjson")
    return ok and json or require("json")
end

function M.resolve(info, source, book)
    local urls = info.downloadUrls
    if type(urls) == "string" and urls:match("^%s*%[") then
        local ok, decoded = pcall(jsonCodec().decode, urls)
        if not ok or type(decoded) ~= "table" then return nil, "下载地址列表格式错误" end
        urls = decoded
    end
    if type(urls) == "table" then
        local count = 0
        for key, value in pairs(urls) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0
                    or type(value) ~= "string" then return nil, "下载地址列表格式错误" end
            count = count + 1
        end
        if count ~= #urls then return nil, "下载地址列表格式错误" end
        urls = table.concat(urls, "\n")
    end
    if urls == nil or urls == "" then
        return nil, "暂无下载地址；当前版本不自动请求远端详情或切换本地解析"
    end
    local first = type(urls) == "string" and urls:match("[^\r\n]+")
    local url = first and first:match("^%s*(.-)%s*$")
    if not url or not url:match("^https?://") or url:find("%s")
            or url:find(",{", 1, true) then
        return nil, "仅支持简单 HTTP(S) 下载地址"
    end
    local urlutil = require("socket.url")
    local parsed_url = urlutil.parse(url)
    if not parsed_url or not parsed_url.host or parsed_url.userinfo then
        return nil, "无效或带认证信息的下载地址"
    end
    url = url:gsub("[\128-\255]", urlutil.escape)
    local json = jsonCodec()
    local headers = {}
    local raw = source.data and source.data.header
    if raw and raw ~= "" then
        local ok, parsed = true, raw
        if type(raw) ~= "table" then ok, parsed = pcall(json.decode, raw) end
        if not ok or type(parsed) ~= "table" then
            return nil, "暂不支持动态下载请求头"
        end
        for key, value in pairs(parsed) do
            if type(key) ~= "string" then return nil, "无效下载请求头" end
            local lower = key:lower()
            if lower ~= "user-agent" and lower ~= "accept" and lower ~= "accept-language" then
                return nil, "暂不支持此文件下载请求头"
            end
            if type(value) ~= "string" or value:find("[%c]") then return nil, "无效下载请求头" end
            headers[key] = value
        end
    end
    return { url = url, name = info.name ~= "" and info.name or book.name, headers = headers }
end

function M.downloadResource(resource, temp, output_dir)
    if type(temp) ~= "string" or temp == "" then return nil, "缺少下载临时文件路径" end
    local urlutil = require("socket.url")
    local url = resource.url
    local headers = {}
    for key, value in pairs(resource.headers) do headers[key] = value end
    headers["Accept-Encoding"] = "identity"
    local FS = require("Legado.Helper.FS")
    local dir = output_dir or require("Legado.Helper.Env").getHomeDir()
    local function fail(message)
        os.remove(temp)
        return nil, message
    end
    local file, open_err = io.open(temp, "wb")
    if not file then return fail(open_err) end
    local clock = require("socket").gettime
    local ok, response = require("Legado.Helper.Http"){
        url = url, headers = headers, file = file, redirect = true, raw_response = true,
        timeout = { 15, 300 }, max_bytes = MAX_BYTES, deadline = clock() + 300, clock = clock,
    }
    if not ok then return fail("文件下载失败：" .. tostring(response)) end
    if response.code ~= 200 then return fail("文件下载失败（HTTP " .. tostring(response.code) .. "）") end
    local response_headers = response.headers
    local bytes = FS.getFileSize(temp)
    local length = tonumber(response_headers["content-length"])
    if length and length ~= bytes then return fail("下载文件不完整") end
    local file, read_err = io.open(temp, "rb")
    if not file then return fail(read_err) end
    local prefix = file:read(512) or ""
    file:close()
    local mime = tostring(response_headers["content-type"] or ""):lower()
    if bytes == 0 or mime:find("text/html", 1, true)
            or prefix:lower():match("^%s*<!doctype%s+html")
            or prefix:lower():match("^%s*<html") then
        return fail("下载响应为空或返回了网页，无法直接下载")
    end
    local disposition = response_headers["content-disposition"] or ""
    local encoded = disposition:match("[Ff]ilename%*=[Uu][Tt][Ff]%-8''([^;]+)")
    local remote_name = encoded and urlutil.unescape(encoded)
        or disposition:match('[Ff]ilename="([^"]+)"') or disposition:match("[Ff]ilename=([^;]+)")
    local hint = (urlutil.parse(response_headers.location or url) or {}).path or ""
    local mime_ext = response.ext or (mime:match("^%s*([^;%s]+)") == "text/plain" and "txt")
    local ext = (remote_name and remote_name:match("%.([%w]+)%s*$")) or mime_ext or hint:match("%.([%w]+)$") or "bin"
    local filename
    if remote_name and remote_name ~= "" then
        filename = remote_name
    elseif resource.name and resource.name ~= "" then
        filename = resource.name .. "." .. ext:lower()
    else
        filename = urlutil.unescape(hint:match("([^/]+)$") or "下载资源")
        if not filename:match("%.[%w]+$") then filename = filename .. "." .. ext:lower() end
    end
    filename = filename:gsub("[%c]", "_"):gsub("[/\\]", "_")
    filename = FS.getSafeFilename(filename)
    if filename == "" or filename == "." or filename == ".." then return fail("无效下载文件名") end
    local path = FS.joinPath(dir, filename)
    local lfs = require("libs/libkoreader-lfs")
    local lock = path .. ".legado-saving"
    local locked = lfs.mkdir(lock)
    if not locked then
        local attr = lfs.attributes(lock)
        if attr and attr.mode == "directory" and attr.modification
                and os.time() - attr.modification > 300 and lfs.rmdir(lock) then
            locked = lfs.mkdir(lock)
        end
    end
    if not locked then return fail("同名文件正在保存，请稍后重试") end
    local message
    if lfs.symlinkattributes(path) then
        message = "同名文件已存在，请更换目录或重命名后重试"
    elseif not os.rename(temp, path) then
        message = "保存文件失败"
    end
    lfs.rmdir(lock)
    if message then return fail(message) end
    return path
end

return M
