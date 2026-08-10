--[[
densestats.koplugin — 高密度阅读统计睡眠屏幕

接管内置的 "readingprogress" 睡眠屏幕类型：screensaver.lua 在该模式下调用
ui.statistics:onShowReaderProgress(true) 取 widget，本插件包住这个方法。
设置里仍选「在休眠屏幕上显示阅读进度」。
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
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local SQ3 = require("lua-ljsqlite3/init")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Finished = require("finished")
local Moon = require("moon")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Screen = Device.screen

-- ============================ 可调参数 ============================
local CFG = {
    max_sec = 120,          -- 单页停留时间上限（秒），与 statistics 插件默认一致
    week_start = 2,         -- 1=周日 2=周一
    curve_days = 30,
    top_books = 6,
    finished_months = 6,
    finished_cache_hours = 12,  -- sidecar 扫描结果缓存时长
    tz_offset = 0,              -- start_time 与设备墙钟一致，真机上为 0；设 nil 则自动推断
}
-- =================================================================

-- 注意：Kindle 上 start_time 与设备本地墙钟一致（系统时区为 UTC），
-- 因此在设备上 tzOffset() 返回 0，分组结果与 KOReader 自身完全一致（已用真实库核对）。
-- 在别的机器上直接读这个库做 SQL 时，偏移应当填 0 而不是 +8h。
local function tzOffset()
    -- 显式覆盖优先（真机上应为 0；在别的机器上读 Kindle 的库做对比测试时也用 0）
    local env = os.getenv("DENSESTATS_TZ_OFFSET")
    if env then return tonumber(env) or 0 end
    if CFG.tz_offset then return CFG.tz_offset end
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
    local conn = SQ3.open(db_path)
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

    -- 当前在读 = 最近一次有阅读记录的那本
    local sql_cur = string.format([[
        SELECT b.title,
               SUM(MIN(p.duration, %d))                        AS total_sec,
               MAX(p.page * 1.0 / NULLIF(p.total_pages, 0))    AS frac,
               MAX(p.page)                                     AS page,
               MAX(p.total_pages)                              AS pages
        FROM page_stat_data p JOIN book b ON b.id = p.id_book
        WHERE p.id_book = (SELECT id_book FROM page_stat_data ORDER BY start_time DESC LIMIT 1)
        GROUP BY p.id_book;
    ]], cap)
    local cur = rowsOf(conn:exec(sql_cur), 5)[1]
    if cur then
        data.current = {
            title = tostring(cur[1] or "?"),
            sec   = tonumber(cur[2]) or 0,
            frac  = tonumber(cur[3]) or 0,
            page  = tonumber(cur[4]) or 0,
            pages = tonumber(cur[5]) or 0,
        }
    end

    -- 读完本数不从数据库来：完成状态存在 sidecar 里（见 finished.lua）
    conn:close()
    return data
end

-- ==================== 读完统计（扫 sidecar，带缓存） ====================

local function cachePath()
    return DataStorage:getSettingsDir() .. "/densestats_finished.lua"
end

local function loadCache()
    local ok, t = pcall(dofile, cachePath())
    if ok and type(t) == "table" and type(t.months) == "table" then return t end
    return nil
end

local function saveCache(summary)
    local f = io.open(cachePath(), "w")
    if not f then return end
    f:write("return {\n  ts = ", tostring(os.time()), ",\n  total = ", tostring(summary.total), ",\n  months = {\n")
    for m, n in pairs(summary.months) do
        f:write(string.format("    [%q] = %d,\n", m, n))
    end
    f:write("  },\n}\n")
    f:close()
end

-- 扫描根目录：集中存放的 docsettings 目录 + 书库主目录（sidecar 默认在书旁边）
local function scanRoots()
    local roots, seen = {}, {}
    local function add(d)
        if d and d ~= "" and not seen[d] then seen[d] = true; roots[#roots + 1] = d end
    end
    add(DataStorage:getDocSettingsDir())   -- 集中存放模式
    if G_reader_settings then
        -- 默认 "doc" 模式下 sidecar 在书旁边，所以还得扫书库。
        -- home_dir 可能没设过（新装、或从没设过主目录），退回最后一次浏览/打开的位置。
        add(G_reader_settings:readSetting("home_dir"))
        add(G_reader_settings:readSetting("lastdir"))
        local lastfile = G_reader_settings:readSetting("lastfile")
        if lastfile then add(lastfile:match("^(.*)/[^/]*$")) end
    end
    return roots
end

local function getFinished(force)
    local cache = loadCache()
    if not force and cache and (os.time() - (cache.ts or 0)) < CFG.finished_cache_hours * 3600 then
        return cache
    end
    local ok, summary = pcall(Finished.summarize, scanRoots(), lfs)
    if not ok then
        logger.warn("densestats: sidecar scan failed:", summary)
        return cache
    end
    saveCache(summary)
    return summary
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

-- 月相圆盘：白底上把"暗面"涂黑。
-- 明暗分界是个椭圆：某一行的半宽为 w 时，分界线横坐标 xt = ±w·cos(2πp)。
local MoonWidget = Widget:extend{ radius = nil, phase = 0 }

function MoonWidget:getSize()
    return Geom:new{ w = self.radius * 2 + 2, h = self.radius * 2 + 2 }
end

function MoonWidget:paintTo(bb, x, y)
    local r = self.radius
    local cx, cy = x + r + 1, y + r + 1
    local p = self.phase
    local c = math.cos(2 * math.pi * p)
    local waxing = p < 0.5
    for dy = -r, r do
        local w = math.floor(math.sqrt(math.max(0, r * r - dy * dy)))
        if w > 0 then
            local xt = waxing and (w * c) or (-w * c)
            local x0, x1
            if waxing then x0, x1 = -w, xt        -- 盈：亮在右，暗在左
            else x0, x1 = xt, w end               -- 亏：亮在左，暗在右
            if x1 > x0 then
                bb:paintRect(cx + math.floor(x0), cy + dy,
                             math.ceil(x1 - x0), 1, Blitbuffer.COLOR_BLACK)
            end
        end
    end
    -- 描一圈边，免得满月时整个盘子消失在白底里
    for dy = -r, r do
        local w = math.floor(math.sqrt(math.max(0, r * r - dy * dy)))
        if w > 0 then
            bb:paintRect(cx - w, cy + dy, 2, 1, Blitbuffer.COLOR_BLACK)
            bb:paintRect(cx + w - 1, cy + dy, 2, 1, Blitbuffer.COLOR_BLACK)
        end
    end
end

local function moonRow(usable_w)
    local now = os.time()
    local r = Screen:scaleBySize(34)
    local disc = MoonWidget:new{ radius = r, phase = Moon.phase01(now) }

    local next_full = Moon.nextPhase(now, 0.5)
    local next_new  = Moon.nextPhase(now, 0)
    local soon_full = next_full <= next_new
    local target_ts = soon_full and next_full or next_new
    local days = math.floor((target_ts - now) / 86400 + 0.5)

    local info = VerticalGroup:new{ align = "left" }
    table.insert(info, txt(Moon.name(now), FACE_V(), usable_w))
    table.insert(info, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(info, txt(string.format("月龄 %.1f 天  ·  照度 %d%%",
        Moon.age(now), math.floor(Moon.illumination(now) * 100 + 0.5)), FACE_L(), usable_w))
    table.insert(info, VerticalSpan:new{ width = Screen:scaleBySize(4) })
    table.insert(info, txt(string.format("%s %s（%d 天后）",
        soon_full and "下次满月" or "下次新月",
        os.date("%m-%d", target_ts), days), FACE_L(), usable_w))

    return HorizontalGroup:new{ align = "center",
        disc,
        HorizontalSpan:new{ width = Screen:scaleBySize(20) },
        info,
    }
end

local function FACE_L() return Font:getFace("cfont", 13) end
local function FACE_V() return Font:getFace("cfont", 21) end
local function FACE_M() return Font:getFace("cfont", 16) end
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
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        txt(value, FACE_V(), col_w),
    }
end

local function cellRow(items, usable_w)
    local n = #items
    local col_w = math.floor(usable_w / n)
    local inner_w = col_w - Screen:scaleBySize(8)
    local cells, max_h = {}, 0
    for i, it in ipairs(items) do
        local c = cell(it[1], it[2], inner_w)
        cells[i] = c
        local ok, h = pcall(function() return c:getSize().h end)
        if ok and h and h > max_h then max_h = h end
    end
    -- 每列包一个定宽 LeftContainer：HorizontalGroup 本身按内容宽度排，
    -- 不定宽的话四列会各自漂移，标签和数值对不齐
    local g = HorizontalGroup:new{ align = "top" }
    for _, c in ipairs(cells) do
        table.insert(g, LeftContainer:new{ dimen = Geom:new{ w = col_w, h = max_h }, c })
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

local function currentBook(cur, usable_w)
    local g = VerticalGroup:new{ align = "left" }
    if not cur then
        table.insert(g, txt("—", FACE_M(), usable_w))
        return g
    end
    table.insert(g, txt(cur.title, FACE_M(), usable_w))
    table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(6) })

    -- 进度条
    local bar_w = usable_w
    local fill = math.max(2, math.floor(bar_w * math.min(cur.frac, 1)))
    table.insert(g, HorizontalGroup:new{ align = "center",
        rect(fill, Screen:scaleBySize(10)),
        HorizontalSpan:new{ width = 1 },
    })
    table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(6) })

    local line = string.format("%d%%  ·  %d / %d 页  ·  累计 %s",
        math.floor(cur.frac * 100 + 0.5), cur.page, cur.pages, fmtHours(cur.sec))
    table.insert(g, txt(line, FACE_L(), usable_w))
    return g
end

-- 读完的书：按月份分组列出书名
local function finishedRows(fin_data, usable_w, max_lines)
    local g = VerticalGroup:new{ align = "left" }
    if not fin_data or not fin_data.titles or #fin_data.titles == 0 then
        table.insert(g, txt("—", FACE_M(), usable_w))
        return g
    end
    local by_month = {}
    for _, t in ipairs(fin_data.titles) do
        by_month[t.month] = by_month[t.month] or {}
        table.insert(by_month[t.month], t.title)
    end
    local months = {}
    for m in pairs(by_month) do months[#months + 1] = m end
    table.sort(months, function(a, b) return a > b end)

    local lines = 0
    for _, m in ipairs(months) do
        if lines >= max_lines then break end
        local row = HorizontalGroup:new{ align = "center" }
        table.insert(row, txt(m, FACE_L(), math.floor(usable_w * 0.2)))
        table.insert(row, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
        table.insert(row, txt(table.concat(by_month[m], " · "), FACE_M(),
            math.floor(usable_w * 0.75)))
        table.insert(g, row)
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(7) })
        lines = lines + 1
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
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(16) })
    table.insert(root, hrule(usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(16) })

    table.insert(root, cellRow({
        { "连续天数", tostring(d.streak) }, { "30天日均", fmtHM(d.avg30) },
        { "有效日均", fmtHM(d.avg_active) }, { "累计", fmtHours(d.total) },
    }, usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(22) })

    local curve, peak = curveWidget(d.curve, usable)
    table.insert(root, txt(string.format("最近 30 天 · 共 %s · 峰值 %s",
        fmtHM(d.curve_total), fmtHM(peak)), FACE_L()))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(5) })
    table.insert(root, curve)
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(22) })
    table.insert(root, hrule(usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(16) })

    table.insert(root, txt("当前在读", FACE_L()))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(root, currentBook(data.current, usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(16) })
    table.insert(root, hrule(usable))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(16) })

    table.insert(root, txt("月相", FACE_L()))
    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(root, moonRow(usable))

    table.insert(root, VerticalSpan:new{ width = Screen:scaleBySize(12) })
    local batt = ""
    local ok_p, pd = pcall(function() return Device:getPowerDevice() end)
    if ok_p and pd then batt = string.format("  ·  %d%%", pd:getCapacity()) end
    table.insert(root, txt(os.date("%Y-%m-%d %H:%M") .. batt, FACE_S()))

    -- 把内容补到整屏高，否则外层会按内容高度居中，屏幕上下会露出底层画面
    local ok_h, ch = pcall(function() return root:getSize().h end)
    if ok_h and ch then
        local rest = H - pad * 2 - ch
        if rest > 0 then
            table.insert(root, VerticalSpan:new{ width = rest })
            -- getSize() 会把 _offsets 缓存住；插完新元素必须清掉，
            -- 否则 paintTo 时 self._offsets[i] 为 nil，直接崩（verticalgroup.lua:51）
            root:resetLayout()
        end
    end

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
    local ok_b, w = pcall(buildWidget)
    if not ok_b then logger.warn("densestats: preview build failed:", w); w = nil end
    self[1] = w or CenterContainer:new{
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

    -- 睡眠屏幕接管点（对 KOReader 2026.07 核实过）：
    --   screensaver.lua:548
    --     widget = self.ui.statistics:onShowReaderProgress(true)
    -- 所以包 ReaderStatistics 的实例方法：get_widget 为真（屏保调用）时返回我们的
    -- widget；为假（菜单调用）时原样走官方逻辑。
    self:_maybeAutoShow()

    local stats = self.ui and self.ui.statistics
    if not stats then return end
    if rawget(stats, "_densestats_wrapped") then return end
    stats._densestats_wrapped = true

    local orig = stats.onShowReaderProgress
    stats.onShowReaderProgress = function(this, get_widget)
        if get_widget then
            local ok, w = pcall(buildWidget)
            if ok and w then return w end
            logger.warn("densestats: build failed:", w)
        end
        return orig(this, get_widget)
    end
end

-- 调试用：设 DENSESTATS_AUTOSHOW=1 启动时自动弹出预览，方便截图。
function DenseStats:onReaderReady()
    self:_maybeAutoShow()
end

function DenseStats:onFileManagerReady()
    self:_maybeAutoShow()
end

function DenseStats:_maybeAutoShow()
    if os.getenv("DENSESTATS_AUTOSHOW") ~= "1" then return end
    if DenseStats._autoshown then return end
    DenseStats._autoshown = true
    UIManager:scheduleIn(2.5, function()
        UIManager:show(Preview:new{})
    end)
end

function DenseStats:addToMainMenu(menu_items)
    menu_items.densestats_rescan = {
        text = "重新扫描已读完书籍",
        sorting_hint = "more_tools",
        callback = function()
            local r = getFinished(true)
            UIManager:show(require("ui/widget/infomessage"):new{
                text = r and string.format("已读完 %d 本", r.total) or "扫描失败",
            })
        end,
    }
    menu_items.densestats_preview = {
        text = "预览：密集统计屏",
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(Preview:new{})
        end,
    }
end

return DenseStats
