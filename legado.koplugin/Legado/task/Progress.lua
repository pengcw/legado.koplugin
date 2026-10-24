local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local InfoMessage = require("ui/widget/infomessage")
local TaskQueue = require("Legado.task.Queue")
local H = require("Legado/Helper")

local M = {}
local SPINNER_STYLES = {{"|", "/", "-", "\\"}, {"\u{25D0}", "\u{25D3}", "\u{25D1}", "\u{25D2}"}}

local function show_progress_info(message, options)
    if not H.is_str(message) then message = "" end
    if not H.is_tbl(options) then options = {} end

    local defaultOptions = {
        text = "\u{231B}  " .. message,
        show_icon = false,
        update_interval = 0.2
    }

    for key, value in pairs(options) do
        defaultOptions[key] = value
    end

    defaultOptions.dismissable = (options.dismissable == true)
    local user_closed = false
    if defaultOptions.dismissable then
        local orig_dismiss_cb = defaultOptions.dismiss_callback
        defaultOptions.dismiss_callback = function()
            user_closed = true
            if H.is_func(orig_dismiss_cb) then orig_dismiss_cb() end
        end
    end

    local spinner_chars = SPINNER_STYLES[math.random(1, #SPINNER_STYLES)]
    local updateText
    local message_dialog
    local current_progress

    local spinner
    local spinner_index = 1
    local current_progress_text = ""
    local progress_max = defaultOptions.progress_max
    local has_progress_max = H.is_num(progress_max)
    updateText = function()
        if user_closed then return end
        if has_progress_max and current_progress then
            current_progress_text = progress_max and string.format("[%s/%s]", current_progress, progress_max) or ""
        else
            spinner = spinner_chars[spinner_index]
            spinner_index = (spinner_index % #spinner_chars) + 1
            current_progress_text = spinner
        end

        local new_text = string.format("%s %s ...", message, current_progress_text)
        if message_dialog and message_dialog.movable and Screen.refreshUI then
            local orig_offset = message_dialog.movable:getMovedOffset()
            message_dialog:free()
            message_dialog.text = new_text
            message_dialog:init()
            message_dialog.movable:setMovedOffset(orig_offset)
            message_dialog:paintTo(Screen.bb, 0, 0)
            local d = message_dialog[1][1].dimen
            Screen.refreshUI(Screen, d.x, d.y, d.w, d.h)
        else
            defaultOptions.text = new_text
            message_dialog = InfoMessage:new(defaultOptions)
            UIManager:show(message_dialog)
        end

        UIManager:scheduleIn(defaultOptions.update_interval, updateText)
    end

    updateText()
    return {
        closed = false,
        close = function()
            user_closed = true
            UIManager:unschedule(updateText)
            if message_dialog then
                UIManager:close(message_dialog)
                message_dialog = nil
            end
        end,
        unschedule = function()
            UIManager:unschedule(updateText)
        end,
        reportProgress = function(_, progress)
            current_progress = progress
        end,
    }
end

function M.loading(message_or_args, runnable, callback, options, silent_cancel)
    local args = {}
    if H.is_tbl(message_or_args) then
        args = message_or_args
    else
        if H.is_tbl(options) then
            for k, v in pairs(options) do
                args[k] = v
            end
        elseif H.is_boolean(options) and silent_cancel == nil then
            silent_cancel = options
        end
        args.text = H.is_str(message_or_args) and message_or_args or ""
        args.runnable = runnable
        args.callback = callback
        if silent_cancel ~= nil then
            args.silent_cancel = silent_cancel
        end
    end

    args.silent_cancel = args.silent_cancel or args.silent or false
    if args.dismissable == nil then
        args.dismissable = args.silent_cancel and true or false
    end

    local message          = args.text or ""
    local task_runnable    = args.runnable
    local on_done          = args.callback
    local is_dismissable   = args.dismissable
    local is_silent_cancel = args.silent_cancel
    local on_cancel_func   = args.on_cancel or args.cancel_callback
    local notify_bg_finish = args.notify_bg_finish or false
    local timeout          = args.timeout

    if not H.is_func(task_runnable) then return end

    local pid
    local is_cancelled = false
    local is_background = false
    local is_finished = false
    local message_dialog
    local confirm_dialog
    local bg_switch_dialog

    local MessageBox = require("Legado/MessageBox")

    if is_dismissable then
        args.dismiss_callback = function()
            if is_cancelled or is_finished then return end
            if message_dialog and message_dialog.unschedule then message_dialog:unschedule() end

            if is_silent_cancel then
                is_cancelled = true
                bg_switch_dialog = MessageBox:notice("取消操作")
                if message_dialog and message_dialog.close then
                    message_dialog:close()
                end
                if H.is_func(on_done) then
                    on_done(false, "cancelled")
                end
                return
            end

            if not on_cancel_func then
                bg_switch_dialog = MessageBox:notice("已切至后台")
                is_background = true
                return
            end

            confirm_dialog = MessageBox:confirm("确定要取消当前任务吗？", function(result)
                if is_finished then
                    if not result and notify_bg_finish == true then
                        local bg_msg = (message ~= "") and (message .. " 已结束") or "后台任务已结束"
                        MessageBox:notice(bg_msg)
                    end
                    return
                end

                if result then
                    is_cancelled = true
                    if H.is_func(on_cancel_func) then
                        pcall(on_cancel_func, pid)
                    end
                    if H.is_func(on_done) then
                        on_done(false, "cancelled")
                    end
                else
                    is_background = true
                end
            end, { ok_text = "确定取消", cancel_text = "后台运行" })
        end
    end

    message_dialog = show_progress_info(message, args)

    pid = TaskQueue.spawnProcess(task_runnable, function(ok, return_values)
        is_finished = true
        if is_cancelled then return end

        if message_dialog and message_dialog.close then
            message_dialog:close()
        end
        if confirm_dialog then UIManager:close(confirm_dialog) end
        if bg_switch_dialog then UIManager:close(bg_switch_dialog) end

        if H.is_func(on_done) then
            if not ok then
                on_done(false, return_values or "Task was cancelled or failed to complete")
            else
                on_done(true, return_values)
            end
        end

        if is_background and notify_bg_finish == true then
            local bg_msg = (message ~= "") and (message .. " 已结束") or "后台任务已结束"
            MessageBox:notice(bg_msg)
        end
    end, timeout)
end

function M.showBar(message, options)
    if not H.is_tbl(options) then options = {} end

    local title = options.title or "progressbar"
    local sub_title = message or ""
    local max = H.is_num(options.max) and options.max or 1
    local show_parent = options.parent
    local dismissable = (options.dismissable == true)
    local dismiss_text = dismissable and (options.dismiss_text or "是否切换到后台?") or nil

    local progressbar_dialog
    local ok, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if ok and ProgressbarDialog then
        progressbar_dialog = ProgressbarDialog:new{
            title = title,
            subtitle = sub_title,
            progress_max = max,
            refresh_time_seconds = 0.4,
            dismiss_text = dismiss_text,
            dismissable = dismissable,
            on_dismiss = options.on_dismiss,
        }
        if progressbar_dialog.progress_bar then
            progressbar_dialog.progress_bar.fillcolor = require("ffi/blitbuffer").COLOR_BLACK
        end
        if dismissable then
            local orig_onCloseWidget = progressbar_dialog.onCloseWidget
            progressbar_dialog.onCloseWidget = function(self_dialog, ...)
                self_dialog.is_closed = true
                if H.is_func(orig_onCloseWidget) then
                    return orig_onCloseWidget(self_dialog, ...)
                end
            end

            local orig_reportProgress = progressbar_dialog.reportProgress
            progressbar_dialog.reportProgress = function(self_dialog, progress)
                if self_dialog.is_closed then
                    return
                end

                if self_dialog.dismiss_box then
                    if self_dialog.progress_bar_visible and self_dialog.progress_bar then
                        self_dialog.progress_bar:setPercentage(progress / self_dialog.progress_max)
                    end
                else
                    if H.is_func(orig_reportProgress) then
                        orig_reportProgress(self_dialog, progress)
                    end
                end
            end

            progressbar_dialog.onDismiss = function(self_dialog)
                if self_dialog.dismiss_box then return end

                if self_dialog.dismiss_text then
                    local MessageBox = require("Legado/MessageBox")
                    self_dialog.dismiss_box = MessageBox:confirm(self_dialog.dismiss_text, function(ok)
                        self_dialog.dismiss_box = nil
                        if ok then
                            UIManager:close(self_dialog)
                            MessageBox:notice("已切至后台, 可在任务队列查看")
                            if H.is_func(self_dialog.on_dismiss) then
                                self_dialog.on_dismiss(self_dialog)
                            end
                        else
                            if self_dialog.progress_bar_visible and H.is_func(self_dialog.redrawProgressbar) then
                                self_dialog:redrawProgressbar()
                            end
                        end
                    end, {ok_text = "后台运行", cancel_text = "取消"})
                else
                    UIManager:close(self_dialog)
                    if H.is_func(self_dialog.on_dismiss) then
                        self_dialog.on_dismiss(self_dialog)
                    end
                end
            end

            progressbar_dialog.onTapClose = progressbar_dialog.onDismiss
            progressbar_dialog.onAnyKeyPressed = progressbar_dialog.onDismiss
        end
        progressbar_dialog:show()
    end
    return progressbar_dialog or show_progress_info(sub_title, {progress_max = max, parent = show_parent, dismissable = dismissable})
end

M.showSpinner = show_progress_info

function M.createCardWidget(options)
    options = options or {}
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Font = require("ui/font")
    local Size = require("ui/size")
    local Blitbuffer = require("ffi/blitbuffer")

    local items = {}
    if options.title and options.title ~= "" then
        table.insert(items, TextWidget:new{
            text = tostring(options.title),
            face = Font:getFace("tfont", options.title_size or 22),
            bold = (options.title_bold ~= false),
            padding = Size.padding.default,
        })
    end

    if options.subtitle and options.subtitle ~= "" then
        table.insert(items, TextWidget:new{
            text = tostring(options.subtitle),
            face = Font:getFace("cfont", options.subtitle_size or 18),
            padding = Size.padding.small,
        })
    end

    if options.detail and options.detail ~= "" then
        table.insert(items, TextWidget:new{
            text = tostring(options.detail),
            face = Font:getFace("smallffont", options.detail_size or 14),
            padding = Size.padding.small,
        })
    end

    if options.action_text and options.action_text ~= "" then
        table.insert(items, TextWidget:new{
            text = tostring(options.action_text),
            face = Font:getFace("cfont", options.action_size or 16),
            bold = true,
            padding = Size.padding.large,
        })
    end

    local vgroup = VerticalGroup:new{
        align = options.align or "center",
    }
    for _, it in ipairs(items) do
        table.insert(vgroup, it)
    end

    local card = FrameContainer:new{
        radius = options.radius or 12,
        padding = options.padding or Size.padding.large,
        margin = options.margin or 0,
        bordersize = options.bordersize or 2,
        background = options.background or Blitbuffer.COLOR_WHITE,
        vgroup,
    }
    return card
end

function M.showCard(options)
    options = options or {}
    local InputContainer = require("ui/widget/container/inputcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Geom = require("ui/geometry")
    local card_wg = M.createCardWidget(options)

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local dialog = InputContainer:new{
        dimen = Geom:new{
            w = screen_w,
            h = screen_h,
        },
        CenterContainer:new{
            dimen = Geom:new{
                w = screen_w,
                h = screen_h,
            },
            card_wg,
        },
    }

    dialog.onTap = function(self_d, _, ges)
        if options.dismissable ~= false then
            UIManager:close(self_d)
            if H.is_func(options.on_dismiss) then options.on_dismiss() end
            return true
        end
        if H.is_func(options.on_tap) then
            return options.on_tap(self_d, ges)
        end
        return true
    end

    dialog.close = function(self_d)
        UIManager:close(self_d)
    end

    UIManager:show(dialog)
    return dialog
end

return M