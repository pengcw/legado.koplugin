local UIManager = require("ui/uimanager")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local MessageBox = require("Legado/MessageBox")
local Backend = require("Legado/Backend")
local TaskProg = require("Legado.task.Progress")
local Device = require("device")
local BookSourceLogin = require("Legado.Helper.BookSourceLogin")

local M = {}

local function clean_http_url(value)
    if type(value) ~= "string" or value == "" then return nil end
    if value:match("^%s*<js>") or value:match("^%s*@js:") or value:match("^%s*js:") then
        return nil
    end
    local url = value:match("^%s*(https?://[^\r\n%s\"'<>{}\\]+)")
    if url then
        url = url:gsub("[;,%.]+$", "")
        if url:match("^https?://[%w%.%-_]+[%w/]") or url:match("^https?://[%w%.%-_]+$") then
            return url
        end
    end
    return nil
end

local function open_external_url(url)
    if not Device:canOpenLink() then
        return MessageBox:notice("当前设备无法打开外部网页登录页")
    end
    Device:openLink(url)
end

local function confirm_open_url(source, request)
    local url = type(request) == "table" and request.url
    local scheme = type(url) == "string" and url:match("^([%a][%w+%.%-]*):")
    scheme = scheme and scheme:lower()
    if not scheme or #url >= 65536 or url:find("[%c]")
            or scheme == "javascript" or scheme == "data" or scheme == "file"
            or scheme == "content" or scheme == "intent" then
        return MessageBox:notice("书源请求的链接无效或不支持")
    end
    if scheme == "legado" or scheme == "yuedu" then
        return MessageBox:notice("暂不支持通过 openUrl 导入 Legado 内容")
    end
    if not Device:canOpenLink() then
        return MessageBox:notice("当前设备无法打开外部链接")
    end
    local shown = url:gsub("[%c]", " ")
    if #shown > 240 then shown = shown:sub(1, 240) .. "…" end
    MessageBox:confirm(
        "书源「" .. tostring(source.bookSourceName or source.bookSourceUrl)
            .. "」请求打开外部链接：\n" .. shown,
        function(confirmed)
            if confirmed then
                local ok, opened = pcall(function() return Device:openLink(url) end)
                if not ok or opened == false then
                    MessageBox:notice("无法打开此链接")
                end
            end
        end
    )
end

local function handle_response(response, on_success)
    Backend:HandleResponse(response, on_success, function(err)
        local message = tostring(err or "未知错误"):gsub("^本地服务:%s*", "")
        MessageBox:error("书源操作失败：", message)
    end)
end

local function show_form(source, form)
    local rows = type(form.fields) == "table" and form.fields or {}
    local saved_values = type(form.values) == "table" and form.values or {}
    local login_url = clean_http_url(form.loginUrl)
    local fields, field_rows, action_rows = {}, {}, {}

    for _, row in ipairs(rows) do
        if type(row) == "table" then
            if row.type == "button" then
                action_rows[#action_rows + 1] = row
            else
                local name = row.name or row.key
                if type(name) == "string" and name ~= "" then
                    field_rows[#field_rows + 1] = row
                    fields[#fields + 1] = {
                        text = tostring(saved_values[name] or ""),
                        hint = row.title or row.label or name,
                        text_type = row.type == "password" and "password" or "text",
                    }
                end
            end
        end
    end

    if #action_rows == 0 and #fields > 0 then
        action_rows[1] = { name = "登录", title = "登录" }
    end

    local has_saved = BookSourceLogin.hasNonemptyValue(saved_values)
        or BookSourceLogin.hasNonemptyValue(form.session)
    if #fields == 0 and #action_rows == 0 and not login_url and not has_saved then
        return MessageBox:notice("该书源没有配置可用的登录表单")
    end

    local function execute_action(action, entered_values, title)
        local clean_action_url = clean_http_url(action)
        if clean_action_url then
            open_external_url(clean_action_url)
        else
            local run = TaskProg.loading
            if Backend:_isLocal() then
                Backend:closeDbManager()
                run = require("Legado.spore.local.browser.task").run
            end
            run("正在执行：" .. tostring(title or (action and "书源动作" or "登录")), function()
                return Backend:loginBookSource({
                    bookSourceUrl = source.bookSourceUrl,
                    values = entered_values or {},
                    action = action,
                })
            end, function(state, response)
                if state == true then
                    handle_response(response, function(result)
                        if type(result) == "table" then
                            if type(result.preview) == "table"
                                    and type(result.preview.html) == "string" then
                                return require("Legado.spore.local.html_dialog").show(result.preview)
                            end
                            if type(result.openUrls) == "table" and result.openUrls[1] then
                                return confirm_open_url(source, result.openUrls[1])
                            end
                        end
                        local message = type(result) == "table" and result.message or "书源脚本执行完成"
                        message = tostring(message):gsub("Error:%s*当前仅支持网页只读预览，不支持等待网页交互验证",
                            "不支持交互webview")
                        MessageBox:info(message)
                    end)
                elseif Backend:_isLocal() and type(response) == "string" then
                    MessageBox:error("书源操作失败：", response)
                end
            end, nil, true)
        end
    end

    if #fields == 0 and #action_rows > 2 then
        local Menu = require("ui/widget/menu")
        local item_table = {}
        for _, act in ipairs(action_rows) do
            table.insert(item_table, {
                text = act.title or act.label or act.name or "操作",
                action = act.action,
            })
        end
        local menu_dialog
        local menu = Menu:new{
            title = "书源操作：" .. tostring(source.bookSourceName or source.bookSourceUrl),
            item_table = item_table,
            items_per_page = 15,
            onMenuSelect = function(_, item)
                if menu_dialog then UIManager:close(menu_dialog) end
                execute_action(item.action, {}, item.text)
            end,
            close_callback = function()
                if menu_dialog then
                    UIManager:close(menu_dialog)
                    menu_dialog = nil
                end
            end,
        }
        menu_dialog = UIManager:show(menu)
        return
    end

    local dialog
    local dialog_buttons = {}

    local function get_current_values()
        local values = {}
        if #field_rows > 0 and dialog and dialog.getFields then
            local entered = dialog:getFields() or {}
            for index, row in ipairs(field_rows) do
                values[row.name or row.key] = entered[index] or ""
            end
        end
        return values
    end

    local primary_action = action_rows[1]
    local row1 = {
        {
            text = "取消",
            callback = function() UIManager:close(dialog) end,
        }
    }
    if primary_action then
        table.insert(row1, {
            text = primary_action.title or primary_action.label or primary_action.name or "保存",
            callback = function()
                local values = get_current_values()
                UIManager:close(dialog)
                execute_action(primary_action.action, values,
                    primary_action.title or primary_action.label or primary_action.name)
            end,
        })
    end
    table.insert(dialog_buttons, row1)

    if #action_rows > 1 then
        table.insert(dialog_buttons, {
            {
                text = string.format("更多操作 (%d)", #action_rows),
                callback = function()
                    local values = get_current_values()
                    UIManager:close(dialog)
                    local Menu = require("ui/widget/menu")
                    local item_table = {}
                    for _, act in ipairs(action_rows) do
                        table.insert(item_table, {
                            text = act.title or act.label or act.name or "操作",
                            action = act.action,
                        })
                    end
                    local menu_dialog
                    local menu = Menu:new{
                        title = "选择操作：" .. tostring(source.bookSourceName or source.bookSourceUrl),
                        item_table = item_table,
                        items_per_page = 15,
                        onMenuSelect = function(_, item)
                            if menu_dialog then UIManager:close(menu_dialog) end
                            execute_action(item.action, values, item.text)
                        end,
                        close_callback = function()
                            if menu_dialog then
                                UIManager:close(menu_dialog)
                                menu_dialog = nil
                            end
                        end,
                    }
                    menu_dialog = UIManager:show(menu)
                end,
            }
        })
    end

    if login_url then
        table.insert(dialog_buttons, {
            {
                text = "打开网页登录页",
                callback = function()
                    UIManager:close(dialog)
                    open_external_url(login_url)
                end,
            }
        })
    end

    local title_prefix = #fields > 0 and "设置书源：" or "书源操作："
    local dialog_title = title_prefix .. tostring(source.bookSourceName or source.bookSourceUrl)

    if #fields > 0 then
        local InputDialogClass = #fields > 2
            and require("Legado.spore.local.scrollable_multiinput_dialog") or MultiInputDialog
        dialog = InputDialogClass:new{
            title = dialog_title,
            fields = fields,
            buttons = dialog_buttons,
            focused_field_idx = 1,
        }
    else
        dialog = ButtonDialog:new{
            title = dialog_title,
            buttons = dialog_buttons,
        }
    end
    UIManager:show(dialog)
end

function M:show(source)
    local source_url = type(source) == "table" and (source.bookSourceUrl or source.url)
    if type(source_url) ~= "string" or source_url == "" then
        return MessageBox:notice("书源信息无效")
    end
    source = {
        bookSourceUrl = source_url,
        bookSourceName = source.bookSourceName or source.name,
    }

    TaskProg.loading("读取书源登录配置", function()
        return Backend:getBookSourceLoginUi(source.bookSourceUrl)
    end, function(state, response)
        if state == true then
            handle_response(response, function(form)
                show_form(source, type(form) == "table" and form or {})
            end)
        end
    end, nil, true)
end

return M
