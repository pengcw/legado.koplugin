
local Reader = require("Legado.spore.local.parser")
local logger = require("logger")
local Probe = require("Legado.Helper.Probe")

local DEFAULT_MAX_PAGES = 100

local BookService = {}
BookService.__index = BookService

local function error_message(err)
    if type(err) == "table" then
        local message = err.message or err.kind or "reader_execute failed"
        if err.kind == "auth_required" then
            return message .. "（可在书源列表长按该书源登录）"
        end
        return message
    end
    return tostring(err or "reader_execute failed")
end

local function has_values(value)
    return type(value) == "table" and next(value) ~= nil
end

local function login_public_error(err)
    local text = error_message(err)
    if text:find("不支持等待网页交互验证", 1, true) then
        return "不支持交互webview"
    end
    if text:find("网页只读预览失败", 1, true) then
        return "网页预览失败，请稍后重试。"
    end
    return "书源脚本执行失败，请查看日志中的返回消息。"
end

local function probe_login_message(action, message, values, session)
    Probe.event("Source", action .. "返回消息", function()
        local text = tostring(message or "<无消息>")
        local function hide(value)
            if type(value) == "table" then
                for _, item in pairs(value) do hide(item) end
            elseif type(value) == "string" and value ~= "" then
                local pattern = value:gsub("([^%w])", "%%%1")
                text = text:gsub(pattern, "<隐藏>")
            end
        end
        hide(values)
        hide(session)
        text = text:gsub("https?://[^%s\"'<>]+", "<URL>")
        text = text:gsub("[\r\n]+", " ")
        return text:sub(1, 512)
    end)
end

local function apply_source_type(source, book)
    if type(book) == "table" and book.type == nil and book.btype == nil then
        book.type = tonumber(source and source.bookSourceType) or 0
    end
    return book
end

local function apply_source_type_list(source, books)
    if type(books) == "table" then
        for _, book in ipairs(books) do
            apply_source_type(source, book)
        end
    end
    return books
end

function BookService.new(source, opts)
    opts = opts or {}
    return setmetatable({
        source = source,
        max_pages = opts.max_pages or DEFAULT_MAX_PAGES,
        save_session = opts.save_session,
        load_source = opts.load_source,
        session_dirty = false,
        save_login_data = opts.save_login_data,
        login_data = source.login_data,
    }, BookService)
end

function BookService:_save_session(session)
    self.source.session = session
    self.session_dirty = true
    if type(self.save_session) == "function" then
        local ok, saved, save_err = pcall(
            self.save_session,
            self.source.bookSourceUrl,
            session
        )
        if ok and saved ~= false then
            self.session_dirty = false
        else
            logger.warn("BookService: session persistence failed for source "
                .. tostring(self.source.bookSourceUrl) .. ": " .. tostring(save_err or saved))
        end
    end
end

function BookService:_execute_once(op, params)
    params = params or {}
    if type(self.load_source) == "function" then
        local ok, latest_source = pcall(self.load_source, self.source.bookSourceUrl)
        if ok and type(latest_source) == "table" then
            if not self.session_dirty then
                self.source.session = type(latest_source.session) == "table" and latest_source.session or nil
            end
            self.login_data = type(latest_source.loginData) == "table" and latest_source.loginData or nil
            self.source.login_data = self.login_data
        end
    end
    local response, err = Reader.execute(self.source:json(), {
        api = 2,
        op = op,
        params = params,
        session = self.source.session,
        options = { maxPages = self.max_pages },
    })
    if type(response) ~= "table" then
        return nil, err or "reader_execute failed"
    end

    if type(response.session) == "table" then
        self:_save_session(response.session)
    end
    if response.infoMapError then
        logger.warn("BookService: infoMap persistence failed: " .. tostring(response.infoMapError))
    end
    return response
end

function BookService:_execute(op, params, already_retried)
    local response, ffi_err = self:_execute_once(op, params)
    if type(response) ~= "table" then
        return nil, error_message(ffi_err)
    end

    if response.ok ~= true then
        local err = response.error or { message = "reader_execute returned ok=false" }
        if op ~= "login" and not already_retried and type(err) == "table"
                and err.kind == "auth_required" and has_values(self.login_data) then
            local login_response = self:_execute_once("login", { values = self.login_data })
            if type(login_response) == "table" and login_response.ok == true then
                return self:_execute(op, params, true)
            end
            if type(login_response) == "table" and type(login_response.error) == "table" then
                err = login_response.error
            end
        end
        return nil, err
    end

    return response.data, nil, response.meta
end

function BookService:login_ui()
    local fields, err = self:_execute("login_ui", {})
    if not fields then return nil, error_message(err) end
    return fields
end

function BookService:login(values, action)
    local has_form_values = has_values(values)
    values = type(values) == "table" and values or self.login_data or {}
    local params = { values = values }
    if type(action) == "string" and action ~= "" then params.action = action end

    local saved_before_login = params.action == nil or has_form_values
    local probe_target = params.action == nil and "confirm" or "custom_action"
    local probe_action = params.action == nil and "书源登录" or "书源动作"
    local t_login = Probe.start("Source", probe_action, probe_target)
    if saved_before_login then
        if type(self.save_login_data) ~= "function" then
            Probe.fail("Source", probe_action, probe_target, t_login, "SAVE_UNAVAILABLE")
            return nil, "凭证保存不可用，未执行登录"
        end
        local ok, saved = pcall(self.save_login_data, self.source.bookSourceUrl, values)
        if not ok or saved ~= true then
            Probe.fail("Source", probe_action, probe_target, t_login, "SAVE_FAILED")
            return nil, "凭证保存失败，未执行登录"
        end
        self.login_data = values
        self.source.login_data = values
        Probe.event("Source", "书源表单", "SAVED")
    end

    local response, err = self:_execute_once("login", params)
    if type(response) ~= "table" then
        probe_login_message(probe_action, error_message(err), values, self.source.session)
        Probe.fail("Source", probe_action, probe_target, t_login, "SO_CALL_FAILED")
        return nil, login_public_error(err)
    end
    if response.ok ~= true then
        probe_login_message(probe_action, error_message(response.error), values, self.source.session)
        Probe.fail("Source", probe_action, probe_target, t_login, "SO_SCRIPT_FAILED")
        return nil, login_public_error(response.error)
    end

    self.login_data = values
    self.source.login_data = values
    if not saved_before_login and type(self.save_login_data) == "function" then
        local ok, saved = pcall(
            self.save_login_data,
            self.source.bookSourceUrl,
            values
        )
        if not ok or saved == false then
            Probe.event("Source", "登录凭证", "SAVE_FAILED")
            logger.warn("BookService: login data persistence failed")
        else
            Probe.event("Source", "书源表单", "SAVED")
        end
    end
    probe_login_message(probe_action,
        type(response.data) == "table" and response.data.message or nil, values, self.source.session)
    Probe.done("Source", probe_action, probe_target, t_login, "SCRIPT_OK")
    return response.data
end

function BookService:search(keyword, page)
    if not self.source:can_search() then
        return nil, "书源未配置 searchUrl"
    end
    local books, err = self:_execute("search", {
        key = keyword or "",
        page = page or 1,
    })
    if not books then return nil, error_message(err) end
    return apply_source_type_list(self.source, books)
end

function BookService:explore_kinds()
    local kinds, err = self:_execute("explore_kinds", {})
    if not kinds then return nil, error_message(err) end
    return kinds
end

function BookService:explore(url, page)
    local books, err = self:_execute("explore", {
        url = url or self.source.exploreUrl or "",
        page = page or 1,
    })
    if not books then return nil, error_message(err) end
    return apply_source_type_list(self.source, books)
end

function BookService:book_info(book_url, book_context)
    if type(book_url) ~= "string" or book_url == "" then
        return nil, "缺少书籍 URL"
    end
    local info, err = self:_execute("info", { url = book_url, book = book_context })
    if not info then return nil, error_message(err) end
    return apply_source_type(self.source, info)
end

local function apply_text_transform(params, transform)
    if type(transform) ~= "table"
            or type(transform.dialect) ~= "string"
            or type(transform.rules) ~= "table"
            or #transform.rules == 0 then
        return
    end
    params.textTransformDialect = transform.dialect
    params.textTransformRules = transform.rules
end

function BookService:fetch_toc(book_url, book_context, transform, run_pre_update_js)
    if type(book_url) ~= "string" or book_url == "" then
        return nil, "缺少书籍 URL"
    end
    local params = { url = book_url }
    if type(book_context) == "table" then params.book = book_context end
    if run_pre_update_js == true then params.runPreUpdateJs = true end
    apply_text_transform(params, transform)
    local toc, err = self:_execute("toc", params)
    if not toc then return nil, error_message(err) end
    return toc
end

function BookService:fetch_content(chapter_url, book_context, chapter_context, transform)
    if type(chapter_url) ~= "string" or chapter_url == "" then
        return nil, "缺少章节 URL"
    end
    local params = { url = chapter_url }
    if type(book_context) == "table" then params.book = book_context end
    if type(chapter_context) == "table" then params.chapter = chapter_context end
    apply_text_transform(params, transform)
    local content, err = self:_execute("content", params)
    if not content then return nil, error_message(err) end
    return content
end

return BookService
