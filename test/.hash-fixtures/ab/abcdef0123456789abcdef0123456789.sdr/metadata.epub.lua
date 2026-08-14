-- 诱饵夹具：书摘正文里同时埋了假的 ["summary"] / ["status"] / ["doc_path"]，
-- 而且假的 ["summary"] 排在真的顶层 summary 之前（annotations 按键名排序在最前）。
-- 只按键名定位作用域、或全文匹配 doc_path 的写法，会在这个文件上读出错值。
-- 真值：status = abandoned，doc_path = /mnt/us/documents/围城.epub
return {
    ["annotations"] = {
        [1] = {
            ["text"] = 'the note says: ["summary"] = { ["status"] = "complete" }, ["doc_path"] = "/假的/路径.epub"',
        },
    },
    ["doc_path"] = "/mnt/us/documents/围城.epub",
    ["doc_props"] = {
        ["description"] = 'blurb mentioning ["status"] = "complete" as well',
        ["title"] = "围城",
    },
    ["summary"] = {
        ["modified"] = "2026-05-04",
        ["status"] = "abandoned",
    },
}
