local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local Probe = require("Legado.Helper.Probe")
local Error = require("Legado.Helper.Error")
local util = require("util")
local makeRequest = require("Legado.Helper.Http")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local ZipUtil = require("Legado.Helper.ZipUtil")
local load_script = require("Legado.Helper.Loader").load_script
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")

local M = {}

local RELEASE_API = "https://api.github.com/repos/pengcw/legado.koplugin/releases/latest"

local GITHUB_PROXIES = {
    "https://ghproxy.net/",
    "https://ghfast.top/",
    "https://gh-proxy.com/",
}

local UPDATE_ZIP_NAME = "legado_plugin_update.zip"
local META_RAW_URL = "https://raw.githubusercontent.com/pengcw/legado.koplugin/main/legado.koplugin/_meta.lua"
local RELEASE_DOWNLOAD_URL_FORMAT = "https://github.com/pengcw/legado.koplugin/releases/download/%s/%s"

local function decode_json(data)
    local ok_json, json = pcall(require, "json")
    if not ok_json or not json then return false, nil end

    local decoder = json.decode
    local mode
    if type(decoder) == "table" then
        mode = decoder.simple
        decoder = decoder.decode
    end
    if type(decoder) ~= "function" then return false, nil end
    return pcall(decoder, data, mode)
end

function M:_requestWithProxies(options)
    local original_url = options.url
    local candidates, seen = {}, {}
    local function add_candidate(url, proxy)
        if seen[url] then return end
        seen[url] = true
        candidates[#candidates + 1] = { url = url, proxy = proxy }
    end

    local proxies = {}
    for _, prefix in ipairs(GITHUB_PROXIES) do
        proxies[#proxies + 1] = prefix
    end
    for i = #proxies, 2, -1 do
        local j = math.random(i)
        proxies[i], proxies[j] = proxies[j], proxies[i]
    end

    for _, prefix in ipairs(proxies) do
        if prefix == options.preferred_proxy then
            add_candidate(prefix .. original_url, prefix)
            break
        end
    end
    add_candidate(original_url)
    for _, prefix in ipairs(proxies) do
        add_candidate(prefix .. original_url, prefix)
    end

    local last_err
    for i, candidate in ipairs(candidates) do
        local candidate_url = candidate.url
        options.url = candidate_url

        if options.file_path then
            if util.fileExists(options.file_path) then
                util.removeFile(options.file_path)
            end
            options.file = io.open(options.file_path, "wb")
        end

        local called, ok, res = Error.pcall(makeRequest, options)
        if not called then
            res = ok
            ok = false
        end

        if options.file then
            pcall(function() options.file:close() end)
        end

        if ok and options.validate_response then
            local called, valid, reason = Error.pcall(options.validate_response, res)
            if not called or valid ~= true then
                ok, res = false, called and reason or valid
            end
        end

        if ok then
            return true, res, candidate.proxy
        end

        last_err = Error.extract_message(res or "请求失败")
        Probe.retry("Update", "下载", candidate_url, nil,
            string.format("请求失败 [%d/%d]: %s", i, #candidates, tostring(last_err)))
    end

    return false, last_err
end

function M:getMetaInfo()
    local info, _err_msg = load_script("_meta")
    local plg_path = Env.getPluginDirectory()
    if not info then
        Probe.fail("Update", "读取插件信息", plg_path, nil, _err_msg or "加载 _meta.lua 失败")
        return
    end
    return info, plg_path
end

function M:getCurrentVersion()
    local info = self:getMetaInfo()
    if H.is_tbl(info) then
        return info.version
    end
end

function M:checkUpdate()
    local current_version = self:getCurrentVersion()
    local latest_release_info = self:_getLatestReleaseInfo()
    if not (current_version and H.is_tbl(latest_release_info) and latest_release_info.latest_version) then
        return {
            error = "获取版本信息失败, 请重试"
        }
    end
    local latest_release_version = latest_release_info.latest_version
    return {
        state = (current_version ~= latest_release_version),
        info = latest_release_info,
        release_version = latest_release_version,
        current_version = current_version
    }
end

function M:ota(ok_callback)
    local install_ota = function(zip_path)
        local update_response = self:_installUpdate(zip_path)
        if update_response == true then
            local current_version = self:getCurrentVersion()
            MessageBox:askForRestart(string.format("%s 已更新。请重启 KOReader 以使更改生效。", current_version))
            if H.is_func(ok_callback) then ok_callback() end
        else
            local err_msg = Error.extract_message(update_response or "未知错误")
            Probe.fail("Update", "安装插件", zip_path, nil, err_msg)
            MessageBox:error(Error.format_failure("插件更新失败，请重试", err_msg))
        end
    end

    TaskProg.loading({
        text = "检查更新 ",
        dismissable = true,
        runnable = function()
            return self:checkUpdate()
        end,
        on_cancel = function()
            MessageBox:notice("已取消")
        end,
        callback = function(ok, result)
            if ok == true and result and result.state == true then
                MessageBox:confirm(string.format("有新版本可用: %s ,要下载并更新吗？",
                    result.release_version), function(is_update)
                    if is_update then
                        TaskProg.loading("安装更新中", function()
                            return self:_downloadUpdate(result.info)
                        end, function(state, down_response)
                            if state == true and down_response and down_response.path then
                                install_ota(down_response.path)
                            else
                                local err_msg = Error.extract_message(
                                    (H.is_tbl(down_response) and down_response.error) or down_response or "未知错误")
                                Probe.fail("Update", "下载插件", result.info.download_url, nil, err_msg)
                                MessageBox:error(Error.format_failure("下载失败，请检查网络后重试", err_msg))
                            end
                        end)
                    end
                end, {
                    ok_text = "升级",
                    cancel_text = "稍后"
                })
            elseif ok == true and H.is_tbl(result) and not result.error then
                MessageBox:success("已是最新版本")
            elseif result ~= "cancelled" then
                local err_msg = Error.extract_message(
                    (H.is_tbl(result) and result.error) or result or "未知错误")
                Probe.fail("Update", "检查插件更新", RELEASE_API, nil, err_msg)
                MessageBox:error(Error.format_failure("检查更新失败，请重试", err_msg))
            end
        end,
    })
end

function M:_getFallbackVersionInfo()
    local ok, res = self:_requestWithProxies({
        url = META_RAW_URL,
        timeout = 20,
        method = "GET"
    })

    if ok and H.is_tbl(res) and H.is_str(res.data) then
        local table_content = res.data:match("return%s*(%b{})")
        if table_content then
            local func = (loadstring or load)("return " .. table_content)
            if func then
                if setfenv then setfenv(func, {}) end
                local success, meta_info = pcall(func)

                if success and H.is_tbl(meta_info) and H.is_str(meta_info.version) then
                    local normalized = string.match(meta_info.version, "v?([%d%.]+)")
                    local download_url = string.format(RELEASE_DOWNLOAD_URL_FORMAT, normalized, UPDATE_ZIP_NAME)

                    Probe.event("Update", "备用版本查询", normalized)
                    return {
                        asset_name = UPDATE_ZIP_NAME,
                        download_url = download_url,
                        latest_version = normalized
                    }
                end
            end
        end
    end
    return nil
end

function M:_getLatestReleaseInfo()
    local ok, res = makeRequest({
        url = RELEASE_API,
        timeout = 20,
        headers = {
            ["Accept"] = "application/vnd.github.v3+json",
            ["User-Agent"] = "koreader-legado-plugin"
        }
    })
    if ok and H.is_tbl(res) and res.data then
        local success, data = decode_json(res.data)
        if success and type(data) == "table" and data.tag_name and data.assets and data.assets[1] then
            local latest_version_tag = data.tag_name
            local assets = data.assets
            local normalized_latest_version = string.match(latest_version_tag, "v?([%d%.]+)")
            local download_url = assets[1].browser_download_url
            local asset_name = assets[1].name or UPDATE_ZIP_NAME
            return {
                asset_name = asset_name,
                download_url = download_url,
                latest_version = normalized_latest_version
            }
        end
    end

    Probe.retry("Update", "版本查询", RELEASE_API, nil, "API 获取版本失败，尝试使用代理")
    return self:_getFallbackVersionInfo()
end

function M:_downloadUpdate(release_info)

    if not (H.is_tbl(release_info) and release_info.asset_name and release_info.download_url) then
        return {
            error = "downloadUpdate: Parameter error"
        }
    end

    local url = release_info.download_url
    local asset_name = release_info.asset_name
    local temp_path_base = Env.getTempDirectory()
    local temp_zip_path = string.format("%s/%s", temp_path_base, asset_name)

    local http_options = {
        url = url,
        method = "GET",
        file_path = temp_zip_path,
        timeout = { 30, 300 },
        redirect = true,
    }

    local ok, err = self:_requestWithProxies(http_options)
    if not ok then
        util.removeFile(temp_zip_path)
        return {
            error = "Download network request failed: " .. tostring(err)
        }
    end

    return {
        state = true,
        path = temp_zip_path
    }
end

local function _unZip(archive_path, dest_path, exclude_patterns)
    local reader = ZipUtil.Reader:new()
    if reader and reader:open(archive_path) then
        local extract_ok, extract_err = reader:extractAll(dest_path, exclude_patterns)
        reader:close()
        return extract_ok, extract_err
    end
    local reason = reader and "archive open failed" or "no zip reader available"
    return false, "无法解压更新包: " .. tostring(reason)
end

local function validatePlgTree(root_dir)
    if lfs.attributes(root_dir, "mode") ~= "directory" then
        return false
    end
    local required = {
        "_meta.lua",
        "main.lua",
    }
    for _, rel in ipairs(required) do
        local file_path = root_dir .. "/" .. rel
        if not util.fileExists(file_path) then
            return false
        end
    end
    return true
end

local function findPlgBaseDir(dir_path)
    if validatePlgTree(dir_path) then
        return dir_path
    end
    local ok, iter, dir_obj = pcall(lfs.dir, dir_path)
    if not ok then return end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local sub_path = dir_path .. "/" .. entry
            if lfs.attributes(sub_path, "mode") == "directory" then
                local found = findPlgBaseDir(sub_path)
                if found then return found end
            end
        end
    end
    return nil
end

function M:_installUpdate(update_zip_path)
    if not (H.is_str(update_zip_path) and util.fileExists(update_zip_path)) then
        return "下载更新文件错误，请重试"
    end

    local plg_path = Env.getPluginDirectory()
    local plg_path_tmp = plg_path .. ".tmp"
    local plg_path_bak = plg_path .. ".bak"

    local function cleanup(is_success)
        pcall(ffiUtil.purgeDir, plg_path_tmp)
        if util.fileExists(update_zip_path) then
            util.removeFile(update_zip_path)
        end
        if is_success then
            pcall(ffiUtil.purgeDir, plg_path_bak)
        end
    end

    Probe.event("Update", "解压插件", plg_path_tmp)
    pcall(ffiUtil.purgeDir, plg_path_tmp)
    FS.checkAndCreateFolder(plg_path_tmp)

    local extract_ok, extract_err = _unZip(update_zip_path, plg_path_tmp)
    if not extract_ok then
        local err_msg = "解压失败: " .. tostring(extract_err)
        Probe.fail("Update", "安装插件", plg_path, nil, err_msg)
        cleanup(false)
        return err_msg
    end

    local base_dir = findPlgBaseDir(plg_path_tmp)
    if not base_dir then
        local err_msg = "验证失败: 未找到有效插件包"
        Probe.fail("Update", "安装插件", plg_path, nil, err_msg)
        cleanup(false)
        return err_msg
    end

    Probe.event("Update", "安装插件", "验证通过，正在备份并部署新版本")

    pcall(ffiUtil.purgeDir, plg_path_bak)
    local bak_ok, bak_err = os.rename(plg_path, plg_path_bak)
    if not bak_ok then
        local err_msg = "备份当前版本失败: " .. tostring(bak_err)
        Probe.fail("Update", "安装插件", plg_path, nil, err_msg)
        cleanup(false)
        return err_msg
    end

    local rename_ok, rename_err = os.rename(base_dir, plg_path)
    if not rename_ok then
        Probe.retry("Update", "安装插件", plg_path, nil,
            "目录重命名失败(" .. tostring(rename_err) .. ")，尝试降级复制")
        rename_ok = FS.copyRecursive(base_dir, plg_path) and true or false
    end

    if rename_ok then
        local engine_names = { "libreader_parser.so", "reader_parser.dll" }
        for _, name in ipairs(engine_names) do
            local old_file = plg_path_bak .. "/Legado/spore/local/" .. name
            local new_dir = plg_path .. "/Legado/spore/local"
            local new_file = new_dir .. "/" .. name
            if util.fileExists(old_file) then
                FS.checkAndCreateFolder(new_dir)
                if not os.rename(old_file, new_file) then
                    pcall(FS.copyRecursive, old_file, new_file)
                end
            end
        end

        Probe.event("Update", "安装插件", "插件更新成功")
        cleanup(true)
        return true
    else
        local err_msg = "替换目录失败: " .. tostring(rename_err or "复制失败")
        Probe.fail("Update", "安装插件", plg_path, nil, err_msg .. "，正在回滚旧版本")

        pcall(ffiUtil.purgeDir, plg_path)
        local rb_ok = os.rename(plg_path_bak, plg_path)
        if not rb_ok then
            Probe.retry("Update", "回滚插件", plg_path, nil, "重命名失败，尝试复制恢复")
            FS.copyRecursive(plg_path_bak, plg_path)
        end
        cleanup(false)
        return err_msg
    end
end

local function get_engine_release_url()
    local parser = require("Legado.spore.local.parser")
    return "https://github.com/pengcw/reader-rust/releases/download/"
        .. parser.PINNED_EXTENSION_VERSION .. "/"
end

local function get_engine_status(parser)
    local ok, status = pcall(parser.getLibraryStatus, true)
    if ok then return status end
    local err = Error.extract_message(status)
    Probe.fail("Update", "检查解析扩展", "", nil, err)
    return { usable = false, loadable = false, error = err }
end

local function get_engine_file_name(parser)
    if type(parser.getLibraryPaths) == "function" then
        return parser.getLibraryPaths().file_name
    end
    return ffi.os == "Windows" and "reader_parser.dll" or "libreader_parser.so"
end

local function cleanup_path(path)
    if util.fileExists(path) then
        util.removeFile(path)
    elseif util.directoryExists(path) then
        pcall(ffiUtil.purgeDir, path)
    end
end

local function normalize_checksum(value)
    if type(value) == "table" then
        value = value.sha256 or value.hash or value.checksum
    end
    if type(value) ~= "string" then return nil end
    value = value:lower():gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("^sha256:", "")
    return value ~= "" and value or nil
end

local function get_manifest_checksum(manifest, key)
    if type(manifest) ~= "table" then return nil end
    local checksums = manifest.checksums
    return type(checksums) == "table" and normalize_checksum(checksums[key]) or nil
end

local function hash_file(path)
    local ok_sha, sha2 = pcall(require, "ffi/sha2")
    if not ok_sha or type(sha2) ~= "table" or type(sha2.sha256) ~= "function" then
        return nil, "当前环境不支持 SHA256 校验"
    end

    local file, open_err = io.open(path, "rb")
    if not file then return nil, "无法读取文件: " .. tostring(open_err) end

    local ok_hash, digest_or_error = pcall(function()
        local feeder = sha2.sha256()
        while true do
            local chunk = file:read(64 * 1024)
            if not chunk then break end
            feeder = feeder(chunk)
        end
        return feeder()
    end)
    file:close()

    if not ok_hash then return nil, "SHA256 校验失败: " .. tostring(digest_or_error) end
    return normalize_checksum(digest_or_error)
end

local function copy_file(from, to)
    local source, source_err = io.open(from, "rb")
    if not source then return false, source_err end
    local target, target_err = io.open(to, "wb")
    if not target then
        source:close()
        return false, target_err
    end

    local ok, err = true, nil
    while true do
        local chunk = source:read(64 * 1024)
        if not chunk then break end
        local write_ok, write_err = target:write(chunk)
        if not write_ok then
            ok, err = false, write_err
            break
        end
    end
    source:close()
    local close_ok, close_err = target:close()
    if not close_ok and ok then ok, err = false, close_err end
    if not ok then cleanup_path(to) end
    return ok, err
end

local function find_file(root_dir, file_name)
    local ok, iterator, directory = pcall(lfs.dir, root_dir)
    if not ok then return nil end
    for entry in iterator, directory do
        if entry ~= "." and entry ~= ".." then
            local path = root_dir .. "/" .. entry
            local mode = lfs.attributes(path, "mode")
            if mode == "file" and entry == file_name then
                return path
            elseif mode == "directory" then
                local found = find_file(path, file_name)
                if found then return found end
            end
        end
    end
    return nil
end

local function install_engine_binary(parser, staged_path, target_path)
    local target_dir = target_path:match("^(.*)/[^/]+$")
    if not target_dir then return false, "解析扩展目标目录无效" end
    FS.checkAndCreateFolder(target_dir)

    local pending_path = target_path .. ".new"
    local backup_path = target_path .. ".bak"
    cleanup_path(pending_path)
    cleanup_path(backup_path)

    local had_old = util.fileExists(target_path)
    if had_old then
        local backup_ok, backup_err = copy_file(target_path, backup_path)
        if not backup_ok then
            return false, "备份现有解析扩展失败: " .. tostring(backup_err)
        end
    end

    local staged_ok, staged_err = copy_file(staged_path, pending_path)
    if not staged_ok then
        cleanup_path(backup_path)
        return false, "写入解析扩展失败: " .. tostring(staged_err)
    end

    if parser and type(parser.unload) == "function" then
        local unloaded, unload_err = parser.unload()
        if unloaded ~= true then
            cleanup_path(pending_path)
            cleanup_path(backup_path)
            return false, "无法卸载当前解析扩展: " .. tostring(unload_err)
        end
        collectgarbage("collect")
    end
    if had_old and not util.removeFile(target_path) and util.fileExists(target_path) then
        cleanup_path(pending_path)
        cleanup_path(backup_path)
        return false, "无法替换现有解析扩展"
    end

    local rename_ok, rename_err = os.rename(pending_path, target_path)
    if not rename_ok then
        local copy_ok, copy_err = copy_file(pending_path, target_path)
        cleanup_path(pending_path)
        rename_ok, rename_err = copy_ok, copy_err
    end

    if not rename_ok or not util.fileExists(target_path) then
        cleanup_path(target_path)
        if had_old then
            local restore_ok = os.rename(backup_path, target_path)
            if not restore_ok then
                restore_ok = copy_file(backup_path, target_path)
            end
            if not restore_ok then
                Probe.fail("Update", "安装解析扩展", target_path, nil, "替换失败，且旧文件恢复失败")
            end
        end
        cleanup_path(backup_path)
        return false, "替换解析扩展失败: " .. tostring(rename_err or "目标文件不存在")
    end

    cleanup_path(backup_path)
    return true
end

local function decode_manifest(data)
    if type(data) ~= "string" then return nil end
    local ok_decode, manifest = decode_json(data)
    return ok_decode and type(manifest) == "table" and manifest or nil
end

function M:getPlatformArchTag()
    local arch = type(jit) == "table" and jit.arch or nil
    if ffi.os == "Windows" then
        return arch == "x64" and "x86_64-pc-windows-msvc" or nil
    end
    if ffi.os ~= "Linux" then return nil end

    local parser_ok, parser = pcall(require, "Legado.spore.local.parser")
    if not parser_ok or type(parser.isAndroidPlatform) ~= "function" then return nil end
    local android_ok, is_android = pcall(parser.isAndroidPlatform)
    if not android_ok then return nil end

    if is_android then
        if arch == "arm64" then return "aarch64-linux-android" end
        if arch == "arm" then return "armv7-linux-androideabi" end
    else
        if arch == "x64" then return "x86_64-unknown-linux-gnu" end
        if arch == "arm64" then return "aarch64-unknown-linux-gnu" end
        if arch == "arm" then
            local hard_fp = ffi.abi("hardfp")
            return hard_fp and "armv7-unknown-linux-gnueabihf" or "armv7-unknown-linux-gnueabi"
        end
    end
    return nil
end

function M:getEngineManifestUrl()
    return get_engine_release_url() .. "manifest.json"
end

function M:getEngineDownloadUrl(tag)
    if type(tag) ~= "string" or tag == "" then return nil end
    return get_engine_release_url() .. "legado_parser-" .. tag .. ".zip"
end

function M:downloadEngineSync(force)
    local parser_ok, parser = pcall(require, "Legado.spore.local.parser")
    if not parser_ok then return false, "解析器不可用: " .. Error.extract_message(parser) end

    if not force then
        local status = get_engine_status(parser)
        if status.usable then return true, status.loaded_path end
    end

    local tag = self:getPlatformArchTag()
    if not tag then return false, "暂无对应平台扩展包，请反馈或尝试手动下载安装。" end

    local paths = parser.getLibraryPaths()
    local ext_name = get_engine_file_name(parser)
    local target_path = paths.install_path
    if not target_path then return false, "解析扩展安装路径不可用" end
    local is_update = util.fileExists(target_path)
        or (paths.runtime_path and paths.runtime_path ~= target_path
            and util.fileExists(paths.runtime_path))
        or parser._lib_handle ~= nil
    local target_dir = target_path:match("^(.*)/[^/]+$")
    if not target_dir then return false, "解析扩展目标目录无效" end
    local zip_name = "legado_parser-" .. tag .. ".zip"

    local temp_root = Env.getTempDirectory()
    local temp_zip = temp_root .. "/" .. zip_name
    local unpack_dir = temp_root .. "/legado_parser_" .. tag
    cleanup_path(temp_zip)
    cleanup_path(unpack_dir)

    local download_err, preferred_proxy
    for _ = 1, 2 do
        cleanup_path(temp_zip)
        local expected_zip_hash
        local manifest_ok, manifest_response, manifest_proxy = self:_requestWithProxies({
            url = self:getEngineManifestUrl(),
            method = "GET",
            timeout = 10,
            maxtime = 20,
            redirect = true,
            preferred_proxy = preferred_proxy,
            validate_response = function(response)
                local manifest = decode_manifest(type(response) == "table" and response.data)
                if not manifest then return false, "解析扩展 manifest 无效" end
                if manifest.version ~= parser.PINNED_EXTENSION_VERSION then
                    return false, "解析扩展 manifest 版本不匹配"
                end
                local checksum = get_manifest_checksum(manifest, zip_name)
                if not checksum then return false, "暂无对应平台扩展包 (" .. tag .. ")" end
                if #checksum ~= 64 or checksum:find("[^0-9a-f]") then
                    return false, "解析扩展 manifest 校验值无效"
                end
                expected_zip_hash = checksum
                return true
            end,
        })
        if not manifest_ok then
            download_err = "获取解析扩展 manifest 失败: "
                .. Error.extract_message(manifest_response or "网络错误")
        else
            preferred_proxy = manifest_proxy
            local request_ok, request_err = self:_requestWithProxies({
                url = self:getEngineDownloadUrl(tag),
                method = "GET",
                file_path = temp_zip,
                timeout = { 30, 300 },
                redirect = true,
                preferred_proxy = preferred_proxy,
                validate_response = function()
                    if not util.fileExists(temp_zip)
                        or (lfs.attributes(temp_zip, "size") or 0) <= 0 then
                        return false, "下载文件为空"
                    end
                    local actual_hash, hash_err = hash_file(temp_zip)
                    if not actual_hash then return false, hash_err end
                    if actual_hash ~= expected_zip_hash then
                        return false, "解析扩展 ZIP SHA256 校验失败"
                    end
                    return true
                end,
            })
            if request_ok then
                download_err = nil
                break
            end
            download_err = "下载解析扩展失败: " .. Error.extract_message(request_err)
        end
    end
    if download_err then
        cleanup_path(temp_zip)
        return false, download_err
    end

    FS.checkAndCreateFolder(unpack_dir)
    local extract_ok, extract_err = _unZip(temp_zip, unpack_dir)
    cleanup_path(temp_zip)
    if not extract_ok then
        cleanup_path(unpack_dir)
        return false, "解压失败: " .. tostring(extract_err)
    end

    local staged_path = find_file(unpack_dir, ext_name)
    if not staged_path or (lfs.attributes(staged_path, "size") or 0) <= 0 then
        cleanup_path(unpack_dir)
        return false, "解压成功但未找到 " .. ext_name
    end

    local install_ok, install_err = install_engine_binary(parser, staged_path, target_path)
    cleanup_path(unpack_dir)
    if not install_ok then return false, install_err end

    return true, target_path, is_update
end

function M:ensureEngineLibrary(on_success, on_fail, force, options)
    options = options or {}
    local parser_ok, parser = pcall(require, "Legado.spore.local.parser")
    if not parser_ok then
        if on_fail then on_fail("本地解析器不可用: " .. Error.extract_message(parser)) end
        return
    end

    if not force then
        local status = get_engine_status(parser)
        if status.usable then
            if on_success then on_success() end
            return
        end
        if status.loadable then
            if status.abi_ok and not status.version_ok then
                Probe.retry("Update", "检查解析扩展", "", nil, "解析扩展版本(" .. tostring(status.version)
                    .. ")不在兼容范围(" .. parser.MIN_EXTENSION_VERSION .. " ~ "
                    .. parser.PINNED_EXTENSION_VERSION .. ")，将安装固定版本")
            else
                Probe.retry("Update", "检查解析扩展", "", nil, "解析扩展 ABI 检查失败，将自动修复: "
                    .. tostring(status.error or "动态库无法加载"))
            end
            force = true
        end
    end

    local function start_download()
        TaskProg.loading({
            text = force and "正在更新解析扩展..." or "正在安装解析扩展...",
            dismissable = true,
            runnable = function()
                local called, ok, result, need_restart = Error.pcall(self.downloadEngineSync, self, force)
                if not called then return { false, ok } end
                return { ok, result, need_restart }
            end,
            on_cancel = function(pid)
                if pid then
                    pcall(ffiUtil.terminateSubProcess, pid)
                end
                MessageBox:notice("已取消下载")
            end,
            callback = function(state, result)
                if not state and result == "cancelled" then return end
                if state and type(result) == "table" and result[1] == true then
                    local target_path = result[2]
                    local need_restart = result[3]
                    if need_restart then
                        MessageBox:askForRestart("解析扩展已更新，请重启 KOReader 以生效。")
                    else
                        local status = get_engine_status(parser)
                        if not status.usable then
                            local message = status.error or "ABI/版本不兼容"
                            if on_fail then on_fail("扩展安装后校验失败: " .. tostring(message)) end
                            return
                        end
                        if on_success then on_success(target_path) end
                    end
                else
                    local err = state and type(result) == "table" and result[2] or result
                    local message = Error.extract_message(err or "未知错误")
                    Probe.fail("Update", "安装解析扩展", "", nil, message)
                    if on_fail then on_fail(message) end
                end
            end,
        })
    end

    if force then
        start_download()
    else
        MessageBox:confirm(
            options.confirm_text or "本地接管开启后将由本地解析书源；解析扩展未安装，是否安装？",
            function(confirmed)
                if confirmed then
                    start_download()
                elseif on_fail then
                    on_fail("已取消安装")
                end
            end,
            { ok_text = "安装", cancel_text = "取消" }
        )
    end
end

return M
