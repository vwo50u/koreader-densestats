package.path = "./densestats.koplugin/?.lua;" .. package.path
local Moon = require("moon")

local pass, fail = 0, 0
local function ok(c, n, extra)
    if c then pass = pass + 1; print("  ok   " .. n)
    else fail = fail + 1; print("  FAIL " .. n .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

-- 参考日期（日本天文口径，与新加坡时区差 1 小时，够用）：
--   2026-08-13 新月（伴日食）  2026-08-28 满月  2026-08-06 下弦
local function ts(y, m, d, h)
    return os.time({ year = y, month = m, day = d, hour = h or 12, min = 0, sec = 0 })
end

print("== 已知月相日 ==")
ok(Moon.name(ts(2026,8,13)) == "新月", "8/13 新月", Moon.name(ts(2026,8,13)))
ok(Moon.name(ts(2026,8,28)) == "满月", "8/28 满月", Moon.name(ts(2026,8,28)))
ok(Moon.name(ts(2026,8,6))  == "下弦月", "8/6 下弦月", Moon.name(ts(2026,8,6)))

print("== 照度 ==")
ok(Moon.illumination(ts(2026,8,13)) < 0.05, "新月几乎全黑",
   string.format("%.3f", Moon.illumination(ts(2026,8,13))))
ok(Moon.illumination(ts(2026,8,28)) > 0.95, "满月接近全亮",
   string.format("%.3f", Moon.illumination(ts(2026,8,28))))

print("== 盈亏方向 ==")
ok(Moon.isWaxing(ts(2026,8,20)), "8/20 在盈（13→28 之间）")
ok(not Moon.isWaxing(ts(2026,8,10)), "8/10 在亏（上个满月之后）")

print("== 下一次相位 ==")
local nf = os.date("*t", Moon.nextPhase(ts(2026,8,10), 0.5))
ok(nf.month == 8 and math.abs(nf.day - 28) <= 1, "8/10 之后的满月是 8/28",
   string.format("%d-%d", nf.month, nf.day))
local nn = os.date("*t", Moon.nextPhase(ts(2026,8,10), 0))
ok(nn.month == 8 and math.abs(nn.day - 13) <= 1, "8/10 之后的新月是 8/13",
   string.format("%d-%d", nn.month, nn.day))

print("== 周期自洽 ==")
local a = Moon.phase01(ts(2026,1,1))
local b = Moon.phase01(ts(2026,1,1) + math.floor(Moon.SYNODIC * 86400))
ok(math.abs(a - b) < 0.001, "隔一个朔望月相位回到原点", math.abs(a-b))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
