local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local M = {}
local HtmlDialog = InputContainer:extend{modal = true}

function HtmlDialog:init()
    local width = math.floor(Screen:getWidth() * 0.95)
    local padding = Size.padding.default
    local content_width = width - 2 * (padding + Size.border.window)
    local gap = Size.padding.default
    local title = TextBoxWidget:new{
        text = self.preview.dialog_title or ("网页预览：" .. tostring(self.preview.title or "")),
        face = Font:getFace("x_smalltfont"),
        width = content_width,
    }
    self.buttons = {{{text = "关闭", callback = function() self:onClose() end}}}
    local buttons = ButtonTable:new{
        width = content_width,
        buttons = self.buttons,
        show_parent = self,
    }
    local available_height = Screen:getHeight() - title:getSize().h - buttons:getSize().h
        - 2 * (padding + Size.border.window) - gap - Screen:scaleBySize(16)
    self.html_widget = ScrollHtmlWidget:new{
        html_body = self.preview.html,
        css = self.preview.css,
        is_xhtml = false,
        default_font_size = Screen:scaleBySize(20),
        width = content_width,
        height = math.max(1, math.min(math.floor(Screen:getHeight() * 0.60), available_height)),
        dialog = self,
        parent = self,
        not_focusable = true,
        highlight_text_selection = false,
        html_link_tapped_callback = nil,
        html_resource_directory = self.preview.resource_directory,
    }
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        margin = 0,
        padding = padding,
        VerticalGroup:new{
            align = "left",
            title,
            VerticalSpan:new{width = gap},
            self.html_widget,
            buttons,
        },
    }
    self.movable = MovableContainer:new{frame}
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
    if Device:hasKeys() then
        self.key_events.Close = {{Device.input.group.Back}}
        self.key_events.ScrollUp = {{Device.input.group.PgBack}}
        self.key_events.ScrollDown = {{Device.input.group.PgFwd}}
    end
end

function HtmlDialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.movable.dimen end)
    return true
end

function HtmlDialog:onClose()
    UIManager:close(self)
    return true
end

function HtmlDialog:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.movable.dimen end)
end

function HtmlDialog:onScrollUp()
    return self.html_widget:onScrollUp()
end

function HtmlDialog:onScrollDown()
    return self.html_widget:onScrollDown()
end

function M.show(preview)
    local dialog = HtmlDialog:new{preview = preview}
    UIManager:show(dialog)
    return dialog
end

return M
