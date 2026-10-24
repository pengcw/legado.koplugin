local JSON = require("json")
local buffer = require("string.buffer")
local Bridge = require("Legado.spore.local.browser.host_bridge")
local Process = require("Legado.task.v2.ProcessStream")
local Browser = require("Legado.spore.local.browser.dialog")
local Progress = require("Legado.task.Progress")
local Resources = require("Legado.spore.local.browser.resources")
local Probe = require("Legado.Helper.Probe")
local M = {}
local RESULT_PREFIX = "source_action_result\0"

function M.run(message, runnable, callback)
    local handle, page, current_reply, spinner
    local result, has_result, cancelled, unsupported_browser
    local resources = Resources.new()
    local task_span = Probe.start("Browser", "本地书源交互任务", "local_action")
    local context = Probe.child_context(nil, task_span)
    local function close_spinner()
        local previous = spinner
        spinner = nil
        if previous then previous:close() end
    end
    local router
    local function cancel_task()
        if cancelled then return end
        cancelled = true
        Probe.event("Browser", "取消交互任务", "USER_CANCELLED", context)
        router:close()
        current_reply = nil
        if page then page:close(); page = nil end
        close_spinner()
        if handle then handle:cancel("user_cancelled") end
    end
    router = Bridge.parent(function(frame) return handle:send(frame) end, {
        browser = function(arguments, reply)
            if arguments.action == "probe" then
                local supported = Browser.is_supported()
                if not supported then unsupported_browser = true end
                reply({offlineHtml = supported})
                return
            end
            if arguments.action ~= "exchange" or type(arguments.snapshot) ~= "table" then
                reply(nil, {kind = "protocol_error", message = "invalid browser request"})
                return
            end
            if not Browser.is_supported() then
                unsupported_browser = true
                reply(nil, {kind = "unsupported", message = Browser.UNSUPPORTED_MESSAGE})
                return
            end
            Probe.event("Browser", "交互页面", "SNAPSHOT_RECEIVED", context)
            close_spinner()
            current_reply = reply
            if page and not page.closed then
                if not page:update(arguments.snapshot) then
                    current_reply = nil
                    page:close(); page = nil
                    reply(nil, {kind = "protocol_error", message = "invalid page revision"})
                end
            else
                local err
                page, err = Browser.show(arguments.snapshot, function(event)
                    local respond = current_reply
                    current_reply = nil
                    if event.kind == "cancel" and not respond then
                        cancel_task()
                        return
                    end
                    if respond then
                        local kind = event.kind
                        if kind ~= "input" and kind ~= "click" and kind ~= "finish" and kind ~= "cancel" then
                            kind = "unknown"
                        end
                        Probe.event("Browser", "页面动作", kind, context)
                        respond(event)
                    end
                end)
                if not page then
                    current_reply = nil
                    Probe.event("Browser", "交互页面", "UI_UNAVAILABLE", context)
                    reply(nil, {kind = "unsupported", message = err})
                end
            end
            return function()
                if current_reply == reply then
                    current_reply = nil
                    if page then page:close(); page = nil end
                end
            end
        end,
    })
    spinner = Progress.showSpinner(message, {
        dismissable = true,
        dismiss_callback = function()
            if spinner then cancel_task() end
        end,
    })
    handle = Process.spawnProcessStream(function(writer, _, stream)
        Probe.event("Browser", "交互进程", "WORKER_READY", context)
        local Reader = require("Legado.spore.local.parser")
        local client = Bridge.worker(writer, stream, {timeout = 120})
        local response = Reader.with_host_handlers({browser = function(arguments)
            if arguments.action == "exchange" and type(arguments.snapshot) == "table"
                    and type(arguments.snapshot.html) == "string"
                    and arguments.snapshot.html:lower():find("<img", 1, true) then
                if not resources then
                    return nil, {kind = "unavailable", message = "browser resource directory unavailable"}
                end
                local snapshot = resources:prepare(arguments.snapshot, stream, context)
                if not snapshot then
                    return nil, {kind = "unavailable", message = "browser image preparation failed"}
                end
                arguments = {action = "exchange", snapshot = snapshot}
            end
            local action = arguments.action == "probe" and "probe" or "exchange"
            local wait_span = Probe.start("Browser", "宿主交互等待", action, nil, context)
            local data, err = client:call("browser", arguments)
            if err then
                Probe.fail("Browser", "宿主交互等待", action, wait_span, "HOST_FAILED", context)
            else
                Probe.done("Browser", "宿主交互等待", action, wait_span, "REPLY", nil, nil, context)
            end
            return data, err
        end}, runnable)
        Probe.event("Browser", "书源动作", "RETURNED", context)
        stream:throw_if_cancelled()
        local frame = RESULT_PREFIX .. buffer.encode({response = response})
        writer(frame)
        Probe.event("Browser", "结果回传", "RESULT_SENT", context)
    end, {
        timeout = 180,
        on_chunk = function(frame)
            if frame:sub(1, #RESULT_PREFIX) == RESULT_PREFIX then
                local decoded = buffer.decode(frame:sub(#RESULT_PREFIX + 1))
                result, has_result = decoded.response, true
                Probe.event("Browser", "结果回传", "RESULT_RECEIVED", context)
                return
            end
            router:dispatch(JSON.decode(frame))
        end,
        on_finish = function(ok, reason)
            if cancelled then
                Probe.done("Browser", "本地书源交互任务", "local_action", task_span, "CANCELLED")
            elseif ok and has_result then
                Probe.done("Browser", "本地书源交互任务", "local_action", task_span, "RESULT_DELIVERED")
            else
                local status = reason == "timeout" and "TIMEOUT"
                    or (reason == "child_exited_without_end" and "MISSING_END"
                    or (ok and "MISSING_RESULT" or "WORKER_FAILED"))
                Probe.fail("Browser", "本地书源交互任务", "local_action", task_span, status)
            end
            router:close()
            current_reply = nil
            if page then page:close(); page = nil end
            close_spinner()
            if callback then
                if unsupported_browser and not cancelled then
                    callback(false, Browser.UNSUPPORTED_MESSAGE)
                elseif ok and has_result and not cancelled then
                    callback(true, result)
                else
                    callback(false, not cancelled and (reason == "timeout"
                        and "书源任务超时，请重试" or "书源任务未完整结束，请重试") or nil)
                end
            end
        end,
    })
    return handle
end

return M
