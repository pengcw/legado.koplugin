local UIManager = require("ui/uimanager")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")
local util = require("util")
local Utf8Proc = require("ffi/utf8proc")

local M = {}

local function fetch_enabled_rules()
    local shelf_id = Backend:getCurrentBookShelfId() or "default"
    local db = Backend.dbManager
    if not db or type(db.getEnabledTextTransformRules) ~= "function" then
        return { error = "本地数据库不可用" }
    end

    local ok, rules = pcall(db.getEnabledTextTransformRules, db, shelf_id)
    if not ok then return { error = tostring(rules) } end
    if type(rules) ~= "table" then return { error = "替换规则数据格式错误" } end
    return {
        rules = rules,
        dialect = Backend:_getTextTransformDialect(),
    }
end

local function rule_text(value)
    if type(value) == "string" then return value end
    if type(value) == "number" then return tostring(value) end
    return ""
end

local function rule_name(rule)
    local name = util.trim(rule_text(rule.name))
    return name ~= "" and name or "未命名规则"
end

local function dialect_name(dialect)
    if dialect == "reader3" then return "Reader3" end
    if dialect == "qread" then return "轻阅读" end
    return "Legado"
end

local function target_name(rule, dialect)
    if dialect == "reader3" then return "标题+正文" end
    if rule.scopeTitle == true and rule.scopeContent == true then return "标题+正文" end
    if rule.scopeTitle == true then return "标题" end
    if rule.scopeContent == true then return "正文" end
    return "未设置"
end

local function scope_name(rule, dialect)
    local scope = util.trim(rule_text(rule.scope))
    if scope ~= "" then return scope end
    if dialect == "reader3" then return "未填写（不会匹配）" end
    return "全部书籍"
end

local function is_js_replacement(replacement, dialect)
    return dialect ~= "reader3" and replacement:match("^%s*@js:") ~= nil
end

local function preview(value)
    local text = rule_text(value):gsub("[\r\n\t]", " ")
    local chars = util.splitToChars(text)
    if #chars > 32 then return table.concat(chars, "", 1, 32) .. "…" end
    return text
end

local function show_rule(rule, dialect)
    local TextViewer = require("ui/widget/textviewer")
    local pattern, replacement = rule_text(rule.pattern), rule_text(rule.replacement)
    local lines = {
        rule_name(rule),
        "",
        "生效目标：" .. target_name(rule, dialect),
        "匹配方式：" .. (rule.isRegex == true and "正则表达式" or "普通文字"),
        "",
        "查找内容：",
        pattern ~= "" and pattern or "未设置匹配内容",
        "",
    }
    if replacement == "" then
        lines[#lines + 1] = "处理方式：删除匹配内容"
    else
        local js_replacement = is_js_replacement(replacement, dialect)
        lines[#lines + 1] = js_replacement and "替换方式：JavaScript" or "替换为："
        lines[#lines + 1] = "「" .. replacement .. "」"
        if js_replacement then
            lines[#lines + 1] = "（当前本地解析暂不支持 JS 替换，将跳过此规则）"
        elseif not replacement:find("%S") then
            lines[#lines + 1] = "（替换内容仅含空白字符，按原样保留）"
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "适用范围：" .. scope_name(rule, dialect)
    if dialect ~= "reader3" then
        local exclude_scope = util.trim(rule_text(rule.excludeScope))
        if exclude_scope ~= "" then
            lines[#lines + 1] = "排除范围：" .. exclude_scope
        end
    end

    local group = util.trim(rule_text(rule.group or rule.groupName))
    if group ~= "" then lines[#lines + 1] = "分组：" .. group end
    if dialect ~= "reader3" and rule.isRegex == true and type(rule.timeoutMs) == "number" then
        lines[#lines + 1] = "正则超时：" .. rule.timeoutMs .. " ms"
    end
    if type(rule.orderIndex) == "number" then lines[#lines + 1] = "规则顺序：" .. rule.orderIndex end
    local rule_key = util.trim(rule_text(rule.ruleKey))
    if rule_key ~= "" then lines[#lines + 1] = "规则标识：" .. rule_key end
    lines[#lines + 1] = "\n这里只查看已启用规则，不修改规则内容或生效方式。"
    local viewer
    viewer = TextViewer:new{
        title = "规则详情",
        text = table.concat(lines, "\n"),
        buttons_table = {{{
            text = "返回列表",
            callback = function() UIManager:close(viewer) end,
        }}},
    }
    UIManager:show(viewer)
end

local function show_rules(rules, dialect)
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, rule in ipairs(rules) do
        local pattern, replacement = rule_text(rule.pattern), rule_text(rule.replacement)
        local summary
        if replacement == "" then
            summary = "删除：" .. preview(pattern)
        elseif is_js_replacement(replacement, dialect) then
            summary = preview(pattern) .. " → JavaScript（暂不支持）"
        else
            summary = preview(pattern) .. " → " .. (replacement:find("%S") and preview(replacement) or "空白字符")
        end
        items[#items + 1] = {
            text = rule_name(rule) .. "\n" .. summary,
            mandatory = target_name(rule, dialect) .. " · " .. (rule.isRegex == true and "正则" or "文字"),
            rule = rule,
            search_text = Utf8Proc.lowercase(table.concat({
                rule_name(rule),
                pattern,
                replacement,
                rule_text(rule.scope),
                rule_text(rule.excludeScope),
                rule_text(rule.group or rule.groupName),
                rule_text(rule.ruleKey),
                target_name(rule, dialect),
            }, "\n")),
        }
    end
    local menu, query
    query = ""
    local function apply_filter(value)
        query = util.trim(value)
        local needle = Utf8Proc.lowercase(query)
        local filtered = {}
        for _, item in ipairs(items) do
            if needle == "" or item.search_text:find(needle, 1, true) then filtered[#filtered + 1] = item end
        end
        local subtitle = string.format("%s · 已启用 %d 条 · 点击查看详情", dialect_name(dialect), #items)
        if query ~= "" then
            subtitle = string.format("%s · 找到 %d/%d 条", dialect_name(dialect), #filtered, #items)
        end
        menu:switchItemTable(nil, filtered, nil, nil, subtitle)
        if #filtered == 0 then MessageBox:notice("没有匹配的规则，换个关键词试试") end
    end
    menu = Menu:new{
        title = "替换规则",
        subtitle = string.format("%s · 已启用 %d 条 · 点击查看详情", dialect_name(dialect), #items),
        item_table = items,
        items_max_lines = 2,
        title_bar_left_icon = "appbar.search",
        onLeftButtonTap = function()
            MessageBox:input("输入名称、匹配/替换内容或范围：", function(value)
                if value ~= nil then apply_filter(value) end
            end, {
                title = "搜索替换规则",
                input = query,
                input_hint = "留空显示全部规则",
            })
        end,
        onMenuSelect = function(_, item)
            show_rule(item.rule, dialect)
            return true
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

function M.show()
    Backend:closeDbManager()
    TaskProg.loading("正在读取本地替换规则...", fetch_enabled_rules, function(ok, result)
        if not ok then
            return MessageBox:error("读取替换规则失败: " .. tostring(result or "未知错误"))
        end
        if type(result) ~= "table" then
            return MessageBox:error("替换规则数据格式错误")
        end
        if result.error then
            return MessageBox:error("读取替换规则失败: " .. result.error)
        end
        if type(result.rules) ~= "table" or #result.rules == 0 then
            return MessageBox:notice("本地数据库中暂无已启用替换规则")
        end
        show_rules(result.rules, result.dialect)
    end)
end

return M
