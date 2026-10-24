local ffi = require("ffi")
local logger = require("logger")

ffi.cdef[[
    typedef int32_t (*reader_host_call)(void *user_data, const char *operation,
        const char *arguments_json, uint8_t *output, size_t output_capacity);
    typedef struct {
        uint32_t abi_version;
        reader_host_call call;
        void *user_data;
        size_t max_response_bytes;
    } ReaderHostServices;
    int32_t reader_set_host_services(const ReaderHostServices *services);
    char* reader_eval(const char* input, const char* rule);
    char* reader_execute(const char* source_json, const char* request_json);
    void reader_free_string(char* s);
]]

local REQUIRED_SYMBOLS = {
    "reader_set_host_services", "reader_eval", "reader_execute", "reader_free_string",
}

local Reader = {
    _lib_handle = nil,
    _json = nil,
    _loaded_path = nil,
    _library_validation = nil,
    MIN_EXTENSION_VERSION = "1.1.2",
    PINNED_EXTENSION_VERSION = "1.1.2",
}

local function is_android_platform()
    local is_android = false
    pcall(function()
        local Device = require("device")
        is_android = Device and Device.isAndroid and Device:isAndroid() or false
    end)
    if not is_android then
        local is_android_env = (ffi.os == "Linux" and os.getenv("IS_ANDROID"))
        is_android = (is_android_env and pcall(require, "android")) == true
    end
    return is_android
end

function Reader.isAndroidPlatform()
    return is_android_platform()
end

local function get_library_file_name()
    return ffi.os == "Windows" and "reader_parser.dll" or "libreader_parser.so"
end

local function get_android_files_dir()
    local ok, android = pcall(require, "android")
    if not ok or type(android) ~= "table" or type(android.dir) ~= "string" then return nil end
    local dir = android.dir:gsub("/+$", "")
    return dir ~= "" and dir:sub(1, 1) == "/" and dir or nil
end

function Reader.getLibraryPaths()
    local plugin_dir
    local env_ok, Env = pcall(require, "Legado.Helper.Env")
    if env_ok and type(Env) == "table" then
        local ok, path = pcall(Env.getPluginDirectory)
        if ok and type(path) == "string" and path ~= "" then plugin_dir = path end
    end

    local file_name = get_library_file_name()
    local install_path = plugin_dir and (plugin_dir .. "/Legado/spore/local/" .. file_name) or nil
    local is_android = is_android_platform()
    local runtime_path = install_path
    if is_android then
        local files_dir = get_android_files_dir()
        runtime_path = files_dir and (files_dir .. "/" .. file_name) or nil
    end
    return {
        file_name = file_name,
        install_path = install_path,
        runtime_path = runtime_path,
        is_android = is_android,
    }
end

local function file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok, util = pcall(require, "util")
    if not ok or type(util.fileExists) ~= "function" then return false end
    local exists_ok, exists = pcall(util.fileExists, path)
    return exists_ok and exists == true
end

local function hash_file(path)
    local ok_sha, sha2 = pcall(require, "ffi/sha2")
    if not ok_sha or type(sha2) ~= "table" or type(sha2.sha256) ~= "function" then
        return nil, "SHA256 校验不可用"
    end
    local file, open_err = io.open(path, "rb")
    if not file then return nil, "无法读取动态库: " .. tostring(open_err) end
    local ok, digest = pcall(function()
        local feeder = sha2.sha256()
        while true do
            local chunk = file:read(64 * 1024)
            if not chunk then break end
            feeder = feeder(chunk)
        end
        return feeder()
    end)
    file:close()
    if not ok then return nil, "动态库指纹计算失败: " .. tostring(digest) end
    return digest
end

local function copy_file_atomic(source_path, target_path, expected_hash)
    local temp_path = target_path .. ".new"
    pcall(os.remove, temp_path)

    local source, source_err = io.open(source_path, "rb")
    if not source then return false, source_err end
    local target, target_err = io.open(temp_path, "wb")
    if not target then
        source:close()
        return false, target_err
    end

    local copied, copy_err = true, nil
    while true do
        local chunk = source:read(64 * 1024)
        if not chunk then break end
        local write_ok, write_err = target:write(chunk)
        if not write_ok then
            copied, copy_err = false, write_err
            break
        end
    end
    source:close()
    local close_ok, close_err = target:close()
    if not close_ok and copied then copied, copy_err = false, close_err end
    if not copied then
        pcall(os.remove, temp_path)
        return false, copy_err
    end

    local temp_hash, hash_err = hash_file(temp_path)
    if not temp_hash or temp_hash ~= expected_hash then
        pcall(os.remove, temp_path)
        return false, hash_err or "动态库副本校验失败"
    end

    local renamed, rename_err = os.rename(temp_path, target_path)
    if renamed then return true end

    local backup_path = target_path .. ".bak"
    pcall(os.remove, backup_path)
    if not file_exists(target_path) then
        pcall(os.remove, temp_path)
        return false, rename_err
    end
    local backed_up, backup_err = os.rename(target_path, backup_path)
    if not backed_up then
        pcall(os.remove, temp_path)
        return false, backup_err or rename_err
    end
    renamed, rename_err = os.rename(temp_path, target_path)
    if not renamed then
        os.rename(backup_path, target_path)
        pcall(os.remove, temp_path)
        return false, rename_err
    end
    pcall(os.remove, backup_path)
    return true
end

local function sync_android_runtime_copy(paths)
    if not paths.is_android or paths.runtime_path == paths.install_path then
        return true
    end
    if not paths.runtime_path then
        return false, "无法从 android.dir 获取 Android 私有 filesDir"
    end
    if not file_exists(paths.install_path) then
        return file_exists(paths.runtime_path), "插件目录中的解析扩展不存在"
    end

    local source_hash, hash_err = hash_file(paths.install_path)
    if not source_hash then return false, hash_err end
    local runtime_hash = file_exists(paths.runtime_path) and hash_file(paths.runtime_path) or nil
    if runtime_hash == source_hash then return true end

    if Reader._lib_handle and Reader._loaded_path == paths.runtime_path then
        local unloaded, unload_err = Reader.unload()
        if not unloaded then return false, unload_err end
    end
    return copy_file_atomic(paths.install_path, paths.runtime_path, source_hash)
end

function Reader.removeRuntimeCopy()
    local paths = Reader.getLibraryPaths()
    if not paths.is_android or not paths.runtime_path or paths.runtime_path == paths.install_path then
        return true
    end
    if Reader._loaded_path == paths.runtime_path then
        local unloaded, unload_err = Reader.unload()
        if not unloaded then return false, unload_err end
    end
    if file_exists(paths.runtime_path) then
        local removed, remove_err = os.remove(paths.runtime_path)
        if not removed and file_exists(paths.runtime_path) then
            return false, remove_err or "无法删除 Android 运行副本"
        end
    end
    return true
end

function Reader.removeLibraryFiles()
    local paths = Reader.getLibraryPaths()
    local remove_paths = {}
    local function append_path(path)
        if type(path) ~= "string" or path == "" then return end
        for _, existing in ipairs(remove_paths) do
            if existing == path then return end
        end
        table.insert(remove_paths, path)
    end
    append_path(paths.install_path)
    append_path(paths.runtime_path)

    local unloaded, unload_err = Reader.unload()
    if not unloaded then return false, unload_err end

    local errors = {}
    for _, path in ipairs(remove_paths) do
        if file_exists(path) then
            local removed, remove_err = os.remove(path)
            if not removed and file_exists(path) then
                errors[#errors + 1] = tostring(remove_err or ("删除失败: " .. path))
            end
        end
    end
    if #errors > 0 then return false, table.concat(errors, "; ") end
    return true
end

Reader.removeAndroidPrivateLibrary = Reader.removeRuntimeCopy

function Reader.compare_versions(v1, v2)
    local function parse(v)
        local parts = {}
        for num in tostring(v or ""):gmatch("%d+") do
            table.insert(parts, tonumber(num) or 0)
        end
        return parts
    end
    local p1, p2 = parse(v1), parse(v2)
    for i = 1, math.max(#p1, #p2) do
        local n1, n2 = p1[i] or 0, p2[i] or 0
        if n1 > n2 then return 1 end
        if n1 < n2 then return -1 end
    end
    return 0
end

function Reader.get_version()
    if not Reader._lib_handle then
        return "0.0.0"
    end
    local ver = Reader.parse_rule_eval("@version", "")
    if type(ver) ~= "string" or not ver:match("^%d+%.%d+%.%d+$") then
        return "0.0.0"
    end
    return ver
end

function Reader.check_version()
    local ver = Reader.get_version()
    return Reader.compare_versions(ver, Reader.MIN_EXTENSION_VERSION) >= 0
        and Reader.compare_versions(ver, Reader.PINNED_EXTENSION_VERSION) <= 0, ver
end

local ok_rjson, rjson = pcall(require, "rapidjson")
Reader._json = (ok_rjson and rjson) or require("json")

function Reader.init_device_id()
    if Reader._device_id then return Reader._device_id end
    local settings = G_reader_settings
    if not settings then return nil end
    local id = settings:readSetting("device_id")
    if type(id) ~= "string" or id == "" then
        id = require("random").uuid()
        settings:saveSetting("device_id", id)
        if settings.flush then settings:flush() end
    end
    Reader._device_id = id
    return id
end

function Reader.init_lib(load_path)
    Reader.init_device_id()
    if Reader._lib_handle then
        return true
    end

    local lib_handle = nil
    local ok = false

    if load_path then
        ok, lib_handle = pcall(ffi.load, load_path)
    else
        local paths = Reader.getLibraryPaths()
        local candidate_paths = {}
        local function append_candidate(path)
            if type(path) ~= "string" or path == "" then return end
            for _, candidate in ipairs(candidate_paths) do
                if candidate == path then return end
            end
            table.insert(candidate_paths, path)
        end

        if paths.is_android then
            local sync_ok, sync_err = sync_android_runtime_copy(paths)
            if sync_ok and file_exists(paths.runtime_path) then
                append_candidate(paths.runtime_path)
            elseif file_exists(paths.install_path) then
                logger.err("[ReaderFFI] Android 运行副本同步失败: " .. tostring(sync_err))
            end
        end
        append_candidate(paths.install_path)

        local legacy_path = paths.is_android and paths.runtime_path
            or (ffi.os == "Windows" and "Legado/spore/local/reader_parser.dll"
                or "Legado/spore/local/libreader_parser.so")
        append_candidate(legacy_path)

        for _, path in ipairs(candidate_paths) do
            ok, lib_handle = pcall(ffi.load, path)
            if ok and lib_handle then
                load_path = path
                break
            end
        end

        if not (ok and lib_handle) then
            logger.dbg("[ReaderFFI] 动态库加载失败！已尝试以下路径:")
            for _, path in ipairs(candidate_paths) do
                logger.dbg("[ReaderFFI]   - " .. tostring(path))
            end
        end
    end

    if ok and lib_handle then
        Reader._lib_handle = lib_handle
        Reader._loaded_path = load_path
        logger.dbg("[ReaderFFI] 动态库加载成功: " .. tostring(load_path))
        return true
    end

    logger.err("[ReaderFFI] 动态库加载失败！")
    return false, lib_handle
end

function Reader.unload()
    if Reader._host_module and Reader._host_module.is_active() then
        return false, "cannot unload Reader while host services are active"
    end
    Reader._lib_handle = nil
    Reader._loaded_path = nil
    Reader._library_validation = nil
    collectgarbage("collect")
    return true
end

function Reader.checkLibraryABI()
    if not Reader._lib_handle then
        return false, false, nil, "解析扩展尚未加载"
    end
    local cached = Reader._library_validation
    if cached and cached.handle == Reader._lib_handle then
        return cached.abi_ok, cached.version_ok, cached.version, cached.error
    end

    local function cache_result(abi_ok, version_ok, version, err)
        Reader._library_validation = {
            handle = Reader._lib_handle,
            abi_ok = abi_ok,
            version_ok = version_ok,
            version = version,
            error = err,
        }
        return abi_ok, version_ok, version, err
    end

    for _, symbol_name in ipairs(REQUIRED_SYMBOLS) do
        local symbol_ok, symbol = pcall(function()
            return Reader._lib_handle[symbol_name]
        end)
        if not symbol_ok or symbol == nil then
            return cache_result(false, false, nil, "缺少解析扩展导出函数: " .. symbol_name)
        end
    end

    local checked, version_ok, version = pcall(Reader.check_version)
    if not checked then
        return cache_result(false, false, nil, tostring(version_ok))
    end
    if not version_ok then
        return cache_result(true, false, version,
            "解析扩展版本不兼容: v" .. tostring(version) .. "（支持 "
                .. Reader.MIN_EXTENSION_VERSION .. " ~ " .. Reader.PINNED_EXTENSION_VERSION .. "）")
    end
    return cache_result(true, true, version)
end

function Reader.getLibraryStatus(verify)
    local paths = Reader.getLibraryPaths()
    local source_exists = file_exists(paths.install_path)
    local runtime_exists = paths.runtime_path == paths.install_path
        and source_exists or file_exists(paths.runtime_path)
    local status = {
        install_path = paths.install_path,
        runtime_path = paths.runtime_path,
        file_name = paths.file_name,
        is_android = paths.is_android,
        source_exists = source_exists,
        runtime_exists = runtime_exists,
        any_file = source_exists or runtime_exists,
        loaded = Reader._lib_handle ~= nil,
        loaded_path = Reader._loaded_path,
        loadable = Reader._lib_handle ~= nil,
    }

    if verify then
        local load_ok, load_err = Reader.init_lib()
        status.loaded = Reader._lib_handle ~= nil
        status.loaded_path = Reader._loaded_path
        status.loadable = load_ok == true
        if load_ok then
            status.abi_ok, status.version_ok, status.version, status.error = Reader.checkLibraryABI()
            status.usable = status.abi_ok and status.version_ok
        else
            status.usable = false
            status.error = tostring(load_err or "解析扩展加载失败")
        end
    end
    return status
end

local function ensure_api()
    if not Reader._lib_handle then
        local ok, err = Reader.init_lib()
        if not ok then
            error("[ReaderFFI Error] Reader 动态库未初始化且自动加载失败: " .. tostring(err))
        end
    end
end

function Reader.set_host_services(handlers, options)
    local HostServices = require("Legado.spore.local.host_services")
    if HostServices.is_active() then return nil, "host services are active" end
    Reader._host_module = HostServices
    if handlers == nil then
        Reader._host_services = nil
        Reader._host_configured = true
        return true
    end
    local ok, services = pcall(HostServices.new, handlers, options)
    if not ok then return nil, tostring(services) end
    Reader._host_services = services
    Reader._host_configured = true
    return true
end

function Reader.with_host_handlers(handlers, run)
    local HostServices = require("Legado.spore.local.host_services")
    assert(not HostServices.is_active(), "host services are active")
    local previous = Reader._task_host_handlers
    Reader._task_host_handlers = handlers
    local ok, result = pcall(run)
    Reader._task_host_handlers = previous
    if not ok then error(result, 0) end
    return result
end

local function call_and_parse(symbol, mode, ...)
    if Reader._host_module and Reader._host_module.is_active() then
        return nil, "host callbacks cannot re-enter Reader"
    end
    ensure_api()
    if not Reader._host_configured then
        local Crypto = require("Legado.spore.local.providers.crypto")
        local RSA = require("Legado.spore.local.providers.rsa")
        local handlers = Crypto.new():handlers()
        handlers["device.android_id"] = function()
            local id = Reader.init_device_id()
            if not id then return nil, {kind = "unsupported", message = "device identity unavailable"} end
            return id
        end
        for operation, handler in pairs(RSA.new():handlers()) do handlers[operation] = handler end
        local Compression = require("Legado.spore.local.providers.compression")
        for operation, handler in pairs(Compression.new():handlers()) do handlers[operation] = handler end
        local chinese
        handlers["text.chinese.convert"] = function(arguments)
            if not chinese then
                chinese = require("Legado.spore.local.providers.chinese").new()
            end
            return chinese:convert(arguments)
        end
        handlers["resource.cache.config"] = function()
            local loaded, Env = pcall(require, "Legado.Helper.Env")
            local ok, root = false, nil
            if loaded then ok, root = pcall(Env.getTempDirectory) end
            if not ok or type(root) ~= "string" or root == "" then
                return nil, {kind = "unavailable", message = "cache root unavailable"}
            end
            return root
        end
        local file_cache
        local function file_cache_call(action,arguments,context)
            if not file_cache then
                file_cache = require("Legado.spore.local.providers.file_cache").new()
            end
            return file_cache:invoke(action,arguments,context)
        end
        handlers["cache.file.get"] = function(arguments,context)
            return file_cache_call("get",arguments,context)
        end
        handlers["cache.file.put"] = function(arguments,context)
            return file_cache_call("put",arguments,context)
        end
        handlers["cache.file.delete"] = function(arguments,context)
            return file_cache_call("delete",arguments,context)
        end
        local info_map
        for _, method in ipairs({"load", "save_now", "commit"}) do
            local action = method
            handlers["info_map." .. action] = function(arguments, context)
                if not info_map then
                    info_map = require("Legado.spore.local.providers.info_map").new()
                end
                return info_map[action](info_map, arguments, context)
            end
        end
        local ok, err = Reader.set_host_services(handlers, {
            max_response_bytes = 2 * 1024 * 1024,
        })
        if not ok then return nil, err end
    end

    local status, ptr
    if Reader._host_services then
        if not (Reader._json and Reader._json.encode and Reader._json.decode) then
            return nil, "JSON codec unavailable for host services"
        end
        local context = { entrypoint = symbol }
        if symbol == "reader_execute" then
            context.source_json, context.request_json = ...
        end
        local services = Reader._host_services
        if Reader._task_host_handlers then
            local handlers = {}
            for operation, handler in pairs(services.handlers) do handlers[operation] = handler end
            for operation, handler in pairs(Reader._task_host_handlers) do handlers[operation] = handler end
            services = Reader._host_module.new(handlers, {
                max_response_bytes = services.max_response_bytes,
            })
        end
        status, ptr = services:with_binding(
            Reader._lib_handle, Reader._json, context, Reader._lib_handle[symbol], ...)
    else
        status, ptr = pcall(Reader._lib_handle[symbol], ...)
    end
    if not status then
        logger.err("[ReaderFFI Error] C 函数执行异常: " .. tostring(ptr))
        return nil, tostring(ptr)
    end
    if ptr == nil or ptr == ffi.NULL then
        return nil, "C 函数返回 NULL 指针"
    end

    local string_ok, raw_str = pcall(ffi.string, ptr)
    Reader._lib_handle.reader_free_string(ptr)
    if not string_ok then return nil, tostring(raw_str) end
    if mode == "text" then return raw_str end

    local decode_fn = Reader._json and Reader._json.decode
    if not decode_fn then
        if mode ~= "auto" then return nil, "JSON decoder unavailable" end
        return raw_str
    end
    local parse_ok, parsed = pcall(decode_fn, raw_str)
    if not parse_ok or parsed == nil then
        if mode ~= "auto" then return nil, "Invalid JSON response" end
        return raw_str
    end
    if mode ~= "auto" and type(parsed) ~= "table" then
        return nil, "Invalid JSON response: expected object or array"
    end
    if mode == "envelope" and type(parsed.ok) ~= "boolean" then
        return nil, "Invalid JSON response: expected execution envelope"
    end
    if mode ~= "envelope" and type(parsed) == "table" and parsed.error then
        return nil, parsed.error
    end
    return parsed
end

local function eval_mode(rule)
    if rule == "@version" or rule == "@uuid" or rule == "@android_id"
            or rule == "@encode" or rule == "@decode" or rule == "@clean" or rule == "@text" then
        return "text"
    end
    return "auto"
end

function Reader.parse_rule_eval(rule, content, _)
    return call_and_parse("reader_eval", eval_mode(rule), content or "", rule or "")
end

function Reader.reader_eval(input, rule)
    return call_and_parse("reader_eval", eval_mode(rule), input or "", rule or "")
end

function Reader.execute(source_json, request)
    if type(request) ~= "table" then
        return nil, "reader_execute request must be a table"
    end
    ensure_api()
    local source = source_json or ""
    if type(source) == "table" then
        if not (Reader._json and Reader._json.encode) then
            return nil, "JSON encoder unavailable for source"
        end
        local ok, encoded = pcall(Reader._json.encode, source)
        if not ok then return nil, tostring(encoded) end
        source = encoded
    end

    local payload = {}
    for key, value in pairs(request) do payload[key] = value end
    if payload.api == nil then payload.api = 2 end
    if not (Reader._json and Reader._json.encode) then
        return nil, "JSON encoder unavailable for request"
    end
    local ok, request_json = pcall(Reader._json.encode, payload)
    if not ok then return nil, tostring(request_json) end

    return call_and_parse("reader_execute", "envelope", tostring(source), request_json)
end

function Reader.url_encode(input)
    return call_and_parse("reader_eval", "text", input or "", "@encode")
end

function Reader.url_decode(input)
    return call_and_parse("reader_eval", "text", input or "", "@decode")
end

function Reader.apply_replace_rules(content, rules_json)
    if not rules_json or rules_json == "" then
        return content or ""
    end
    return call_and_parse("reader_eval", "text", content or "", rules_json)
end

function Reader.merge_search_results(books_json)
    return call_and_parse("reader_eval", "json", books_json or "[]", "@merge")
end

function Reader.validate_source(source_json)
    return call_and_parse("reader_eval", "json", source_json or "{}", "@validate")
end

function Reader.normalize_source(source_json)
    local response, err = call_and_parse("reader_eval", "envelope", source_json or "{}", "@normalize_source")
    if not response then return nil, err end
    if not response.ok then return nil, response.error end
    if type(response.data) ~= "table" then return nil, "Invalid normalized source" end
    return response.data
end

function Reader.normalize_reviews(html)
    local response, err = call_and_parse("reader_eval", "envelope", html or "", "@normalize_reviews")
    if not response then return nil, err end
    if not response.ok or type(response.data) ~= "table" or type(response.data.html) ~= "string" then
        return nil, "评论规范化不可用"
    end
    return response.data.html
end

function Reader.html_to_text(html)
    return call_and_parse("reader_eval", "text", html or "", "@text")
end

function Reader.format_html(html)
    return call_and_parse("reader_eval", "text", html or "", "@clean")
end

function Reader.debug_parse(source_json, html_body, base_url, mode)
    if not (Reader._json and Reader._json.encode) then return nil, "JSON encoder unavailable" end
    local ok, input = pcall(Reader._json.encode, {
        source = source_json or "", body = html_body or "",
        baseUrl = base_url or "", mode = mode or "",
    })
    if not ok then return nil, tostring(input) end
    return call_and_parse("reader_eval", "json", input, "@debug_parse")
end

function Reader.generate_uuid()
    return call_and_parse("reader_eval", "text", "", "@uuid")
end

function Reader.get_android_id()
    return call_and_parse("reader_eval", "text", "", "@android_id")
end

if jit then jit.off(call_and_parse, true) end
return Reader
