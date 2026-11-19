local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local InfoMessage = require("ui/widget/infomessage")
local TaskQueue = require("Legado.task.Queue")
local H = require("Legado/Helper")
local socket = require("socket")

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
    local completed = false

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

        local new_text = completed and message or string.format("%s %s ...", message, current_progress_text)
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

        if not completed then UIManager:scheduleIn(defaultOptions.update_interval, updateText) end
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
        unschedule = function() UIManager:unschedule(updateText) end,
        reportProgress = function(_, progress) current_progress = progress end,
        setMessage = function(_, text) message = text end,
        finish = function(_, text)
            UIManager:unschedule(updateText)
            completed = true
            message = text
            updateText()
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
    local pending_finish

    local MessageBox = require("Legado/MessageBox")

    if is_dismissable then
        args.dismiss_callback = function()
            if is_cancelled then return end
            if is_finished then
                if pending_finish then pending_finish() end
                return
            end
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

    local shown_at = socket.gettime()
    message_dialog = show_progress_info(message, args)

    local function finish(ok, return_values)
        if is_finished then return end
        is_finished = true
        if is_cancelled then return end

        local delivered = false
        local function complete()
            if delivered then return end
            delivered = true
            if pending_finish then UIManager:unschedule(pending_finish) end
            pending_finish = nil
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
        end

        local remaining = (args.min_visible_time or 0) - (socket.gettime() - shown_at)
        if remaining > 0 and not is_background then
            local text = H.is_func(args.completion_text)
                and args.completion_text(ok, return_values) or "任务已结束"
            message_dialog:finish(text)
            pending_finish = complete
            UIManager:scheduleIn(remaining, complete)
        else
            complete()
        end
    end

    if args.on_progress then
        local started, err = pcall(function()
            require("Legado.task.v2").stream(task_runnable, {
                engine = "process",
                timeout = timeout,
                on_progress = function(_, text)
                    if not is_finished and not is_background and H.is_str(text) then
                        message_dialog:setMessage(text)
                    end
                end,
                on_finish = finish,
            })
        end)
        if not started then finish(false, tostring(err)) end
    else
        pid = TaskQueue.spawnProcess(task_runnable, finish, timeout)
    end
end

local function show_detailed_progress(message, options)
    local ButtonDialog = require("ui/widget/buttondialog")
    if type(ButtonDialog.addWidget) ~= "function"
            or type(ButtonDialog.getAddedWidgetAvailableWidth) ~= "function" then
        return nil
    end
    local TextWidget = require("ui/widget/textwidget")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Geom = require("ui/geometry")
    local splitToArray = require("util").splitToArray
    local ProgressWidget = require("ui/widget/progresswidget")
    local Font = require("ui/font")
    local MessageBox = require("Legado/MessageBox")
    local closed = false
    local text, progress = message, 0
    local rendered_text, rendered_progress = message, 0
    local refresh
    local dialog
    local function background()
        dialog:onClose()
    end
    dialog = ButtonDialog:new{
        title = options.title,
        title_align = "center",
        dismissable = options.dismissable == true,
        tap_close_callback = function()
            MessageBox:notice("已切至后台")
            if options.on_dismiss then options.on_dismiss(dialog) end
        end,
        buttons = options.dismissable and {{{text = "后台运行", callback = background}}} or {},
    }
    local width = dialog:getAddedWidgetAvailableWidth()
    local rows = {}
    local lines = splitToArray(text, "\n", true)
    for i = 1, 3 do
        local row = TextWidget:new{
            text = lines[i] or "",
            face = Font:getFace("smallffont"),
            max_width = width,
            truncate_with_ellipsis = true,
        }
        rows[i] = row
        dialog:addWidget(LeftContainer:new{
            dimen = Geom:new{w = width, h = row:getSize().h},
            parent = dialog,
            not_focusable = true,
            row,
        })
    end
    local bar = ProgressWidget:new{
        width = width,
        height = Screen:scaleBySize(12),
        percentage = 0,
        fillcolor = require("ffi/blitbuffer").COLOR_BLACK,
        parent = dialog,
        not_focusable = true,
    }
    dialog:addWidget(bar)
    refresh = function()
        if closed then return end
        if text ~= rendered_text or progress ~= rendered_progress then
            local lines = splitToArray(text, "\n", true)
            for i, row in ipairs(rows) do row:setText(lines[i] or "") end
            bar:setPercentage(progress / options.max)
            rendered_text, rendered_progress = text, progress
            UIManager:setDirty(dialog, "ui")
        end
        UIManager:scheduleIn(0.5, refresh)
    end
    local on_close = dialog.onCloseWidget
    dialog.onCloseWidget = function(self, ...)
        closed = true
        UIManager:unschedule(refresh)
        if on_close then return on_close(self, ...) end
    end
    UIManager:show(dialog)
    UIManager:scheduleIn(0.5, refresh)
    return {
        close = function()
            if not closed then UIManager:close(dialog) end
        end,
        reportProgress = function(_, value) progress = value end,
        setDetails = function(_, value) text = value end,
    }
end

function M.showBar(message, options)
    if not H.is_tbl(options) then options = {} end
    if options.detailed then
        local dialog = show_detailed_progress(message, options)
        if dialog then return dialog end
        message = "正在缓存章节..."
    end

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