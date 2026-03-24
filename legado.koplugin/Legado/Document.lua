local CreDocument = require("document/credocument")
local DocSettings = require("docsettings")
local logger = require("logger")
local util = require("util")
local DocSettings = require("docsettings")
local H = require("Legado/Helper")
local Backend = require("Legado/Backend")


local Document= CreDocument:extend{
    _is_browser_book = nil,
    _is_cache_book = nil,
}

function Document:init()
    CreDocument.init(self)
    if self:is_legado_browser_book() then
        self._is_browser_book = true
    end
    if self:is_legado_cache_file() then
        self._is_cache_book = true
    end
end

function Document:is_legado_browser_book(file_path)
    file_path = file_path or self.file
    return type(file_path) == "string"
                and file_path:find("/Legado\u{200B}书目/", 1, true)
                and file_path:find("\u{200B}.html", 1, true)
end

function Document:is_legado_path(file_path)
    file_path = file_path or self.file
    return type(file_path) == 'string' and file_path:lower():find('/cache/legado.cache/', 1, true) or false
end

function Document:is_legado_cache_file(file_path)
    file_path = file_path or self.file
    if type(file_path) ~= "string" then return false end

    local extension = file_path:match("%.([^%.]+)$")
    return self:is_legado_path(file_path) 
        and extension 
        and extension:lower():match("^html?$|^xhtml$|^txt$")
end

function Document:get_book_info_from_lnk(fullpath)
     local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, fullpath)
     if ok and H.is_tbl(lnk_config) and lnk_config.readSetting then
        return lnk_config:readSetting("book_cache_id"), lnk_config
     end
    local doc_settings = DocSettings:open(fullpath)
    if doc_settings then
        return doc_settings:readSetting("book_cache_id"), doc_settings
    end
end

function Document:get_book_info_from_shared(fullpath)
    if not H.is_str(fullpath) then return end
    local directory, file_name = util.splitFilePathName(fullpath)
    -- onSaveSettings
    local shared_data = Backend:sharedChapterMetadata(directory)
    if H.is_tbl(shared_data ) and H.is_tbl(shared_data .data) and H.is_tbl(shared_data .data.bookinfo) then
        return shared_data .data.bookinfo
    end
end

-- getDocumentProps Override custom metadata
function Document:getProps()
    local base_props = CreDocument.getProps(self)
    -- logger.info("Document:getProps_is_browser_book", self._is_browser_book)
    if H.is_tbl(base_props) and self.file  then
        if self._is_browser_book then
            local book_cache_id, lnk_config = self:get_book_info_from_lnk(self.file)
            if H.is_tbl(lnk_config) and H.is_tbl(lnk_config.data) then
                -- title authors description book_cache_id
                -- series series_index language keywords identifiers
                for k, v in pairs(lnk_config.data) do
                    base_props[k] = v
                end
            end
        elseif self._is_cache_book then
               local book_mate = self:get_book_info_from_shared(self.file)
                if H.is_tbl(book_mate) then
                    for k, v in pairs(shared_data .data.bookinfo) do
                        base_props[k] = v
                    end
                end
        end
    end
    return base_props
end

-- Alternative to custom cover
function Document:getCoverPageImage()
    local doc_path = self.file
    local custom_cover_file

    if self._is_browser_book or self._is_cache_book then
        if self._is_cache_book then
            local cover_dir = util.splitFilePathName(doc_path)
            local  cover_path_no_ext = cover_dir .. "/cover"
            custom_cover_file = Backend:findCustomCoverFileInDir(cover_path_no_ext)
        elseif self._is_browser_book then
            local book_id = self:get_book_info_from_lnk(doc_path)
            if book_id then
                custom_cover_file = Backend:get_default_cover_cache(book_id)  
            end
        end

        if custom_cover_file then 
            local DocumentRegistry = require("document/documentregistry")
            local cover_doc = DocumentRegistry:openDocument(custom_cover_file)
            if cover_doc then
                local ok, cover_bb = pcall(cover_doc.getCoverPageImage, cover_doc)
                cover_doc:close()
                if ok and cover_bb then return cover_bb end 
            end
                -- todo moren fengmian  down tasker
        end
    end

    return CreDocument.getCoverPageImage(self)
end

function Document:register(registry)
    registry:addProvider("html", "text/html", self, 150)
    registry:addProvider("htm", "text/html", self, 150)
end

return Document
