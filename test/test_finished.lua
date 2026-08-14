-- 用 KOReader 自带的 luajit 跑：./test/run.sh
-- 不需要启动 KOReader，只用 lfs
package.path = "./densestats.koplugin/?.lua;" .. package.path
local lfs = require("libs/libkoreader-lfs")
local F = require("finished")

local pass, fail = 0, 0
local function ok(cond, name, extra)
    if cond then pass = pass + 1; print("  ok   " .. name)
    else fail = fail + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

print("== isSidecarFile ==")
ok(F.isSidecarFile("metadata.epub.lua"), "认得 metadata.epub.lua")
ok(F.isSidecarFile("metadata.pdf.lua"), "认得 metadata.pdf.lua")
ok(not F.isSidecarFile("notes.lua"), "忽略 notes.lua")
ok(not F.isSidecarFile("custom_metadata.lua"), "忽略 custom_metadata.lua")

print("== collectSidecars ==")
local files = F.collectSidecars("./test/fixtures", lfs)
ok(#files == 5, "扫到 5 个 sidecar", #files)

print("== summarize ==")
local s = F.summarize({ "./test/fixtures" }, lfs)
ok(s.total == 3, "读完 3 本（坏文件不算、在读不算）", s.total)
ok(s.months["2026-08"] == 2, "2026-08 两本", s.months["2026-08"])
ok(s.months["2026-07"] == 1, "2026-07 一本", s.months["2026-07"])
ok(s.months["2026-10"] == nil, "没有凭空冒出来的月份")

print("== 完整日期 ==")
local with_date = 0
for _, t in ipairs(s.titles) do
    if t.date and t.date:match("^%d%d%d%d%-%d%d%-%d%d$") then with_date = with_date + 1 end
end
ok(with_date == 3, "每本都带完整日期", with_date)
ok(s.titles[1].month == s.titles[1].date:sub(1,7), "月份是日期的前缀")

print("== recentMonths ==")
local r = F.recentMonths(s, 6)
ok(#r == 2, "两个月份", #r)
ok(r[1].month == "2026-08" and r[1].n == 2, "降序，最新在前", r[1] and r[1].month)

print("== 边界 ==")
ok(#F.collectSidecars("./不存在的目录", lfs) == 0, "目录不存在不报错")
local s2 = F.summarize({ "./test/fixtures", "./test/fixtures" }, lfs)
ok(s2.total == 3, "同一目录传两遍不重复计数", s2.total)

print("== 路径归一化（防重复计数）==")
ok(F.normDir("/a/b/") == "/a/b", "去掉尾斜杠", F.normDir("/a/b/"))
ok(F.normDir("/a/b///") == "/a/b", "多个尾斜杠", F.normDir("/a/b///"))
ok(F.normDir("/a/b") == "/a/b", "本来就没有则不变")
ok(F.normDir(nil) == "", "nil 返回空串")
local s1 = F.summarize({ "./test/fixtures" }, lfs)
local s2 = F.summarize({ "./test/fixtures", "./test/fixtures/" }, lfs)
ok(s2.total == s1.total, "带尾斜杠的同一目录不重复计数", s2.total .. " vs " .. s1.total)
local s3 = F.summarize({ "./test", "./test/fixtures" }, lfs)
ok(s3.total == s1.total, "父目录与子目录同时给出也不重复", s3.total)

print("== summary 块外的干扰文本 ==")
-- 夹具里 annotations 的书摘正文中混入了 ["status"] = "complete"，
-- 而真正的 summary.status 是 abandoned。全文正则会先命中书摘，读出错值。
local st, mt = F.readSidecar("./test/.hash-fixtures/ab/abcdef0123456789abcdef0123456789.sdr/metadata.epub.lua")
ok(st == "abandoned", "只在 summary 块之后取 status，不被书摘带偏", tostring(st))
ok(mt == "2026-05-04", "modified 同样取自 summary 块", tostring(mt))

print("== hash 存放模式 ==")
local sh = F.summarize({ "./test/.hash-fixtures" }, lfs)
ok(sh.total == 1, "hash 目录下能扫到（md5 分桶要钻两层）", sh.total)
ok(sh.titles[1].title == "活着", "书名取自 doc_path，不是 32 位 md5", sh.titles[1].title)
ok(sh.titles[1].month == "2026-06", "月份仍来自 summary.modified", sh.titles[1].month)

print("== titleFrom ==")
ok(F.titleFrom("00112233445566778899aabbccddeeff", "/a/b/活着.pdf") == "活着", "md5 目录名 → doc_path 文件名")
ok(F.titleFrom("百年孤独", "/a/b/别的.epub") == "百年孤独", "普通目录名不被 doc_path 覆盖")
ok(F.titleFrom("00112233445566778899aabbccddeeff", nil) == "00112233445566778899aabbccddeeff",
   "没有 doc_path 时只能退回目录名")
ok(F.titleFrom("0011223344556677", "/a/b/x.epub") == "0011223344556677", "长度不是 32 的十六进制不算 md5")
ok(F.titleFrom("00112233445566778899aabbccddeeff", "/a/b/无扩展名") == "无扩展名", "doc_path 没扩展名也不崩")

print("== 排除目录 ==")
ok(F.skip_dirs["/mnt/base-us"], "Kindle 的重复挂载点在排除表里")
ok(F.skip_names["RECYCLED"] and F.skip_names["System Volume Information"],
   "非点开头的回收站目录也排除")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
