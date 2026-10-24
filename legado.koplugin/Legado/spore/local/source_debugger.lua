
local Reader = require("Legado.spore.local.parser")
local BookSource = require("Legado.spore.local.book_source")
local BookService = require("Legado.spore.local.book_service")
local Backend = require("Legado/Backend")

local M = {}

local MAX_CONTENT_PREVIEW_CHARS = 400

local utf8c = nil
pcall(function()
    utf8c = require("Legado.Helper.utf8proc")
end)

local function clean_str(...)
    for i = 1, select("#", ...) do
        local val = select(i, ...)
        if type(val) == "string" or type(val) == "number" then
            local s = tostring(val)
            s = s:gsub("^%s+", ""):gsub("%s+$", "")
            if s ~= "" then return s end
        end
    end
    return ""
end

local function test_keyword(source, keyword)
    local rule = source and source.ruleSearch
    local configured = type(rule) == "table" and rule.checkKeyWord
    return clean_str(keyword, type(configured) == "string" and configured or nil, "剑")
end

local function display_str(...)
    local text = clean_str(...)
    return text ~= "" and text or "未提取"
end

local function failure_reason(value, fallback)
    if type(value) == "table" then value = value.message or value.kind end
    return clean_str(value, fallback)
end

local function safe_utf8_len(str)
    if type(str) ~= "string" or str == "" then return 0 end
    if utf8c and type(utf8c.len) == "function" then
        local ok, l = pcall(utf8c.len, str)
        if ok and type(l) == "number" then return l end
    end
    local len = 0
    for i = 1, #str do
        local b = str:byte(i)
        if b < 0x80 or b >= 0xC0 then
            len = len + 1
        end
    end
    return len
end

local function safe_utf8_sub(str, max_chars)
    if type(str) ~= "string" or str == "" then return "" end
    if utf8c and type(utf8c.sub) == "function" and type(utf8c.len) == "function" then
        local ok_l, total_len = pcall(utf8c.len, str)
        if ok_l and total_len <= max_chars then return str end
        local ok_s, sub_res = pcall(utf8c.sub, str, 1, max_chars)
        if ok_s and type(sub_res) == "string" then return sub_res end
    end
    local len = 0
    local i = 1
    local byte_len = #str
    while i <= byte_len and len < max_chars do
        local b = str:byte(i)
        if b < 128 then i = i + 1
        elseif b >= 192 and b < 224 then i = i + 2
        elseif b >= 224 and b < 240 then i = i + 3
        elseif b >= 240 and b < 248 then i = i + 4
        else i = i + 1 end
        len = len + 1
    end
    return str:sub(1, i - 1)
end

local function truncate_content(text, max_chars)
    max_chars = max_chars or MAX_CONTENT_PREVIEW_CHARS
    if type(text) ~= "string" or text == "" then return "" end
    local total_len = safe_utf8_len(text)
    if total_len <= max_chars then
        return text
    end
    local preview = safe_utf8_sub(text, max_chars)
    return string.format("%s\n\n... (正文过长已截断，本章共 %d 字) ...", preview, total_len)
end

local function create_official_logger()
    local socket = nil
    pcall(function() socket = require("socket") end)
    local now = (socket and type(socket.gettime) == "function") and socket.gettime or os.time
    local start_time = now()
    local buffer = {}

    local function elapsed()
        return math.max(0, now() - start_time)
    end

    local function get_timestamp()
        local diff = elapsed()
        local mins = math.floor(diff / 60)
        local secs = diff - (mins * 60)
        return string.format("[%02d:%06.3f]", mins, secs)
    end

    local function log(msg)
        local line = get_timestamp() .. " " .. tostring(msg or "")
        table.insert(buffer, line)
    end

    local function blank()
        table.insert(buffer, "")
    end

    return {
        log = log,
        elapsed = elapsed,
        blank = blank,
        get_text = function() return table.concat(buffer, "\n") end,
        get_lines = function() return buffer end,
    }
end

local STAGES = {
    { key = "search", name = "搜索", user_name = "查找书籍" },
    { key = "info", name = "详情", user_name = "读取书籍信息" },
    { key = "toc", name = "目录", user_name = "获取章节列表" },
    { key = "content", name = "正文", user_name = "读取正文" },
}

local function new_summary(source_input, keyword)
    local summary = {
        source_name = type(source_input) == "table" and clean_str(source_input.bookSourceName, source_input.name) or "",
        source_url = type(source_input) == "string" and source_input or "",
        keyword = clean_str(keyword, "剑"),
        search_ok = false, info_ok = false, toc_ok = false, content_ok = false,
        stages = {},
    }
    for _, stage in ipairs(STAGES) do summary.stages[stage.key] = { status = "skipped" } end
    return summary
end

local function make_user_report(summary)
    local advice = {
        search = "建议换个书名或作者再试；如果仍然失败，请检查网络或更换书源。",
        info = "建议稍后重试，或换个关键词测试其他书籍。",
        toc = "建议换个关键词测试其他书籍；如果仍然失败，可更换书源。",
        content = "建议稍后重试，或换一本书测试；如果仍无法读取，可更换书源。",
    }
    local lines = {
        summary.ok and "测试通过：已成功读取一章正文。"
            or (summary.failed_stage and "本次测试未通过。" or "未能开始测试。"),
        "",
        "书源：" .. clean_str(summary.source_name, "未命名书源"),
        "关键词：" .. summary.keyword,
        "书籍：" .. (summary.book_name ~= nil and clean_str(summary.book_name, "暂无书名") or "尚未找到"),
    }
    if summary.book_author and summary.book_author ~= "" then lines[#lines + 1] = "作者：" .. summary.book_author end
    if summary.book_kind and summary.book_kind ~= "" then lines[#lines + 1] = "分类：" .. summary.book_kind end
    if summary.book_word_count and summary.book_word_count ~= "" then lines[#lines + 1] = "字数：" .. summary.book_word_count end
    if summary.chapter_title then lines[#lines + 1] = "章节：" .. clean_str(summary.chapter_title, "暂无章节名") end
    lines[#lines + 1] = ""
    local labels = { success = "正常", failed = "未成功", skipped = "未测试" }
    for index, stage in ipairs(STAGES) do
        lines[#lines + 1] = string.format("%d. %s：%s", index, stage.user_name, labels[summary.stages[stage.key].status])
    end
    lines[#lines + 1] = string.format("耗时：%.1f 秒", summary.duration)
    if not summary.ok then
        lines[#lines + 1] = ""
        if summary.failed_stage then
            lines[#lines + 1] = advice[summary.failed_stage]
        else
            lines[#lines + 1] = "测试未能启动，请重新打开书源列表再试。"
        end
        lines[#lines + 1] = "如需进一步排查，可查看详细日志。"
    end
    if summary.content_preview then
        lines[#lines + 1] = "\n正文预览（最多 200 字）\n"
        lines[#lines + 1] = summary.content_preview
    end
    lines[#lines + 1] = "\n本次只测试搜索结果中的第一本书和目录中的第一个章节，不代表所有书籍都能正常阅读。"
    return table.concat(lines, "\n")
end

local function finish_debug(logger, summary)
    local passed = 0
    local skipped_reason = "前置阶段失败，未执行" .. (summary.error and ("：" .. summary.error) or "")
    for _, stage in ipairs(STAGES) do
        local result = summary.stages[stage.key]
        if result.status == "success" then passed = passed + 1 end
        if result.status == "skipped" then result.reason = skipped_reason end
    end
    summary.ok = passed == #STAGES
    summary.duration = logger.elapsed()
    summary.report = make_user_report(summary)
    logger.blank()
    logger.log("==================================================")
    logger.log(summary.ok and "★ 测试结论:【测试流程正常 (4/4 成功)】"
        or string.format("★ 测试结论:【测试未通过 (%d/4 成功)】", passed))
    logger.log("==================================================")

    local header = {
        "书源测试摘要",
        "书源：" .. display_str(summary.source_name),
        "关键词：" .. summary.keyword,
        "策略：搜索首本书 → 首个目录章节（串行测试）",
        "测试书籍：" .. display_str(summary.book_name),
        "测试章节：" .. display_str(summary.chapter_title),
        string.format("结果：%d/4 成功；总耗时 %.3f 秒", passed, summary.duration),
    }
    if summary.error then header[#header + 1] = "失败原因：" .. summary.error end
    local labels = { success = "成功", failed = "失败", skipped = "跳过" }
    for index, stage in ipairs(STAGES) do
        local result = summary.stages[stage.key]
        local line = string.format("%d. %s：%s", index, stage.name, labels[result.status])
        if result.duration then line = line .. string.format("（%.3f 秒）", result.duration) end
        if result.reason then line = line .. " — " .. result.reason end
        header[#header + 1] = line
    end
    header[#header + 1] = "\n详细日志\n=================================================="
    return table.concat(header, "\n") .. "\n" .. logger.get_text(), summary
end

function M.resolve_source_and_service(source_input, allow_fallback)
    if type(source_input) == "table" and source_input.can_search and type(source_input.can_search) == "function" and source_input:can_search() then
        local ok_svc, svc = pcall(BookService.new, source_input)
        if ok_svc and svc then
            return source_input, svc, nil
        end
    end

    if type(source_input) == "table" and (source_input.searchUrl or source_input.ruleSearch or source_input.ruleBookInfo or source_input.ruleToc) then
        local ok_s, src = pcall(BookSource.new, source_input)
        if not ok_s then
            local json_mod = Reader._json or require("rapidjson")
            local enc_ok, enc_str = pcall(json_mod.encode, source_input)
            if not enc_ok then
                pcall(function() enc_str = require("json").encode(source_input) end)
            end
            if enc_str then
                ok_s, src = pcall(BookSource.new, enc_str)
            end
        end
        if ok_s and src and src.can_search and src:can_search() then
            local ok_svc, svc = pcall(BookService.new, src)
            if ok_svc and svc then
                return src, svc, nil
            end
        end
    end

    local book_source_url = type(source_input) == "string" and source_input
        or (type(source_input) == "table" and (source_input.bookSourceUrl or source_input.url))

    if not book_source_url or book_source_url == "" then
        return nil, nil, "缺少有效的书源 URL"
    end

    local be = Backend

    local client = be.apiClient
    if client and type(client._get_source_entry) == "function" then
        local entry = client:_get_source_entry(book_source_url)
        if entry and entry.source and entry.service and entry.source.can_search and entry.source:can_search() then
            return entry.source, entry.service, nil
        end
    end

    local db = be.dbManager
    local last_error = nil
    if db then
        local raw, lookup_error
        local shelf_id = type(be.getCurrentBookShelfId) == "function" and be:getCurrentBookShelfId() or nil
        if type(db.getBookSourceByUrl) == "function" then
            raw, lookup_error = db:getBookSourceByUrl(shelf_id, book_source_url, allow_fallback)
        end

        if raw then
            local ok_s, src = pcall(BookSource.new, raw)
            if ok_s and src then
                local ok_svc, svc = pcall(BookService.new, src)
                if ok_svc and svc then
                    return src, svc, nil
                else
                    last_error = "创建 BookService 失败"
                end
            else
                last_error = "书源规则解析失败: " .. tostring(src)
            end
        else
            last_error = lookup_error or "数据库中未检索到该书源完整规则"
        end
    else
        last_error = "书源数据库未能初始化或无法连接"
    end

    return nil, nil, "未能从数据库或服务中加载该书源完整规则" .. (last_error and (" (" .. last_error .. ")") or "") .. " (URL: " .. tostring(book_source_url) .. ")"
end

function M.run_debug(source_input, keyword, allow_fallback)
    local logger = create_official_logger()
    local summary = new_summary(source_input, keyword)
    local function record_stage(key, started, reason)
        summary.stages[key] = {
            status = reason and "failed" or "success",
            duration = math.max(0, logger.elapsed() - started),
            reason = reason,
        }
        summary[key .. "_ok"] = reason == nil
        if reason then
            summary.error = reason
            summary.failed_stage = key
        end
    end

    local source, service, err_resolve = M.resolve_source_and_service(source_input, allow_fallback)
    if not source or not service then
        local reason = failure_reason(err_resolve, "无法创建测试服务")
        summary.error = "初始化：" .. reason
        logger.log("≡初始化失败:" .. reason)
        return finish_debug(logger, summary)
    end
    keyword = test_keyword(source, keyword)
    summary.keyword = keyword
    summary.source_name = clean_str(source.bookSourceName, summary.source_name, "未命名书源")
    summary.source_url = clean_str(source.bookSourceUrl)
    local source_url = summary.source_url

    logger.log(string.format("⇒开始搜索关键字:%s", keyword))
    logger.log("︾开始解析搜索页")

    local search_url_preview = clean_str(source.searchUrl, source_url .. "/search")
    search_url_preview = search_url_preview:gsub("{{key}}", function() return keyword end)
        :gsub("{{keyword}}", function() return keyword end)
    search_url_preview = search_url_preview:gsub("\r?\n%s*", "")

    local search_started = logger.elapsed()
    local ok_s, books, err_s = pcall(function()
        return service:search(keyword, 1)
    end)

    local target_book = nil
    if ok_s and type(books) == "table" and type(books[1]) == "table"
            and clean_str(books[1].bookUrl) ~= "" then
        target_book = books[1]
        record_stage("search", search_started)
        summary.book_count = #books
        summary.book_name = clean_str(target_book.name)
        summary.book_author = clean_str(target_book.author)
        summary.book_kind = clean_str(target_book.kind)
        summary.book_word_count = clean_str(target_book.wordCount)
        summary.book_url = clean_str(target_book.bookUrl)

        logger.log(string.format("≡搜索成功, URL模板预览:%s", safe_utf8_sub(search_url_preview, 120)))
        logger.log("┌获取书籍列表")
        logger.log(string.format("└列表大小:%d", #books))
        logger.log("┌获取书名")
        logger.log("└" .. display_str(target_book.name))
        logger.log("┌获取作者")
        logger.log("└" .. display_str(target_book.author))
        logger.log("┌获取分类")
        logger.log("└" .. display_str(target_book.kind))
        logger.log("┌获取字数")
        logger.log("└" .. display_str(target_book.wordCount))
        logger.log("┌获取最新章节")
        logger.log("└" .. display_str(target_book.latestChapterTitle, target_book.lastChapter))
        logger.log("┌获取简介")
        logger.log("└" .. display_str(target_book.intro))
        logger.log("┌获取封面链接")
        logger.log("└" .. display_str(target_book.coverUrl))
        logger.log("┌获取详情页链接")
        logger.log("└" .. display_str(target_book.bookUrl))
        logger.log(string.format("◇书籍总数:%d", #books))
        logger.log("︽搜索页解析完成")
    else
        local reason = failure_reason((not ok_s and books) or err_s,
            type(books) == "table" and #books > 0 and "首本书缺少有效详情页链接" or "未检索到匹配书籍")
        record_stage("search", search_started, reason)
        logger.log(string.format("≡搜索失败:%s, URL模板预览:%s", reason, safe_utf8_sub(search_url_preview, 120)))
        logger.log("︽搜索页解析完成")
        logger.blank()
        logger.log(string.format("◇测试中止:搜索阶段失败 (%s)", reason))
        return finish_debug(logger, summary)
    end
    logger.blank()

    logger.log("︾开始解析详情页")
    local book_url = summary.book_url

    local book_context = {}
    for key, value in pairs(target_book) do book_context[key] = value end
    local info_started = logger.elapsed()
    local ok_i, info, err_i = pcall(function()
        return service:book_info(book_url, book_context)
    end)

    local target_toc_url = nil
    if ok_i and type(info) == "table" and clean_str(info.name, info.tocUrl) ~= "" then
        record_stage("info", info_started)
        summary.book_name = clean_str(info.name, target_book.name)
        summary.book_author = clean_str(info.author, target_book.author)
        summary.book_kind = clean_str(info.kind, target_book.kind)
        summary.book_word_count = clean_str(info.wordCount, target_book.wordCount)
        target_toc_url = clean_str(info.tocUrl)
        if target_toc_url == "" then target_toc_url = book_url end
        for key, value in pairs(info) do
            if type(value) ~= "userdata" then book_context[key] = value end
        end

        logger.log(string.format("≡获取成功:%s", safe_utf8_sub(book_url, 120)))
        logger.log("┌获取书名")
        logger.log("└" .. display_str(info.name, target_book.name))
        logger.log("┌获取作者")
        logger.log("└" .. display_str(info.author, target_book.author))
        logger.log("┌获取分类")
        logger.log("└" .. display_str(info.kind, target_book.kind))
        logger.log("┌获取字数")
        logger.log("└" .. display_str(info.wordCount, target_book.wordCount))
        logger.log("┌获取最新章节")
        logger.log("└" .. display_str(info.latestChapterTitle, info.lastChapter, target_book.latestChapterTitle, target_book.lastChapter))
        logger.log("┌获取简介")
        logger.log("└" .. display_str(info.intro, target_book.intro))
        logger.log("┌获取封面链接")
        logger.log("└" .. display_str(info.coverUrl, target_book.coverUrl))
        logger.log("┌获取目录链接")
        logger.log("└" .. display_str(target_toc_url))
        logger.log("︽详情页解析完成")
    else
        local reason = failure_reason((not ok_i and info) or err_i, "详情解析失败")
        record_stage("info", info_started, reason)
        logger.log(string.format("≡获取失败:%s, %s", reason, safe_utf8_sub(book_url, 120)))
        logger.log("︽详情页解析完成")
        logger.blank()
        logger.log(string.format("◇测试中止:详情阶段失败 (%s)", reason))
        return finish_debug(logger, summary)
    end
    logger.blank()

    logger.log("︾开始解析目录页")
    local toc_req_url = target_toc_url or book_url

    local toc_started = logger.elapsed()
    local ok_t, toc_data, err_t = pcall(function()
        return service:fetch_toc(book_url, book_context)
    end)

    local chapters = nil
    if ok_t and type(toc_data) == "table" then
        chapters = toc_data.chapters or (toc_data[1] and toc_data) or nil
    end

    local first_chapter = nil
    if ok_t and type(chapters) == "table" and type(chapters[1]) == "table" then
        record_stage("toc", toc_started)
        summary.chapter_count = #chapters
        first_chapter = chapters[1]
        summary.chapter_title = clean_str(first_chapter.title, first_chapter.name)
        summary.chapter_url = clean_str(first_chapter.url)
        local toc_variable = toc_data.variable
        if (type(toc_variable) == "string" and toc_variable ~= "")
                or type(toc_variable) == "table" then
            book_context.variable = toc_variable
        end

        logger.log(string.format("≡获取成功:%s", safe_utf8_sub(toc_req_url, 120)))
        logger.log("┌获取目录列表")
        logger.log(string.format("└列表大小:%d", #chapters))
        logger.log("┌解析目录列表")
        for idx, chap in ipairs(chapters) do
            if clean_str(chap.url) == "" then
                if idx <= 3 or idx == #chapters then
                    logger.log(string.format("⇒目录项%d缺少章节链接", idx - 1))
                end
            end
        end
        logger.log("└目录列表解析完成")
        logger.log("≡首章信息")
        logger.log("◇章节名称:" .. display_str(first_chapter.title, first_chapter.name))
        logger.log("◇章节链接:" .. display_str(first_chapter.url))
        logger.log("◇章节信息:" .. display_str(first_chapter.tag, first_chapter.info))
        logger.log("◇是否VIP:" .. tostring(first_chapter.isVip == true))
        logger.log("◇是否购买:" .. tostring(first_chapter.isPay == true))
        logger.log(string.format("◇目录总数:%d", #chapters))
        logger.log("︽目录页解析完成")
    else
        local reason = failure_reason((not ok_t and toc_data) or err_t, "无目录章节数据")
        record_stage("toc", toc_started, reason)
        logger.log(string.format("≡获取失败:%s, %s", reason, safe_utf8_sub(toc_req_url, 120)))
        logger.log("︽目录页解析完成")
        logger.blank()
        logger.log(string.format("◇测试中止:目录阶段失败 (%s)", reason))
        return finish_debug(logger, summary)
    end
    logger.blank()

    logger.log("︾开始解析正文页")
    local first_chapter_url = summary.chapter_url
    local content_started = logger.elapsed()

    if first_chapter_url and first_chapter_url ~= "" then
        local chapter_context = {}
        for key, value in pairs(first_chapter) do chapter_context[key] = value end
        if type(chapters[2]) == "table" and clean_str(chapters[2].url) ~= "" then
            chapter_context.nextChapterUrl = chapters[2].url
        end
        local ok_c, content_res, err_c = pcall(function()
            return service:fetch_content(first_chapter_url, book_context, chapter_context)
        end)

        local raw_text = type(content_res) == "table" and content_res.content or content_res
        if ok_c and type(raw_text) == "string" and raw_text:find("%S") then
            local total_pages = type(content_res) == "table" and tonumber(content_res.pages) or 1
            total_pages = total_pages or 1
            local chapter_title = clean_str(type(content_res) == "table" and content_res.title, summary.chapter_title)
            local next_page_url = type(content_res) == "table" and content_res.nextUrl or nil

            record_stage("content", content_started)
            summary.content_bytes = #raw_text
            summary.content_preview = safe_utf8_sub(raw_text, 200)

            logger.log(string.format("≡获取成功:%s", safe_utf8_sub(first_chapter_url, 120)))
            logger.log("┌获取正文下一页链接")
            logger.log("└" .. display_str(next_page_url))
            logger.log(string.format("◇本章总页数:%d", total_pages))
            logger.log("┌获取章节名称")
            logger.log("└" .. display_str(chapter_title))
            logger.log("┌获取正文内容")
            logger.log("└\n" .. truncate_content(raw_text, MAX_CONTENT_PREVIEW_CHARS))
            logger.log("︽正文页解析完成")
        else
            local reason = failure_reason((not ok_c and content_res) or err_c, "正文为空或格式无效")
            record_stage("content", content_started, reason)
            logger.log(string.format("≡获取失败:%s, %s", reason, safe_utf8_sub(first_chapter_url, 120)))
            logger.log("︽正文页解析完成")
        end
    else
        record_stage("content", content_started, "缺少可用章节链接")
        logger.log("≡获取失败:缺少可用章节链接")
        logger.log("︽正文页解析完成")
    end

    return finish_debug(logger, summary)
end

function M.show_log_dialog(log_text, item, keyword, allow_fallback, summary, show_details)
    local TextViewer = require("ui/widget/textviewer")
    local UIManager = require("ui/uimanager")

    local source_name = type(item) == "table" and clean_str(item.bookSourceName, item.name, "书源") or "书源"
    local viewer
    local buttons = {
        {
            {
                text = "重新测试",
                callback = function()
                    UIManager:close(viewer)
                    M:start_test(item, keyword, allow_fallback)
                end,
            },
            {
                text = "换个关键词",
                callback = function()
                    UIManager:close(viewer)
                    M:edit_keyword(item, keyword, allow_fallback)
                end,
            },
        },
        {
            {
                text = "关闭",
                callback = function()
                    UIManager:close(viewer)
                end,
            },
        }
    }

    if summary and summary.report then
        table.insert(buttons, 2, {{
            text = show_details and "返回测试结果" or "查看详细日志",
            callback = function()
                UIManager:close(viewer)
                M.show_log_dialog(log_text, item, keyword, allow_fallback, summary, not show_details)
            end,
        }})
    end
    local report = summary and summary.report
    viewer = TextViewer:new{
        title = (show_details and "书源测试：" or "书源：") .. source_name,
        text = (not show_details and report) or log_text or "暂无测试结果",
        text_type = (show_details or not report) and "code" or nil,
        alignment = "left",
        auto_para_direction = false,
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

function M:start_test(item, keyword, allow_fallback)
    if not item then return end
    if keyword ~= nil then
        keyword = clean_str(keyword)
        if keyword == "" then return end
    end
    if allow_fallback == nil then allow_fallback = true end
    local MessageBox = require("Legado/MessageBox")
    local TaskProg = require("Legado.task.Progress")
    local resolved_source, _, resolve_error = M.resolve_source_and_service(item, allow_fallback)
    if not resolved_source then
        local logger = create_official_logger()
        local summary = new_summary(item, keyword)
        local reason = failure_reason(resolve_error, "无法加载该书源完整规则")
        summary.error = "初始化：" .. reason
        logger.log("≡初始化失败:" .. reason)
        local text = finish_debug(logger, summary)
        M.show_log_dialog(text, item, keyword, allow_fallback, summary)
        return
    end
    keyword = test_keyword(resolved_source, keyword)
    local be = Backend
    if type(be._isLocal) == "function" and be:_isLocal() and type(be.closeDbManager) == "function" then
        be:closeDbManager()
    end
    TaskProg.loading("正在检查书源，请稍候", function()
        local text, summary = M.run_debug(resolved_source, keyword, allow_fallback)
        return { log = text, summary = summary }
    end, function(ok, result)
        if ok and type(result) == "table" and type(result.log) == "string" then
            M.show_log_dialog(result.log, item, keyword, allow_fallback, result.summary)
        else
            if result ~= "cancelled" then
                MessageBox:error("本次测试未能完成，请稍后重试。")
            end
        end
    end, nil, true)
end

function M:edit_keyword(item, keyword, allow_fallback)
    if not item then return end
    local MessageBox = require("Legado/MessageBox")
    local source_name = type(item) == "table" and clean_str(item.bookSourceName, item.name, "当前书源") or "当前书源"
    MessageBox:input(string.format("书源: %s\n请输入书名或作者来测试：", source_name), function(new_keyword)
        self:start_test(item, new_keyword, allow_fallback)
    end, {
        title = "书源测试",
        input = clean_str(keyword, "剑"),
    })
end

function M:show(item, keyword, allow_fallback)
    if not item then return end
    self:start_test(item, keyword, allow_fallback)
end

return M
