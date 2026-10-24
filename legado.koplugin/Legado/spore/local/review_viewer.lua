local Reader = require("Legado.spore.local.parser")
local TaskProg = require("Legado.task.Progress")
local MessageBox = require("Legado/MessageBox")
local Preview = require("Legado.spore.local.html_dialog")
local ReviewLink = require("Legado.Helper.ReviewLink")
local M = {}
local RESOURCE_REQUESTS = 32
local RESOURCE_BYTES = 16 * 1024 * 1024
local RESOURCE_SECONDS = 15

local COMMENTS_CSS = [[
@page { margin: 0; }
body { margin: 0; padding: 0; color: #000; line-height: 1.4; }
.legado-comments h2 { font-size: 1.2em; margin: 0 0 0.6em; }
.legado-comments h3 { font-size: 1em; margin: 1em 0 0.4em; border-bottom: 2px solid #555; }
.legado-comments blockquote { margin: 0.6em 0; padding: 0.5em 0.7em; border-left: 3px solid #777; color: #444; }
.comment-item { margin: 0.8em 0; padding: 0 0.2em 0.8em; border-bottom: 1px solid #aaa; }
.comment-header, .comment-username { font-weight: bold; }
.comment-index { font-weight: normal; color: #666; }
.comment-tag { font-size: 0.8em; font-weight: normal; border: 1px solid #888; padding: 0 0.2em; }
.comment-content { margin: 0.45em 0 0.6em; line-height: 1.6; overflow-wrap: break-word; }
.comment-meta, .comment-footer { font-size: 0.8em; color: #555; }
.reply-list { margin-left: 1em; border-left: 1px solid #aaa; padding-left: 0.5em; }
button, input, select, img, iframe, .loading, .loading-more { display: none; }
]]

function M.fetch(reference, extension_source, extension_url)
    if type(reference) ~= "table" then return nil, "无效评论链接" end
    local Backend = require("Legado/Backend")
    local book = Backend:getBookInfoCache(reference.book_cache_id)
    local chapter = Backend.dbManager:getChapterInfo(reference.book_cache_id, reference.chapters_index)
    if type(book) ~= "table" or not book.origin or type(chapter) ~= "table" or not chapter.book_cache_id then
        return nil, "评论所属章节不存在"
    end
    chapter = Backend:getCacheChapterFilePath(chapter, true)
    local file = chapter and chapter.cacheFilePath and io.open(chapter.cacheFilePath, "rb")
    if not file then return nil, "请刷新章节后重试" end
    local html = file:read(16 * 1024 * 1024 + 1)
    file:close()
    if not html or #html > 16 * 1024 * 1024 then return nil, "章节缓存过大" end
    local action = ReviewLink.read_action(html, reference.id, reference)
    if not action then return nil, "请刷新章节后重试" end
    local raw = Backend.dbManager:getBookSourceByUrl(book.book_self_id or Backend:getCurrentBookShelfId(), book.origin)
    local browser, render_session
    if action.kind == "url" then
        render_session = type(raw) == "table" and raw.session or nil
        browser = {url = action.value, title = action.title or "评论", html = ""}
    else
        if type(raw) ~= "table" then return nil, "评论所属书源不存在" end
        local source = require("Legado.spore.local.book_source").new(raw)
        render_session = source.session
        chapter.index = reference.chapters_index
        chapter.url = chapter.chapterUrl or chapter.url
        book.variable = chapter.bookVariable or book.variable
        local result = Reader.execute(source:json(), {
            api = 2, op = "click", session = source.session,
            params = {action = action.value, book = book, chapter = chapter},
            options = {timeoutMs = 20000},
        })
        browser = type(result) == "table" and result.ok == true and type(result.data) == "table" and result.data.browser
        if browser and type(result.session) == "table" then render_session = result.session end
    end
    if type(browser) ~= "table" then return nil, "评论动作执行失败，请刷新章节后重试" end
    local target = browser.url or ""
    if target ~= "" and not ReviewLink.http_url(target) then return nil, "无效评论地址" end
    if target == "" and (type(browser.html) ~= "string" or browser.html == "") then return nil, "无评论内容" end
    if extension_source == nil and target ~= "" then
        extension_source, extension_url = require("Legado.spore.local.review_ext").select(book.origin, target)
    end
    if extension_source == false or target == "" then extension_source = nil end
    local using_extension = type(extension_source) == "table"
    local params = {url = target, title = browser.title or "评论", html = browser.html or ""}
    if using_extension then
        params.url = extension_url or target
        params.output = "html"
    end
    local request_session = render_session
    if using_extension then request_session = nil end
    local response = Reader.execute(using_extension and extension_source
        or {bookSourceUrl = book.origin, bookSourceName = "评论"}, {
        api = 2, op = using_extension and "content" or "preview",
        session = request_session,
        params = params,
        options = {timeoutMs = 35000, scriptTimeoutMs = 0, renderTimeoutMs = 0},
    })
    local preview
    if type(response) == "table" and response.ok == true and type(response.data) == "table" then
        if using_extension and type(response.data.content) == "string" then
            preview = {
                html = response.data.content,
                url = type(response.meta) == "table" and response.meta.finalUrl or target,
                title = browser.title or "评论",
            }
        elseif not using_extension then
            preview = response.data.preview
        end
    end
    if type(preview) ~= "table" or type(preview.html) ~= "string" or preview.html == "" then
        return nil, "书评加载失败，请稍后重试"
    end
    preview.dialog_title = browser.title or "评论"
    preview.css = COMMENTS_CSS
    local ok, prepared = pcall(function()
        local cache = require("Legado.spore.local.resources.cache").new{
            root = require("Legado.Helper.Env").getTempDirectory(),
            download = require("Legado.spore.local.resources.downloader").new(),
            limits = {
                max_requests = RESOURCE_REQUESTS,
                max_bytes = RESOURCE_BYTES,
                deadline = os.time() + RESOURCE_SECONDS,
            },
        }
        return require("Legado.spore.local.resources.localizer").new(cache):prepare(preview, {skip_images = true})
    end)
    return ok and prepared or preview
end

function M.show(reference, extension_source, extension_url)
    if not require("ui/network/manager"):isConnected() then
        MessageBox:notice("网络未连接")
        return
    end
    TaskProg.loading("正在加载评论", function()
        local preview, err = M.fetch(reference, extension_source, extension_url)
        return { preview = preview, error = err }
    end, function(ok, result)
        if ok and type(result) == "table" and type(result.preview) == "table" then
            Preview.show(result.preview)
        else
            local message = ok and type(result) == "table" and result.error
            MessageBox:error(type(message) == "string" and message or "书评加载失败，请稍后重试")
        end
    end)
end

return M
