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
ok(S.fmtHours(5375) == "1.5h", "小时保留一位", S.fmtHours(5375))

print("== rowsOf ==")
ok(#S.rowsOf(nil, 2) == 0, "nil 结果返回空表")
ok(#S.rowsOf({}, 2) == 0, "空结果返回空表")
local r = S.rowsOf({ {"a","b"}, {1,2} }, 2)
ok(#r == 2 and r[1][1] == "a" and r[2][2] == 2, "列存转行存")
ok(S.rowsOf({ {"a"} }, 3)[1][3] == nil, "列数不足补 nil")

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
}, pages_by_day = { ["2026-08-10"]=108, ["2026-08-08"]=54 } }
local d = S.derive(real, ts(2026,8,10,23), { curve_days=30, week_start=2 })
ok(S.fmtHM(d.today) == "1h29", "今日 = 5375 秒", S.fmtHM(d.today))
ok(d.week == 5375, "本周从周一算起,只有今天", d.week)
ok(d.month == 30309, "本月 = 全部", d.month)
ok(d.year == d.month, "今年 = 本月（数据只有 8 月）")
ok(d.streak == 1, "8-09 断档,连续只有 1 天", d.streak)
ok(d.pages_today == 108 and d.pages_week == 108, "页数汇总", d.pages_today)
ok(#d.curve == 30, "曲线固定 30 格", #d.curve)
ok(d.curve[30] == 5375 and d.curve[29] == 0, "最后一格是今天,前一天为 0")
ok(d.active_days == 8, "有记录的天数", d.active_days)

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
ok(dc.month == 1800, "本月不含去年 12 月", dc.month)
ok(dc.year == 1800, "今年不含去年", dc.year)
ok(dc.total == 5400, "累计含全部", dc.total)
ok(dc.streak == 2, "跨年连续天数", dc.streak)

print("== derive：空库与脏数据 ==")
local e = S.derive({}, ts(2026,8,10))
ok(e.total == 0 and e.streak == 0 and e.avg_active == 0, "空库全 0")
ok(#e.curve == 30, "空库曲线仍是 30 格")
local dirty = { by_day = { ["2026-08-10"]="5375", ["2026-08-09"]=false, ["2026-08-08"]=60 } }
local dd = S.derive(dirty, ts(2026,8,10))
ok(dd.today == 5375, "字符串数字能算", dd.today)
ok(dd.streak == 1, "脏值不算读过,连续在此中断", dd.streak)
ok(dd.active_days == 2, "脏值不计入有记录天数", dd.active_days)
local zero = { by_day = { ["2026-08-10"]=0, ["2026-08-09"]=60 } }
ok(S.derive(zero, ts(2026,8,10)).streak == 1, "今天记 0 秒不算读过,从昨天算起",
   S.derive(zero, ts(2026,8,10)).streak)
ok(S.derive(nil, ts(2026,8,10)).total == 0, "data 为 nil 不炸")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
