local CreDocument = require("document/credocument")
local DocSettings = require("docsettings")
local logger = require("logger")
local util = require("util")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")
local Backend = require("Legado/Backend")

local Document= CreDocument:extend{
    provider = "legadodoc",
    provider_name = "Legado Document",
    _is_browser_book = nil,
    _is_cache_book = nil,
}

function Document:init()
    CreDocument.init(self)
    if Env.is_legado_cache_file(self.file) then
        self._is_cache_book = true
    elseif Env.is_legado_browser_book(self.file) then
        self._is_browser_book = true
    end
end

function Document:get_book_metadata_from_lnk(fullpath)
     if not H.is_str(fullpath) then return nil, nil end
     local ok, lnk_conf = pcall(Backend.getLuaConfig, Backend, fullpath)
     if ok and H.is_tbl(lnk_conf) and lnk_conf.readSetting then
        return lnk_conf:readSetting("book_cache_id"), lnk_conf
     end
    local doc_settings = DocSettings:open(fullpath)
    if doc_settings then
        return doc_settings:readSetting("book_cache_id"), doc_settings
    end
    return nil, nil
end

function Document:get_book_metadata_from_shared(fullpath)
    if not H.is_str(fullpath) then return nil end
    local directory, file_name = util.splitFilePathName(fullpath)
    if not H.is_str(directory) then return nil end
    -- onSaveSettings
    local shared_data = Backend:sharedChapterMetadata(directory)
    if H.is_tbl(shared_data) and H.is_tbl(shared_data.data) and H.is_tbl(shared_data.data.bookinfo) then
        return shared_data.data.bookinfo
    end
end

-- getDocumentProps Override custom metadata
function Document:getProps()
    local base_props = CreDocument.getProps(self)
    if not H.is_tbl(base_props) or not self.file then
        return base_props
    end

    if self._is_browser_book then
        local book_cache_id, lnk_conf = self:get_book_metadata_from_lnk(self.file)
        if H.is_tbl(lnk_conf) and H.is_tbl(lnk_conf.data) then
            -- title authors description book_cache_id
            -- series series_index language keywords identifiers
            for k, v in pairs(lnk_conf.data) do base_props[k] = v end
            base_props["keywords"] = "legado"
        end
    elseif self._is_cache_book then
        local book_metadata = self:get_book_metadata_from_shared(self.file)
        if H.is_tbl(book_metadata) then
            --  for k, v in pairs(book_metadata) do base_props[k] = v end
            base_props["title"] = book_metadata["title"] or base_props.title
            base_props["authors"] = book_metadata["authors"] or base_props.authors
            base_props["description"] = book_metadata["description"] or base_props.description
            base_props["book_cache_id"] = book_metadata["book_cache_id"]
            base_props["keywords"] = "legado"
        end
    end
    return base_props
end

function Document:getCoverPageImage()
    if not (self._is_browser_book or self._is_cache_book) then
        return CreDocument.getCoverPageImage(self)
    end

    local custom_cover_file
    if self._is_cache_book then
        local cover_dir = util.splitFilePathName(self.file)
        local  cover_path_no_ext = cover_dir .. "/cover"
        custom_cover_file = Backend:findCustomCoverFileInDir(cover_path_no_ext)
    elseif self._is_browser_book then
        local book_id = self:get_book_metadata_from_lnk(self.file)
        if book_id then
            custom_cover_file = Backend:get_default_cover_cache(book_id)  
        end
    end

    if custom_cover_file then 
        local DocumentRegistry = require("document/documentregistry")
        local cover_doc = DocumentRegistry:openDocument(custom_cover_file)
        if cover_doc then
            local success, cover_bb = pcall(cover_doc.getCoverPageImage, cover_doc)
            if cover_doc.close then cover_doc:close() end
            if success and cover_bb then return cover_bb end 
         end
        -- todo cover down tasker
    end

    return CreDocument.getCoverPageImage(self)
end

function Document:register(registry)
    registry:addProvider("html", "text/html", self, 150)
    registry:addProvider("htm", "text/html", self, 150)
    registry:addProvider("xhtm", "text/html", self, 150)
end

return Document
