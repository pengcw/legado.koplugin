local M = {
    ctx = nil,
    _selected_book = nil,
    _displayed_chapter = nil,
    _chapter_direction = nil,
    _readerui_is_showing = nil,
    
    last_page_turn_time = nil,
    last_reader_ready_time = nil,
    ui_refresh_time = nil, 
    
    book_links_homedir = nil, 
    shared_meta_data = nil, 
    shared_meta_data_directory = nil,
    
    plg_name = nil,
    plg_path = nil,
    is_low_version = nil,
    last_search_input = nil,
}

local is_str = function(s)
    return "string" == type(s)
end

local is_tbl = function(t)
    return "table" == type(t)
end

local is_boolean = function(t)
    return "boolean" == type(t)
end

function M:readingChapter(chapter)
    if is_tbl(chapter) and chapter.book_cache_id then
        M._displayed_chapter = chapter
        return M._displayed_chapter
    else
        local current = M._displayed_chapter
        if is_tbl(current) and current.book_cache_id then
            return current
        end
    end
end

function M:currentSelectedBook(book)
    if is_tbl(book) and book.cache_id then
        M._selected_book = book
    end
    return M._selected_book
end

function M:chapterDirection(direction)
    if is_str(direction) then
        if direction == "prev" or direction == "next" then
            M._chapter_direction = direction
        elseif direction == "nil" then
            M._chapter_direction = nil
        end
    end
    return M._chapter_direction
end

function M:readerUiVisible(is_showing)
    if is_boolean(is_showing) then
        M._readerui_is_showing = is_showing
    end
    return M._readerui_is_showing
end

function M:sharedMetaData(dir, meta_data)
    if dir and meta_data then
        M.shared_meta_data_directory = dir
        M.shared_meta_data = meta_data
    end
    if is_str(M.shared_meta_data_directory) and M.shared_meta_data_directory == dir then
        return M.shared_meta_data
    end
    return nil
end

function M:getUI()
    return self.ctx and self.ctx.ui
end

function M:isReaderOpen()
    local ui = self:getUI()
    return ui ~= nil and ui.name == "ReaderUI"
end

function M:getDocument()
    local ui = self:getUI()
    return ui and ui.document
end

return M
