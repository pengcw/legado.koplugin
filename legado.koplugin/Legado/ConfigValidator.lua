local H = require("Legado/Helper")
local socket_url = require("socket.url")

local M = {}

--- server_type: 1=legado, 2=reader3, 3=qread
function M.check(url, server_type, user, pwd)
    if not (H.is_num(server_type) and (server_type == 1  or server_type == 2 or server_type == 3)) then
        return nil, '服务器类型必须是1、2或3'
    end
    if server_type == 3 then
        if not (H.is_str(user) and user ~= '') then
            return nil, '轻阅读必须认证凭证'
        end
        if not (H.is_str(pwd) and pwd ~= '') then
            return nil, '轻阅读必须认证凭证'
        end
    elseif server_type == 2 then
        if H.is_str(user) and user ~= "" and (pwd == "" or not H.is_str(pwd)) then
            return nil, "请清空用户名或补全用户凭证"
        end
    end

    if not (H.is_str(url) and url ~= '') then
        return nil, '地址为空，保存失败'
    end

    local parsed = socket_url.parse(url)
    if not parsed then
        return nil, '地址不合规则，请检查'
    end
    if parsed.scheme ~= "http" and parsed.scheme ~= "https" then
        return nil, '不支持的协议，请检查'
    end
    if not parsed.host or parsed.host == "" then
        return nil, "没有主机名"
    end
    if parsed.port then
        local port_num = tonumber(parsed.port)
        if not port_num or port_num < 1 or port_num > 65535 then
            return nil, "端口号不正确"
        end
    end

    local clean_url = socket_url.build(parsed)
    if  server_type == 2 and not string.find(string.lower(parsed.path or ""), "/reader3$") then
        clean_url = socket_url.absolute(clean_url, "/reader3")
    elseif server_type == 3 and not string.find(string.lower(parsed.path or ""), "/api/5$") then
        clean_url = socket_url.absolute(clean_url, "/api/5")
    end

    return { url = clean_url, type = server_type, user = user, pwd = pwd }
end

function M.settings(conf)
    if not H.is_tbl(conf) then return false end
    local current_conf_name = conf.current_conf_name
    if not (H.is_str(current_conf_name) and current_conf_name ~= "")then
        return false
    end
    if not (H.is_str(conf.server_address) and conf.server_address ~= "") then
        return false
    end
    if not H.is_num(conf.server_type) then return false end
    return true
end

return M
