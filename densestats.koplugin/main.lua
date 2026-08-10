--[[
densestats.koplugin — 高密度阅读统计睡眠屏幕

接管内置的 "readingprogress" 睡眠屏幕类型（screensaver.lua 里
widget = Screensaver.getReaderProgress()），设置里仍选「在休眠屏幕上显示阅读进度」。
数据只读 statistics 插件的 statistics.sqlite3，不写。
statistics 插件必须保持启用。

调试：主菜单 → 更多工具 → 「预览：密集统计屏」可直接查看，无需真的睡眠
（桌面/模拟器上睡眠屏幕功能不可用，只能用这个入口）。
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local SQ3 = require("lua-ljsqlite3/init")
local Screensaver = require("ui/screensaver")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Screen = Device.screen

-- ============================ 可调参数 ============================
local CFG = {
    max_sec = 120,          -- 单页停留时间上限（秒），与 statistics 插件默认一致
    week_start = 2,         -- 1=周日 2=周一
    curve_days = 30,
    top_books = 6,
    finished_ratio = 0.97,  -- "读完"判定阈值（启发式）
    finished_months = 6,
}
-- =================================================================

local function tzOffset()
    local now = os.time()
    local u = os.date("!*t", now)
    u.isdst = false
    return math.floor(os.difftime(now, os.time(u)))
end

local function fmtHM(sec)
    sec = math.floor(sec or 0)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh%02d", h, m) end
    return string.format("%dm", m)
end

local function fmtHours(sec)
    return string.format("%.1fh", (sec or 0) / 3600)
end

local function rowsOf(res, ncol)
    local out = {}
    if not res or not res[1] then return out end
    for i = 1, #res[1] do
        local r = {}
        for c = 1, ncol do
            r[c] = res[c] and res[c][i] or nil
        end
        out[#out + 1] = r
    end
    return out
end

-- ============================ 取数 ============================

local function collect()
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn = SQ3.open(db_path, "ro")
    if not conn then return nil end

    local off = tzOffset()
    local cap = CFG.max_sec
    local data = {}

    local sql_days = string.format([[
        SELECT date(start_time + %d, 'unixepoch') AS d,
               SUM(MIN(duration, %d)) AS s
        FROM page_stat_data
        GROUP BY d ORDER BY d;
    ]], off, cap)
    local by_day, day_list = {}, {}
    for _, r in ipairs(rowsOf(conn:exec(sql_days), 2)) do
        local d, s = tostring(r[1]), tonumber(r[2]) or 0
        by_day[d] = s
        day_list[#day_list + 1] = d
    end
    data.by_day = by_day
    data.day_list = day_list

    local sql_books = string.format([[
        SELECT b.title, SUM(MIN(p.duration, %d)) AS s
        FROM page_stat_data p JOIN book b ON b.id = p.id_book
        GROUP BY p.id_book ORDER BY s DESC LIMIT %d;
    ]], cap, CFG.top_books)
    data.books = {}
    for _, r in ipairs(rowsOf(conn:exec(sql_books), 2)) do
        data.books[#data.books + 1] = { title = tostring(r[1] or "?"), sec = tonumber(r[2]) or 0 }
    end

    local sql_fin = string.format([[
        SELECT strftime('%%Y-%%m', x.last_ts + %d, 'unixepoch') AS m, COUNT(*) AS n
        FROM (
            SELECT id_book, MAX(start_time) AS last_ts,
                   MAX(page * 1.0 / NULLIF(total_pages, 0)) AS frac
            FROM page_stat_data GROUP BY id_book
        ) x
        WHERE x.frac >= %f
        GROUP BY m ORDER BY m DESC LIMIT %d;
    ]], off, CFG.finished_ratio, CFG.finished_months)
    data.finished = {}
    for _, r in ipairs(rowsOf(conn:exec(sql_fin), 2)) do
        data.finished[#data.finished + 1] = { month = tostring(r[1]), n = tonumber(r[2]) or 0 }
    end

    conn:close()
    return data
end

-- ============================ 算数 ============================

local function derive(data)
    local d = {}
    local today = os.date("*t")
    local today_key = os.date("%Y-%m-%d")

    local back = (today.wday - CFG.week_start) % 7
    local week_key = os.date("%Y-%m-%d",
        os.time({ year = today.year, month = today.month, day = today.day - back, hour = 12 }))
    local month_key = os.date("%Y-%m")
    local year_key = os.date("%Y")

    d.today, d.week, d.month, d.year, d.total = 0, 0, 0, 0, 0
    for day, s in pairs(data.by_day) do
        d.total = d.total + s
        if day == today_key then d.today = d.today + s end
        if day >= week_key and day <= today_key then d.week = d.week + s end
        if day:sub(1, 7) == month_key then d.month = d.month + s end
        if day:sub(1, 4) == year_key then d.year = d.year + s end
    end

    d.curve, d.curve_total = {}, 0
    for i = CFG.curve_days - 1, 0, -1 do
        local k = os.date("%Y-%m-%d",
            os.time({ year = today.year, month = today.month, day = today.day - i, hour = 12 }))
        local v = data.by_day[k] or 0
        d.curve[#d.curve + 1] = v
        d.curve_total = d.curve_total + v
    end
    d.avg30 = d.curve_total / CFG.curve_days

    d.active_days = #data.day_list
    d.avg_active = d.active_days > 0 and (d.total / d.active_days) or 0

    local streak = 0
    local i = data.by_day[today_key] and 0 or 1
    while true do
        local k = os.date("%Y-%m-%d",
            os.time({ year = today.year, month = today.month, day = today.day - i, hour = 12 }))
        if data.by_day[k] then streak = streak + 1; i = i + 1 else break end
    end
    d.streak = streak

    return d
end

-- ============================ 画面 ============================

local function FACE_L() return Font:getFace("cfont", 15) end
local function FACE_V() return Font:getFace("cfont", 24) end
local function FACE_M() return Font:getFace("cfont", 17) end
local function FACE_S() return Font:getFace("cfont", 13) end

local function txt(s, face, max_width)
    return TextWidget:new{ text = tostring(s), face = face, max_width = max_width }
end

local function rect(w, h)
    return LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = math.max(1, math.floor(w)), h = math.max(1, math.floor(h)) },
    }
end

local function hrule(w)
    return LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{ w = w, h = Screen:scaleBySize(1) },
    }
end

local function cell(label, value, col_w)
    return VerticalGroup:new{
        align = "left",
        txt(label, FACE_L(), col_w),
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        txt(value, FACE_V(), col_w),
    }
end

local function cellRow(items, usable_w)
    local n = #items
    local col_w = math.floor(usable_w / n)
    local g = HorizontalGroup:new{ align = "top" }
    for i, it in ipairs(items) do
        table.insert(g, cell(it[1], it[2], col_w - Screen:scaleBySize(6)))
        if i < n then table.insert(g, HorizontalSpan:new{ width = Screen:scaleBySize(6) }) end
    end
    return g
end

local function curveWidget(curve, usable_w)
    local n = #curve
    local gap = Screen:scaleBySize(1)
    local bar_w = math.max(2, math.floor((usable_w - gap * (n - 1)) / n))
    local max_h = Screen:scaleBySize(70)
    local peak = 1
    for _, v in ipairs(curve) do if v > peak then peak = v end end

    local g = HorizontalGroup:new{ align = "bottom" }
    for i, v in ipairs(curve) do
        local h = math.max(1, math.floor(max_h * v / peak))
        table.insert(g, VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = max_h - h },
            rect(bar_w, h),
        })
        if i < n then table.insert(g, HorizontalSpan:new{ width = gap }) end
    end
    return g, peak
end

local function bookRows(books, usable_w)
    local g = VerticalGroup:new{ align = "left" }
    local peak = 1
    for _, b in ipairs(books) do if b.sec > peak then peak = b.sec end end
    local title_w = math.floor(usable_w * 0.52)
    local bar_max = math.floor(usable_w * 0.33)
    local mid = usable_w - title_w - bar_max - Screen:scaleBySize(60)
    if mid < Screen:scaleBySize(4) then mid = Screen:scaleBySize(4) end
    for _, b in ipairs(books) do
        local row = HorizontalGroup:new{ align = "center" }
        table.insert(row, txt(b.title, FACE_M(), title_w))
        table.insert(row, HorizontalSpan:new{ width = mid })
        table.insert(row, rect(math.max(2, bar_max * b.sec / peak), Screen:scaleBySize(8)))
        table.insert(row, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(row, txt(fmtHours(b.sec), FACE_M()))
        table.insert(g, row)
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(3) })
    end
    return g
end

local function buildWidget()
    local data = collect()
    if not data then return nil end
    local d = derive(data)

    local pad = Screen:scaleBySize(16)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local usable = W - pad * 2
    local root = VerticalGroup:new{ align = "left" }

    table.insert(root, cellRow({
        { "今日", fmtHM(d.today) }, { "本周", fmtHM(d.week) },
        { "本月", fmtHM(d.month) }, { "今年", fmtHM(d.year) },
    }, usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(root, hrule(usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    table.insert(root, cellRow({
        { "连续天数", tostring(d.streak) }, { "30天日均", fmtHM(d.avg30) },
        { "有效日均", fmtHM(d.avg_active) }, { "累计", fmtHours(d.total) },
    }, usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(14) })

    local curve, peak = curveWidget(d.curve, usable)
    table.insert(root, txt(string.format("最近 30 天 · 共 %s · 峰值 %s",
        fmtHM(d.curve_total), fmtHM(peak)), FACE_L()))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(5) })
    table.insert(root, curve)
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    table.insert(root, hrule(usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    table.insert(root, txt("各书累计时长", FACE_L()))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(5) })
    table.insert(root, bookRows(data.books, usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(root, hrule(usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(10) })

    local fin = {}
    for _, f in ipairs(data.finished) do
        fin[#fin + 1] = string.format("%s  %d", (f.month or ""):sub(6), f.n)
    end
    table.insert(root, txt("每月读完（估算）", FACE_L()))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(root, txt(#fin > 0 and table.concat(fin, "   ") or "—", FACE_M(), usable))

    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(12) })
    local batt = ""
    local ok_p, pd = pcall(function() return Device:getPowerDevice() end)
    if ok_p and pd then batt = string.format("  ·  %d%%", pd:getCapacity()) end
    table.insert(root, txt(os.date("%Y-%m-%d %H:%M") .. batt, FACE_S()))

    return CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            width = W, height = H,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, padding = pad,
            root,
        },
    }
end

-- ============================ 调试预览 ============================

local Preview = InputContainer:extend{}

function Preview:init()
    self.dimen = Screen:getSize()
    self[1] = buildWidget() or CenterContainer:new{
        dimen = Screen:getSize(),
        TextWidget:new{ text = "densestats: 构建失败，看 crash.log", face = FACE_M() },
    }
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    end
end

function Preview:onTap()
    UIManager:close(self)
    return true
end

function Preview:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

-- ============================ 插件挂载 ============================

local DenseStats = WidgetContainer:extend{
    name = "densestats",
    is_doc_only = false,
}

function DenseStats:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if Screensaver._densestats_wrapped then return end
    Screensaver._densestats_wrapped = true

    local orig_setup = Screensaver.setup
    Screensaver.setup = function(this, event, event_message)
        local prev = Screensaver.getReaderProgress
        Screensaver.getReaderProgress = function(...)
            local ok, w = pcall(buildWidget)
            if ok and w then return w end
            logger.warn("densestats: build failed:", w)
            if prev then return prev(...) end
            return nil
        end
        return orig_setup(this, event, event_message)
    end
end

function DenseStats:addToMainMenu(menu_items)
    menu_items.densestats_preview = {
        text = "预览：密集统计屏",
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(Preview:new{})
        end,
    }
end

return DenseStats
