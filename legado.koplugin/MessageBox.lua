local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local ProgressWidget = require("ui/widget/progresswidget")
local Screen = require("device").screen
local Trapper = require("ui/trapper")

local _ = require("gettext")

local function custom_concat(tbl, sep)
    sep = sep or ""
    local result = {}

    for i, v in ipairs(tbl) do
        if v == nil then
            result[i] = "nil"
        elseif type(v) == "table" then

            result[i] = "{" .. custom_concat(v, ",") .. "}"
        else
            result[i] = tostring(v)
        end
    end

    return table.concat(result, sep)
end

local M = {}

function M:custom(options)
    local defaultOptions = {
        text = '',
        icon = "notice-info",

        timeout = nil,

        alignment = "left",
        modal = true,

        _timeout_func = nil
    }
    if options then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end
    local dialog = InfoMessage:new(defaultOptions)
    UIManager:show(dialog)
    return dialog
end

function M:error(message, ...)
    local args = {...}

    local timeout = nil
    if #args > 0 and type(args[1]) == "number" then
        timeout = table.remove(args, 1)

    end

    if #args > 0 then
        message = message .. " " .. custom_concat(args, " ")
    end
    return self:custom({
        text = message,
        icon = "notice-warning",
        timeout = timeout
    })
end

function M:info(message, ...)

    local args = {...}

    local timeout = nil
    if #args > 0 and type(args[1]) == "number" then
        timeout = table.remove(args, 1)

    end

    if #args > 0 then
        message = message .. " " .. custom_concat(args, " ")
    end

    return self:custom({
        text = message,
        icon = "notice-info",
        timeout = timeout
    })

end

function M:success(message, ...)
    local args = {...}

    local timeout = nil
    if #args > 0 and type(args[1]) == "number" then
        timeout = table.remove(args, 1)

    end

    if #args > 0 then
        message = message .. " " .. custom_concat(args, " ")
    end
    return self:custom({
        text = _(message),
        icon = "check",
        timeout = timeout
    })
end

function M:confirm(message, callback, options)

    local dialog
    local defaultOptions = {
        text = message,

        timeout = nil

    }

    if options then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end

    if callback then
        defaultOptions.ok_callback = function()
            callback(true)
            UIManager:close(dialog)
        end
        defaultOptions.cancel_callback = function()
            callback(false)
            UIManager:close(dialog)
        end
    end

    dialog = ConfirmBox:new(defaultOptions)
    UIManager:show(dialog)

    if defaultOptions.timeout then
        UIManager:scheduleIn(defaultOptions.timeout, function()
            UIManager:close(dialog)
        end)
    end
    return dialog
end

function M:input(message, callback, options)
    local dialog = {}

    local defaultOptions = {
        title = "",

        input_hint = "",

        description = _(message),

        buttons = {{{
            text = _("Cancel"),

            callback = function()
                if callback then
                    callback(nil)
                end
                UIManager:close(dialog)
            end
        }, {
            text = _("OK"),

            is_enter_default = true,

            callback = function()
                local input_text = dialog:getInputText()
                if callback then
                    callback(input_text)
                end
                UIManager:close(dialog)
            end
        }}},
        timeout = nil

    }

    if options then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end

    dialog = InputDialog:new(defaultOptions)
    UIManager:show(dialog)
    dialog:onShowKeyboard()

    if defaultOptions.timeout then
        UIManager:scheduleIn(defaultOptions.timeout, function()
            UIManager:close(dialog)
        end)
    end
    return dialog
end

function M:loading(message, runnable, callback, options)

    local defaultOptions = {
        text = "\u{231B}  " .. message,
        dismissable = false,

        update_interval = 0.8

    }

    if type(options) == 'table' then
        for key, value in pairs(options) do
            defaultOptions[key] = value
        end
    end

    local start_time = os.time() - 1
    local updateText
    local message_dialog

    updateText = function()

        local elapsed_time = os.time() - start_time
        defaultOptions.text = string.format("%s [%d] ...", message, elapsed_time)

        message_dialog = InfoMessage:new(defaultOptions)

        UIManager:show(message_dialog)

        UIManager:scheduleIn(defaultOptions.update_interval, updateText)

    end

    updateText()

    Trapper:wrap(function()

        local completed, return_values = Trapper:dismissableRunInSubprocess(runnable, true)

        UIManager:unschedule(updateText)

        UIManager:close(message_dialog)

        if type(callback) == 'function' then

            if not completed then
                callback(false, "Task was cancelled or failed to complete")
            else
                callback(true, return_values)
            end
        end

    end)
end

return M
