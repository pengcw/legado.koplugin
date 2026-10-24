
local BookSource = require("Legado.spore.local.book_source")
local BookService = require("Legado.spore.local.book_service")
local logger = require("logger")
local util = require("util")

local M = {}
M.__index = M

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, M)
    self.sources = {}
    self.source_keys = {}
    self.save_session = opts.save_session
    self.load_source = opts.load_source
    self.save_login_data = opts.save_login_data
    return self
end

function M:add(raw)
    local ok, source = pcall(BookSource.new, raw)
    if not ok then
        if logger and logger.warn then
            logger.warn("[SourceManager] 跳过无效书源: " .. tostring(source))
        end
        return nil, source
    end

    local key = type(source.bookSourceUrl) == "string" and source.bookSourceUrl or ""
    if key ~= "" and self.source_keys[key] then
        return self.source_keys[key].source
    end

    local service = BookService.new(source, {
        save_session = self.save_session,
        load_source = self.load_source,
        save_login_data = self.save_login_data
    })
    local entry = { source = source, service = service }
    table.insert(self.sources, entry)

    if key ~= "" then
        self.source_keys[key] = entry
    end

    return source
end

function M:add_file(path)
    local f = io.open(path, "r")
    if not f then return nil, "无法打开书源文件: " .. tostring(path) end
    local raw = f:read("*a")
    f:close()
    return self:add(raw)
end

function M:add_dir(dir)
    local count = 0
    if not (type(dir) == "string" and dir ~= "") then return count end
    if util and type(util.findFiles) == "function" then
        util.findFiles(dir, function(path, name)
            if name:match("%.json$") then
                local ok, source = pcall(function()
                    return self:add_file(path)
                end)
                if ok and source then
                    count = count + 1
                end
            end
        end, false)
    end
    return count
end

function M:search(keyword, page, on_source, is_cancelled)
    page = page or 1
    local results, errors = {}, {}
    for _, entry in ipairs(self.sources) do
        if type(is_cancelled) == "function" and is_cancelled() then
            return results, errors, true
        end

        local ok, books, err = pcall(function()
            return entry.service:search(keyword, page)
        end)
        if type(is_cancelled) == "function" and is_cancelled() then
            return results, errors, true
        end

        if ok and type(books) == "table" then
            local chunk = {}
            for _, book in ipairs(books) do
                book.sourceName = book.sourceName or entry.source.bookSourceName
                if not book.origin or book.origin == "" then
                    book.origin = entry.source.bookSourceUrl
                end
                if not book.originName or book.originName == "" then
                    book.originName = entry.source.bookSourceName
                end
                results[#results + 1] = book
                chunk[#chunk + 1] = book
            end
            if #chunk > 0 and type(on_source) == "function" then
                on_source(chunk, entry.source)
            end
        else
            errors[#errors + 1] = {
                sourceName = entry.source.bookSourceName,
                error = ok and (err or "搜索结果无效") or tostring(books),
            }
        end
    end
    return results, errors, false
end

function M:count()
    return #self.sources
end

return M
