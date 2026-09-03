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

-- data: { by_day = {["YYYY-MM-DD"]=秒}, pages_by_day = {...} }
-- now:  时间戳（测试时注入）
function M.derive(data, now, cfg)
    cfg = cfg or {}
    local curve_days = cfg.curve_days or 30
    local week_start = cfg.week_start or 2

    local by_day = (data and data.by_day) or {}
    local pages_by_day = (data and data.pages_by_day) or {}

    local t = os.date("*t", now)
    local today_key = dayKey(now)
    local week_key = M.weekStartKey(now, week_start)
    local month_key = os.date("%Y-%m", now)
    local year_key = os.date("%Y", now)

    local d = { today = 0, week = 0, month = 0, year = 0, total = 0 }
    for day, s in pairs(by_day) do
        s = tonumber(s) or 0
        d.total = d.total + s
        if day == today_key then d.today = d.today + s end
        if day >= week_key and day <= today_key then d.week = d.week + s end
        if day:sub(1, 7) == month_key then d.month = d.month + s end
        if day:sub(1, 4) == year_key then d.year = d.year + s end
    end

    -- 时段日均：除以已过去的天数（含今天）。空着的日子也属于这一周/这一月，
    -- 除以"有记录的天数"会把偷懒的日子抹掉，得出一个自我安慰的数。
    -- 曲线上那条虚线是终身有效日均，口径不同，正好互为对照。
    local elapsed_week = (t.wday - week_start) % 7 + 1
    d.avg_week = d.week / elapsed_week
    d.avg_month = d.month / t.day

    d.pages_today, d.pages_week = 0, 0
    for day, n in pairs(pages_by_day) do
        n = tonumber(n) or 0
        if day == today_key then d.pages_today = d.pages_today + n end
        if day >= week_key and day <= today_key then d.pages_week = d.pages_week + n end
    end

    d.curve, d.curve_total = {}, 0
    for i = curve_days - 1, 0, -1 do
        local k = dayKey(os.time({ year = t.year, month = t.month, day = t.day - i, hour = 12 }))
        local v = tonumber(by_day[k]) or 0
        d.curve[#d.curve + 1] = v
        d.curve_total = d.curve_total + v
    end

    -- "有记录的天"以真正读过（秒数 > 0）为准，0 秒或脏值不算
    -- 累计和"有记录天数"优先用调用方给的全量汇总（逐日明细只覆盖近一年多，
    -- 拿窗口内的数据当累计会少算）。没有就退回按窗口算。
    local active = 0
    for _, v in pairs(by_day) do
        if (tonumber(v) or 0) > 0 then active = active + 1 end
    end
    d.window_total = d.total
    d.total = tonumber(data and data.total_all) or d.total
    d.active_days = tonumber(data and data.active_days_all) or active
    d.avg_active = d.active_days > 0 and (d.total / d.active_days) or 0

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

    return d
end

return M
