local legado_app = {
    base_url = "http://127.0.0.1:1122",
    name = "legado_app",
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

local reader3 = {
    base_url = "http://127.0.0.1:1122",
    name = "reader3",
    version = "0.2",
    methods = {
        login = {
            path = "/login",
            method = "POST",
            payload = {"username", "password", "code", "isLogin"},
            required_params = {"username", "password", "code", "isLogin", "v"},
            expected_status = {200}
        },
        getUserConfig = {
            path = "/getUserConfig",
            method = "GET",
            required_params = {"v"},
            expected_status = {200}
        },
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
        getShelfBook = {
            path = "getShelfBook",
            method = "GET",
            required_params = {"v", "url"},
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
        getAvailableBookSource = {
            path = "/getAvailableBookSource",
            method = "POST",
            required_params = {"url", "refresh"},
            optional_params = {"v"},
            payload = {"url", "refresh"},
            expected_status = {200}
        },
        setBookSource = {
            path = "/setBookSource",
            method = "POST",
            required_params = {"bookUrl", "bookSourceUrl", "newUrl"},
            optional_params = {"v"},
            payload = {"bookUrl", "bookSourceUrl", "newUrl"},
            expected_status = {200}
        },
        searchBookSource = {
            path = "/searchBookSource",
            method = "GET",
            required_params = {"url", "bookSourceGroup"},
            optional_params = {"v", "searchSize", "lastIndex"},
            expected_status = {200}
        },
        searchBookMulti = {
            path = "/searchBookMulti",
            method = "GET",
            required_params = {"v", "key", "bookSourceGroup", "concurrentCount", "lastIndex"},
            optional_params = {"searchSize", "bookSourceUrl"},
            expected_status = {200}
        },
        getBookSources = {
            path = "/getBookSources",
            method = "GET",
            required_params = {"v", "simple"},
            expected_status = {200}
        },
        searchBook = {
            path = "/searchBook",
            method = "GET",
            required_params = {"v", "key", "bookSourceUrl", "bookSourceGroup", "concurrentCount", "lastIndex", "page"},
            expected_status = {200}
        },
        getBookInfo = {
            path = "/getBookInfo",
            method = "POST",
            required_params = {"bookSourceUrl", "url"},
            payload = {"bookSourceUrl", "url"},
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
        getSystemInfo = {
            path = "/getSystemInfo",
            method = "GET",
            required_params = {"v"},
            expected_status = {200}
        },
    }
}

local qread = {
    base_url = "http://127.0.0.1:1122",
    name = "qread",
    version = "0.2",
    methods = {
        login = {
            path = "/login",
            method = "POST",
            -- model = web
            required_params = {"username", "password", "model"}, 
            expected_status = {200}
        },
        getBookshelfPage = {
            path = "/getBookshelfPage",
            method = "POST",
            -- oldmd5 2025-09-28 08:50:11.020Z
            required_params = {"oldmd5"}, 
            expected_status = {200}
        },
        getgroupNew = {
            path = "/getgroupNew",
            method = "POST",
            required_params = {"md5"},
            expected_status = {200}
        },
        getBookshelfNew = {
            path = "/getBookshelfNew",
            method = "POST",
            required_params = {"md5", "page"},
            expected_status = {200}
        },
        getChapterListNew = {
            path = "/getChapterListNew",
            method = "POST",
            required_params = {"needRefresh", "useReplaceRule", "bookSourceUrl", "url"},
            optional_params = {"bookname"},
            expected_status = {200}
        },
        getBookContentNew = {
            path = "/getBookContentNew",
            method = "POST",
            required_params = {"index", "url", "bookSourceUrl", "useReplaceRule"},
            optional_params = {"bookname", "type"},
            expected_status = {200}
        },
        getBookSourcesPage = {
            path = "/getBookshelfPage",
            method = "POST",
            -- is md5
            required_params = {"oldmd5"}, 
            expected_status = {200}
        },
        getBookSourcesNew = {
            path = "/getBookSourcesNew",
            method = "POST",
            required_params = {"md5", "page"},
            expected_status = {200}
        },
        refreshBook = {
            path = "/refreshBook",
            method = "POST",
            required_params = {"bookurl"},
            expected_status = {200}
        },
        getBookshelf = {
            path = "/getBookshelf",
            method = "POST",
            required_params = {"version"},
            expected_status = {200}
        },
        getChapterList = {
            path = "/getChapterList",
            method = "POST",
            required_params = {"bookSourceUrl", "url"},
            expected_status = {200}
        },
        getBookContent = {
            path = "/getBookContent",
            method = "POST",
            required_params = {"index", "url", "bookSourceUrl"},
            -- type 0 使用缓存 1 强制刷新
            optional_params = {"type"},
            expected_status = {200}
        },
        getBookSources = {
            path = "/getBookSources",
            method = "POST",
            -- 1 所有 0 已开启
            required_params = {"isall"},
            expected_status = {200}
        },
        searchBook = {
            path = "/searchBook",
            method = "POST",
            required_params = {"key", "bookSourceUrl"},
            optional_params = {"page"},
            expected_status = {200}
        },
        -- 查找书籍可用书源
        urlsaveBook = {
            path = "/urlsaveBook",
            method = "POST",
            required_params = {"url"},
            expected_status = {200}
        },
        setBookSource = {
            path = "/setBookSource",
            method = "POST",
            required_params = {"bookUrl", "bookSourceUrl", "newUrl"},
            optional_params = {"v"},
            payload = {"bookUrl", "bookSourceUrl", "newUrl"},
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
            expected_status = {200}
        },
        saveBookProgress = {
            path = "/saveBookProgress",
            method = "POST",
            required_params = {"index", "url", "title", "pos"},
            expected_status = {200}
        },
        fetchBookContent = {
            path = "/fetchBookContent",
            method = "POST",
            required_params = {"url", "index"},
            expected_status = {200}
        },
        getBookinfo = {
            path = "/getBookinfo2",
            method = "POST",
            required_params = {"url"},
            expected_status = {200}
        },
    }
}

return {
    legado_app = legado_app,
    reader3 = reader3,
    qread = qread,
}