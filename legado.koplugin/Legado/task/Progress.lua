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
        dismissable = options.dismissable,
        show_icon = false,
        update_interval = 0.2
    }

    for key, value in pairs(options) do
        defaultOptions[key] = value
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
        close = function()
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

    local progressbar_dialog
    local ok, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if ok and ProgressbarDialog then
        progressbar_dialog = ProgressbarDialog:new{
            title = title,
            subtitle = sub_title,
            progress_max = max,
            refresh_time_seconds = 0.4
        }
        -- fix bar fill color on Koreader 2025.08
        if progressbar_dialog.progress_bar then  
            progressbar_dialog.progress_bar.fillcolor = require("ffi/blitbuffer").COLOR_BLACK
        end
        progressbar_dialog:show()
    end
    return progressbar_dialog or show_progress_info(sub_title, {progress_max = max, parent = show_parent})
end

return M