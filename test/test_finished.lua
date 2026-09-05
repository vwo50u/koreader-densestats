-- 用 KOReader 自带的 luajit 跑：./test/run.sh
-- 不需要启动 KOReader，只用 lfs
package.path = "./densestats.koplugin/?.lua;" .. package.path
-- 优先用 KOReader 自带的 lfs；CI 上没有 KOReader.app，退回 luarocks 的 luafilesystem
local has_ko, lfs = pcall(require, "libs/libkoreader-lfs")
if not has_ko then lfs = require("lfs") end
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
-- 屏幕上只用总数。按月计数和书名列表是旧版"已读完列表"的遗留，扫出来只会
-- 让缓存文件和子进程回传的负载变大，不该再返回。
ok(s.months == nil and s.titles == nil, "summarize 只返回总数，不再带月份和书名",
   tostring(s.months) .. "/" .. tostring(s.titles))
ok(F.recentMonths == nil, "recentMonths 已移除", tostring(F.recentMonths))

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

print("== 书摘正文里的诱饵 ==")
-- 夹具的 annotations 正文里同时埋了假的 ["summary"] = { ["status"] = "complete" }
-- 和假的 ["doc_path"]，而且假 summary 排在真的顶层 summary **之前**。
-- 真值是 abandoned + /mnt/us/documents/围城.epub。
-- 三种写法会在这里翻车：全文匹配 status；只按键名 ["summary"] 定位作用域；
-- 全文匹配 doc_path。判别靠的是顶层键固定缩进 4 格。
local st, mt, dp = F.readSidecar("./test/.hash-fixtures/ab/abcdef0123456789abcdef0123456789.sdr/metadata.epub.lua")
ok(st == "abandoned", "status 取自顶层 summary，不被诱饵带偏", tostring(st))
ok(mt == "2026-05-04", "modified 同样取自顶层 summary", tostring(mt))
ok(dp == "/mnt/us/documents/围城.epub", "doc_path 也只取顶层的", tostring(dp))
-- 这本是 abandoned，所以不该被计入"已读完"
local sa = F.summarize({ "./test/.hash-fixtures/ab" }, lfs)
ok(sa.total == 0, "诱饵没让 abandoned 的书被算成读完", sa.total)

print("== hash 存放模式 ==")
local sh = F.summarize({ "./test/.hash-fixtures" }, lfs)
ok(sh.total == 1, "hash 目录下能扫到（md5 分桶要钻两层）", sh.total)
-- 书名只服务于已删掉的列表；doc_path 仍要读，它是跨存放位置的去重键。
ok(F.titleFrom == nil, "titleFrom 已移除（书名不再上屏）", tostring(F.titleFrom))

print("== 排除目录 ==")
ok(F.skip_dirs["/mnt/base-us"], "Kindle 的重复挂载点在排除表里")
ok(F.skip_names["RECYCLED"] and F.skip_names["System Volume Information"],
   "非点开头的回收站目录也排除")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
