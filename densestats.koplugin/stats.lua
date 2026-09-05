--[[
stats.lua — 纯计算部分（格式化 + 汇总）

刻意不依赖任何 KOReader 模块，也不读时钟：derive 的"现在"由调用方传入。
这样可以用 luajit 直接跑测试，把"跨月""断档""空库"这些边界固定下来。
--]]

local M = {}

-- 今日大字专用：H:MM，像 1:20 / 0:45。小时不补零——"01:20" 会被读成时钟。
-- 分钟截断不进位，理由同 fmtHM。
function M.fmtClock(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 0 then sec = 0 end
    return string.format("%d:%02d", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

-- 累计等小字里的时长写法。精度跟着量级走：
--   < 1h    47m      分钟就是全部信息
--   < 10h   3h20     分钟仍然有意义
--  >= 10h   24h      分钟是噪音，去掉
--
-- 10 小时以上丢分钟：累计动辄上千小时，"1234h56" 又长又没信息量，
-- 而且 "10h02" 这种零填充在大数上会被读成小数（像 10.02 小时）。
-- 反正读了十几个小时之后，多半小时少半小时也没人在意。
--
-- 一律截断不进位：宁可少报，也不要把没读的时间算进去。
function M.fmtHM(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 0 then sec = 0 end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h == 0 then return string.format("%dm", m) end
    if h < 10 then return string.format("%dh%02d", h, m) end
    return string.format("%dh", h)
end

-- lua-ljsqlite3 的 exec 结果按列存，转成行数组。
--
-- nrows 要由调用方从 conn:exec 的第二个返回值传进来，别用 #res[1]：结果集里
-- NULL 存成 nil，第一列一旦有 NULL，那一列就是带洞的数组，长度未定义，整块数据
-- 会静默消失。空库时 `SELECT SUM(total_read_time) FROM book` 返回的正是 NULL，
-- 书名缺失时 `SELECT b.title, ...` 也是。官方同样拿这个返回值当行数
-- （statistics.koplugin/main.lua:2807/2811）。
-- 不传时退回 #res[1]，只为让不涉及 NULL 的老调用方保持原样。
function M.rowsOf(res, ncol, nrows)
    local out = {}
    if type(res) ~= "table" or type(res[1]) ~= "table" then return out end
    for i = 1, (tonumber(nrows) or #res[1]) do
        local r = {}
        for c = 1, ncol do
            r[c] = res[c] and res[c][i] or nil
        end
        out[#out + 1] = r
    end
    return out
end

local function dayKey(t)
    return os.date("%Y-%m-%d", t)
end

-- 某天所在周的起始日（week_start: 1=周日 2=周一）
function M.weekStartKey(now, week_start)
    local t = os.date("*t", now)
    local back = (t.wday - (week_start or 2)) % 7
    return dayKey(os.time({ year = t.year, month = t.month, day = t.day - back, hour = 12 }))
end

-- data: { by_day = {["YYYY-MM-DD"]=秒}, total_all = 全量累计秒数（可省） }
-- now:  时间戳（测试时注入）
-- 只算上屏要用的：今日/昨日/本周（大字及其回退）、累计、连读、曲线。
-- 旧版网格的本月/今年/日均/页数在极简版里没有位置，不再算。
function M.derive(data, now, cfg)
    cfg = cfg or {}
    local curve_days = cfg.curve_days or 30
    local week_start = cfg.week_start or 2

    local by_day = (data and data.by_day) or {}

    local t = os.date("*t", now)
    local today_key = dayKey(now)
    local week_key = M.weekStartKey(now, week_start)

    local d = { today = 0, week = 0, total = 0 }
    for day, s in pairs(by_day) do
        s = tonumber(s) or 0
        d.total = d.total + s
        if day == today_key then d.today = d.today + s end
        if day >= week_key and day <= today_key then d.week = d.week + s end
    end

    d.curve = {}
    for i = curve_days - 1, 0, -1 do
        local k = dayKey(os.time({ year = t.year, month = t.month, day = t.day - i, hour = 12 }))
        d.curve[#d.curve + 1] = tonumber(by_day[k]) or 0
    end

    -- 累计优先用调用方给的全量汇总（逐日明细只覆盖近一年多，拿窗口内的数据
    -- 当累计会少算）。没有就退回按窗口求和。
    d.total = tonumber(data and data.total_all) or d.total

    -- 连续天数：今天还没读不算断，从昨天往回数。
    -- 加上限兜底，防止数据异常（时钟回拨造出的怪日期）把循环拖死。
    local function readOn(k) return (tonumber(by_day[k]) or 0) > 0 end
    local streak = 0
    local i = readOn(today_key) and 0 or 1
    while streak < 100000 do
        local k = dayKey(os.time({ year = t.year, month = t.month, day = t.day - i, hour = 12 }))
        if readOn(k) then streak = streak + 1; i = i + 1 else break end
    end
    d.streak = streak

    d.yesterday = tonumber(by_day[dayKey(os.time({ year = t.year, month = t.month, day = t.day - 1, hour = 12 }))]) or 0

    return d
end

-- 大字给谁：今天还没读就退到昨天，昨天也没有就退到本周。
-- 锁屏顶着一个 0:00 不像海报像催债；只有整周都空着才认命显示 0。
function M.hero(d)
    if (d.today or 0) > 0 then return d.today, "今日阅读" end
    if (d.yesterday or 0) > 0 then return d.yesterday, "昨日阅读" end
    if (d.week or 0) > 0 then return d.week, "本周阅读" end
    return 0, "今日阅读"
end

-- 大字下面那行小字。零值是负面信息（"连读 0 天""读完 0 本"），直接不写；
-- 累计永远在，作为这行的锚。fin_total 为 nil 表示缓存还没扫出来，同样不写。
function M.summaryLine(d, fin_total)
    local parts = {}
    if (d.streak or 0) > 0 then parts[#parts + 1] = string.format("连读 %d 天", d.streak) end
    parts[#parts + 1] = "累计 " .. M.fmtHM(d.total)
    if fin_total and fin_total > 0 then parts[#parts + 1] = string.format("读完 %d 本", fin_total) end
    return table.concat(parts, "  ·  ")
end

-- 书名截短：单行放不下时先丢副标题。只认冒号和带空格的破折号，
-- "Spider-Man" 这种连字符不碰。截完为空就退回原名。
-- Lua 模式按字节匹配，多字节字符不能进字符类 [...]，所以分隔符逐个试，取最靠前的。
local TITLE_SEPS = { "%s*：", "%s*:", "%s+%-+%s", "%s*—", "%s*–" }
function M.shortTitle(title)
    title = tostring(title or "")
    local best
    for _, sep in ipairs(TITLE_SEPS) do
        local main = title:match("^(.-)" .. sep)
        if main and (not best or #main < #best) then best = main end
    end
    best = best and best:gsub("^%s+", "") or ""
    if best == "" then return title end
    return best
end

return M
