local Http=require("Legado.Helper.Http")
local url=require("socket.url")
local M={}
local redirects={[301]=true,[302]=true,[303]=true,[307]=true,[308]=true}

local function address(reference,base)
    local absolute=url.absolute(base or "",reference)
    local parsed=url.parse(absolute)
    local scheme=parsed and parsed.scheme and parsed.scheme:lower()
    if not parsed or (scheme~="http" and scheme~="https") or not parsed.host
        or parsed.userinfo or parsed.user or parsed.password then return end
    parsed.scheme=scheme
    parsed.fragment=nil
    return url.build(parsed)
end

function M.new(options)
    options=options or {}
    local clock=options.clock or os.time
    return function(reference,kind,remaining)
        local received,requests=0,0
        local function failed(reason)
            return nil,{kind=reason,bytes_received=received,requests=requests}
        end
        local current=address(reference)
        if not current then return failed("invalid_argument") end
        for hop=0,5 do
            if clock()>=remaining.deadline or received>=remaining.max_bytes
                or requests>=remaining.max_requests then return failed("limit_exceeded") end
            local headers
            if options.headers_for_url then
                local ok,value=pcall(options.headers_for_url,current,kind)
                if not ok then return failed("download_failed") end
                headers=value
            end
            requests=requests+1
            local ok,response,err=Http{
                url=current,method="GET",redirect=false,raw_response=true,
                headers=headers,proxy=options.proxy,probe_url=options.probe_url,
                max_bytes=remaining.max_bytes-received,
                deadline=remaining.deadline,clock=clock,
            }
            if not ok then
                received=received+(err and err.bytes_received or remaining.max_bytes-received)
                return failed(err and err.kind or "download_failed")
            end
            received=received+response.bytes_received
            if redirects[response.code] then
                local location=response.headers.location
                if hop==5 or type(location)~="string" or location=="" then return failed("download_failed") end
                current=address(location,current)
                if not current then return failed("invalid_response") end
            elseif response.code>=200 and response.code<=299 then
                return {data=response.data,headers=response.headers,final_url=current,
                    bytes_received=received,requests=requests}
            else return failed("download_failed") end
        end
    end
end

return M
