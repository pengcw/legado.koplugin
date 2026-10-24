local Cache = require('Legado.spore.local.providers.file_cache')

local InfoMap = {}
InfoMap.__index = InfoMap
local PREFIX = 'legado-info-map-v1:'
local KEY = 'snapshot'
local MAX_ENTRIES, MAX_BYTES, MAX_KEY_BYTES = 64, 256 * 1024, 1024

local function fail(kind, message) return nil, { kind = kind, message = message } end

local function object(json, values)
    local result = json.object({})
    for key, value in pairs(values or {}) do result[key] = value end
    return result
end

local function normalize(json, state)
    if type(state) ~= 'table' or type(state.values) ~= 'table'
            or type(state.needSave) ~= 'boolean' or type(state.saveTime) ~= 'number'
            or state.saveTime % 1 ~= 0 or state.saveTime < 0 or state.saveTime > 2147483647 then
        return nil, { kind = 'invalid_argument', message = 'invalid infoMap state' }
    end
    local values, count, bytes = object(json), 0, 0
    for key, value in pairs(state.values) do
        if type(key) ~= 'string' or type(value) ~= 'string' or #key > MAX_KEY_BYTES then
            return nil, { kind = 'invalid_argument', message = 'infoMap keys and values must be bounded strings' }
        end
        count = count + 1
        bytes = bytes + #key + #value
        if count > MAX_ENTRIES or bytes > MAX_BYTES then
            return nil, { kind = 'limit_exceeded', message = 'infoMap state too large' }
        end
        values[key] = value
    end
    return { values = values, needSave = state.needSave, saveTime = state.saveTime }
end

function InfoMap.new(options)
    options = options or {}
    return setmetatable({ cache = options.cache or Cache.new(options),
        json = options.json or require('rapidjson'), states = {}, save_errors = {} }, InfoMap)
end

function InfoMap:identity(context)
    if type(context) ~= 'table' or type(context.source_json) ~= 'string' then
        return nil, { kind = 'permission_denied', message = 'infoMap requires a trusted source context' }
    end
    local ok, source = pcall(self.json.decode, context.source_json)
    local key = ok and type(source) == 'table' and source.bookSourceUrl or nil
    if type(key) ~= 'string' or key == '' or #key + #PREFIX > 8192 then
        return nil, { kind = 'permission_denied', message = 'invalid infoMap source identity' }
    end
    return key
end

function InfoMap:read(key)
    local raw, err = self.cache:get({ namespace = PREFIX .. key, key = KEY })
    if raw == nil then
        if err then return nil, err end
        return { values = object(self.json), needSave = false, saveTime = 0 }
    end
    local ok, stored = pcall(self.json.decode, raw)
    if not ok or type(stored) ~= 'table' then
        return fail('operation_failed', 'invalid persisted infoMap snapshot')
    end
    local state, state_err = normalize(self.json, stored)
    if not state then return nil, state_err end
    state.needSave = false
    return state
end

function InfoMap:load(_, context)
    local key, identity_err = self:identity(context)
    if not key then return nil, identity_err end
    self.save_errors[key] = nil
    local current = self.states[key]
    if current then return current end
    local state, err = self:read(key)
    if not state then return nil, err end
    self.states[key] = state
    return state
end

function InfoMap:write(key, state)
    local snapshot = { values = object(self.json, state.values), needSave = false, saveTime = state.saveTime }
    local ok, encoded = pcall(self.json.encode, snapshot)
    if not ok or type(encoded) ~= 'string' then
        return fail('operation_failed', 'infoMap JSON encoding failed')
    end
    return self.cache:put({ namespace = PREFIX .. key, key = KEY,
        value = encoded, saveTime = state.saveTime })
end

function InfoMap:save_now(args, context)
    local key, identity_err = self:identity(context)
    if not key then return nil, identity_err end
    if type(args) ~= 'table' then return fail('invalid_argument', 'invalid infoMap save request') end
    local state, state_err = normalize(self.json, {
        values = args.values, needSave = true, saveTime = args.saveTime,
    })
    if not state then return nil, state_err end
    local ok, err = self:write(key, state)
    if not ok then
        self.states[key] = state
        self.save_errors[key] = err and err.message or 'infoMap persistence failed'
        return nil, err
    end
    self.save_errors[key] = nil
    state.needSave = false
    self.states[key] = state
    return true
end

function InfoMap:commit(args, context)
    local key, identity_err = self:identity(context)
    if not key then return nil, identity_err end
    if type(args) ~= 'table' or (args.flush ~= nil and type(args.flush) ~= 'boolean') then
        return fail('invalid_argument', 'invalid infoMap commit request')
    end
    local state, state_err = normalize(self.json, args.state)
    if not state then return nil, state_err end
    self.states[key] = state

    local persistence_error = self.save_errors[key]
    if args.flush ~= false and state.needSave and not persistence_error then
        local ok, err = self:write(key, state)
        if ok then
            state.needSave = false
            self.states[key] = state
        else
            persistence_error = err and err.message or 'infoMap persistence failed'
        end
    end
    local result = { state = state }
    if persistence_error then result.persistenceError = persistence_error end
    return result
end

function InfoMap:handlers()
    return {
        ['info_map.load'] = function(args, context) return self:load(args, context) end,
        ['info_map.save_now'] = function(args, context) return self:save_now(args, context) end,
        ['info_map.commit'] = function(args, context) return self:commit(args, context) end,
    }
end

return InfoMap
