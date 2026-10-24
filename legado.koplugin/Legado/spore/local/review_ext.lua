local url = require("socket.url")
local JSON = require("json")
local M = {}

function M.select(source_id, target)
    if type(source_id) ~= "string" or type(target) ~= "string" then return end
    local is_shushan = source_id:find("书山聚合", 1, true)
    local is_guangyu = source_id:find("光遇聚合", 1, true)
    local is_dahuilang = source_id:find("大灰狼", 1, true)
    local is_qingtian = source_id:find("晴天", 1, true)
    if not (is_shushan or is_guangyu or is_dahuilang or is_qingtian) then return end
    local parsed = url.parse(target)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https")
        or not parsed.host or parsed.userinfo then return end

    local filename
    if is_shushan then
        filename = "shushan_comments.json"
    elseif is_guangyu then
        filename = "guangyu_comments.json"
    elseif is_qingtian then
        filename = "qingtian_comments.json"
    else
        filename = "dahuilang_comments.json"
    end
    local path = require("Legado.Helper.FS").joinPath(
        require("Legado.Helper.Env").getPluginDirectory(),
        "Legado/spore/local/extensions/" .. filename)
    local file = io.open(path, "rb")
    if not file then return end
    local data = file:read(64 * 1024 + 1)
    file:close()
    if not data or #data == 0 or #data > 64 * 1024 then return end
    local ok, source = pcall(JSON.decode, data)
    if not ok or type(source) ~= "table" or type(source.ruleContent) ~= "table"
        or type(source.ruleContent.content) ~= "string" or source.ruleContent.content == "" then return end

    source.bookSourceUrl = parsed.scheme .. "://" .. parsed.host
        .. (parsed.port and (":" .. parsed.port) or "") .. "/"
    return source, target
end

return M
