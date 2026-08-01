return {
    base_url = "http://127.0.0.1:1122",
    name = "qread",
    version = "0.2",
    methods = {
        login = {
            path = "/login",
            method = "POST",
            required_params = {"username", "password", "model"}, 
            payload = {"username", "password", "model"},
            form_payload = true,
            expected_status = {200}
        },
        getBookshelfPage = {
            path = "/getBookshelfPage",
            method = "POST",
            -- oldmd5 2025-09-28 08:50:11.020Z
            required_params = {"oldmd5"}, 
            payload = {"oldmd5"},
            form_payload = true,
            expected_status = {200}
        },
        getgroupNew = {
            path = "/getgroupNew",
            method = "POST",
            required_params = {"md5"},
            payload = {"md5"},
            form_payload = true,
            expected_status = {200}
        },
        getBookshelfNew = {
            path = "/getBookshelfNew",
            method = "POST",
            required_params = {"md5", "page"},
            payload = {"md5", "page"},
            form_payload = true,
            expected_status = {200}
        },
        getChapterListNew = {
            path = "/getChapterListNew",
            method = "POST",
            required_params = {"needRefresh", "useReplaceRule", "bookSourceUrl", "url"},
            optional_params = {"bookname"},
            payload = {"needRefresh", "useReplaceRule", "bookSourceUrl", "url", "bookname"},
            form_payload = true,
            expected_status = {200}
        },
        getBookContentNew = {
            path = "/getBookContentNew",
            method = "POST",
            required_params = {"index", "url", "bookSourceUrl", "useReplaceRule"},
            optional_params = {"bookname", "type", "needRefresh"},
            payload = {"index", "url", "bookSourceUrl", "useReplaceRule", "bookname", "type", "needRefresh"},
            form_payload = true,
            expected_status = {200}
        },
        getBookSourcesPage = {
            path = "/getBookshelfPage",
            method = "POST",
            -- is md5
            required_params = {"oldmd5"}, 
            payload = {"oldmd5"},
            form_payload = true,
            expected_status = {200}
        },
        getBookSourcesNew = {
            path = "/getBookSourcesNew",
            method = "POST",
            required_params = {"md5", "page"},
            payload = {"md5", "page"},
            form_payload = true,
            expected_status = {200}
        },
        refreshBook = {
            path = "/refreshBook",
            method = "POST",
            required_params = {"bookurl"},
            payload = {"bookurl"},
            form_payload = true,
            expected_status = {200}
        },
        getBookshelf = {
            path = "/getBookshelf",
            method = "POST",
            required_params = {"version"},
            payload = {"version"},
            form_payload = true,
            expected_status = {200}
        },
        getChapterList = {
            path = "/getChapterList",
            method = "POST",
            required_params = {"bookSourceUrl", "url"},
            payload = {"bookSourceUrl", "url"},
            form_payload = true,
            expected_status = {200}
        },
        getBookContent = {
            path = "/getBookContent",
            method = "POST",
            required_params = {"index", "url", "bookSourceUrl"},
            -- type 0 使用缓存 1 强制刷新
            optional_params = {"type"},
            payload = {"type", "index", "url", "bookSourceUrl"},
            form_payload = true,
            expected_status = {200}
        },
        getBookSources = {
            path = "/getBookSources",
            method = "POST",
            -- 1 所有 0 已开启
            required_params = {"isall"},
            payload = {"isall"},
            form_payload = true,
            expected_status = {200}
        },
        searchBook = {
            path = "/searchBook",
            method = "POST",
            required_params = {"key", "bookSourceUrl"},
            optional_params = {"page"},
            payload = {"key", "bookSourceUrl", "page"},
            form_payload = true,
            expected_status = {200}
        },
        -- 查找书籍可用书源
        urlsaveBook = {
            path = "/urlsaveBook",
            method = "POST",
            required_params = {"url"},
            payload = {"url"},
            form_payload = true,
            expected_status = {200}
        },
        setBookSource = {
            path = "/setBookSource",
            method = "POST",
            required_params = {"bookUrl", "bookSourceUrl", "newUrl"},
            optional_params = {"v"},
            payload = {"bookUrl", "bookSourceUrl", "newUrl"},
            form_payload = true,
            expected_status = {200}
        },
        saveBook = {
            path = "/saveBook",
            method = "POST",
            required_params = {"name", "author", "bookUrl", "origin", "originName", "originOrder"},
            optional_params = {"durChapterIndex", "durChapterPos", "durChapterTime", "durChapterTitle",
                               "wordCount", "intro", "totalChapterNum", "kind", "type"},
            payload = {"name", "author", "bookUrl", "origin", "originName", "originOrder", "durChapterIndex",
                       "durChapterPos", "durChapterTime", "durChapterTitle", "wordCount", "intro", "totalChapterNum",
                       "kind", "type"},
            unattended_params = true,
            form_payload = true,
            expected_status = {200}
        },
        deleteBook = {
            path = "/deleteBook",
            method = "POST",
            required_params = {"name", "author", "bookUrl", "origin", "originName", "originOrder"},
            optional_params = {"durChapterIndex", "durChapterPos", "durChapterTime", "durChapterTitle",
                               "wordCount", "intro", "totalChapterNum", "kind", "type"},
            payload = {"name", "author", "bookUrl", "origin", "originName", "originOrder", "durChapterIndex",
                       "durChapterPos", "durChapterTime", "durChapterTitle", "wordCount", "intro", "totalChapterNum",
                       "kind", "type"},
            unattended_params = true,
            form_payload = true,
            expected_status = {200}
        },
        saveBookProgress = {
            path = "/saveBookProgress",
            method = "POST",
            required_params = {"index", "url", "title", "pos"},
            payload = {"index", "url", "title", "pos"},
            form_payload = true,
            expected_status = {200}
        },
        fetchBookContent = {
            path = "/fetchBookContent",
            method = "POST",
            required_params = {"url", "index"},
            payload = {"url", "index"},
            form_payload = true,
            expected_status = {200}
        },
        getBookinfo = {
            path = "/getBookinfo2",
            method = "POST",
            required_params = {"url"},
            payload = {"url"},
            form_payload = true,
            expected_status = {200}
        },
        exploreBook =  {
            path = "/exploreBook",
            method = "POST",
            required_params = {"bookSourceUrl", "ruleFindUrl", "page"},
            payload = {"bookSourceUrl", "ruleFindUrl", "page"},
            form_payload = true,
            optional_params = {"v"},
            expected_status = {200}
        },
        getBookSourcesExploreUrl = {
            path = "/getBookSourcesExploreUrl",
            method = "POST",
            -- need = 1 刷新?
            required_params = {"bookSourceUrl"},
            payload = {"bookSourceUrl","need"},
            form_payload = true,
            optional_params = {"v", "need"},
            expected_status = {200}
        },
    }
}
