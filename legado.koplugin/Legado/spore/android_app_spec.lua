return {
    base_url = "http://127.0.0.1:1122",
    name = "android_app",
    version = "0.2",
    methods = {
        getChapterList = {
            path = "/getChapterList",
            method = "GET",
            required_params = {"url"},
            optional_params = {"v", "refresh","bookSource","bookSourceUrl"},
            expected_status = {200}
        },
        getBookshelf = {
            path = "/getBookshelf",
            method = "GET",
            required_params = {"v", "refresh"},
            expected_status = {200}
        },
        getBookContent = {
            path = "/getBookContent",
            method = "GET",
            required_params = {"url", "index"},
            optional_params = {"v", "cache", "refresh"},
            expected_status = {200}
        },
        saveBookProgress = {
            path = "/saveBookProgress",
            method = "POST",
            required_params = {"name", "author", "durChapterPos", "durChapterIndex", "durChapterTime",
                               "durChapterTitle", "index", "url"},
            payload = {"name", "author", "durChapterPos", "durChapterIndex", "durChapterTime", "durChapterTitle",
                       "index", "url"},
            optional_params = {"v"},
            expected_status = {200}
        },
        saveBook = {
            path = "/saveBook",
            method = "POST",
            required_params = {"name", "author", "bookUrl", "origin", "originName", "originOrder"},
            optional_params = {"v", "durChapterIndex", "durChapterPos", "durChapterTime", "durChapterTitle",
                               "wordCount", "intro", "totalChapterNum", "kind", "type"},
            payload = {"name", "author", "bookUrl", "origin", "originName", "originOrder", "durChapterIndex",
                       "durChapterPos", "durChapterTime", "durChapterTitle", "wordCount", "intro", "totalChapterNum",
                       "kind", "type"},
            unattended_params = true,
            expected_status = {200}
        },
        deleteBook = {
            path = "/deleteBook",
            method = "POST",
            required_params = {"name", "author", "bookUrl", "origin", "originName", "originOrder"},
            optional_params = {"v", "durChapterIndex", "durChapterPos", "durChapterTime", "durChapterTitle",
                               "wordCount", "intro", "totalChapterNum", "kind", "type"},
            payload = {"name", "author", "bookUrl", "origin", "originName", "originOrder", "durChapterIndex",
                       "durChapterPos", "durChapterTime", "durChapterTitle", "wordCount", "intro", "totalChapterNum",
                       "kind", "type"},
            unattended_params = true,
            expected_status = {200}
        },
        getTxtTocRules = {
            path = "/getTxtTocRules",
            method = "GET",
            required_params = {"v"},
            expected_status = {200}
        },
        getReplaceRules ={
            path = "/getReplaceRules",
            method = "GET",
            required_params = {"v"},
            expected_status = {200}
        },
        refreshToc = {
            path = "/refreshToc",
            method = "POST",
            required_params = {"url"},
            payload = {"url"},
            optional_params = {"v"},
            expected_status = {200}
        },
    }
}
