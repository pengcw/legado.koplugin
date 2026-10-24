
local bit = require("bit")
local ffi = require("ffi")
require("ffi/zlib_h")
local util = require("util")
local ffi_util = require("ffi/util")
local logger = require("logger")
local gc_ok, ffi_gc = pcall(require, "ffi/__gc")
local ok_archiver, archiver = pcall(require, "ffi.archiver")

local libarchive, libz
local has_archiver = false
local rewrite_buff, rewrite_size, rewrite_offs
local truncate_c
if ok_archiver  and type(archiver) == "table" and archiver.Writer then
    has_archiver = true
    rewrite_buff = ffi.new("const void *[1]")
    rewrite_size = ffi.new("size_t[1]")
    rewrite_offs = ffi.new("int64_t[1]")
    if ffi.abi("64bit") then
        pcall(ffi.cdef, "int truncate(const char *pathname, int64_t length);")
        truncate_c = function(path, len)
            return ffi.C.truncate(path, len)
        end
    else
        local ok_64 = pcall(ffi.cdef, "int truncate64(const char *pathname, int64_t length);")
        local has_64, sym_64 = pcall(function() return ffi.C.truncate64 end)
        if ok_64 and has_64 and sym_64 then
            truncate_c = function(path, len)
                return sym_64(path, len)
            end
        else
            pcall(ffi.cdef, "int truncate(const char *pathname, long length);")
            truncate_c = function(path, len)
                return ffi.C.truncate(path, tonumber(len))
            end
        end
    end
end

local ZipUtil = {}
function ZipUtil.isArchiverAvailable()
    return has_archiver == true
end

local Writer = {}
Writer.__index = Writer

function Writer:new()
    local o = {
        backend = nil,
        backend_type = nil,
        closed = true,
        _last_method = nil,
    }
    setmetatable(o, Writer)
    do
        if has_archiver then
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
        ok, result = pcall(function()
            self.backend:add(in_zip_filepath, content, no_compression)
            local flushed, err = self.backend.ziphandle:flush()
            if not flushed then error(err) end
        end)
    end
    if not ok then return false, result end
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
    if result == false then
        return false, self.backend.err or "close failed"
    end
    return true
end

if type(ffi_gc) == "function" then
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

local function ensure_file_readable(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return
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
    if self._tmp_dir and util.directoryExists(self._tmp_dir) then
        ffi_util.purgeDir(self._tmp_dir)
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
        os.remove(f)
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
    end, true)
end

function Reader:extractToMemory(path)
    if self._mode == "archiver" then
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
        ensure_file_readable(target)
        data = util.readFromFile(target, "rb")
        if not data then
            return nil, "no such entry: " .. tostring(path)
        end
    end
    return data
end

local function is_safe_entry_path(p)
    if not p or p == "" then return false end
    if p:byte(1) == 47 then return false end
    if p:match("^%a:") then return false end
    for seg in p:gmatch("[^/\\]+") do
        if seg == ".." then return false end
    end
    return true
end

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
                if not is_safe_entry_path(entry.path) then
                    error("unsafe entry path: " .. tostring(entry.path))
                end
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
        ffi_util.purgeDir(self._tmp_dir)
        self._tmp_dir = nil
    end
end

if type(ffi_gc) == "function" then
    ffi_gc(Reader, {
        __gc = function(t)
            pcall(function() t:close() end)
        end
    })
end

ZipUtil.Reader = Reader

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

local CRC32_TABLE
local function build_crc32_table()
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            local lsb = bit.band(c, 1)
            c = bit.rshift(c, 1)
            if lsb == 1 then c = bit.bxor(c, 0xEDB88320) end
        end
        t[i] = c
    end
    return t
end

function ZipUtil.crc32(data)
    if type(data) ~= "string" then return 0 end
    if not libz then libz = ffi.loadlib("z", 1) end
    if libz and  libz.crc32 then
        return tonumber(libz.crc32(0, data, #data)) % 4294967296
    end
    CRC32_TABLE = CRC32_TABLE or build_crc32_table()
    local c = 0xFFFFFFFF
    for i = 1, #data do
        c = bit.bxor(CRC32_TABLE[bit.band(bit.bxor(c, data:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return bit.band(bit.bnot(c), 0xFFFFFFFF) % 4294967296
end

local EOCD_SIG = "\80\75\5\6"
local CD_SIG = "\80\75\1\2"
local LFH_SIG = "\80\75\3\4"

local function le16(s, off)
    return s:byte(off) + s:byte(off + 1) * 256
end

local function le32(s, off)
    local b1, b2, b3, b4 = s:byte(off, off + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function u16(v)
    v = v % 65536
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
    v = v % 4294967296
    return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function build_lfh(path, data)
    local crc = ZipUtil.crc32(data)
    local lfh = LFH_SIG
        .. u16(20) .. u16(0) .. u16(0)
        .. u16(0) .. u16(0)
        .. u32(crc) .. u32(#data) .. u32(#data)
        .. u16(#path) .. u16(0)
        .. path
    return lfh .. data
end

local function build_cd(path, data, local_offset)
    local crc = ZipUtil.crc32(data)
    return CD_SIG
        .. u16(20) .. u16(20) .. u16(0) .. u16(0)
        .. u16(0) .. u16(0)
        .. u32(crc) .. u32(#data) .. u32(#data)
        .. u16(#path) .. u16(0) .. u16(0)
        .. u16(0) .. u16(0) .. u32(0)
        .. u32(local_offset)
        .. path
end

local function build_eocd(total_entries, cd_size, cd_offset)
    return EOCD_SIG
        .. u16(0) .. u16(0) .. u16(total_entries) .. u16(total_entries)
        .. u32(cd_size) .. u32(cd_offset) .. u16(0)
end

local truncate_file = truncate_c and function(path, length)
    if truncate_c(path, length) == 0 then
        local f = io.open(path, "rb")
        if f then
            local actual_size = f:seek("end")
            f:close()
            if actual_size ~= length then
                return nil, string.format("truncate size mismatch: expected %s, got %s", tostring(length), tostring(actual_size))
            end
        end
        return true
    end
    return nil, "errno " .. tostring(ffi.errno())
end

local Patcher = {}
Patcher.__index = Patcher

function Patcher:new()
    local o = {
        filepath = nil,
        entries = nil,
        cd_offset = nil,
        cd_size = nil,
        entry_count = nil,
        waste_bytes = 0,
    }
    setmetatable(o, self or Patcher)
    return o
end

function Patcher:open(filepath)
    local f = io.open(filepath, "rb")
    if not f then return nil, "cannot open file: " .. tostring(filepath) end
    local fsize = f:seek("end")
    if fsize < 22 then
        f:close()
        return nil, "file too small to be a zip"
    end

    local scan_len = math.min(fsize, 65557)
    f:seek("set", fsize - scan_len)
    local tail = f:read(scan_len)
    local eocd_idx = 0
    local pos = 1
    while true do
        local p = tail:find(EOCD_SIG, pos, true)
        if not p then break end
        eocd_idx = p
        pos = p + 1
    end
    if eocd_idx == 0 then
        f:close()
        return nil, "EOCD signature not found"
    end
    local eocd = tail:sub(eocd_idx, eocd_idx + 21)
    if #eocd < 22 then
        f:close()
        return nil, "truncated EOCD"
    end

    local entry_count = le16(eocd, 11)
    local cd_size = le32(eocd, 13)
    local cd_offset = le32(eocd, 17)

    local cd
    if cd_size > 0 then
        f:seek("set", cd_offset)
        cd = f:read(cd_size)
        if not cd or #cd < cd_size then
            f:close()
            return nil, "cannot read central directory"
        end
    else
        cd = ""
    end
    f:close()

    local entries = {}
    local p = 1
    while p <= #cd do
        if p + 45 > #cd then
            return nil, "truncated central directory record at offset " .. tostring(p - 1)
        end
        if cd:sub(p, p + 3) ~= CD_SIG then
            return nil, "corrupt central directory at offset " .. tostring(p - 1)
        end
        local fname_len = le16(cd, p + 28)
        local extra_len = le16(cd, p + 30)
        local comment_len = le16(cd, p + 32)
        local rec_len = 46 + fname_len + extra_len + comment_len
        if p + rec_len > #cd + 1 then
            return nil, "truncated central directory record"
        end
        local path = cd:sub(p + 46, p + 45 + fname_len)
        table.insert(entries, {
            path = path,
            raw = cd:sub(p, p + rec_len - 1),
            local_offset = le32(cd, p + 42),
            csize = le32(cd, p + 20),
            method = le16(cd, p + 10),
        })
        p = p + rec_len
    end

    self.filepath = filepath
    self.entries = entries
    self.cd_offset = cd_offset
    self.cd_size = cd_size
    self.entry_count = entry_count
    if entry_count ~= #entries then
        return nil, string.format("central directory entry count mismatch (%d vs %d)", #entries, entry_count)
    end
    local logical_data = 0
    for _, e in ipairs(entries) do
        logical_data = logical_data + e.csize
    end
    self.waste_bytes = math.max(0, fsize - (logical_data + cd_size + 22))
    return true
end

function Patcher:commit(updates)
    if not self.filepath then return nil, "patcher not opened", true end
    if type(updates) ~= "table" or not next(updates) then return true end

    local update_list = {}
    for path, data in pairs(updates) do
        if type(path) == "string" and type(data) == "string" and path ~= "mimetype" then
            update_list[#update_list + 1] = { path = path, data = data }
        end
    end
    if #update_list == 0 then return true end

    local total_entries = self.entry_count
    local replaced = {}
    for _, u in ipairs(update_list) do
        if not replaced[u.path] then
            replaced[u.path] = true
            total_entries = total_entries + 1
        end
    end
    for _, e in ipairs(self.entries) do
        if replaced[e.path] then total_entries = total_entries - 1 end
    end
    if total_entries > 65535 then return nil, "too many entries for classic zip", true end
    if not truncate_file then
        return nil, "truncate not available (ffi missing)", true
    end

    local new_local = {}
    local new_cd_recs = {}
    local append_pos = self.cd_offset

    for _, u in ipairs(update_list) do
        if append_pos + #u.path + 30 + #u.data > 4294967295 then
            return nil, "zip too large (4GB limit)", true
        end
        local lfh = build_lfh(u.path, u.data)
        table.insert(new_local, lfh)
        table.insert(new_cd_recs, build_cd(u.path, u.data, append_pos))
        append_pos = append_pos + #lfh
    end

    for _, e in ipairs(self.entries) do
        if not replaced[e.path] then
            table.insert(new_cd_recs, e.raw)
        end
    end

    local cd_bytes = table.concat(new_cd_recs)
    local cd_offset_new = append_pos
    if cd_offset_new > 4294967295 then
        return nil, "central directory offset exceeds 4GB", true
    end
    local eocd = build_eocd(total_entries, #cd_bytes, cd_offset_new)

    local f = io.open(self.filepath, "r+b")
    if not f then return nil, "cannot open file for writing", true end
    local ok_t, err_t = truncate_file(self.filepath, self.cd_offset)
    if not ok_t then
        f:close()
        return nil, "truncate failed: " .. tostring(err_t), true
    end
    f:seek("set", self.cd_offset)
    local ok_w, err_w = f:write(table.concat(new_local), cd_bytes, eocd)
    f:close()
    if not ok_w then return nil, "write failed: " .. tostring(err_w), false end

    local ok_reopen, err_reopen = self:open(self.filepath)
    if not ok_reopen then return nil, err_reopen, false end
    return true
end

ZipUtil.Patcher = Patcher

local function copy_entry_stream(writer, reader, entry, archive_lib)
    local backend = writer.backend
    local entry_ae = ffi.gc(archive_lib.archive_entry_new(), archive_lib.archive_entry_free)
    archive_lib.archive_entry_set_pathname(entry_ae, entry.path)
    archive_lib.archive_entry_set_filetype(entry_ae, archive_lib.AE_IFREG)
    archive_lib.archive_entry_set_perm(entry_ae, 0644)
    archive_lib.archive_entry_set_size(entry_ae, entry.size)
    if archive_lib.archive_write_header(backend.archive, entry_ae) ~= 0 then
        return false, "archive_write_header failed for " .. tostring(entry.path)
    end
    while true do
        local rc = archive_lib.archive_read_data_block(reader._archive.archive, rewrite_buff, rewrite_size, rewrite_offs)
        if rc == archive_lib.ARCHIVE_EOF then break end
        if rc ~= archive_lib.ARCHIVE_OK then
            return false, "archive_read_data_block failed for " .. tostring(entry.path) .. " (rc=" .. tostring(rc) .. ")"
        end
        if archive_lib.archive_write_data(backend.archive, rewrite_buff[0], rewrite_size[0]) ~= rewrite_size[0] then
            return false, "archive_write_data short write for " .. tostring(entry.path)
        end
    end
    return true
end

function ZipUtil.rewriteWithUpdates(src_path, dst_path, updates)
    updates = updates or {}
    local reader = ZipUtil.Reader:new()
    local ok_open, err_open = reader:open(src_path)
    if not ok_open then
        return nil, "cannot open source: " .. tostring(err_open or "unknown")
    end

    local writer = ZipUtil.Writer:new()
    local ok_w, err_w = writer:open(dst_path)
    if not ok_w then
        reader:close()
        return nil, "cannot open destination: " .. tostring(err_w or "unknown")
    end

    local can_stream = (reader._mode == "archiver"
        and writer.backend_type == "archiver")
    if can_stream and not libarchive then
        libarchive =  ffi.loadlib("archive", "13")
    end

    local ok = true
    local err
    local wrote_mimetype = false

    local function add_entry(path, data)
        if not ok then return end
        local r = writer:add(path, data, true)
        if not r then
            ok, err = false, "failed to write " .. tostring(path)
        end
    end

    reader:iterate(function(entry)
        if not ok then return false end
        if entry.mode ~= "file" then return end
        if entry.path == "mimetype" then
            local data = reader:extractToMemory(entry.path)
            if data then
                add_entry(entry.path, data)
                wrote_mimetype = true
            end
            return
        end
        local new_content = updates[entry.path]
        if new_content ~= nil then
            add_entry(entry.path, new_content)
        elseif can_stream then
            local s_ok, s_err = copy_entry_stream(writer, reader, entry, libarchive)
            if not s_ok then
                ok, err = false, s_err
                return false
            end
        else
            local data = reader:extractToMemory(entry.path)
            if data then
                add_entry(entry.path, data)
            else
                ok, err = false, "failed to extract " .. tostring(entry.path)
                return false
            end
        end
    end)

    if not wrote_mimetype then
        add_entry("mimetype", "application/epub+zip")
    end

    local ok_close, err_close = writer:close()
    reader:close()
    if not ok then return nil, err end
    if not ok_close then return nil, err_close end
    return true
end

function ZipUtil.readMemoryEntry(data, path)
    if type(data) ~= "string" or #data > 512 * 1024 then return nil, "invalid archive input" end
    if type(path) ~= "string" or #path > 1024 or path:find("\0", 1, true)
        or path:find("\\", 1, true) or not is_safe_entry_path(path) then
        return nil, "invalid entry path"
    end
    if not has_archiver then return nil, "memory ZIP reader unavailable" end
    local loaded, library = pcall(function()
        ffi.cdef[[
            int archive_read_open_memory(struct archive *, const void *, size_t);
            int archive_read_support_format_zip(struct archive *);
        ]]
        local lib = ffi.loadlib("archive", "13")
        local _ = lib.archive_read_open_memory
        _ = lib.archive_read_support_format_zip
        return lib
    end)
    if not loaded then return nil, "memory ZIP reader unavailable" end
    local archive = library.archive_read_new()
    if archive == nil then return nil, "archive allocation failed" end
    archive = ffi.gc(archive, library.archive_free)
    local entry = ffi.gc(library.archive_entry_new(), library.archive_entry_free)
    if entry == nil then
        ffi.gc(archive, nil); library.archive_free(archive)
        return nil, "archive allocation failed"
    end
    local buffer = ffi.new("unsigned char[?]", #data + 1)
    ffi.copy(buffer, data, #data)
    local ok, result, err = pcall(function()
        if library.archive_read_support_format_zip(archive) ~= 0
            or library.archive_read_open_memory(archive, buffer, #data) ~= 0 then
            return nil, "invalid ZIP archive"
        end
        for index = 1, 256 do
            local status = library.archive_read_next_header2(archive, entry)
            if status == 1 then return nil, "entry not found" end
            if status ~= 0 then return nil, "invalid ZIP header" end
            local name = library.archive_entry_pathname(entry)
            if name ~= nil and ffi.string(name) == path then
                if library.archive_entry_filetype(entry) ~= library.AE_IFREG then
                    return nil, "unsupported ZIP entry type"
                end
                local size = tonumber(library.archive_entry_size(entry))
                if size > 256 * 1024 then return nil, "entry output too large" end
                local parts, total = {}, 0
                local output = ffi.new("unsigned char[32768]")
                while true do
                    local count = tonumber(library.archive_read_data(archive, output, 32768))
                    if count < 0 then return nil, "invalid ZIP data" end
                    if count == 0 then return table.concat(parts) end
                    total = total + count
                    if total > 256 * 1024 then return nil, "entry output too large" end
                    parts[#parts + 1] = ffi.string(output, count)
                end
            end
        end
        return nil, "ZIP entry count limit exceeded"
    end)
    ffi.gc(entry, nil); library.archive_entry_free(entry)
    ffi.gc(archive, nil); library.archive_free(archive)
    if not ok then return nil, "memory ZIP operation failed" end
    return result, err
end

return ZipUtil
