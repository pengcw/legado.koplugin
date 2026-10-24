local M = {}
local MAX_BYTES = 100 * 1024 * 1024

function M.temporaryPath()
    local temp = os.tmpname()
    os.remove(temp)
    return require("Legado.Helper.FS").joinPath(
        require("Legado.Helper.Env").getHomeDir(), ".legado-download-" .. temp:match("[^/]+$") .. ".part")
end

function M.download(info, source, book, temp)
    local first = type(info.downloadUrls) == "string" and info.downloadUrls:match("[^\r\n]+")
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
    local json = require("Legado.spore.local.parser")._json
    local headers = {}
    local raw = source.data and source.data.header
    if raw and raw ~= "" then
        local ok, parsed = pcall(json.decode, raw)
        if not ok or type(parsed) ~= "table" then
            return nil, "暂不支持动态下载请求头"
        end
        for key, value in pairs(parsed) do
            if type(key) ~= "string" then return nil, "无效下载请求头" end
            local lower = key:lower()
            if lower ~= "user-agent" and lower ~= "accept" and lower ~= "accept-language" then
                return nil, "暂不支持此文件下载请求头"
            end
            if type(value) ~= "string" then return nil, "无效下载请求头" end
            headers[key] = value
        end
    end
    headers["Accept-Encoding"] = "identity"
    local http = require("socket.http")
    local socketutil = require("socketutil")
    local FS = require("Legado.Helper.FS")
    local dir = require("Legado.Helper.Env").getHomeDir()
    temp = temp or M.temporaryPath()
    local file, open_err = io.open(temp, "wb")
    if not file then return nil, open_err end
    local bytes, prefix, sink_error = 0, "", nil
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15, 300)
    local sink = socketutil.file_sink(file)
    local ok, result, code, response_headers = pcall(http.request, {
        url = url, headers = headers, redirect = false,
        sink = function(chunk, err)
            if chunk then
                bytes = bytes + #chunk
                if bytes > MAX_BYTES then
                    sink_error = "文件超过 100 MiB 上限"
                    return nil, sink_error
                end
                if #prefix < 512 then prefix = prefix .. chunk:sub(1, 512 - #prefix) end
            end
            return sink(chunk, err)
        end,
    })
    socketutil:reset_timeout()
    pcall(file.close, file)
    local function fail(message)
        os.remove(temp)
        return nil, message
    end
    if sink_error then return fail(sink_error) end
    if not ok or not result or tonumber(code) ~= 200 then
        local detail = tonumber(code) or "未知"
        return fail("文件下载失败（HTTP " .. tostring(detail) .. "）；暂不支持重定向")
    end
    response_headers = response_headers or {}
    local mime = tostring(response_headers["content-type"] or ""):lower()
    if bytes == 0 or mime:find("text/html", 1, true)
            or prefix:lower():match("^%s*<!doctype%s+html")
            or prefix:lower():match("^%s*<html") then
        return fail("下载响应不是有效书籍文件")
    end
    local disposition = response_headers["content-disposition"] or ""
    local remote_name = disposition:match('filename="([^"]+)"')
        or disposition:match("filename=([^;]+)")
        or (urlutil.parse(url).path or ""):match("([^/]+)$") or ""
    local ext = remote_name:match("%.([%w]+)%s*$")
    if not ext then return fail("无法识别下载文件格式") end
    ext = ext:lower()
    local name = FS.getSafeFilename(info.name ~= "" and info.name or book.name or "下载书籍")
    local path = FS.joinPath(dir, name .. "." .. ext)
    if not require("document/documentregistry"):hasProvider(path) then
        return fail("KOReader 不支持此文件格式：" .. ext .. "（不自动解压）")
    end
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
    if not locked then return fail("同名书籍正在保存，请稍后重试") end
    local message
    if require("util").fileExists(path) then
        message = "同名文件已存在，请在本地书库打开或重命名"
    elseif not os.rename(temp, path) then
        message = "保存文件失败"
    end
    lfs.rmdir(lock)
    if message then return fail(message) end
    return path
end

return M
