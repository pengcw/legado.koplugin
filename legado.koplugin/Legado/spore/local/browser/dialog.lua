local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local Screen = require("device").screen
local MessageBox = require("Legado/MessageBox")
local M = {}
M.UNSUPPORTED_MESSAGE = "交互浏览需 KOReader 2025.06.1+"

function M.is_supported()
    return type(ButtonDialog.addWidget) == "function"
        and type(ButtonDialog.getAddedWidgetAvailableWidth) == "function"
end
local ACTION_CSS = [[
img { display: block; }
.legado-input, .legado-click {
    display: block;
    border: 1px solid #666;
    padding: 0.45em 0.6em;
    margin: 0.35em 0;
    text-decoration: underline;
}
]]
local DISPLAY_CSS = [[
* { color: #000 !important; background-color: transparent !important;
    font-size: inherit !important; }
body { color: #000 !important; background-color: #fff !important;
    margin: 0; padding: 0; font-size: %dpx !important; line-height: 1.3; }
h1 { font-size: 1.2em !important; margin: 0.4em 0 !important; }
h2, h3 { font-size: 1.1em !important; margin: 0.35em 0 !important; }
small { font-size: 0.85em !important; }
svg { width: 1em !important; height: 1em !important; }
img { max-width: 100%%; height: auto !important; }
a { text-decoration: underline !important; }
.legado-input, .legado-click {
    padding: 0.3em 0.45em !important; margin: 0.2em 0 !important;
}
]]

function M.show(snapshot, emit)
    if not M.is_supported() then
        return nil, M.UNSUPPORTED_MESSAGE
    end
    local page = {closed = false}
    local actions, revision, dialog, editor, content
    local pending = false
    local function close_editor()
        if editor then UIManager:close(editor); editor = nil end
    end
    function page:close()
        if self.closed then return end
        self.closed = true
        close_editor()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function finish(kind)
        if page.closed or (kind == "finish" and pending) then return end
        page:close()
        emit({kind = kind, revision = revision})
    end
    function page:update(next_snapshot)
        if self.closed then return false end
        if revision and next_snapshot.revision <= revision then return false end
        local previous_box = content and content.htmlbox_widget
        local previous_ratio = previous_box
            and (previous_box.page_number - 1) / previous_box.page_count or 0
        close_editor()
        if dialog then UIManager:close(dialog) end
        if pending then MessageBox:notice("操作已处理，页面已更新") end
        revision, actions, pending = next_snapshot.revision, {}, false
        for _, action in ipairs(next_snapshot.actions) do actions[action.uri] = action end
        local screen_height = Screen:getHeight()
        dialog = ButtonDialog:new{
            title = next_snapshot.title or "网页交互",
            width = math.floor(math.min(Screen:getWidth(), screen_height) * 0.95),
            tap_close_callback = function() finish("cancel") end,
            buttons = {{
                {text = "取消", callback = function() finish("cancel") end},
                {text = "✓ 完成", callback = function() finish("finish") end},
            }},
        }
        local function activate(link)
            local action = actions[link.uri]
            if page.closed or editor or not action then return end
            if action.kind == "click" then
                actions, pending = {}, true
                MessageBox:notice("已点击，正在处理")
                emit({kind = "click", revision = revision, uri = action.uri})
                return
            end
            if action.kind ~= "input" then return end
            local opened_revision = revision
            local input
            input = InputDialog:new{
                title = action.password and "输入密码" or "输入内容",
                input = action.value or "",
                text_type = action.password and "password" or nil,
                buttons = {{
                    {text = "取消", callback = function()
                        if editor == input then close_editor() end
                    end},
                    {text = "确认", callback = function()
                        if page.closed or editor ~= input or opened_revision ~= revision then return end
                        local value = input:getInputText()
                        close_editor()
                        actions, pending = {}, true
                        MessageBox:notice("输入已提交，正在处理")
                        emit({kind = "input", revision = revision, uri = action.uri, value = value})
                    end},
                }},
            }
            editor = input
            UIManager:show(input)
            input:onShowKeyboard()
        end
        local available_height = screen_height - dialog.movable[1]:getSize().h
            - Size.padding.default - Screen:scaleBySize(16)
        content = ScrollHtmlWidget:new{
            html_body = next_snapshot.html,
            css = ACTION_CSS .. "\n" .. (next_snapshot.css or "") .. "\n"
                .. string.format(DISPLAY_CSS, Screen:scaleBySize(20)),
            is_xhtml = false,
            width = dialog:getAddedWidgetAvailableWidth(),
            height = math.max(1, math.min(math.floor(screen_height * 0.75), available_height)),
            default_font_size = Screen:scaleBySize(20),
            dialog = dialog,
            parent = dialog,
            not_focusable = true,
            html_link_tapped_callback = activate,
            html_resource_directory = next_snapshot.resource_directory,
        }
        content.htmlbox_widget.onTapText = function(box, _, gesture)
            local pos = box:getPosFromAbsPos(gesture.pos)
            local link = pos and box:getLinkByPosition(pos)
            if link and actions[link.uri] then activate(link); return true end
        end
        dialog:addWidget(content)
        UIManager:show(dialog)
        if (next_snapshot.image_failures or 0) > 0 then
            MessageBox:notice("部分图片加载失败，请重试")
        end
        if previous_ratio > 0 then
            content:scrollToRatio(previous_ratio)
        end
        return true
    end
    page:update(snapshot)
    return page
end

return M
