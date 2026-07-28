local logger = require("logger")
local type = type
local string = string

local m = {}

function m.call(args, req)
    local app = args.app
    if not app then return function(res) return res end end
    
    local spore = req.env.spore

    if true == app._need_login then
        local loginSuccess, token = app:ensureLogin()
        if loginSuccess == true and type(token) == 'string' and token ~= '' then
            local accessToken = string.format("accessToken=%s", token)
            if type(req.env.QUERY_STRING) == 'string' and #req.env.QUERY_STRING > 0 then
                req.env.QUERY_STRING = req.env.QUERY_STRING .. '&' .. accessToken
            else
                req.env.QUERY_STRING = accessToken
            end
        else
            logger.warn('Legado3Auth', '登录失败', token or 'nil')
        end
    end

    return function(res)
        if type(res) == 'table' and type(res.body) == 'table' and 
            res.body.isSuccess == false and app:isNeedLogin(res.body) then
            app.tokenManager:clear()
        end
        return res
    end
end

return m
