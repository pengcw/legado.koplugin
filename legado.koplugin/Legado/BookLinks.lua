local logger = require("logger")
local util = require("util")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Backend = require("Legado/Backend")
local Store = require("Legado.Skeleton.BookStore")
local NetworkMgr = require("ui/network/manager")
local H = require("Legado/Helper")
local FS = require("Legado.Helper.FS")
local Env = require("Legado.Helper.Env")

local function init_book_links(parent)
    if parent.book_links then
        return parent.book_links
    end

    local book_links = {
        parent = parent
    }

    function book_links:show_view(focused_file, selected_files)
        local homedir = self.parent:getBrowserHomeDir()
        if not homedir then return end
        local current_dir = self.parent:getBrowserCurrentDir()
        if current_dir and current_dir == homedir then
            if not self.parent.book_shelf then
                self.parent.book_shelf = self.parent:getMenuWidget()
            end
            self.parent.book_shelf:show_view()
            self.parent.book_shelf:refreshItems(true)
            return
        end
        self.parent:openLegadoFolder(homedir, focused_file, selected_files)
    end

    function book_links:goHome()
        if FileManager.instance then
            FileManager.instance:goHome()
        end
    end

    function book_links:refreshItems()
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end

    function book_links:deleteFile(file, is_file)
        self.parent:deleteFile(file, is_file)
    end

    function book_links:verifyBooksMetadata()
        local browser_homedir = self.parent:getBrowserHomeDir()
        if not util.directoryExists(browser_homedir) then return end
        local SkeletonEpub = require("Legado.Skeleton.Epub")

        util.findFiles(browser_homedir, function(fullpath, name)
            if not (util.fileExists(fullpath) and H.is_str(name) and name:find("\u{200B}.epub", 1, true)) then
                return
            end

            local doc_settings = DocSettings:open(fullpath)
            local book_cache_id = doc_settings and doc_settings:readSetting("book_cache_id")
            if not book_cache_id then
                local metadata = SkeletonEpub.readSkeletonMetadata(fullpath)
                book_cache_id = metadata and metadata.book_cache_id
            end
            if not book_cache_id then return end

            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                return
            end

            local ok_path = Store:ensureEpub(bookinfo, nil, fullpath)
            if ok_path and util.fileExists(ok_path) then
                self:refreshBookMetadata(ok_path, bookinfo)
            end
        end, false)
    end

    function book_links:addBookShortcut(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir() or Env.getLinksDir()
        if not home_dir then
            return nil, "本地书库保存目录不可用"
        end
        if not (H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            return nil, "书籍信息不完整，无法生成本地书籍"
        end

        local ReadingFlow = require("Legado.ReadingFlow")
        if not ReadingFlow:isSkeletonEnabled(bookinfo) then
            return nil, "当前阅读模式或书籍类型不支持生成整本 EPUB"
        end

        local epub_name = FS.getSafeFilename(string.format("%s-%s", bookinfo.name, bookinfo.author or "未知作者")) .. "\u{200B}.epub"
        local epub_path = FS.joinPath(home_dir, epub_name)
        local ok_path, build_err = Store:ensureEpub(bookinfo, nil, epub_path)
        if not ok_path then
            return nil, build_err or "生成整本 EPUB 失败"
        end
        if not util.fileExists(ok_path) then
            return nil, "EPUB 文件未生成或无法访问"
        end

        self:refreshBookMetadata(ok_path, bookinfo)
        if bookinfo.coverUrl and not Backend:get_default_cover_cache(bookinfo.cache_id) and NetworkMgr:isConnected() then
            Backend:launchProcess(function()
                return Backend:download_cover_img(bookinfo.cache_id, bookinfo.coverUrl)
            end)
        end
        return ok_path, epub_name
    end

    function book_links:refreshBookMetadata(epub_path, bookinfo)
        if not (H.is_str(epub_path) and H.is_tbl(bookinfo) and bookinfo.cache_id and bookinfo.name) then
            return
        end

        pcall(util.removeFile, epub_path .. ".old")

        local doc_settings = DocSettings:open(epub_path)
        doc_settings:saveSetting("provider", "legado")
        doc_settings:saveSetting("book_cache_id", bookinfo.cache_id)
        doc_settings:saveSetting("title", bookinfo.name)
        doc_settings:saveSetting("authors", bookinfo.author or "未知作者")
        doc_settings:saveSetting("description", bookinfo.intro or "")
        doc_settings:saveSetting("is_skeleton_epub", true)
        if doc_settings.flush then doc_settings:flush() end

        Backend:emitMetadataChanged(epub_path)
    end

    parent.book_links = book_links
    return book_links
end

return init_book_links