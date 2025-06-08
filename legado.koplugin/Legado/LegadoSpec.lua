return {
    base_url = "http://127.0.0.1:1122",
    name = "LegadoAPI",
    version = "0.2",
    methods = {
        reader3Login = {
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
        getCover = {
            path = "/getCover",
            method = "GET",
            expected_status = {200}
        },
        refreshToc = {
            path = "/refreshToc",
            method = "POST",
            required_params = {"url"},
            payload = {"url"},
            optional_params = {"v"},
            expected_status = {200}
        }
    }
}
