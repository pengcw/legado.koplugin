local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local makeRequest = require("Legado.Helper.Http")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
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

function M:_requestWithProxies(options)
    local original_url = options.url
    local candidates = { original_url }
    
    local proxies = {}
    for _, prefix in ipairs(GITHUB_PROXIES) do
        table.insert(proxies, prefix)
    end

    for i = #proxies, 2, -1 do
        local j = math.random(i)
        proxies[i], proxies[j] = proxies[j], proxies[i]
    end

    for _, prefix in ipairs(proxies) do
        table.insert(candidates, prefix .. original_url)
    end
    
    local last_err
    for i, candidate_url in ipairs(candidates) do
        options.url = candidate_url
        
        if options.file_path then
            if util.fileExists(options.file_path) then
                util.removeFile(options.file_path)
            end
            options.file = io.open(options.file_path, "wb")
        end
        
        local ok, res = makeRequest(options)
        
        if options.file then
            pcall(function() options.file:close() end)
        end
        
        if ok then
            return ok, res
        end
        
        last_err = res or "请求失败"
        logger.warn(string.format("下载请求失败 [%d/%d]: %s, error: %s", i, #candidates, candidate_url, tostring(last_err)))
    end
    
    return false, last_err
end

function M:getMetaInfo()
    local info, err_msg= load_script("_meta")
    local plg_path = Env.getPluginDirectory()
    if not info then
        logger.warn(string.format("getMetaInfo load %s/_meta.lua err", plg_path))
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
            local err_msg = H.is_str(update_response) and update_response or "更新失败, 请重试"
            MessageBox:error(err_msg)
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
                        -- multi process Android unzip prompts no permission
                        TaskProg.loading("安装更新中", function()
                            return self:_downloadUpdate(result.info)
                        end, function(state, down_response)
                            if state == true and down_response and down_response.path then
                                install_ota(down_response.path)
                            else
                                local err_msg = (H.is_tbl(down_response) and down_response.error) or tostring(down_response or "未知错误")
                                MessageBox:error("下载失败，请重试: " .. err_msg)
                            end
                        end)
                    end
                end, {
                    ok_text = "升级",
                    cancel_text = "稍后"
                })
            elseif H.is_tbl(result) then
                MessageBox:success(result.error or "已是最新版本")
            end
        end,
    })
end

function M:_getFallbackVersionInfo()
    local ok, res = self:_requestWithProxies({
        url = META_RAW_URL,
        timeout = 10,
        maxtime = 20,
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
                    
                    logger.dbg("[Update] 备用获取版本成功: " .. normalized)
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
        timeout = 10,
        maxtime = 20,
        headers = {
            ["Accept"] = "application/vnd.github.v3+json",
            ["User-Agent"] = "koreader-legado-plugin"
        }
    })
    if ok and H.is_tbl(res) and res.data then
        local json = require("json")
        local success, data = pcall(json.decode, res.data, json.decode.simple)
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

    logger.warn("[Update] API 获取版本失败，尝试使用代理...")
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
        timeout = 30,
        maxtime = 300,
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

-- zip plugin/legado.koplugin/
local function _unZip(archive_path, dest_path, exclude_patterns)
    local archiver_ok, Archiver = pcall(require, "ffi/archiver")
    local has_archiver = archiver_ok and type(Archiver) == "table" and type(Archiver.Reader) == "table"

    local patterns = {}
    if type(exclude_patterns) == "string" then
        patterns = { exclude_patterns }
    elseif type(exclude_patterns) == "table" then
        patterns = exclude_patterns
    end

    if not util.directoryExists(dest_path) then
        local ok, err = util.makePath(dest_path)
        if not ok then return false, "无法创建目标目录: " .. tostring(err) end
    end

    local extract_ok, extract_err = false, nil
    local extracted = 0
    if has_archiver then
        local reader = Archiver.Reader:new()
        if reader:open(archive_path) then
            local iterate_ok, err = pcall(function()
                extract_ok = true
                for entry in reader:iterate() do
                    local skip = false
                    for _, pattern in ipairs(patterns) do
                        if entry.path:find(pattern, 1, true) then skip = true; break end
                    end
                    if not skip then
                        local target_full_path = dest_path .. "/" .. entry.path
                        local parent_dir
                        if entry.mode == "directory" then
                            parent_dir = target_full_path
                        else
                            parent_dir = util.splitFilePathName(target_full_path)
                        end
                        if parent_dir and not util.directoryExists(parent_dir) then
                            util.makePath(parent_dir)
                        end
                        if entry.mode ~= "directory" then
                            if entry.mode ~= "file" then
                                error("unsupported entry type: " .. tostring(entry.mode))
                            end
                            if not reader:extractToPath(entry.path, target_full_path) then
                                error(reader.err or ("failed to extract " .. entry.path))
                            end
                        end
                    end
                    extracted = extracted + 1
                end
            end)
            reader:close()
            if not iterate_ok then
                extract_ok = false
                extract_err = err
            end
        else
            extract_err = reader.err or "archive open failed"
        end
    end

    if extract_ok and extracted == 0 then
        extract_ok, extract_err = false, "压缩包为空，没有提取到任何文件"
    end

    if not has_archiver or (not extract_ok and extract_err) then
        if logger and logger.info then
            local reason = not has_archiver and "Archiver missing" or ("Archiver failed: " .. tostring(extract_err))
            logger.info(string.format("Switching to CLI unzip. Reason: %s", reason))
        end

        local exclude_args = ""
        if #patterns > 0 then
            exclude_args = string.format(" -x '%s'", table.concat(patterns, "' '"))
        end
        local cmd = string.format("unzip -qo '%s' -d '%s'%s", archive_path, dest_path, exclude_args)

        local result = os.execute(cmd)
        if result == 0 or result == true then
            extract_ok, extract_err = true, nil
        else
            extract_ok, extract_err = false, "unzip command failed"
        end
    end
    
    return extract_ok, extract_err
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

-- return true or err_string
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

    logger.info("[installUpdate] 开始解压至临时目录: " .. plg_path_tmp)
    pcall(ffiUtil.purgeDir, plg_path_tmp)
    FS.checkAndCreateFolder(plg_path_tmp)

    local extract_ok, extract_err = _unZip(update_zip_path, plg_path_tmp)
    if not extract_ok then
        local err_msg = "解压失败: " .. tostring(extract_err)
        logger.err("[installUpdate] " .. err_msg)
        cleanup(false)
        return err_msg
    end

    local base_dir = findPlgBaseDir(plg_path_tmp)
    if not base_dir then
        local err_msg = "验证失败: 未找到有效插件包"
        logger.err("[installUpdate] " .. err_msg)
        cleanup(false)
        return err_msg
    end

    logger.info("[installUpdate] 验证通过，正在备份并部署新版本")
    
    pcall(ffiUtil.purgeDir, plg_path_bak)
    local bak_ok, bak_err = os.rename(plg_path, plg_path_bak)
    if not bak_ok then
        local err_msg = "备份当前版本失败: " .. tostring(bak_err)
        logger.err("[installUpdate] " .. err_msg)
        cleanup(false)
        return err_msg
    end

    local rename_ok, rename_err = os.rename(base_dir, plg_path)
    if not rename_ok then
        logger.warn("[installUpdate] 目录重命名失败(" .. tostring(rename_err) .. ")，尝试降级复制")
        rename_ok = FS.copyRecursive(base_dir, plg_path) and true or false
    end

    if rename_ok then
        logger.info("[installUpdate] 插件更新成功")
        cleanup(true)
        return true
    else
        local err_msg = "替换目录失败: " .. tostring(rename_err or "复制失败")
        logger.err("[installUpdate] " .. err_msg .. "，正在回滚旧版本")
        
        pcall(ffiUtil.purgeDir, plg_path)
        local rb_ok = os.rename(plg_path_bak, plg_path)
        if not rb_ok then
            logger.warn("回滚重命名失败，尝试复制恢复")
            FS.copyRecursive(plg_path_bak, plg_path)
        end
        cleanup(false)
        return err_msg
    end
end

return M
