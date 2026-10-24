local M = {
    _selected_book = nil,
    _displayed_chapter = nil,
    _chapter_direction = nil,
    _readerui_is_showing = nil,
    _reading_mode = nil,
    _reading_book_cache_id = nil,
    _reading_container = nil,
    _reading_route_source = nil,

    last_page_turn_time = nil,
    ui_refresh_time = nil,

    shared_meta_data = nil,
    shared_meta_data_directory = nil,

    plg_name = nil,
    plg_path = nil,
    is_low_version = nil,
    last_search_input = nil,

    _local_mode_states = {},
    LOCAL_MODE_ENTRY_ENABLED = true,

    _preload_task = nil,
    _preload_timer_cancel = nil,
    _open_entry = nil,
    _after_readui_open_callback = nil,
}

function M:cancelPreload(reason)
    if M._preload_timer_cancel then
        pcall(M._preload_timer_cancel)
        M._preload_timer_cancel = nil
    end
    if M._preload_task and M._preload_task.cancel then
        pcall(M._preload_task.cancel, M._preload_task, reason or "cancelled")
        M._preload_task = nil
    end
end

local is_str = function(s)
    return "string" == type(s)
end

local is_tbl = function(t)
    return "table" == type(t)
end

local is_boolean = function(t)
    return "boolean" == type(t)
end

function M:isLocalMode(conf_name, value)
    conf_name = conf_name or "default"
    if is_boolean(value) then
        M._local_mode_states[conf_name] = value
    end
    return M._local_mode_states[conf_name] == true
end

function M:isLocalModeEntryEnabled(value)
    if is_boolean(value) then
        M.LOCAL_MODE_ENTRY_ENABLED = value
    end
    return M.LOCAL_MODE_ENTRY_ENABLED == true
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

function M:readingMode(mode)
    if is_str(mode) then
        if mode == "full_book" or mode == "chapter_mode" then
            M._reading_mode = mode
        elseif mode == "nil" then
            M._reading_mode = nil
        end
    elseif mode == false or mode == nil then
        M._reading_mode = nil
    end
    return M._reading_mode
end

function M:readingRoute(book_cache_id, container, source)
    if is_str(book_cache_id) and is_str(container) then
        if container == "legacy" or container == "skeleton" or container == "stream" then
            M._reading_book_cache_id = book_cache_id
            M._reading_container = container
            M._reading_route_source = source
        end
    elseif is_str(book_cache_id) and M._reading_book_cache_id == book_cache_id then
        return M._reading_container, M._reading_route_source
    end
    return nil
end

function M:clearReadingRoute(book_cache_id)
    if book_cache_id == nil or M._reading_book_cache_id == book_cache_id then
        M._reading_book_cache_id = nil
        M._reading_container = nil
        M._reading_route_source = nil
    end
end

function M:isFullBookMode()
    return M._reading_mode == "full_book"
end

function M:entrySource(source)
    if is_str(source) or source == nil then
        M._open_entry = source
    end
    return M._open_entry
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

function M:afterReadUiOpenCallback(callback)
    if callback ~= nil then
        M._after_readui_open_callback = ("function" == type(callback)) and callback or nil
        return M._after_readui_open_callback
    else
        local cb = M._after_readui_open_callback
        M._after_readui_open_callback = nil
        return cb
    end
end

return M
