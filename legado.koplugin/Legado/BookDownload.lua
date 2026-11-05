local util = require("util")
local urlutil = require("socket.url")
local M = {}
local download_active = false

local function temporaryPath(output_dir)
    local temp = os.tmpname()
    os.remove(temp)
    return require("Legado.Helper.FS").joinPath(
        output_dir, ".legado-download-" .. temp:match("[^/]+$") .. ".part")
end

local function start(resource, output_dir)
    local Backend = require("Legado/Backend")
    local MessageBox = require("Legado/MessageBox")
    if download_active then
        MessageBox:notice("已有资源下载任务，请等待完成后再下载")
        return
    end
    if not require("ui/network/manager"):isConnected() then
        return MessageBox:notice("当前无网络连接")
    end
    local Progress = require("Legado.task.Progress")
    if not require("util").directoryExists(output_dir) then
        return MessageBox:error("选择的目录不可用")
    end
    local temp = temporaryPath(output_dir)
    download_active = true
    local ok, err = pcall(Progress.loading, {
        text = "下载资源…",
        dismissable = true,
        runnable = function()
            local BookUtil = require("Legado.spore.bookutil")
            local checked, message = BookUtil.resolveDownloadResource(
                { name = resource.name, downloadUrls = resource.url },
                { data = { header = resource.headers } }, resource)
            if not checked then return { type = "ERROR", message = message } end
            local path
            path, message = BookUtil.downloadResource(checked, temp, output_dir)
            return { type = path and "SUCCESS" or "ERROR", body = path, message = message }
        end,
        on_cancel = function(pid)
            if pid then pcall(require("ffi/util").terminateSubProcess, pid) end
        end,
        callback = function(ok, response)
            download_active = false
            os.remove(temp)
            if not ok then
                if response ~= "cancelled" then MessageBox:error("下载任务失败") end
                return
            end
            Backend:HandleResponse(response, function(path)
                local UIManager = require("ui/uimanager")
                local dialog
                dialog = require("ui/widget/buttondialog"):new{
                    title = "下载完成，文件已保存：\n" .. path,
                    buttons = {{
                        {
                            text = "关闭",
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = "删除",
                            callback = function()
                                UIManager:close(dialog)
                                MessageBox:confirm("删除下载的文件？\n" .. path, function(remove)
                                    if not remove then return end
                                    local ok, err = os.remove(path)
                                    if not ok then MessageBox:error("删除失败：", err) end
                                end, {ok_text = "删除", cancel_text = "取消"})
                            end,
                        },
                        {
                            text = "打开",
                            callback = function()
                                UIManager:close(dialog)
                                require("Legado/ExportDialog"):showReaderUI(path)
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
            end, function(err)
                MessageBox:error("下载失败：", err)
            end)
        end,
    })
    if not ok then
        download_active = false
        os.remove(temp)
        MessageBox:error("下载任务启动失败：", tostring(err))
    end
end

function M.downloadResource(resource)
    local MessageBox = require("Legado/MessageBox")
    if download_active then return MessageBox:notice("已有资源下载任务，请等待完成后再下载") end
    if not require("ui/network/manager"):isConnected() then
        return MessageBox:notice("当前无网络连接")
    end
    local UIManager = require("ui/uimanager")
    UIManager:show(require("ui/widget/pathchooser"):new{
        title = "选择下载目录",
        path = require("Legado.Helper.Env").getHomeDir(),
        select_directory = true,
        select_file = false,
        onConfirm = function(output_dir) start(resource, output_dir) end,
    })
end

function M.extract(content)
    local links, seen = {}, {}
    local function add(raw, label, decode)
        local url = util.trim(decode and util.htmlEntitiesToUtf8(raw) or raw)
        if not url:match("^https?://") then return end
        local parsed = urlutil.parse(url)
        if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https")
                or not parsed.host or parsed.userinfo or url:find("[%s%c]") then return end
        if not seen[url] then
            seen[url] = true
            links[#links + 1] = {url = url, label = label, headers = {}}
        end
    end
    local function text(raw, decode)
        raw = decode and util.htmlEntitiesToUtf8(raw) or raw
        for url in raw:gmatch("https?://[^%s<>\"']+") do
            local trimmed
            repeat
                trimmed = false
                for _, suffix in ipairs({"，", "。", "；", "！", "？", "、"}) do
                    if url:sub(-#suffix) == suffix then
                        url = url:sub(1, -#suffix - 1)
                        trimmed = true
                        break
                    end
                end
            until not trimmed
            add(url, nil, false)
        end
    end
    if not content:find("<[%a!/]" ) then
        text(content, false)
        return links
    end
    local ok, root = pcall(require("htmlparser").parse, content, 10000)
    if not ok or not root then return nil, "正文 HTML 解析失败" end
    local source = root:gettext()
    local skipped = {head = true, script = true, style = true, svg = true}
    local function walk(node, first, last)
        local name = node.name:lower()
        if skipped[name] then return end
        if name == "a" then
            for key, value in pairs(node.attributes) do
                if key:lower() == "href" then
                    add(value, util.htmlToPlainText(node:getcontent()), true)
                    break
                end
            end
        end
        local cursor = first
        for _, child in ipairs(node.nodes) do
            text(source:sub(cursor, child._openstart - 1), true)
            walk(child, child._openend + 1, child._closestart - 1)
            cursor = child._closeend + 1
        end
        text(source:sub(cursor, last), true)
    end
    local body = root("body")[1]
    if body then walk(body, body._openend + 1, body._closestart - 1)
    else walk(root, 1, #source) end
    return links
end

function M.readChapter(chapter, skeleton_path)
    local Backend = require("Legado/Backend")
    local Store = require("Legado.Skeleton.BookStore")
    local request = {}
    for key, value in pairs(chapter) do request[key] = value end
    if request.cacheFilePath and not util.fileExists(request.cacheFilePath) then request.cacheFilePath = nil end
    local cached = Backend:getCacheChapterFilePath(request, true)
    local path = cached and cached.cacheFilePath
    if path and path:lower():match("%.cbz$") then return nil, "当前章节为漫画，无可扫描文本" end
    local ext = path and path:lower():match("%.([^./]+)$")
    if ext and ext ~= "html" and ext ~= "htm" and ext ~= "xhtml" and ext ~= "txt" then
        return nil, "当前章节无可扫描文本"
    end
    if path and util.fileExists(path) then
        local data = util.readFromFile(path)
        if data and data ~= "" and not Store:isPlaceholder(data) then return data end
    end
    if skeleton_path then
        local Epub = require("Legado.Skeleton.Epub")
        local metadata = Epub.readSkeletonMetadata(skeleton_path)
        if not metadata or metadata.book_cache_id ~= chapter.book_cache_id then
            return nil, "骨架书籍身份校验失败"
        end
        local reader = require("Legado.Helper.ZipUtil").Reader:new()
        local opened, err = reader:open(skeleton_path)
        if not opened then return nil, err end
        local ok, data = pcall(reader.extractToMemory, reader, Epub.getChapterEntryPath(chapter.chapters_index))
        reader:close()
        if ok and data and data ~= "" and not Store:isPlaceholder(data) then return data end
    end
    return nil, "当前章节尚未缓存，请等待正文加载或缓存后重试"
end

function M.showResources(ui)
    local State = require("Legado/PlgState")
    local MessageBox = require("Legado/MessageBox")
    local chapter = State:readingChapter()
    local skeleton_path
    if State:isFullBookMode() then
        skeleton_path = ui and ui.document and ui.document.file
        local settings = skeleton_path and require("docsettings"):open(skeleton_path)
        local id = settings and settings:readSetting("book_cache_id")
        chapter = id and require("Legado.Skeleton.Reader"):resolveChapter(ui, id)
    end
    if not chapter or chapter.chapters_index == nil then
        return MessageBox:notice("无法定位当前章节，请返回正文后重试")
    end
    local content, message = M.readChapter(chapter, skeleton_path)
    if not content then return MessageBox:notice(message) end
    local links, err = M.extract(content)
    if not links then return MessageBox:error(err) end
    if #links == 0 then
        return MessageBox:confirm("仅用于资源(下载)型书源，当前未发现有效资源", nil, {
            no_ok_button = true,
            cancel_text = "确定",
            dismissable = false,
        })
    end
    local UIManager = require("ui/uimanager")
    local menu
    local items = {}
    local endpoint_ext = {php = true, asp = true, aspx = true, jsp = true, cgi = true}
    for index, resource in ipairs(links) do
        local parsed = urlutil.parse(resource.url)
        local name = resource.label and util.trim(resource.label)
        if not name or name == "" or name:match("^https?://") then
            name = urlutil.unescape((parsed.path or ""):match("([^/]+)$") or "")
            local ext = name:lower():match("%.([%w]+)$")
            if not ext or endpoint_ext[ext] then name = "资源链接 " .. index end
        end
        name = name:gsub("[%c%s]+", " ")
        items[#items + 1] = {
            text = name .. " · " .. parsed.host,
            resource = resource,
            callback = function()
                UIManager:close(menu)
                M.downloadResource(resource)
            end,
        }
    end
    menu = require("ui/widget/menu"):new{
        title = "提取资源 · " .. (chapter.title or "当前章节"),
        subtitle = "点击选择下载，长按查看完整链接",
        item_table = items,
        onMenuHold = function(_, item)
            MessageBox:info(item.resource.url)
            return true
        end,
    }
    UIManager:show(menu)
end

return M
