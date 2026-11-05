
local JSON = require("json")

local M = {}

local function parser()
    return require("Legado.spore.local.parser")
end

function M.status(verify)
    return parser().getLibraryStatus(verify == true)
end

function M.available()
    local ok, p = pcall(parser)
    if not ok then return false, tostring(p) end

    local cached = p._library_validation
    if p._lib_handle and cached and cached.handle == p._lib_handle
            and cached.abi_ok and cached.version_ok then
        return true, cached.version
    end

    local status
    ok, status = pcall(p.getLibraryStatus, false)
    if not ok then return false, tostring(status) end
    if not status.any_file and not status.loaded then return false, "MISSING_SO" end

    ok, status = pcall(p.getLibraryStatus, true)
    if not ok then return false, tostring(status) end
    if status.usable then return true, status.version end
    return false, status.error or "LOAD_FAILED"
end

function M.createProvider(options)
    options = options or {}

    local available, err = M.available()
    if not available then return nil, err end

    local db = options.db
    local shelf_id = options.shelf_id or "default"
    local provider_options = {
        settings = options.settings or {},
    }

    if db and type(db.getEnabledBookSources) == "function" then
        if type(db.getBookSourceByUrl) == "function" then
            provider_options.single_source_loader = function(origin)
                return db:getBookSourceByUrl(shelf_id, origin)
            end
        end
        if type(db.getBookSourceRuntimeState) == "function" then
            provider_options.source_state_loader = function(origin)
                return db:getBookSourceRuntimeState(shelf_id, origin)
            end
        end
        provider_options.all_sources_loader = function()
            return db:getEnabledBookSources(shelf_id)
        end
        if type(db.saveBookSourceSession) == "function" then
            provider_options.save_source_session = function(book_source_url, session)
                return db:saveBookSourceSession(shelf_id, book_source_url, session)
            end
        end
        if type(db.clearBookSourceState) == "function" then
            provider_options.clear_source_state = function(url, kind)
                return db:clearBookSourceState(shelf_id, url, kind)
            end
        end
        if type(db.saveBookSourceLoginData) == "function" then
            provider_options.save_source_login_data = function(book_source_url, login_data)
                return db:saveBookSourceLoginData(shelf_id, book_source_url, login_data)
            end
        end
    end

    return require("Legado.spore.local"):new(provider_options)
end

function M.testSource(item, keyword, allow_fallback)
    return require("Legado.spore.local.source_debugger"):show(item, keyword, allow_fallback)
end

function M.showSourceLogin(item)
    return require("Legado.spore.local.book_source_login_dialog"):show(item)
end

function M.showReplaceRules()
    return require("Legado.spore.local.replace_rules").show()
end

function M.applyReader3TextTransform(values, rules)
    if type(values) ~= "table" then return nil, "values must be a table" end
    if type(rules) ~= "table" or #rules == 0 then return values end

    local available, err = M.available()
    if not available then return nil, err end

    local compact_rules = {}
    for _, rule in ipairs(rules) do
        if type(rule) == "table" and type(rule.pattern) == "string" then
            compact_rules[#compact_rules + 1] = {
                pattern = rule.pattern,
                replacement = type(rule.replacement) == "string" and rule.replacement or "",
                isRegex = rule.isRegex == true,
            }
        end
    end
    if #compact_rules == 0 then return values end

    local ok_encode, payload = pcall(JSON.encode, {
        values = values,
        rules = compact_rules,
    })
    if not ok_encode then return nil, tostring(payload) end

    if not M.reader3_text_transform_js then
        M.reader3_text_transform_js = [[@js:
(function() {
    var payload = JSON.parse(result);
    var values = Array.isArray(payload.values) ? payload.values : [];
    var rules = (Array.isArray(payload.rules) ? payload.rules : []).map(function(rule) {
        var pattern = String(rule.pattern);
        return {
            pattern: rule.isRegex === true ? new RegExp(pattern, "ig") : pattern,
            replacement: rule.replacement == null ? "" : String(rule.replacement)
        };
    });
    return values.map(function(value) {
        var text = String(value);
        rules.forEach(function(rule) {
            text = text.replace(rule.pattern, rule.replacement);
        });
        return text;
    });
})()
]]
    end

    local ok_eval, transformed, eval_err = pcall(function()
        return parser().reader_eval(payload, M.reader3_text_transform_js)
    end)
    if not ok_eval then return nil, tostring(transformed) end
    if type(transformed) ~= "table" then return nil, eval_err or "invalid Reader3 transform result" end
    if #transformed ~= #values then return nil, "Reader3 transform result size mismatch" end
    return transformed
end

function M.remove()
    return parser().removeLibraryFiles()
end

return M
