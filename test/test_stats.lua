package.path = "./densestats.koplugin/?.lua;" .. package.path
local S = require("stats")

local pass, fail = 0, 0
local function ok(c, n, extra)
    if c then pass = pass + 1; print("  ok   " .. n)
    else fail = fail + 1; print("  FAIL " .. n .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function ts(y, m, d, h) return os.time({ year=y, month=m, day=d, hour=h or 12 }) end

print("== fmtHM ==")
ok(S.fmtHM(0) == "0m", "0 秒", S.fmtHM(0))
ok(S.fmtHM(59) == "0m", "不足一分钟", S.fmtHM(59))
ok(S.fmtHM(60) == "1m", "整一分钟", S.fmtHM(60))
ok(S.fmtHM(3600) == "1h00", "整一小时补零", S.fmtHM(3600))
ok(S.fmtHM(3661) == "1h01", "1 小时 1 分", S.fmtHM(3661))
ok(S.fmtHM(nil) == "0m", "nil 不炸", S.fmtHM(nil))
ok(S.fmtHM(-5) == "0m", "负数按 0", S.fmtHM(-5))
-- 10 小时以上去掉分钟：h02 那种零填充在大数上会被读成小数（10h02 像 10.02），
-- 而且读了十几个小时之后，分钟已经是噪音。
ok(S.fmtHM(9 * 3600 + 3540) == "9h59", "9h59 仍带分钟", S.fmtHM(9 * 3600 + 3540))
ok(S.fmtHM(10 * 3600) == "10h", "满 10 小时起只给整小时", S.fmtHM(10 * 3600))
ok(S.fmtHM(10 * 3600 + 120) == "10h", "10 小时以上丢弃分钟", S.fmtHM(10 * 3600 + 120))
ok(S.fmtHM(1234 * 3600 + 3360) == "1234h", "四位数小时", S.fmtHM(1234 * 3600 + 3360))
-- 截断而不是四舍五入：宁可少报，也不要把没读的时间算进去
ok(S.fmtHM(11 * 3600 + 3599) == "11h", "接近整点也不进位", S.fmtHM(11 * 3600 + 3599))
ok(S.fmtHours == nil, "fmtHours 已从 stats 移除", tostring(S.fmtHours))

print("== fmtClock ==")
ok(S.fmtClock(0) == "0:00", "0 秒", S.fmtClock(0))
ok(S.fmtClock(59) == "0:00", "不足一分钟", S.fmtClock(59))
ok(S.fmtClock(45 * 60) == "0:45", "不足一小时不补小时前导零", S.fmtClock(45 * 60))
ok(S.fmtClock(3600) == "1:00", "整一小时分钟补零", S.fmtClock(3600))
ok(S.fmtClock(3600 + 20 * 60 + 59) == "1:20", "1 小时 20 分，秒截断", S.fmtClock(3600 + 20 * 60 + 59))
ok(S.fmtClock(12 * 3600 + 7 * 60) == "12:07", "两位数小时仍带分钟", S.fmtClock(12 * 3600 + 7 * 60))
ok(S.fmtClock(nil) == "0:00", "nil 不炸", S.fmtClock(nil))
ok(S.fmtClock(-5) == "0:00", "负数按 0", S.fmtClock(-5))

print("== hero ==")
local function hero(d) local v, l = S.hero(d); return S.fmtClock(v) .. " " .. l end
ok(hero({ today = 80*60, yesterday = 3600, week = 9000 }) == "1:20 今日阅读", "今天读了就显示今天", hero({ today = 80*60, yesterday = 3600, week = 9000 }))
ok(hero({ today = 0, yesterday = 45*60, week = 9000 }) == "0:45 昨日阅读", "今天没读退到昨天", hero({ today = 0, yesterday = 45*60, week = 9000 }))
ok(hero({ today = 0, yesterday = 0, week = 7200 }) == "2:00 本周阅读", "昨天也没读退到本周", hero({ today = 0, yesterday = 0, week = 7200 }))
ok(hero({ today = 0, yesterday = 0, week = 0 }) == "0:00 今日阅读", "整周空着才显示 0", hero({ today = 0, yesterday = 0, week = 0 }))
ok(hero({}) == "0:00 今日阅读", "空表不炸", hero({}))

print("== summaryLine ==")
ok(S.summaryLine({ streak = 3, total = 100*3600 }, 12) == "连读 3 天  ·  累计 100h  ·  读完 12 本", "三段齐全",
   S.summaryLine({ streak = 3, total = 100*3600 }, 12))
ok(S.summaryLine({ streak = 0, total = 100*3600 }, 0) == "累计 100h", "零值不写", S.summaryLine({ streak = 0, total = 100*3600 }, 0))
ok(S.summaryLine({ streak = 0, total = 100*3600 }, nil) == "累计 100h", "缓存未就绪不写读完", S.summaryLine({ streak = 0, total = 100*3600 }, nil))
ok(S.summaryLine({}, nil) == "累计 0m", "空表不炸", S.summaryLine({}, nil))

print("== shortTitle ==")
ok(S.shortTitle("置身事外：房地产、债务与经济增长") == "置身事外", "中文冒号截副标题", S.shortTitle("置身事外：房地产、债务与经济增长"))
ok(S.shortTitle("Thinking, Fast and Slow: A Study") == "Thinking, Fast and Slow", "英文冒号", S.shortTitle("Thinking, Fast and Slow: A Study"))
ok(S.shortTitle("Foo - Bar") == "Foo", "带空格的连字符当破折号", S.shortTitle("Foo - Bar"))
ok(S.shortTitle("Spider-Man") == "Spider-Man", "无空格连字符不碰", S.shortTitle("Spider-Man"))
ok(S.shortTitle("红楼梦 — 脂评本") == "红楼梦", "破折号", S.shortTitle("红楼梦 — 脂评本"))
ok(S.shortTitle("红楼梦") == "红楼梦", "没有副标题原样返回", S.shortTitle("红楼梦"))
ok(S.shortTitle("：无正题") == "：无正题", "截完为空退回原名", S.shortTitle("：无正题"))
ok(S.shortTitle(nil) == "", "nil 不炸", S.shortTitle(nil))

print("== rowsOf ==")
ok(#S.rowsOf(nil, 2) == 0, "nil 结果返回空表")
ok(#S.rowsOf({}, 2) == 0, "空结果返回空表")
local r = S.rowsOf({ {"a","b"}, {1,2} }, 2)
ok(#r == 2 and r[1][1] == "a" and r[2][2] == 2, "列存转行存")
ok(S.rowsOf({ {"a"} }, 3)[1][3] == nil, "列数不足补 nil")

-- 第一列为 NULL 的情形。ljsqlite3 把 NULL 存成 nil，所以 res[1] 是带洞的数组，
-- #res[1] 未定义（LuaJIT 上这里是 0）——只有 conn:exec 的第二个返回值可信。
local nulled = { { nil }, { 42 } }
ok(#S.rowsOf(nulled, 2) == 0, "不传行数时第一列为 NULL 会丢数据（记录现状）")
local n1 = S.rowsOf(nulled, 2, 1)
ok(#n1 == 1, "传了行数就不会丢", #n1)
ok(n1[1][1] == nil and n1[1][2] == 42, "NULL 列读成 nil，其余列照常")
-- 多行、第一列部分为 NULL
local mixed = { { nil, "b" }, { 1, 2 } }
local n2 = S.rowsOf(mixed, 2, 2)
ok(#n2 == 2 and n2[1][1] == nil and n2[2][1] == "b" and n2[2][2] == 2,
   "部分 NULL 也不影响后续行")
ok(#S.rowsOf({ {"a","b"} }, 1, 2) == 2, "行数由参数决定，不由列长决定")

print("== weekStartKey ==")
-- 2026-08-10 是周一
ok(S.weekStartKey(ts(2026,8,10), 2) == "2026-08-10", "周一当天就是周首",
   S.weekStartKey(ts(2026,8,10), 2))
ok(S.weekStartKey(ts(2026,8,16), 2) == "2026-08-10", "周日回溯到本周一",
   S.weekStartKey(ts(2026,8,16), 2))
ok(S.weekStartKey(ts(2026,8,16), 1) == "2026-08-16", "week_start=周日时周日是周首",
   S.weekStartKey(ts(2026,8,16), 1))

print("== derive：真实数据（对照 KOReader 截图）==")
local real = { by_day = {
    ["2026-08-02"]=5, ["2026-08-03"]=8591, ["2026-08-04"]=2723, ["2026-08-05"]=5084,
    ["2026-08-06"]=3353, ["2026-08-07"]=2521, ["2026-08-08"]=2657, ["2026-08-10"]=5375,
} }
local d = S.derive(real, ts(2026,8,10,23), { curve_days=30, week_start=2 })
ok(S.fmtHM(d.today) == "1h29", "今日 = 5375 秒", S.fmtHM(d.today))
ok(S.derive(real, ts(2026,8,11,23), { curve_days=30, week_start=2 }).yesterday == d.today, "昨日 = 前一天的今日")
ok(d.week == 5375, "本周从周一算起,只有今天", d.week)
ok(d.streak == 1, "8-09 断档,连续只有 1 天", d.streak)
ok(#d.curve == 30, "曲线固定 30 格", #d.curve)
ok(d.curve[30] == 5375 and d.curve[29] == 0, "最后一格是今天,前一天为 0")

print("== derive：只保留上屏的字段 ==")
-- 极简版只画今日/昨日/本周、累计、连读、曲线。下面这些是旧版网格和日均线的
-- 遗留，算了没人读，删掉后不该再冒出来。
for _, k in ipairs({ "month", "year", "avg_week", "avg_month", "pages_today", "pages_week",
                     "active_days", "avg_active", "window_total", "curve_total" }) do
    ok(d[k] == nil, "derive 不再返回 " .. k, tostring(d[k]))
end

print("== derive：连续天数 ==")
local run = { by_day = { ["2026-08-08"]=60, ["2026-08-09"]=60, ["2026-08-10"]=60 } }
ok(S.derive(run, ts(2026,8,10)).streak == 3, "连读三天")
local no_today = { by_day = { ["2026-08-08"]=60, ["2026-08-09"]=60 } }
ok(S.derive(no_today, ts(2026,8,10)).streak == 2, "今天还没读不算断", 
   S.derive(no_today, ts(2026,8,10)).streak)
local broken = { by_day = { ["2026-08-06"]=60, ["2026-08-09"]=60 } }
ok(S.derive(broken, ts(2026,8,10)).streak == 1, "中间断了就停",
   S.derive(broken, ts(2026,8,10)).streak)

print("== derive：跨月跨年 ==")
local cross = { by_day = { ["2025-12-31"]=3600, ["2026-01-01"]=1800 } }
local dc = S.derive(cross, ts(2026,1,1))
ok(dc.today == 1800, "元旦当天", dc.today)
ok(dc.total == 5400, "累计含全部", dc.total)
ok(dc.streak == 2, "跨年连续天数", dc.streak)

print("== derive：空库与脏数据 ==")
local e = S.derive({}, ts(2026,8,10))
ok(e.total == 0 and e.streak == 0 and e.today == 0, "空库全 0")
ok(#e.curve == 30, "空库曲线仍是 30 格")
local dirty = { by_day = { ["2026-08-10"]="5375", ["2026-08-09"]=false, ["2026-08-08"]=60 } }
local dd = S.derive(dirty, ts(2026,8,10))
ok(dd.today == 5375, "字符串数字能算", dd.today)
ok(dd.streak == 1, "脏值不算读过,连续在此中断", dd.streak)
local zero = { by_day = { ["2026-08-10"]=0, ["2026-08-09"]=60 } }
ok(S.derive(zero, ts(2026,8,10)).streak == 1, "今天记 0 秒不算读过,从昨天算起",
   S.derive(zero, ts(2026,8,10)).streak)
ok(S.derive(nil, ts(2026,8,10)).total == 0, "data 为 nil 不炸")

print("== derive：累计走全量汇总,逐日只覆盖窗口 ==")
local win = { by_day = { ["2026-08-10"]=5375, ["2026-08-09"]=60 }, total_all = 999999 }
local dw = S.derive(win, ts(2026,8,10))
ok(dw.total == 999999, "累计用 total_all,不是窗口内求和", dw.total)
ok(dw.today == 5375, "今日不受影响", dw.today)
local nofall = S.derive({ by_day = { ["2026-08-10"]=3600 } }, ts(2026,8,10))
ok(nofall.total == 3600, "没给全量汇总时退回窗口内求和", nofall.total)

print("== dayKeyOf / dayCutoff / tzOffsetAt ==")
-- 函数还不存在时 pcall 返回 false，让这里显示 FAIL 而不是让整个文件炸掉
local function try(f, ...) local okc, v = pcall(f, ...); return okc and v or nil end
ok(try(S.dayKeyOf, 0) == "1970-01-01", "天号 0 是纪元起点", try(S.dayKeyOf, 0))
ok(try(S.dayKeyOf, 19000) == "2022-01-08", "天号按 UTC 转成日期", try(S.dayKeyOf, 19000))
ok(try(S.dayKeyOf, nil) == "1970-01-01", "nil 不炸")
local day8 = 1641600000                                   -- 2022-01-08 00:00 UTC
ok(try(S.dayCutoff, day8 + 3600, 0, 1) == day8 - 86400, "偏移 0：回退 1 天到 UTC 零点",
   try(S.dayCutoff, day8 + 3600, 0, 1))
ok(try(S.dayCutoff, day8 + 3600, 28800, 0) == day8 - 28800, "偏移 +8h：01:00 UTC 是当地 09:00，截到当地零点",
   try(S.dayCutoff, day8 + 3600, 28800, 0))
ok(try(S.dayCutoff, day8 - 3600, 28800, 0) == day8 - 28800, "23:00 UTC 已是当地次日，截断点跟着后移",
   try(S.dayCutoff, day8 - 3600, 28800, 0))
-- 截断点必须落在桶的边界上，否则最早那个桶只覆盖半天
local cut = try(S.dayCutoff, day8 + 3600, 28800, 400)
ok(cut and (cut + 28800) % 86400 == 0, "400 天前的截断点对齐到当地零点", cut)
ok(cut and try(S.dayKeyOf, (cut + 28800) / 86400) == "2020-12-04", "截断点所在的桶就是那一天",
   cut and try(S.dayKeyOf, (cut + 28800) / 86400))
-- 本机偏移：与 strftime 的 %z 一致；用它切出的桶名要等于本地日期——derive 的
-- today_key 就是本地日期，两边对不上"今日"就会漏
local now = os.time()
local off = try(S.tzOffsetAt, now)
local z = os.date("%z", now)                              -- 如 +0800
local want = tonumber(z:sub(1, 3)) * 3600 + tonumber(z:sub(1, 1) .. z:sub(4, 5)) * 60
ok(off == want, "偏移等于 %z 给出的值", tostring(off) .. " vs " .. want)
ok(off and try(S.dayKeyOf, math.floor((now + off) / 86400)) == os.date("%Y-%m-%d", now),
   "按偏移切出的桶名等于本地日期", off and try(S.dayKeyOf, math.floor((now + off) / 86400)))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
