-- Legado/BookBrowser.lua
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Backend = require("Legado/Backend")
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

        local function is_valid_book_file(fullpath, name)
            return util.fileExists(fullpath) and H.is_str(name) and name:find("\u{200B}.html", 1, true)
        end

        local function get_book_id(fullpath)
            local ok, lnk_conf = pcall(Backend.getLuaConfig, Backend, fullpath)
            if ok and H.is_tbl(lnk_conf) and lnk_conf.readSetting then
                local bid = lnk_conf:readSetting("book_cache_id")
                if bid then return bid end
            end
            local doc_settings = DocSettings:open(fullpath)
            return doc_settings:readSetting("book_cache_id")
        end

        util.findFiles(browser_homedir, function(fullpath, name)
            local is_html = is_valid_book_file(fullpath, name)
            local is_epub = util.fileExists(fullpath) and name:match("%.epub$") ~= nil
            if not (is_html or is_epub) then goto continue end

            local book_cache_id = get_book_id(fullpath)
            if not book_cache_id then
                self:deleteFile(fullpath, true)
                goto continue
            end

            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                goto continue
            end

            local ReadingFlow = require("Legado.ReadingFlow")
            if is_html and ReadingFlow:isSkeletonEnabled(bookinfo) then
                -- 平滑升级：先建后删
                local epub_name = FS.getSafeFilename(string.format("%s-%s.epub", bookinfo.name, bookinfo.author or "未知作者"))
                local epub_path = FS.joinPath(browser_homedir, epub_name)
                local ok_path = Backend:ensureVirtualBookEpub(bookinfo, nil, epub_path)
                if ok_path and util.fileExists(ok_path) then
                    self:bind_provider(ok_path)
                    self:refreshLnkMetadata(epub_name, ok_path, bookinfo)
                    self:deleteFile(fullpath, true)
                    goto continue
                end
            end

            self:refreshLnkMetadata(nil, fullpath, bookinfo)
            ::continue::
        end, true)
    end

    function book_links:wirteLnk(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            return
        end
        local book_name = bookinfo.name
        local book_lnk_name = Env.getLinkName(book_name, bookinfo.author)
        if not book_lnk_name then return end
        local book_lnk_path = FS.joinPath(home_dir, book_lnk_name)
        if book_lnk_path and util.fileExists(book_lnk_path) then
            return book_lnk_path, book_lnk_name
        end
        self:refreshLnkMetadata(book_lnk_name, book_lnk_path, bookinfo)
        return book_lnk_path, book_lnk_name
    end

    function book_links:addBookShortcut(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir() or Env.getLinksDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            return
        end

        local ReadingFlow = require("Legado.ReadingFlow")
        local is_skeleton = ReadingFlow:isSkeletonEnabled(bookinfo)

        if is_skeleton then
            local epub_name = FS.getSafeFilename(string.format("%s-%s.epub", bookinfo.name, bookinfo.author or "未知作者"))
            local epub_path = FS.joinPath(home_dir, epub_name)
            if util.fileExists(epub_path) then
                local attr = lfs.attributes(epub_path)
                if attr and attr.size > 1024 then
                    return epub_path, epub_name
                end
            end
            local ok_path = Backend:ensureVirtualBookEpub(bookinfo, nil, epub_path)
            if ok_path and util.fileExists(ok_path) then
                self:bind_provider(ok_path)
                self:refreshLnkMetadata(epub_name, ok_path, bookinfo)
                if bookinfo.coverUrl and not Backend:get_default_cover_cache(bookinfo.cache_id) and NetworkMgr:isConnected() then
                    Backend:launchProcess(function()
                        return Backend:download_cover_img(bookinfo.cache_id, bookinfo.coverUrl)
                    end)
                end
                return ok_path, epub_name
            end
        end

        local book_cache_id = bookinfo.cache_id
        local book_lnk_path, book_lnk_name = self:wirteLnk(bookinfo)
        if not (book_lnk_path and util.fileExists(book_lnk_path)) then
            return
        end

        self:bind_provider(book_lnk_path)

        if Backend:get_default_cover_cache(book_cache_id) then return end
        if not NetworkMgr:isConnected() then return end
        
        local cover_url = bookinfo.coverUrl
        if cover_url then
            Backend:runTaskWithRetry(function()
                if DocSettings:findCustomCoverFile(book_lnk_path) then
                    Backend:emitMetadataChanged(book_lnk_path)
                    return true
                end
            end, 12000, 2000)
            Backend:launchProcess(function()
                return Backend:download_cover_img(book_cache_id, cover_url)
            end, function(status, cover_path, cover_name)
                if status == true and cover_path and util.fileExists(cover_path) then
                    --DocSettings:flushCustomCover(book_lnk_path, cover_path)
                end
            end)
        end
        return book_lnk_path, book_lnk_name
    end

    function book_links:bind_provider(file)
        local doc_settings = DocSettings:open(file)
        local provider = doc_settings:readSetting("provider")
        if provider ~= "legado" then
            doc_settings:saveSetting("provider", "legado"):flush()
        end
        return doc_settings
    end

    function book_links:refreshLnkMetadata(lnk_name, lnk_path, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (H.is_str(lnk_name) and H.is_tbl(bookinfo) and bookinfo.cache_id and bookinfo.name) then
            return
        end

        local book_cache_id = bookinfo.cache_id
        local book_name = bookinfo.name
        local book_author = bookinfo.author or "未知作者"

        local lnk_conf = Backend:getLuaConfig(lnk_path)
        lnk_conf:saveSetting("book_cache_id", book_cache_id)
        lnk_conf:saveSetting("title", book_name)
        lnk_conf:saveSetting("authors", book_author)
        lnk_conf:saveSetting("description", bookinfo.intro or ""):flush()

        pcall(util.removeFile, lnk_path .. ".old")

        local doc_settings = self:bind_provider(lnk_path)
        if not doc_settings:readSetting("book_cache_id") then
            doc_settings:saveSetting("book_cache_id", book_cache_id):flush()
        end

        Backend:emitMetadataChanged(lnk_path)
    end

    parent.book_links = book_links
    return book_links
end

return init_book_links
