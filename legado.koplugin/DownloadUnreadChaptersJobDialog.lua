local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Icons = require("libs/Icons")
local logger = require('logger')

--- @class DownloadUnreadChaptersJobDialog
--- @field job DownloadUnreadChapters
--- @field show_parent unknown
--- @field cancellation_requested boolean
--- @field dismiss_callback fun():nil|nil
local DownloadUnreadChaptersJobDialog = InputContainer:extend{
    show_parent = nil,
    modal = true,
    -- The `DownloadUnreadChapters` job.
    job = nil,
    -- If cancellation was requested.
    cancellation_requested = false,
    -- A callback to be called when dismissed.
    dismiss_callback = nil,
    job_inspection_interval = 1
}

function DownloadUnreadChaptersJobDialog:init()
    local widget, _ = self:pollAndCreateTextWidget()
    self[1] = widget
end

local function overrideInfoMessageDismissHandler(widget, new_dismiss_handler)
    -- Override the default `onTapClose`/`onAnyKeyPressed` actions
    local originalOnTapClose = widget.onTapClose
    widget.onTapClose = function(messageSelf)
        new_dismiss_handler()

        originalOnTapClose(messageSelf)
    end

    local originalOnAnyKeyPressed = widget.onAnyKeyPressed
    widget.onAnyKeyPressed = function(messageSelf)
        new_dismiss_handler()

        originalOnAnyKeyPressed(messageSelf)
    end
end

function DownloadUnreadChaptersJobDialog:pollAndCreateTextWidget()
    local state = self.job:poll()
    local message = '正在下载章节'

    if state.type == 'SUCCESS' then
        message = self.cancellation_requested and '下载已取消!' or '下载完成!'
    elseif state.type == 'PENDING' then
        if self.cancellation_requested then
            message = "正在等待下载被取消…"
        elseif state.body.type == 'INITIALIZING' then
            message = "正在下载章节，这将需要一段时间…"
        else
            message = string.format("正在下载章节，这将需要一段时间… (%s / %s)", state.body.downloaded,
                state.body.total)
        end
    elseif state.type == 'ERROR' then
        message = '下载章节时出错： ' .. state.message
    end

    if type(state.body) == 'table' and type(state.body.message) == 'string' then
        message = state.body.message
    end

    local is_cancellable = state.type == 'PENDING' and not self.cancellation_requested
    local is_finished = state.type ~= 'PENDING'

    local widget = InfoMessage:new{
        modal = false,
        text = ("%s %s"):format(Icons.FA_HOURGLASS, message),
        show_icon = false,
        dismissable = is_cancellable or is_finished
    }

    overrideInfoMessageDismissHandler(widget, function()
        if is_cancellable then
            self:onCancellationRequested()

            return
        end

        self:onDismiss()
    end)

    return widget, is_finished
end

function DownloadUnreadChaptersJobDialog:show()
    UIManager:show(self)

    UIManager:nextTick(self.updateProgress, self)
end

function DownloadUnreadChaptersJobDialog:updateProgress()
    -- Unschedule any remaining update calls we might have.
    UIManager:unschedule(self.updateProgress)

    local old_message_size = self[1]:getVisibleArea()
    -- Request a redraw of the component we're drawing over.
    UIManager:setDirty(self.show_parent, function()
        return 'ui', old_message_size
    end)

    local widget, is_finished = self:pollAndCreateTextWidget()
    self[1] = widget
    self.dimen = nil

    -- Request a redraw of ourselves.
    UIManager:setDirty(self, 'ui')

    if not is_finished then
        UIManager:scheduleIn(self.job_inspection_interval, self.updateProgress, self)
    end
end

function DownloadUnreadChaptersJobDialog:onCancellationRequested()
    self.job:requestCancellation()
    self.cancellation_requested = true

    UIManager:nextTick(self.updateProgress, self)
end

function DownloadUnreadChaptersJobDialog:onDismiss()
    UIManager:close(self)

    if self.dismiss_callback ~= nil then
        self.dismiss_callback()
    end
end

return DownloadUnreadChaptersJobDialog
