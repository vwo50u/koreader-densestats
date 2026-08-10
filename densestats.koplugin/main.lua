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
local Stats = require("stats")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Screen = Device.screen

-- ============================ 可调参数 ============================
local CFG = {
    max_sec = 120,          -- 单页停留时间上限（秒），与 statistics 插件默认一致
    week_start = 2,         -- 1=周日 2=周一
    curve_days = 30,
    window_days = 400,   -- 逐日明细只查这个窗口；累计另走 book 表汇总
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

local fmtHM, fmtHours, rowsOf = Stats.fmtHM, Stats.fmtHours, Stats.rowsOf

-- ============================ 取数 ============================

local function collect()
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    -- 不存在就别开：SQ3.open 会凭空建一个空库，后面查表全是错
    if not lfs.attributes(db_path, "mode") then
        logger.warn("densestats: statistics.sqlite3 不存在:", db_path)
        return nil
    end
    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not ok_conn or not conn then
        logger.warn("densestats: 打开数据库失败:", conn)
        return nil
    end

    local off = tzOffset()
    local cap = CFG.max_sec
    local data = {}
    local function query()

    -- 时长和页数一次扫完：分开查等于把整表扫两遍。
    -- 只取近 window_days 天——曲线只要 30 天，今日/本周/本月/今年最多回溯到年初，
    -- 400 天足够覆盖，全表扫描留给下面那条便宜的汇总。
    local since = os.time() - CFG.window_days * 86400
    local sql_days = string.format([[
        SELECT date(start_time + %d, 'unixepoch')      AS d,
               SUM(MIN(duration, %d))                  AS s,
               COUNT(DISTINCT id_book * 1000000 + page) AS n
        FROM page_stat_data
        WHERE start_time >= %d
        GROUP BY d;
    ]], off, cap, since)
    local by_day, pages_by_day = {}, {}
    for _, r in ipairs(rowsOf(conn:exec(sql_days), 3)) do
        local d = tostring(r[1])
        by_day[d] = tonumber(r[2]) or 0
        pages_by_day[d] = tonumber(r[3]) or 0
    end
    data.by_day = by_day
    data.pages_by_day = pages_by_day

    -- 累计时长直接取 book 表的汇总列（KOReader 写入时已按 max_sec 截断过，
    -- 和上面逐行截断的结果一致——用真实库比对过），比全表求和快一个数量级。
    -- 有记录的天数仍要全表扫一次，但只做 COUNT DISTINCT，代价可接受。
    local totals = rowsOf(conn:exec(string.format([[
        SELECT (SELECT SUM(total_read_time) FROM book),
               (SELECT COUNT(DISTINCT date(start_time + %d, 'unixepoch')) FROM page_stat_data);
    ]], off)), 2)[1]
    if totals then
        data.total_all = tonumber(totals[1]) or 0
        data.active_days_all = tonumber(totals[2]) or 0
    end

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

    end

    -- 查询失败也必须关连接，否则文件句柄会一直挂着
    local ok_q, err = pcall(query)
    pcall(function() conn:close() end)
    if not ok_q then
        logger.warn("densestats: 查询失败:", err)
        return nil
    end
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
    f:write("  },\n  titles = {\n")
    for _, t in ipairs(summary.titles or {}) do
        f:write(string.format("    { title = %q, month = %q, date = %q },\n",
            t.title, t.month, t.date or ""))
    end
    f:write("  },\n}\n")
    f:close()
end

-- 扫描根目录：集中存放的 docsettings 目录 + 书库主目录（sidecar 默认在书旁边）
local function scanRoots()
    local roots, seen = {}, {}
    local function add(d)
        d = d and Finished.normDir(d) or ""   -- 尾斜杠不归一化会导致重复计数
        if d ~= "" and not seen[d] then seen[d] = true; roots[#roots + 1] = d end
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

-- 只读缓存。渲染发生在入睡路径上，绝不能在这里遍历书库。
local function getFinished()
    return loadCache()
end

-- 真正的扫描：只在开书之后延迟触发，或菜单里手动触发。
local function rescanFinished()
    local ok, summary = pcall(Finished.summarize, scanRoots(), lfs)
    if not ok then
        logger.warn("densestats: sidecar scan failed:", summary)
        return nil
    end
    saveCache(summary)
    return summary
end

local rescan_scheduled = false
local function maybeRescanLater()
    if rescan_scheduled then return end   -- ReaderUI 与 FileManager 各有一个插件实例
    local cache = loadCache()
    if cache and (os.time() - (cache.ts or 0)) < CFG.finished_cache_hours * 3600 then return end
    rescan_scheduled = true
    -- 有旧缓存就慢慢来（20 秒后），别和开书抢时间；
    -- 一次都没扫过就尽快扫，否则首次安装后的头一屏"已读完"永远是空的
    local delay = cache and 20 or 1
    UIManager:scheduleIn(delay, function()
        rescan_scheduled = false
        rescanFinished()
    end)
end

-- ============================ 算数 ============================

-- ============================ 画面 ============================

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

-- 占满宽度的元素统一居中：HorizontalGroup 里的取整余数会让它们偏左几个像素
local function centered(w, widget)
    local ok, sz = pcall(function() return widget:getSize() end)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = (ok and sz and sz.h) or 0 },
        widget,
    }
end

local function hrule(w)
    return LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{ w = w, h = Screen:scaleBySize(1) },
    }
end

-- 小块内部一律左对齐：标签、数值、附注共用左边缘，
-- 位数变化只往右长，数字不会左右晃。小块本身也由 cellRow 靠左摆放。
local function cell(label, value, col_w, extra)
    local g = VerticalGroup:new{
        align = "left",
        txt(label, FACE_L(), col_w),
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        txt(value, FACE_V(), col_w),
    }
    if extra then
        table.insert(g, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(g, txt(extra, FACE_L(), col_w))
    end
    return g
end

local function cellRow(items, usable_w)
    local n = #items
    local col_w = math.floor(usable_w / n)
    local inner_w = col_w - Screen:scaleBySize(8)
    local cells, max_h = {}, 0
    for i, it in ipairs(items) do
        local c = cell(it[1], it[2], inner_w, it[3])
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

-- 柱状曲线自绘：顺便画一条 1 小时参考虚线。
-- 纵轴刻度取 max(峰值, 1 小时)，这样读得少的时候参考线也在画面里。
local CurveWidget = Widget:extend{ values = nil, w = 0, h = 0, scale = 3600, gap = 1 }

function CurveWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function CurveWidget:paintTo(bb, x, y)
    local n = #(self.values or {})
    if n == 0 or self.w <= 0 or self.h <= 0 then return end
    local gap = self.gap
    local bar_w = math.max(2, math.floor((self.w - gap * (n - 1)) / n))
    local leftover = self.w - (bar_w * n + gap * (n - 1))
    local cx = x
    for i, v in ipairs(self.values) do
        local w = bar_w + (i <= leftover and 1 or 0)
        local h = math.max(1, math.floor(self.h * v / self.scale))
        bb:paintRect(cx, y + self.h - h, w, h, Blitbuffer.COLOR_BLACK)
        cx = cx + w + gap
    end
    -- 1 小时参考线：虚线，画满整宽
    local ry = y + self.h - math.floor(self.h * 3600 / self.scale)
    local dash, step = Screen:scaleBySize(5), Screen:scaleBySize(10)
    local px = x
    while px < x + self.w do
        bb:paintRect(px, ry, math.min(dash, x + self.w - px), Screen:scaleBySize(1),
                     Blitbuffer.COLOR_GRAY)
        px = px + step
    end
end

local function curveWidget(curve, usable_w)
    local peak = 1
    for _, v in ipairs(curve) do if v > peak then peak = v end end
    return CurveWidget:new{
        values = curve,
        w = usable_w,
        h = Screen:scaleBySize(70),
        scale = math.max(peak, 3600),
        gap = Screen:scaleBySize(1),
    }, peak
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

    -- 有些格式（如刚打开、或 total_pages 缺失）拿不到总页数，别显示 "0 / 0 页"
    local line
    if cur.pages > 0 then
        line = string.format("%d%%  ·  %d / %d 页  ·  累计 %s",
            math.floor(cur.frac * 100 + 0.5), cur.page, cur.pages, fmtHours(cur.sec))
    else
        line = string.format("累计 %s", fmtHours(cur.sec))
    end
    table.insert(g, txt(line, FACE_L(), usable_w))
    return g
end

-- 读完的书：一行一本，日期在前、书名在后。
-- 按给定的高度预算往里填，长期条目只增不减，所以必须"能放几行放几行"。
local function finishedRows(fin_data, usable_w, budget_h)
    local g = VerticalGroup:new{ align = "left" }
    local list = fin_data and fin_data.titles
    if not list or #list == 0 then
        table.insert(g, txt("—", FACE_L(), usable_w))
        return g
    end

    local items = Stats.groupFinished(list)

    local date_w = Screen:scaleBySize(72)
    local gap_w = Screen:scaleBySize(14)
    local line_gap = Screen:scaleBySize(7)
    local used, shown = 0, 0

    for _, t in ipairs(items) do
        local dw = txt(t.label, FACE_M(), date_w)
        local tw = txt(t.title or "", FACE_L(), usable_w - date_w - gap_w)
        local h = math.max(dw:getSize().h, tw:getSize().h)
        if used + h + line_gap > budget_h then break end
        table.insert(g, HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = date_w, h = h }, dw },
            HorizontalSpan:new{ width = gap_w },
            tw })
        table.insert(g, VerticalSpan:new{ width = line_gap })
        used = used + h + line_gap
        shown = shown + 1
    end

    if shown < #items then
        local more = txt(string.format("…更早还有 %d 本", #items - shown), FACE_S(), usable_w)
        if used + more:getSize().h <= budget_h then table.insert(g, more) end
    end
    return g
end

-- 页脚：时间 · 电量，整行居中
local function footerRow(usable_w)
    local batt = ""
    local ok_p, pd = pcall(function() return Device:getPowerDevice() end)
    if ok_p and pd then batt = string.format("  ·  %d%%", pd:getCapacity()) end
    return centered(usable_w, txt(os.date("%Y-%m-%d %H:%M") .. batt, FACE_S()))
end

local function buildWidget()
    local data = collect()
    if not data then return nil end
    local d = Stats.derive(data, os.time(), CFG)

    local pad = Screen:scaleBySize(16)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local usable = W - pad * 2
    local root = VerticalGroup:new{ align = "left" }

    -- 区块之间的间距做成"弹性"的：先按基准值排版，最后把多出来的高度平摊回去。
    -- 原来的做法是把剩余空间一股脑塞在末尾，内容全挤在屏幕上半部分。
    local flex = {}
    local function gap(px)
        local sp = VerticalSpan:new{ width = Screen:scaleBySize(px) }
        flex[#flex + 1] = sp
        table.insert(root, sp)
    end

    table.insert(root, cellRow({
        { "今日", fmtHM(d.today) }, { "本周", fmtHM(d.week) },
        { "本月", fmtHM(d.month) }, { "今年", fmtHM(d.year) },
    }, usable))
    gap(16)
    table.insert(root, hrule(usable))
    gap(16)

    table.insert(root, cellRow({
        { "连续天数", tostring(d.streak) },
        { "有效日均", fmtHM(d.avg_active) },
        { "累计", fmtHours(d.total) },
        { "今日页数", tostring(d.pages_today), string.format("本周 %d 页", d.pages_week) },
    }, usable))
    gap(22)

    local curve, peak = curveWidget(d.curve, usable)
    table.insert(root, txt(string.format("最近 30 天 · 共 %s · 峰值 %s",
        fmtHM(d.curve_total), fmtHM(peak)), FACE_L()))
    gap(5)
    table.insert(root, centered(usable, curve))
    gap(22)
    table.insert(root, centered(usable, hrule(usable)))
    gap(16)

    table.insert(root, currentBook(data.current, usable))
    gap(16)
    table.insert(root, centered(usable, hrule(usable)))
    gap(16)

    if os.getenv("DENSESTATS_DEBUG") == "1" then
        local function wof(w) local ok, sz = pcall(function() return w:getSize() end)
            return (ok and sz and sz.w) or -1 end
        logger.info(string.format("densestats widths: screen=%d pad=%d usable=%d curve=%d hrule=%d root=%d col=%d v9999=%d wk9999=%d",
            W, pad, usable, wof(curve), wof(hrule(usable)), wof(root),
            math.floor(usable / 4), wof(txt("9999", FACE_V())), wof(txt("本周 9999 页", FACE_L()))))
    end

    -- 已读完：先量此刻用掉多少高度，剩下的（扣掉页脚）全给它，装不下就截断
    local fin_data = getFinished()
    local fin_title = "已读完"
    if fin_data and fin_data.total then
        fin_title = string.format("已读完 · 共 %d 本", fin_data.total)
    end
    table.insert(root, txt(fin_title, FACE_L()))
    gap(8)

    local footer = footerRow(usable)
    local ok_f, fh = pcall(function() return footer:getSize().h end)
    local footer_h = (ok_f and fh) or Screen:scaleBySize(30)
    root:resetLayout()
    local used_h = root:getSize().h
    -- 12 是页脚上方的间距，也得从预算里扣，否则会顶出屏幕
    local budget = H - pad * 2 - used_h - footer_h - Screen:scaleBySize(12) - Screen:scaleBySize(12)
    table.insert(root, finishedRows(fin_data, usable, math.max(0, budget)))

    gap(12)
    table.insert(root, footer)
    root:resetLayout()

    -- 把剩余高度平摊到各区块之间，让内容纵向铺满整屏、页脚落到底部。
    -- 注意 getSize() 会缓存 _offsets，改完必须 resetLayout()，
    -- 否则 paintTo 时 _offsets[i] 为 nil 直接崩（verticalgroup.lua:51）。
    local ok_h, ch = pcall(function() return root:getSize().h end)
    if ok_h and ch and #flex > 0 then
        local rest = H - pad * 2 - ch
        if rest > 0 then
            local each = math.floor(rest / #flex)
            local extra = rest - each * #flex          -- 除不尽的余数给最后一个
            for i, sp in ipairs(flex) do
                sp.width = sp.width + each + (i == #flex and extra or 0)
            end
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
    maybeRescanLater()

    local stats = self.ui and self.ui.statistics
    if not stats then return end
    -- 这个接管点在 KOReader 2026.07 上核实过。更老的版本走的是
    -- Screensaver.getReaderProgress，方法名对不上就什么都不会发生——
    -- 与其静默失效，不如在日志里留一句，方便对着 crash.log 判断。
    if type(stats.onShowReaderProgress) ~= "function" then
        logger.warn("densestats: 未找到 onShowReaderProgress，睡眠屏幕接管失败，"
                    .. "该 KOReader 版本可能过旧；菜单里的预览仍可用")
        return
    end
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
    maybeRescanLater()
end

function DenseStats:_maybeAutoShow()
    if os.getenv("DENSESTATS_AUTOSHOW") ~= "1" then return end
    if DenseStats._autoshown then return end
    DenseStats._autoshown = true
    UIManager:scheduleIn(6, function()
        UIManager:show(Preview:new{})
    end)
end

function DenseStats:addToMainMenu(menu_items)
    menu_items.densestats_rescan = {
        text = "重新扫描已读完书籍",
        sorting_hint = "more_tools",
        callback = function()
            local r = rescanFinished()
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
