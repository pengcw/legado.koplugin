local M = {}

function M.new(book)
    return {
        inject_one = function(...) return require("Legado.Skeleton.BookStore"):syncChapter(...) end,
        inject_many = function(...) return require("Legado.Skeleton.BookStore"):syncChapters(...) end,
        request_refresh = function(...) return require("Legado.Skeleton.Refresh"):request(...) end,
        show_chapter_loading = function(...) return require("Legado.Skeleton.Refresh"):showLoading(...) end,
        hide_chapter_loading = function(...)
            local refresh = package.loaded["Legado.Skeleton.Refresh"]
            if refresh then return refresh:hideLoading(...) end
        end,
        sync_new_chapters = function(...)
            return (book or require("Legado.Skeleton.Book")):syncNewChapters(...)
        end,
        cleanup = function()
            local refresh = package.loaded["Legado.Skeleton.Refresh"]
            if refresh then return refresh:_clearPreloadRefreshScheduler() end
        end,
    }
end

return M
