local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")

local Backend = require("Legado/Backend")
local Env = require("Legado.Helper.Env")
local FS = require("Legado.Helper.FS")
local H = require("Legado/Helper")
local MessageBox = require("Legado/MessageBox")
local TaskProg = require("Legado.task.Progress")
local TaskQueue = require("Legado.task.Queue")

local CACHE_DIRECTORY_SUFFIX = ".sdr"
local SCAN_REUSE_SECONDS = 60
local recent_scan

local function formatCacheProgress(summary)
    return (summary.total_count or 0) > 0
        and string.format("%d / %d 章", summary.cached_count or 0, summary.total_count)
        or string.format("%d 章", summary.cached_count or 0)
end

local function fileAttributes(path)
    local fn = lfs.symlinkattributes or lfs.attributes
    local ok, attr = pcall(fn, path)
    return ok and attr or nil
end

local function isChapterPayload(entry, attr, is_root)
    if not is_root or not attr or attr.mode ~= "file"
            or (tonumber(attr.size) or 0) <= 0 then
        return false
    end
    if entry:match("^cover%.") then return false end

    local extension = entry:match("%.([^%.]+)$")
    if not extension then return false end
    local ext_map = Env.CHAPTER_CACHE_EXTENSIONS
    if ext_map then
        return ext_map[extension] == true or ext_map[extension:lower()] == true
    end
    return false
end

local function scanCacheDirectories(root)
    local summaries = {}

    local function scanDirectory(path, is_root)
        local size, chapter_count = 0, 0
        local ok, iterator, state = pcall(lfs.dir, path)
        if not ok or not iterator then return size, chapter_count end

        pcall(function()
            for entry in iterator, state do
                if entry ~= "." and entry ~= ".." then
                    local child = FS.joinPath(path, entry)
                    local attr = fileAttributes(child)
                    if attr and attr.mode == "file" then
                        size = size + (tonumber(attr.size) or 0)
                        if isChapterPayload(entry, attr, is_root) then
                            chapter_count = chapter_count + 1
                        end
                    elseif attr and attr.mode == "directory" then
                        size = size + scanDirectory(child, false)
                    end
                end
            end
        end)
        return size, chapter_count
    end

    local ok, iterator, state = pcall(lfs.dir, root)
    if not ok or not iterator then return summaries end
    pcall(function()
        for entry in iterator, state do
            if entry ~= "." and entry ~= ".."
                    and entry:sub(-#CACHE_DIRECTORY_SUFFIX) == CACHE_DIRECTORY_SUFFIX then
                local cache_id = entry:sub(1, -#CACHE_DIRECTORY_SUFFIX - 1)
                local path = FS.joinPath(root, entry)
                local attr = fileAttributes(path)
                if cache_id ~= "" and attr and attr.mode == "directory" then
                    local size, chapter_count = scanDirectory(path, true)
                    if chapter_count > 0 then
                        table.insert(summaries, {
                            cache_id = cache_id,
                            size = size,
                            cached_count = chapter_count,
                        })
                    end
                end
            end
        end
    end)
    return summaries
end

local M = Menu:extend{
    name = "cache_manager",
    title = "缓存管理",
    subtitle = "书名排序 · 长按刷新按钮切换",
    _sort_mode = "name",
    align_baselines = true,
    is_borderless = true,
    covers_fullscreen = true,
    single_line = false,
    title_bar_left_icon = "cre.render.reload",
    _scan_token = 0,
    _scan_pid = nil,
    _scan_progress = nil,
    title_bar_fm_style = true,
}

function M:init()
    Menu.init(self)
    self:refreshItems(true)
end

function M:generateEmptyViewItemTable()
    return {{
        text = "暂无缓存目录",
        dim = true,
        select_enabled = false,
    }}
end

function M:generateItemTable(summaries)
    local items = {}
    for _, summary in ipairs(summaries) do
        local title = summary.name or "未关联缓存"
        local author = summary.author or summary.cache_id
        local progress
        if summary.total_count > 0 then
            progress = string.format("%d/%d", summary.cached_count, summary.total_count)
        else
            progress = string.format("%d 章", summary.cached_count)
        end
        table.insert(items, {
            cache_id = summary.cache_id,
            summary = summary,
            text = string.format("《%s》 (%s)", title, author),
            mandatory = string.format("%s · %s", FS.formatFileSize(summary.size), progress),
        })
    end
    return items
end

function M:_cancelScan()
    self._scan_token = self._scan_token + 1
    if self._scan_pid then
        pcall(ffiUtil.terminateSubProcess, self._scan_pid)
        self._scan_pid = nil
    end
end

function M:_closeScanProgress()
    if self._scan_progress then
        self._scan_progress:close()
        self._scan_progress = nil
    end
end

function M:_updateItems(summaries, no_recalculate_dimen)
    self._summaries = summaries
    table.sort(summaries, function(a, b)
        if self._sort_mode == "size" and a.size ~= b.size then return a.size > b.size end
        local a_name, b_name = a.name or a.cache_id, b.name or b.cache_id
        if a_name ~= b_name then return a_name < b_name end
        return a.cache_id < b.cache_id
    end)
    if #summaries > 0 then
        self.item_table = self:generateItemTable(summaries)
        self.multilines_show_more_text = false
        self.items_per_page = nil
    else
        self.item_table = self:generateEmptyViewItemTable()
        self.multilines_show_more_text = true
        self.items_per_page = 1
    end
    Menu.updateItems(self, nil, no_recalculate_dimen)
end

function M:_enrichSummaries(scanned)
    local summaries = {}
    local cached_info = Backend.dbManager:getAllBookCacheInfo()
    for _, disk in ipairs(scanned or {}) do
        local info = cached_info[disk.cache_id] or {}
        table.insert(summaries, {
            cache_id = disk.cache_id,
            bookinfo = info.book_self_id and info or nil,
            name = info.name,
            author = info.author,
            cached_count = disk.cached_count or 0,
            total_count = info.total_count or 0,
            size = disk.size or 0,
        })
    end
    return summaries
end

function M:refreshItems(no_recalculate_dimen, force_refresh)
    self:_cancelScan()
    self:_closeScanProgress()
    local token = self._scan_token
    local cache_root = Env.getTempDirectory()
    if force_refresh then recent_scan = nil end
    if recent_scan and recent_scan.root == cache_root then
        local elapsed = os.time() - recent_scan.updated_at
        if elapsed >= 0 and elapsed < SCAN_REUSE_SECONDS then
            self:_updateItems(self:_enrichSummaries(recent_scan.scanned), no_recalculate_dimen)
            return
        end
    end

    if not self._summaries then self:_updateItems({}, no_recalculate_dimen) end

    self._scan_progress = TaskProg.showSpinner("正在统计缓存")
    self._scan_pid = TaskQueue.spawnProcess(function()
        return scanCacheDirectories(cache_root)
    end, function(ok, scanned)
        if token ~= self._scan_token then return end
        self._scan_pid = nil
        self:_closeScanProgress()
        if not ok or not H.is_tbl(scanned) then
            MessageBox:error("缓存扫描失败，请稍后重试")
            return
        end

        local summaries = self:_enrichSummaries(scanned)
        recent_scan = {root = cache_root, updated_at = os.time(), scanned = scanned}
        self:_updateItems(summaries, no_recalculate_dimen)
    end)
end

function M:forceRefresh()
    self:refreshItems(true, true)
end

function M:onLeftButtonTap()
    self:forceRefresh()
end

function M:setSortMode(mode)
    self._sort_mode = mode
    self.page, self.itemnumber = 1, nil
    self.subtitle = (mode == "size" and "占用大小排序" or "书名排序") .. " · 长按刷新按钮切换"
    if self.title_bar then self.title_bar:setSubTitle(self.subtitle, true) end
    self:_updateItems(self._summaries or {}, true)
end

function M:onLeftButtonHold()
    local dialog
    local function select(mode)
        UIManager:close(dialog)
        self:setSortMode(mode)
    end
    dialog = require("ui/widget/buttondialog"):new{
        title = "排序方式",
        buttons = {{
            {text = "书名", callback = function() select("name") end},
            {text = "占用大小", callback = function() select("size") end},
        }},
    }
    UIManager:show(dialog)
end

function M:showBookActions(item)
    if not item or not item.cache_id then return end
    local summary = item.summary or {}
    local bookinfo = Backend:getBookInfoCache(item.cache_id)
    local associated = H.is_tbl(bookinfo) and bookinfo.cache_id == item.cache_id
    if not associated then bookinfo = summary.bookinfo or summary end
    local dialog
    local actions = {{
        text = "清理缓存",
        callback = function()
            UIManager:close(dialog)
            self:confirmClean(bookinfo, summary)
        end,
    }}

    if associated then
        table.insert(actions, 1, {
            text = "缓存全书",
            callback = function()
                UIManager:close(dialog)
                require("Legado/ExportDialog"):new{bookinfo = bookinfo}:cacheAllChapters(function()
                    self:forceRefresh()
                end)
            end,
        })
        table.insert(actions, 2, {
            text = "导出书籍",
            callback = function()
                UIManager:close(dialog)
                require("Legado/ExportDialog"):new{bookinfo = bookinfo}:exportBook()
            end,
        })
    elseif summary.bookinfo then
        table.insert(actions, 1, {
            text = "离线导出",
            callback = function()
                UIManager:close(dialog)
                require("Legado/ExportDialog"):new{bookinfo = bookinfo}:exportBook(true)
            end,
        })
    end

    dialog = require("ui/widget/buttondialog"):new{
        title = string.format("《%s》 (%s)\n\n已缓存：%s\n缓存占用：%s",
            bookinfo.name or "未关联缓存",
            bookinfo.author or item.cache_id,
            formatCacheProgress(summary), FS.formatFileSize(summary.size or 0)),
        buttons = { actions, {
            {
                text = "取消",
                callback = function() UIManager:close(dialog) end,
            },
        }},
    }
    UIManager:show(dialog)
end

function M:confirmClean(bookinfo, summary)
    local cache_id = summary.cache_id or bookinfo.cache_id
    MessageBox:confirm(string.format(
        "请确认清除《%s》的章节缓存：\n\n已缓存：%s\n缓存占用：%s",
        bookinfo.name or "未关联缓存",
        formatCacheProgress(summary),
        FS.formatFileSize(summary.size or 0)
    ), function(result)
        if not result then return end
        Backend:closeDbManager()
        TaskProg.loading("清理中 ", function()
            return Backend:purgeBookCache(cache_id)
        end, function(state, response)
            if state ~= true then
                MessageBox:error("清理失败：", tostring(response))
                return
            end
            Backend:HandleResponse(response, function()
                MessageBox:success("已清理")
                self:forceRefresh()
            end, function(err_msg)
                MessageBox:error("请稍后重试：", err_msg)
            end)
        end)
    end, {
        title = string.format("《%s》 (%s)",
            bookinfo.name or "未关联缓存",
            bookinfo.author or cache_id),
        ok_text = "清理",
        cancel_text = "取消",
    })
end

function M:confirmClearAll(on_done)
    MessageBox:confirm(
        "是否清空本地书架所有已缓存章节与阅读记录？\n（刷新会重新下载）",
        function(result)
            if not result then return end
            Backend:closeDbManager()
            TaskProg.loading("清除中", function()
                return Backend:cleanAllBookCaches()
            end, function(state, response)
                if state ~= true then return end
                Backend:HandleResponse(response, function()
                    local settings = Backend:getSettings()
                    settings.servers_history = {}
                    Backend:saveSettings(settings)
                    MessageBox:notice("已清除")
                    recent_scan = nil
                    if H.is_func(on_done) then on_done() end
                end, function(err_msg)
                    MessageBox:error("操作失败：", tostring(err_msg))
                end)
            end)
        end, { ok_text = "清空", cancel_text = "取消" })
end

function M:onMenuChoice(item)
    if item and item.select_enabled ~= false then
        self:showBookActions(item)
    end
    return true
end

function M:onCloseWidget()
    self:_cancelScan()
    self:_closeScanProgress()
    Menu.onCloseWidget(self)
end

function M:open()
    local manager = M:new{}
    UIManager:show(manager)
    return manager
end

return M
