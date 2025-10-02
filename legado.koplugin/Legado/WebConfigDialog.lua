
local UIManager = require("ui/uimanager")
local socket_url = require("socket.url")
local util = require("util")
local logger = require("logger")

local ButtonDialog = require("ui/widget/buttondialog")
local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local M = {
    refresh_library = nil,
    manager_menu = nil,
}

function M:openWebConfigTypeSelector()
    local dialog
    local on_select = function(server_type)
        UIManager:close(dialog)
        self:openWebConfigEditorWithType(nil, nil, server_type)
    end
    dialog = ButtonDialog:new{
        title = "选择配置类型 (新建)",
        title_align = "center",
        buttons = {{{
            text = "手机 APP", callback = function()
                on_select(1)
        end,}}, {{
            text = "轻阅读后端", callback = function()
                on_select(3)
        end,}}, {{
            text = "Reader3 服务器版", callback = function()
                on_select(2)
        end,}},},
    }
    UIManager:show(dialog)
end

function M:getUrlHintByType(server_type)
    local hints = {
        [1] = "手机APP WEB服务地址 (如: http://127.0.0.1:1122)",
        [2] = "(如: http://127.0.0.1:1122 - 会自动添加/reader3)",
        [3] = "(如: http://127.0.0.1:1122 - 会自动添加/api/5)"
    }
    return hints[server_type] or "WEB地址 (必填)"
end

function M:openWebConfigManager(callback)
    if callback then
        self.refresh_library = callback
    end
    -- 无参数刷新
    if not callback and self.manager_menu then
        UIManager:close(self.manager_menu)
    end

    local settings = Backend:getSettings()
    local web_configs = settings.web_configs or {}
    local config_buttons = {}
    
    table.insert(config_buttons, {{
        text = Icons.FA_PLUS .. " 新增配置",
        callback = function()
            self:openWebConfigTypeSelector()
        end
    }})

    for config_name, config in pairs(web_configs) do
        local is_current = (config_name == settings.current_conf_name)
        table.insert(config_buttons, {{
            text = string.format("%s %s%s",
                is_current and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE, config_name,
                is_current and " (当前)" or "" ),
            callback = function()
                self:openWebConfigEditorWithType(config_name, config, config.type, is_current)
            end,
            hold_callback = function()
                if is_current then return end
                MessageBox:confirm(
                    string.format("确定要切换到配置 \"%s\" 吗？", config_name),
                    function(result)
                        if result then
                            Backend:HandleResponse(Backend:switchWebConfig(config_name), function(data)
                                UIManager:close(self.manager_menu)
                                MessageBox:notice("配置切换成功")
                                if H.is_func(self.refresh_library) then
                                    self:refresh_library()
                                end
                            end, function(err_msg)
                                MessageBox:error('切换失败：', tostring(err_msg))
                            end)
                        end
                    end, {
                        ok_text = "切换",
                        cancel_text = "取消"
                    })
            end,
        }})
    end

    local has_web_configs_item = next(web_configs) ~= nil
    table.insert(config_buttons, {{
        text = has_web_configs_item and "(点击编辑，长按切换)" or "(暂无配置，点击上方新增)",
        enabled = false
    }})

    self.manager_menu = ButtonDialog:new{
        title = "Legado WEB 配置管理",
        title_align = "center",
        buttons = config_buttons,
    }
    UIManager:show(self.manager_menu)
end

function M:openWebConfigEditorWithType(config_name, config, server_type, is_current)
    local is_edit = config_name ~= nil
    local type_names = {
        [1] = "手机APP",
        [2] = "Reader3 服务器版", 
        [3] = "轻阅读后端"
    }

    local name_input = config_name or ""
    local url_input = config and config.url or "http://"
    local desc_input = config and config.desc or ""
    local username_input = config and config.user or ""
    local password_input = config and config.pwd or ""
    
    -- 根据编辑模式获取当前类型，否则使用传入的类型
    local current_type = is_edit and (config and config.type or 1) or server_type

    local title = string.format("%s WEB 配置 - %s", 
        is_edit and "编辑" or "新增", 
        type_names[current_type] or "未知类型")

    local fields = {{
            text = name_input,
            hint = "配置名称 (必填)",
        }, {
            text = url_input,
            hint = self:getUrlHintByType(current_type),
            input_type = "text",
        }, {
            text = desc_input,
            hint = "描述 (可选)",
        },}
        
    if current_type == 2 or current_type == 3 then
        local hint_info = current_type == 2 and "可选" or "必填"
        table.insert(fields, {
            text = username_input,
            hint = string.format("用户名 (%s)", hint_info),
        })
        table.insert(fields, {
            text = password_input,
            hint = string.format("用户名 (%s)", hint_info),
            text_type = "password",
        })
    end

    local dialog
    local buttons = {{{
                    text = "取消",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                }, {
                    text = is_edit and "修改" or "创建",
                    callback = function()
                        self:handleConfigSave(dialog, config_name, config, current_type, is_edit)
                    end,
                }}}
    
    if is_edit then
          table.insert(buttons[1], 2, {
                    text = "删除",
                    callback = function()
                        if is_current then
                            return MessageBox:error("不能删除当前激活配置")
                        end
                        MessageBox:confirm(
                            string.format("确定要删除配置 \"%s\" 吗？", config_name),
                            function(result)
                                if result then
                                    Backend:HandleResponse(Backend:deleteWebConfig(config_name), function(data)
                                        UIManager:close(dialog)
                                        MessageBox:notice("配置删除成功")
                                        self:openWebConfigManager()
                                    end, function(err_msg)
                                        MessageBox:error('删除失败：', tostring(err_msg))
                                    end)
                                end
                            end, {
                                ok_text = "删除",
                                cancel_text = "取消"
                            })
                    end,
                })
    end 

    dialog = require("ui/widget/multiinputdialog"):new{
        title = title,
        fields = fields,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function M:handleConfigSave(dialog, current_conf_name, old_config, server_type, is_edit)
    local fields = dialog:getFields()
    local config_name = util.trim(fields[1] or "")
    local url = util.trim(fields[2] or "")
    local description = util.trim(fields[3] or "")
    local user, pwd
    
    -- 根据类型获取
    if server_type == 2 or server_type == 3 then
        user = util.trim(fields[4] or "")
        pwd = util.trim(fields[5] or "")
    end
    if H.is_tbl(old_config) and old_config.type and old_config.type ~= server_type then
        return MessageBox:notice("不支持修改类型")
    end
    if H.is_str(current_conf_name) and current_conf_name ~= config_name then
        return MessageBox:notice("不支持修改配置名称")
    end
    Backend:HandleResponse(Backend:saveWebConfig(current_conf_name, {
        edit_name = config_name,
        url = url,
        desc = description,
        type = server_type,
        user = user,
        pwd = pwd,
    }), function(data)
        UIManager:close(dialog)
        MessageBox:notice(is_edit and "配置更新成功" or "配置创建成功")
        self:openWebConfigManager()
    end, function(err_msg)
        MessageBox:error((is_edit and '更新失败：' or '创建失败：'), tostring(err_msg))
    end)
end

return M