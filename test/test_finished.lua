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

print("== recentMonths ==")
local r = F.recentMonths(s, 6)
ok(#r == 2, "两个月份", #r)
ok(r[1].month == "2026-08" and r[1].n == 2, "降序，最新在前", r[1] and r[1].month)

print("== 边界 ==")
ok(#F.collectSidecars("./不存在的目录", lfs) == 0, "目录不存在不报错")
local s2 = F.summarize({ "./test/fixtures", "./test/fixtures" }, lfs)
ok(s2.total == 3, "同一目录传两遍不重复计数", s2.total)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
