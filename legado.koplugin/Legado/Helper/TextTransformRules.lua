
local M = {}

function M.validateSnapshot(rules)
    if type(rules) ~= "table" then return false, "规则快照必须是数组" end
    local count = 0
    for key, rule in pairs(rules) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
            or type(rule) ~= "table" or type(rule.name) ~= "string"
            or type(rule.pattern) ~= "string" then
            return false, "规则快照包含非法项"
        end
        count = count + 1
    end
    for index = 1, count do
        if rules[index] == nil then return false, "规则快照不是连续数组" end
    end
    return true
end

local function nonempty(value)
    return type(value) == "string" and value ~= ""
end

local function like_contains(haystack, needle)
    if not nonempty(haystack) or not nonempty(needle) then return false end
    return haystack:lower():find(needle:lower(), 1, true) ~= nil
end

local function contains(haystack, needle)
    if not nonempty(haystack) or not nonempty(needle) then return false end
    return haystack:find(needle, 1, true) ~= nil
end

local function target_enabled(rule, target)
    if target == "title" then return rule.scopeTitle == true end
    if target == "content" then return rule.scopeContent == true end
    error("Unsupported text transform target: " .. tostring(target))
end

local function match_reader3(rule, book)
    local scope = rule.scope
    if not nonempty(scope) then return false end

    local name_scope, url_scope = scope:match("^([^;]*);([^;]*)")
    if name_scope == nil then name_scope = scope end

    local book_name = type(book.name) == "string" and book.name or ""
    if name_scope ~= "*" and name_scope ~= book_name then return false end
    if url_scope ~= nil then
        return url_scope == (type(book.bookUrl) == "string" and book.bookUrl or "")
    end
    return true
end

local function match_legado(rule, book, target)
    if not target_enabled(rule, target) then return false end

    local name = book.name
    local origin = book.origin
    local scope = rule.scope
    if nonempty(scope)
            and not like_contains(scope, name)
            and not like_contains(scope, origin) then
        return false
    end

    local exclude = rule.excludeScope
    if nonempty(exclude)
            and (like_contains(exclude, name) or like_contains(exclude, origin)) then
        return false
    end
    return true
end

local function match_qread(rule, book, target)
    if not target_enabled(rule, target) then return false end

    local name = book.name
    local origin = book.origin
    local scope = rule.scope
    if nonempty(scope)
            and scope ~= origin
            and not like_contains(scope, name) then
        return false
    end

    local exclude = rule.excludeScope
    if nonempty(exclude) then
        if like_contains(exclude, name) or contains(exclude, origin) then return false end
    end
    return true
end

local matchers = {
    reader3 = function(rule, book) return match_reader3(rule, book) end,
    legado = match_legado,
    qread = match_qread,
}

function M.filter(rules, dialect, book, target)
    if type(rules) ~= "table" then return {} end
    if type(book) ~= "table" then return {} end

    local matcher = matchers[dialect]
    if not matcher then
        error("Unsupported text transform dialect: " .. tostring(dialect))
    end
    if target ~= "title" and target ~= "content" then
        error("Unsupported text transform target: " .. tostring(target))
    end

    local matched = {}
    for _, rule in ipairs(rules) do
        if type(rule) == "table" and rule.isEnabled ~= false
                and matcher(rule, book, target) then
            matched[#matched + 1] = rule
        end
    end
    return matched
end

return M
