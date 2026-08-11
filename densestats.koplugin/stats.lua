--[[
stats.lua — 纯计算部分（格式化 + 汇总）

刻意不依赖任何 KOReader 模块，也不读时钟：derive 的"现在"由调用方传入。
这样可以用 luajit 直接跑测试，把"跨月""断档""空库"这些边界固定下来。
--]]

local M = {}

-- 时长的唯一写法。精度跟着量级走：
--   < 1h    47m      分钟就是全部信息
--   < 10h   3h20     分钟仍然有意义
--  >= 10h   24h      分钟是噪音，去掉
--
-- 10 小时以上丢分钟有两个理由。一是 "10h02" 这种零填充在大数上会被读成小数
-- （像 10.02 小时）——歧义恰好只在两位数小时才明显。二是读了十几个小时之后，
-- 多半小时少半小时没人在意，而位数少了四列布局的横向余量也宽松。
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

-- lua-ljsqlite3 的 exec 结果按列存，转成行数组
function M.rowsOf(res, ncol)
    local out = {}
    if type(res) ~= "table" or type(res[1]) ~= "table" then return out end
    for i = 1, #res[1] do
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

-- 已读完列表：按日期降序，同月只在第一行标月份（label），其余留空。
-- 缺日期的条目排在最后，用月份兜底。
function M.groupFinished(list)
    local items = {}
    for _, t in ipairs(list or {}) do
        if type(t) == "table" then
            local month = t.month
            if (not month or month == "") and type(t.date) == "string" then
                month = t.date:sub(1, 7)
            end
            items[#items + 1] = {
                title = tostring(t.title or ""),
                month = month or "",
                date = tostring(t.date or ""),
            }
        end
    end
    table.sort(items, function(a, b)
        local da = a.date ~= "" and a.date or a.month
        local db = b.date ~= "" and b.date or b.month
        if da ~= db then return da > db end
        return a.title < b.title
    end)
    local last = nil
    for _, t in ipairs(items) do
        t.label = (t.month ~= last) and t.month or ""
        last = t.month
    end
    return items
end

return M
