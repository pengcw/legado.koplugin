
local M = {}

function M.hasNonemptyValue(value)
    if type(value) == "string" then return value:match("%S") ~= nil end
    if type(value) == "number" then return value ~= 0 end
    if type(value) ~= "table" then return false end
    for _, child in pairs(value) do
        if M.hasNonemptyValue(child) then return true end
    end
    return false
end

local function has_login_ui(value)
    if type(value) ~= "string" then return false end
    local trimmed = value:match("^%s*(.-)%s*$")
    return trimmed ~= "" and not trimmed:match("^%[%s*%]$")
        and not trimmed:match("^{%s*}$") and trimmed ~= "null"
end

local function has_http_login_url(source)
    local value = source.loginUrl
    if type(value) ~= "string" or value == "" then return false end
    local first_line = value:match("([^\r\n]*)") or value
    local candidate = first_line:match("^%s*(.-)%s*$")
    if candidate == "" or candidate:find("%s")
            or candidate:match("^<js>") or candidate:match("^@js:") or candidate:match("^js:") then
        return false
    end
    candidate = candidate:gsub("[;,%.]+$", "")

    local ok, socket_url = pcall(require, "socket.url")
    if not ok then return false end
    local resolved = candidate
    if not candidate:lower():match("^https?://") then
        local base_url = source.bookSourceUrl
        if type(base_url) ~= "string" or not base_url:match("^https?://") then return false end
        local resolved_ok, absolute = pcall(socket_url.absolute, base_url, candidate)
        if not resolved_ok or type(absolute) ~= "string" then return false end
        resolved = absolute
    end
    local parsed_ok, parsed = pcall(socket_url.parse, resolved)
    return parsed_ok and type(parsed) == "table"
        and type(parsed.scheme) == "string" and parsed.scheme:lower():match("^https?$") ~= nil
        and type(parsed.host) == "string" and parsed.host ~= ""
end

function M.hasLogin(source)
    if type(source) ~= "table" then return false end
    return has_login_ui(source.loginUi)
        or has_http_login_url(source)
        or M.hasNonemptyValue(source.session)
        or M.hasNonemptyValue(source.loginData)
end

return M
