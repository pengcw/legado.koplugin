local m = {}
-- fix koreader ver 2024.05 issues/13629
function m.call(_, req)
    return function(res)
        if type(res) ~= "table" then res = {} end
        res.headers = res.headers or {}
        res.headers["content-type"] = 'application/json'
        return res
    end
end

return m
