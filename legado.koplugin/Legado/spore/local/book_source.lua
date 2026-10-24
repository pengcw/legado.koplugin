
local Reader = require("Legado.spore.local.parser")

local BookSource = {}
BookSource.__index = BookSource

function BookSource.new(raw)
    local self = setmetatable({}, BookSource)

    local json = Reader._json or require("json")
    if type(raw) == "string" then
        local ok, parsed = pcall(json.decode, raw)
        if not ok or type(parsed) ~= "table" then
            error("[BookSource] 无效书源 JSON: " .. tostring(parsed))
        end
        self.data = parsed
    elseif type(raw) == "table" then
        self.data = raw
    else
        error("[BookSource] 参数必须是 JSON 字符串或 table")
    end

    local data = self.data
    if type(data) == "table" and #data > 0 and type(data[1]) == "table" and not data.bookSourceUrl then
        self.data = data[1]
        self._raw_json = nil
    end

    local original = self.data or {}
    self.session = type(original.session) == "table" and original.session or nil
    self.login_data = type(original.loginData) == "table" and original.loginData or nil

    local source_data = {}
    for key, value in pairs(original) do
        if key ~= "session" and key ~= "loginData" then source_data[key] = value end
    end
    local source_type = original.bookSourceType
    if type(source_type) == "string" and source_type:upper() == "AUDIO" then
        source_type = 1
    end
    source_data.bookSourceType = tonumber(source_type) or 0
    Reader.init_lib()
    local d = Reader.normalize_source(json.encode(source_data))
    if not d then d = source_data end
    self.bookSourceUrl = d.bookSourceUrl or ""
    self.bookSourceName = d.bookSourceName or "未命名书源"
    self.bookSourceGroup = d.bookSourceGroup
    self.bookSourceType = d.bookSourceType
    self.searchUrl = d.searchUrl or ""
    self.exploreUrl = d.exploreUrl
    self.ruleSearch = d.ruleSearch or {}
    self.ruleBookInfo = d.ruleBookInfo or {}
    self.ruleToc = d.ruleToc or {}
    self.ruleContent = d.ruleContent or {}
    self.loginUi = d.loginUi or ""
    self._raw_json = json.encode(d)

    return self
end

function BookSource:json()
    return self._raw_json
end

function BookSource:absolute(rel)
    if not rel or rel == "" then return self.bookSourceUrl end
    if rel:match("^%a+://") then return rel end
    return require("socket.url").absolute(self.bookSourceUrl, rel)
end

function BookSource:can_search()
    return self.searchUrl and self.searchUrl ~= ""
end

return BookSource
