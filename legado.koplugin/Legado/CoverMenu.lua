local NetworkMgr = require("ui/network/manager")
local Font = require("ui/font")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Menu = require("ui/widget/menu")
local util = require("util")
local UIManager = require("ui/uimanager") 
local Geom = require("ui/geometry")
local Size = require("ui/size")

local H = require("Legado/Helper")
local TaskQueue = require("Legado.async")
local Backend = require("Legado/Backend")

local M = Menu:extend{
    _cover_channel = nil,
    _debounce_timer_cancel = nil,
    _last_page_summary = nil,
    _is_closed = nil,
    is_enable_shortcut = false,
}

-- fix the Koreader crash when `no_title = true`.
function M:mergeTitleBarIntoLayout()
    if self.no_title then return end
    Menu.mergeTitleBarIntoLayout(self)
end

function M:init()
    self._is_closed = false
    Menu.init(self)
end

function M:_isCoverEnabled()
    return self.show_cover
        and H.is_tbl(self.item_table)
        and #self.item_table > 0
        and not self:_isEmptyHint()
end

local function downloadCover(url, book_cache_id)
    if type(book_cache_id) ~= "string" then return false end
    local cover_cache_path = Backend:get_default_cover_cache(book_cache_id)
    local exists = cover_cache_path and util.fileExists(cover_cache_path)
    if not exists then
        if type(url) ~= "string" or url == "" then
            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            url = bookinfo and bookinfo.coverUrl
        end
        if type(url) == "string" and url ~= "" then
            cover_cache_path = Backend:download_cover_img(book_cache_id, url)
            exists = cover_cache_path and util.fileExists(cover_cache_path)
        end
    end
    return exists == true
end

local function buildCoverState(item, cover_w, cover_h)
    if type(item) ~= "table" then return nil end
    item._is_cover_state = true

    local book_cache_id = item.cache_id
    if book_cache_id and book_cache_id ~= "" then
        local cover_cache_path = Backend:get_default_cover_cache(book_cache_id)
        if cover_cache_path and util.fileExists(cover_cache_path) then
            item.state = CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                ImageWidget:new{ 
                    file = cover_cache_path,
                    width = cover_w,
                    height = cover_h, 
                    scale_factor = 0, 
                    file_do_cache = true,
                    alpha = false,
                    use_legacy_image_scaling = true,
                }
            }
            return cover_cache_path
        end
    end

    local border = Size.border.thin
    local in_w, in_h = cover_w - 2 * border, cover_h - 2 * border
    item.state = FrameContainer:new{
        width = cover_w, height = cover_h, 
        bordersize = border, margin = 0, padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = in_w, h = in_h },
            TextBoxWidget:new{
                text = "⛶",
                face = Font:getFace("cfont", math.floor(in_h * 0.2)),
                width = in_w, alignment = "center",
            }
        }
    }
    return nil
end

function M:_updateCoverItems()
    local perpage = self.perpage
    local current_page = self.page
    local total_items = #self.item_table
    local idx_offset = (current_page - 1) * perpage
    local cover_h = self._cached_cover_h
    local cover_w = self._cached_cover_w

    local items_on_page = math.min(perpage, total_items - idx_offset)
    -- rebuild state for current page to avoid use-after-free
    for idx = 1, items_on_page do
        local item = self.item_table[idx_offset + idx]
        if type(item) == "table" then
            if not cover_h then
                if item._is_cover_state then item.state = nil end
            else
                item._is_cover_loaded = buildCoverState(item, cover_w, cover_h) 
            end
        end
    end

    if not cover_h or items_on_page == 0 then return end

    -- find first valid book item for page summary
    local first_item = self.item_table[idx_offset + 1]
    if not (first_item and first_item.cache_id and first_item.cache_id ~= "") then 
        first_item = self.item_table[idx_offset + 2]
        if not (first_item and first_item.cache_id and first_item.cache_id ~= "") then
            return
        end
    end

    -- skip async download if page hasn't changed
    local new_summary = first_item.cache_id .. "_" .. tostring(perpage)
    if new_summary == self._last_page_summary then return end

    self._last_page_summary = new_summary
    self._cover_channel = self._cover_channel or TaskQueue:createChannel("Menu_Covers", 4)
    self._cover_channel:clearTasks()
    
    if self._debounce_timer_cancel then
        self._debounce_timer_cancel()
    end

    if not NetworkMgr:isConnected() then return end

    self._debounce_timer_cancel = TaskQueue.delay(1, function()
        self._debounce_timer_cancel = nil
        if self._is_closed or self.page ~= current_page then return end

        local missing = {}
        local seen = {}
        for idx = 1, items_on_page do
            local item = self.item_table[idx_offset + idx]
            if item and item.cache_id and item.cache_id ~= "" then
                if not item.cover_url then
                    local bookinfo = Backend:getBookInfoCache(item.cache_id)
                    item.cover_url = bookinfo and bookinfo.coverUrl
                end
                if item.cover_url and item.cover_url ~= ""
                   and not item._is_cover_loaded and not seen[item.cache_id] then
                    missing[#missing + 1] = { item = item }
                    seen[item.cache_id] = true
                end
            end
        end

        if #missing == 0 then return end

        local pending_refresh = false
        self._cover_channel:executeBatch({
            items = missing,
            task_func = downloadCover,
            max_retries = 2,
            get_task_args = function(req)
                return { req.item.cover_url, req.item.cache_id }
            end,
            on_item_end = function(_, req, success)
                if self._is_closed or self.page ~= current_page then return false end
                if success and req and req.item and not pending_refresh then
                    pending_refresh = true
                    UIManager:nextTick(function()
                        pending_refresh = false
                        if not self._is_closed then
                            self:updateItems(nil, true)
                        end
                    end)
                end
                return false 
            end
        })
    end) 
end

function M:_isEmptyHint()
    return H.is_tbl(self.item_table)
        and #self.item_table == 1
        and self.item_table[1].select_enabled == false
end

function M:_recalculateDimen()
    if not self:_isEmptyHint() then
        local settings = Backend:getSettings()
        local default_items = settings.show_cover and 10 or (G_reader_settings:readSetting("items_per_page") or 14)
        self.items_per_page = settings.items_per_page or default_items
    end
    Menu._recalculateDimen(self)
    if self.item_dimen then
        self._cached_cover_h = self.item_dimen.h - 2 * Size.line.medium 
        self._cached_cover_w = math.floor(self._cached_cover_h * 2 / 3)
        if self:_isCoverEnabled() then
            self.state_w = self._cached_cover_w + 8 * Size.padding.small
        else
            self.state_w = nil
        end
    end
end

function M:updateItems(select_number, no_recalculate_dimen)
    self.show_cover = (Backend:getSettings().show_cover == true)
    if not no_recalculate_dimen then self:_recalculateDimen() end

    if self:_isCoverEnabled() then
        self:_updateCoverItems()
    elseif H.is_tbl(self.item_table) then
        for _, item in ipairs(self.item_table) do
            if type(item) == "table" and item._is_cover_state then
                item.state = nil
            end
        end
    end
    return Menu.updateItems(self, select_number, true)
end

function M:onCloseWidget()
    if self._cover_channel then self._cover_channel:clearTasks() end
    self._last_page_summary = nil
    self._is_closed = true
    if self._debounce_timer_cancel then
        self._debounce_timer_cancel()
        self._debounce_timer_cancel = nil
    end
    Menu.onCloseWidget(self)
end

return M