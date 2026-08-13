-- ZipUtil.lua

local util = require("util")
local logger = require("logger")

local ZipUtil = {}

local Writer = {}
Writer.__index = Writer

function Writer:new()
    local o = {
        backend = nil,
        backend_type = nil,
        closed = true,
        _last_method = nil, -- avoid repeated set
    }
    setmetatable(o, Writer)
    do
        local ok, archiver = pcall(require, "ffi.archiver")
        -- require may return true on missing module, check type
        if ok and type(archiver) == "table" and archiver.Writer then
            local w_ok, writer = pcall(
                archiver.Writer.new,
                archiver.Writer
            )
            if w_ok and writer then
                o.backend = writer
                o.backend_type = "archiver"
                return o
            end
        end
    end

    do
        local ok, zipwriter = pcall(require, "ffi.zipwriter")
        if ok and type(zipwriter) == "table" and zipwriter.new then
            local w_ok, writer = pcall(
                zipwriter.new,
                zipwriter
            )
            if w_ok and writer then
                o.backend = writer
                o.backend_type = "zipwriter"
                return o
            end
        end
    end
    error("ZipUtil.Writer: no zip backend available")
end

function Writer:open(zipfilepath)
    if not zipfilepath or zipfilepath == "" then
        return nil, "invalid zip file path"
    end
    self:close()
    if not self.backend then return nil, "no zip backend" end
    local ok, result
    if self.backend_type == "archiver" then
        ok, result = pcall(
            self.backend.open,
            self.backend,
            zipfilepath,
            "zip"
        )
    else
        ok, result = pcall(
            self.backend.open,
            self.backend,
            zipfilepath
        )
    end
    if not ok then
        self.closed = true
        return nil, result
    end
    if not result then
        self.closed = true
        return nil, self.backend.err or "open failed"
    end
    self.closed = false
    self._last_method = nil
    return self
end

function Writer:add(
    in_zip_filepath,
    content,
    no_compression
)
    if self.closed or not self.backend then
        return false, "zip writer is not open"
    end

    if not in_zip_filepath or in_zip_filepath == "" then
        return false, "invalid entry path"
    end
    if content == nil then return false, "content is nil" end
    if type(content) ~= "string" then return false, "content must be a string" end
    local ok, result
    if self.backend_type == "archiver" then
        -- set compression before addFileFromMemory()
        local method = no_compression and "store" or "deflate"
        ok, result = pcall(
            function()
                if self._last_method ~= method then
                    local compression_ok = self.backend:setZipCompression(method)
                    if not compression_ok then return false end
                    self._last_method = method
                end
                return self.backend:addFileFromMemory(
                    in_zip_filepath,
                    content,
                    os.time()
                )
            end
        )
    else
        -- zipwriter.add handles store/deflate internally
        ok, result = pcall(
            self.backend.add,
            self.backend,
            in_zip_filepath,
            content,
            no_compression
        )
    end
    if not ok then return false, result end
    -- archiver: true=ok, nil/false=fail
    -- zipwriter add(): no return, always ok
    if self.backend_type == "archiver" and result ~= true then
        return false, self.backend.err or "add failed"
    end
    return true
end

function Writer:close()
    if self.closed then return true end
    self.closed = true
    if not self.backend then return true end
    local ok, result = pcall(self.backend.close, self.backend)
    if not ok then
        return false, result
    end
    -- archiver.Writer.close no return value
    if result == false then
        return false, self.backend.err or "close failed"
    end
    return true
end

local gc_ok, ffi_gc = pcall(require, "ffi/__gc")
if gc_ok and type(ffi_gc) == "function" then
    ffi_gc(Writer, {
        __gc = function(t)
            pcall(function() t:close() end)
        end
    })
end

ZipUtil.Writer = Writer

local Reader = {}
Reader.__index = Reader

local function shell_escape(s)
    return tostring(s or ""):gsub("'", "'\\''")
end

-- libarchive may shift zip perm bits (0644 -> 0o1204; &0777 -> 0204),
-- leaving extracted files unreadable. chmod only when open fails;
-- normal files are untouched (a failed open may just mean a missing file)
local function ensure_file_readable(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return -- readable, nothing to fix
    end
    os.execute(string.format("chmod 0644 '%s' 2>/dev/null", shell_escape(path)))
end

local function chmod_tree(root)
    if not util.directoryExists(root) then return end
    util.findFiles(root, function(path, fname, attr)
        if not (attr and attr.mode == "directory") then
            ensure_file_readable(path)
        end
    end, true)
end

local function unzip_available()
    local probe = os.execute("command -v unzip >/dev/null 2>&1")
    return probe == 0 or probe == true
end

function Reader:new()
    local ok, Archiver = pcall(require, "ffi.archiver")
    if ok and type(Archiver) == "table" and type(Archiver.Reader) == "table" then
        local r_ok, archive = pcall(Archiver.Reader.new, Archiver.Reader)
        if r_ok and archive then
            local o = {
                _mode = "archiver",
                _archive = archive,
                _path = nil,
            }
            setmetatable(o, Reader)
            return o
        end
    end
    if unzip_available() then
        logger.info("ZipUtil.Reader: using unzip CLI fallback")
        local o = {
            _mode = "unzip_cli",
            _path = nil,
            _tmp_dir = nil,
            _extracted = false,
        }
        setmetatable(o, Reader)
        return o
    end
    return nil, "no zip reader available"
end

-- true or nil, err
function Reader:open(path)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid zip file path"
    end
    if self._mode == "archiver" then
        pcall(function() self._archive:close() end)
        self._archive.size = 0
        self._archive.entries = {}
        if not self._archive:open(path) then
            return nil, self._archive.err or "open failed"
        end
        self._path = path
        return true
    end
    -- open only stores path; re-open cleans old temp dir and resets state.
    if self._tmp_dir and util.directoryExists(self._tmp_dir) then
        util.removePath(self._tmp_dir)
    end
    self._extracted = false
    self._tmp_dir = nil
    self._path = path
    return true
end

local function ensure_extracted(self)
    if self._extracted then return true end
    if not self._path then return nil, "zip not opened" end
    if not self._tmp_dir then
        local f = os.tmpname()
        os.remove(f) -- tmpname path usually doesn't exist, remove just in case.
        self._tmp_dir = f
    end
    local make_ok, make_err = util.makePath(self._tmp_dir)
    if not make_ok and not util.directoryExists(self._tmp_dir) then
        return nil, "cannot create temporary directory: " .. tostring(make_err)
    end
    local cmd = string.format("unzip -qqo '%s' -d '%s'",
        shell_escape(self._path), shell_escape(self._tmp_dir))
    local ok = os.execute(cmd)
    self._extracted = (ok == 0 or ok == true)
    if not self._extracted then
        return nil, "unzip command failed: " .. self._path
    end
    return true
end

-- Iterate entries; callback(entry) returning false early terminates (unzip_cli doesn't support early termination)
-- entry: { path = relative_path, mode = "file"|"directory"|"other", size = bytes }
function Reader:iterate(callback)
    if type(callback) ~= "function" then return end
    if self._mode == "archiver" then
        for entry in self._archive:iterate() do
            if callback(entry) == false then break end
        end
        return
    end
    local ok, err = ensure_extracted(self)
    if not ok then error(err) end
    util.findFiles(self._tmp_dir, function(path, fname, attr)
        local rel = path:sub(#self._tmp_dir + 2)
        local mode = (attr and attr.mode == "directory") and "directory" or "file"
        callback({ path = rel, mode = mode, size = (attr and attr.size) or 0 })
    end, false)
end

function Reader:extractToMemory(path)
    if self._mode == "archiver" then
        -- archiver's seek relies on an entries cache (filled only by iterate);
        -- iterate once first, otherwise entries are never found
        if self._archive.entries and not next(self._archive.entries) then
            for _ in self._archive:iterate() do end
        end
        local data = self._archive:extractToMemory(path)
        if data == nil then
            return nil, self._archive.err or ("no such entry: " .. tostring(path))
        end
        return data
    end
    local ok, err = ensure_extracted(self)
    if not ok then return nil, err end
    local target = self._tmp_dir .. "/" .. path
    local data = util.readFromFile(target, "rb")
    if not data then
        -- maybe unreadable: chmod then retry once
        ensure_file_readable(target)
        data = util.readFromFile(target, "rb")
        if not data then
            return nil, "no such entry: " .. tostring(path)
        end
    end
    return data
end

-- Full extract to dir, supports exclude_patterns (string or table, plain match)
-- returns extract_ok, extract_err
function Reader:extractAll(dest_dir, exclude_patterns)
    local patterns = {}
    if type(exclude_patterns) == "string" then
        patterns = { exclude_patterns }
    elseif type(exclude_patterns) == "table" then
        patterns = exclude_patterns
    end

    if not util.directoryExists(dest_dir) then
        local ok, err = util.makePath(dest_dir)
        if not ok and not util.directoryExists(dest_dir) then
            return false, "无法创建目标目录: " .. tostring(err)
        end
    end

    if self._mode == "archiver" then
        local extract_ok, extract_err = false, nil
        local extracted = 0
        local iterate_ok, err = pcall(function()
            extract_ok = true
            for entry in self._archive:iterate() do
                local skip = false
                for _, pattern in ipairs(patterns) do
                    if entry.path:find(pattern, 1, true) then skip = true; break end
                end
                if not skip then
                    local target_full_path = dest_dir .. "/" .. entry.path
                    local parent_dir
                    if entry.mode == "directory" then
                        parent_dir = target_full_path
                    else
                        parent_dir = util.splitFilePathName(target_full_path)
                    end
                    if parent_dir and not util.directoryExists(parent_dir) then
                        local make_ok, make_err = util.makePath(parent_dir)
                        if not make_ok and not util.directoryExists(parent_dir) then
                            error("failed to create directory: " .. tostring(make_err))
                        end
                    end
                    if entry.mode ~= "directory" then
                        if entry.mode ~= "file" then
                            error("unsupported entry type: " .. tostring(entry.mode))
                        end
                        if not self._archive:extractToPath(entry.path, target_full_path) then
                            error(self._archive.err or ("failed to extract " .. entry.path))
                        end
                        -- write_disk may restore unreadable perms; ensure readable after extract
                        ensure_file_readable(target_full_path)
                    end
                end
                extracted = extracted + 1
            end
        end)
        if not iterate_ok then
            extract_ok, extract_err = false, err
        end
        if extract_ok and extracted == 0 then
            extract_ok, extract_err = false, "压缩包为空，没有提取到任何文件"
        end
        return extract_ok, extract_err
    end

    -- unzip -x uses wildcard matching, different from archiver branch's plain substring semantics
    local exclude_args = ""
    if #patterns > 0 then
        local escaped = {}
        for _, p in ipairs(patterns) do
            escaped[#escaped + 1] = "'" .. shell_escape(p) .. "'"
        end
        exclude_args = " -x " .. table.concat(escaped, " ")
    end
    local cmd = string.format("unzip -qo '%s' -d '%s'%s",
        shell_escape(self._path), shell_escape(dest_dir), exclude_args)
    local result = os.execute(cmd)
    if result == 0 or result == true then
        -- Empty archive check (target dir should have no files)
        local count = 0
        util.findFiles(dest_dir, function() count = count + 1 end, true)
        if count == 0 then return false, "压缩包为空，没有提取到任何文件" end
        chmod_tree(dest_dir)
        return true, nil
    end
    return false, "unzip command failed"
end

function Reader:close()
    if self._mode == "archiver" and self._archive then
        pcall(function() self._archive:close() end)
    end
    if self._tmp_dir and util.directoryExists(self._tmp_dir) then
        util.removePath(self._tmp_dir)
        self._tmp_dir = nil
    end
end

ZipUtil.Reader = Reader

-- ==========================================
-- ComicInfo.xml for CBZ (appended at the end of the zip)
-- bookinfo optional: { name, author, kind, intro }; missing fields left empty
-- ==========================================
function ZipUtil.createComicInfo(bookinfo, total_pages)
    bookinfo = bookinfo or {}
    local function escape_xml(str)
        if not str then return "" end
        return tostring(str):gsub("&", "&amp;")
            :gsub("<", "&lt;")
            :gsub(">", "&gt;")
            :gsub("\"", "&quot;")
            :gsub("'", "&apos;")
    end
    local page_count = tonumber(total_pages) or 0
    return string.format([[<?xml version="1.0" encoding="utf-8"?>
<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <Title>%s</Title>
  <Series>%s</Series>
  <Writer>%s</Writer>
  <Publisher>Legado</Publisher>
  <Genre>%s</Genre>
  <PageCount>%d</PageCount>
  <Summary>%s</Summary>
  <LanguageISO>zh</LanguageISO>
  <Manga>Yes</Manga>
</ComicInfo>]],
        escape_xml(bookinfo.name),
        escape_xml(bookinfo.name),
        escape_xml(bookinfo.author),
        escape_xml(bookinfo.kind or "漫画"),
        page_count,
        escape_xml(bookinfo.intro or "")
    )
end

return ZipUtil
