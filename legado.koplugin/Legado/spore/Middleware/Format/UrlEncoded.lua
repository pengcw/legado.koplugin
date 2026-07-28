local escape = require'socket.url'.escape
local tconcat = table.concat
local pairs = pairs
local type = type

local m = {}
m['content-type'] = 'application/x-www-form-urlencoded'

function m.call (_args, req)
    local spore = req.env.spore
    local payload = spore.payload
    
    if payload and type(payload) == 'table' then
        local ct = req.headers['content-type'] or req.headers['Content-Type']
        if not ct and spore.method and spore.method.headers then
            ct = spore.method.headers['content-type'] or spore.method.headers['Content-Type']
        end
        
        local is_form = (ct and ct:lower():match('application/x%-www%-form%-urlencoded')) or (spore.method and spore.method.form_payload)
        
        if is_form then
            local t = {}
            for k, v in pairs(payload) do
                t[#t+1] = escape(tostring(k)) .. '=' .. escape(tostring(v))
            end
            spore.payload = tconcat(t, '&')
            req.headers['content-type'] = m['content-type']
        end
    end
    return function(res) return res end
end

return m
