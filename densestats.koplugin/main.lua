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
local Layout = require("layout")
local Finished = require("finished")
local Stats = require("stats")
local Widget = require("ui/widget/widget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Size = require("ui/size")
local time = require("ui/time")
local Screen = Device.screen

-- 函数，或带 __call 的表，都算"可调用"
local function isCallable(v)
    if type(v) == "function" then return true end
    if type(v) == "table" then
        local mt = getmetatable(v)
        return mt ~= nil and mt.__call ~= nil
    end
    return false
end

-- ============================ 可调参数 ============================
local CFG = {
    max_sec = 120,          -- 单页停留时间上限（秒），与 statistics 插件默认一致
    week_start = 2,         -- 1=周日 2=周一
    curve_days = 30,
    window_days = 400,   -- 逐日明细只查这个窗口；累计另走 book 表汇总
    finished_cache_hours = 12,  -- sidecar 扫描结果缓存时长
    cache_titles = 60,          -- 缓存里最多保留多少本书名（渲染时要整份解析）
    tz_offset = 0,              -- start_time 与设备墙钟一致，真机上为 0；设 nil 则自动推断
    -- 字号自适应：从大到小试，第一个"放得下"的档位胜出。
    -- 放不下的判据见 layoutOnce 的返回值（截断 / 已读完行数）。
    fscale_steps = { 1.30, 1.20, 1.10, 1.00, 0.90, 0.80, 0.70, 0.60 },
    min_fin_rows = 2,           -- "已读完"至少要放得下几行，否则降档
    gap_max_ratio = 1.6,        -- 区块间隙最多长到基准值的几倍，吸收不掉的归上下边距
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
               -- 乘数要大于任何可能的页码；SQLite 是 64 位整数，
               -- 就算 id 到十亿、页码到百万也不会溢出，不同书之间也不会撞车。
               COUNT(DISTINCT id_book * 10000000 + page) AS n
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
    -- 只写最近 CFG.cache_titles 本：屏幕上最多也就显示十几行，
    -- 但这个文件每次渲染都要 dofile 解析一遍，无上限增长会把成本压到入睡路径上。
    -- 总数 total 仍然是全量，标题栏的"共 N 本"不受影响。
    local titles = summary.titles or {}
    local sorted = {}
    for _, t in ipairs(titles) do sorted[#sorted + 1] = t end
    table.sort(sorted, function(a, b)
        return (a.date or a.month or "") > (b.date or b.month or "")
    end)
    f:write("  },\n  titles = {\n")
    for i = 1, math.min(#sorted, CFG.cache_titles) do
        local t = sorted[i]
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
local rescan_task              -- 存下来才能 unschedule
local function maybeRescanLater()
    if rescan_scheduled then return end   -- ReaderUI 与 FileManager 各有一个插件实例
    local cache = loadCache()
    if cache and (os.time() - (cache.ts or 0)) < CFG.finished_cache_hours * 3600 then return end
    rescan_scheduled = true
    -- 有旧缓存就慢慢来（20 秒后），别和开书抢时间；
    -- 一次都没扫过就尽快扫，否则首次安装后的头一屏"已读完"永远是空的
    local delay = cache and 20 or 1
    rescan_task = function()
        rescan_scheduled = false
        rescanFinished()
    end
    UIManager:scheduleIn(delay, rescan_task)
end

-- ============================ 算数 ============================

-- ============================ 画面 ============================

-- 三档字号 = KOReader 命名档位的原始设计尺寸（font.lua:90-92 的 sizemap）
-- × 一个自适应系数 FSCALE，由 buildWidget 的 fit 循环设定。
--
-- getFace 的第二个参数是"未缩放的设计尺寸"，内部还会做 Screen:scaleBySize
-- （font.lua:269-277），而 scaleBySize 是按屏幕短边 / 600 缩放、默认完全不看 DPI
-- （ffi/framebuffer.lua:414-425）。所以这里写的不是像素，跨分辨率自动成立；
-- FSCALE 只负责回答"这一屏内容在这台设备的这个方向上放不放得下"。
-- 写死一组数字的问题不在跨分辨率（那是 scaleBySize 的事），而在于横屏、
-- 用户把「屏幕 DPI」调大、以及内容变长时没有退路。
--
-- 仍然只用三档，且按"角色"固定分配，同一角色全篇一致：
--   强调 只给统计大数字；
--   正文 只给"当前在读"的书名——它是整屏唯一的焦点；
--   辅助 给标签、说明、明细、页脚，以及"已读完"清单
--        （那是归档参考，不该和焦点抢视觉重量）。
-- 之前是哪里觉得不合适就单独调一处，屏幕上同时出现四五种大小，看着就乱。
local BASE_V, BASE_M, BASE_L = 25, 20, 15   -- largeffont / ffont / smallffont
local FSCALE = 1.0

local function scaled(base)
    return math.max(8, math.floor(base * FSCALE + 0.5))
end
local function FACE_V() return Font:getFace("largeffont", scaled(BASE_V)) end
local function FACE_M() return Font:getFace("ffont",      scaled(BASE_M)) end
local function FACE_L() return Font:getFace("smallffont", scaled(BASE_L)) end
local FACE_S = FACE_L

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
        VerticalSpan:new{ width = Size.span.vertical_large },
        txt(value, FACE_V(), col_w),
    }
    if extra then
        table.insert(g, VerticalSpan:new{ width = Size.span.vertical_large })
        table.insert(g, txt(extra, FACE_L(), col_w))
    end
    return g
end

-- 一排小块：两端对齐。第一块贴左边缘、最后一块贴右边缘，中间按剩余空间均分。
-- 之前是"等宽列 + 每列左对齐"，最后一列的字只占列宽的一小截，
-- 右边就空出一大块，看起来像左右边距不一样。
local function cellRow(items, usable_w)
    local n = #items
    if n == 0 then return VerticalGroup:new{}, false end
    local cap_w = math.floor(usable_w / n)          -- 单块最大宽度，超了就截断
    local cells, widths, total = {}, {}, 0
    local truncated = false
    for i, it in ipairs(items) do
        local c = cell(it[1], it[2], cap_w, it[3])
        cells[i] = c
        local ok, sz = pcall(function() return c:getSize() end)
        widths[i] = (ok and sz and sz.w) or 0
        total = total + widths[i]
        -- 有没有哪一格被 cap_w 截成 "1234h5…"。isTruncated 走的是真实排版
        -- （含 kerning 和 CJK 回退字体），比自己量宽度可靠（textwidget.lua:307-310）。
        -- 截了就让外层的 fit 循环降一档字号重排：FSCALE 变小而 cap_w 不变，
        -- 所以截断是单调消失的，循环必然收敛。
        for _, w in ipairs(c) do
            if type(w) == "table" and type(w.isTruncated) == "function" then
                local ok_t, cut = pcall(function() return w:isTruncated() end)
                if ok_t and cut then truncated = true end
            end
        end
    end

    local g = HorizontalGroup:new{ align = "top" }
    if n == 1 then
        table.insert(g, cells[1])
        return g, truncated
    end
    local space = usable_w - total
    local gap_w = math.floor(space / (n - 1))
    local extra = space - gap_w * (n - 1)           -- 除不尽的余数塞进最后一个间隙
    if gap_w < 0 then gap_w, extra = 0, 0 end       -- 内容撑满时退化为紧挨着
    for i, c in ipairs(cells) do
        table.insert(g, c)
        if i < n then
            table.insert(g, HorizontalSpan:new{
                width = gap_w + (i == n - 1 and extra or 0),
            })
        end
    end
    return g, truncated
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

local function curveWidget(curve, usable_w, avail_h)
    local peak = 1
    for _, v in ipairs(curve) do if v > peak then peak = v end end
    return CurveWidget:new{
        values = curve,
        w = usable_w,
        -- 按"内容区"的比例，不是按屏幕高度：横屏时两者差得远，
        -- 占内容区 12% 才是本意（screensaver.lua:330-335 不会把本模式转成竖屏）
        h = math.floor(avail_h * 0.12),
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
    table.insert(g, VerticalSpan:new{ width = Size.padding.default })

    -- 进度条
    local bar_w = usable_w
    local fill = math.max(2, math.floor(bar_w * math.min(cur.frac, 1)))
    table.insert(g, HorizontalGroup:new{ align = "center",
        rect(fill, Screen:scaleBySize(14)),   -- 与官方 readerprogress.lua:262 一致
        HorizontalSpan:new{ width = 1 },
    })
    table.insert(g, VerticalSpan:new{ width = Size.padding.default })

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

    -- 日期列宽按真实文字宽度量，写死的话字号一变就会被截成 "2026-..."
    local probe = txt("2026-08", FACE_L())
    local ok_p, psz = pcall(function() return probe:getSize() end)
    local date_w = ((ok_p and psz and psz.w) or Screen:scaleBySize(80))
                   + Screen:scaleBySize(6)
    local gap_w = Screen:scaleBySize(14)
    local line_gap = Size.padding.large
    local used, shown = 0, 0
    local last_h = 0            -- 最后一行的行高：退行时要拿它回滚 used

    for _, t in ipairs(items) do
        local dw = txt(t.label, FACE_L(), date_w)
        local tw = txt(t.title or "", FACE_L(), usable_w - date_w - gap_w)
        local h = math.max(dw:getSize().h, tw:getSize().h)
        if used + h + line_gap > budget_h then break end
        table.insert(g, HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = date_w, h = h }, dw },
            HorizontalSpan:new{ width = gap_w },
            tw })
        table.insert(g, VerticalSpan:new{ width = line_gap })
        used = used + h + line_gap
        last_h = h
        shown = shown + 1
    end

    if shown < #items then
        -- 上面这个循环是贪心的，会把 budget_h 吃干净，fit 循环替提示行预留的那块
        -- 空间照样会被填成书。所以提示行放不下时要退掉最后一行给它腾位置：
        -- 宁可少显示一本，也要让用户知道下面还有。fit 循环按 min_fin_rows 行
        -- + 提示行预留过空间（见 buildWidget 的 need），退一行后仍不少于 min_fin_rows 行，
        -- 所以只退一行、不循环。shown > 1 是兜底：只剩一本时显示这本书比
        -- 显示"还有 N 本"有用。
        local function hintFor(n)
            return txt(string.format("…更早还有 %d 本", n), FACE_S(), usable_w)
        end
        local more = hintFor(#items - shown)
        if used + more:getSize().h > budget_h and shown > 1 then
            table.remove(g)                     -- 退掉 VerticalSpan
            table.remove(g)                     -- 退掉 HorizontalGroup
            used = used - (last_h + line_gap)
            shown = shown - 1
            more = hintFor(#items - shown)      -- 少显示了一本，N 变了，文案得重建
        end
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

-- 按当前的 FSCALE 排一遍版。返回值供 fit 循环判断"放不放得下"：
--   widget     排好的部件
--   budget     留给"已读完"列表的高度预算（可能为负 = 溢出）
--   fin_row_h  "已读完"一行占多高
--   truncated  四列小块里有没有哪一格被截断
--   fin_hint_h "…更早还有 N 本"那行占多高
local function layoutOnce(data, d, fin_data)
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- 留白按屏幕"短边"的 6%，不能按 getWidth()：横屏时宽度是长边，
    -- 按宽度取会白白吃掉本来就紧张的高度。下限用 KOReader 的
    -- Size.padding.fullscreen（原生全屏 widget 就是这个值，readerprogress.lua:30）。
    local pad = math.max(Size.padding.fullscreen, math.floor(math.min(W, H) * 0.06))
    local avail_h = H - pad * 2          -- 内容区高度：曲线、预算、余白分配共用同一个口径
    local usable = W - pad * 2
    local root = VerticalGroup:new{ align = "left" }

    -- 区块之间的间距做成"弹性"的：先按基准值排版，剩余高度在末尾统一分配（见下面的 slack 块）。
    local flex = {}
    local function gap(px)
        local w = Screen:scaleBySize(px)
        local sp = VerticalSpan:new{ width = w }
        sp._base = w            -- 记下基准值：余白按基准比例分，不是均分
        flex[#flex + 1] = sp
        table.insert(root, sp)
    end

    local row1, cut1 = cellRow({
        { "今日", fmtHM(d.today) }, { "本周", fmtHM(d.week) },
        { "本月", fmtHM(d.month) }, { "今年", fmtHM(d.year) },
    }, usable)
    table.insert(root, row1)
    gap(16)
    table.insert(root, hrule(usable))
    gap(16)

    local row2, cut2 = cellRow({
        { "连续天数", tostring(d.streak) },
        { "有效日均", fmtHM(d.avg_active) },
        { "累计", fmtHours(d.total) },
        { "今日页数", tostring(d.pages_today), string.format("本周 %d 页", d.pages_week) },
    }, usable)
    table.insert(root, row2)
    gap(22)

    local curve, peak = curveWidget(d.curve, usable, avail_h)
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
        local function hof(w) local ok, sz = pcall(function() return w:getSize() end)
            return (ok and sz and sz.h) or -1 end
        logger.info(string.format(
            "densestats layout: screen=%dx%d dpi_scale=%d pad=%d usable=%d curve_w=%d curve_h=%d "
            .. "大字高=%d 正文高=%d 小字高=%d",
            W, H, Screen:scaleBySize(100), pad, usable, wof(curve), hof(curve),
            hof(txt("8h26", FACE_V())), hof(txt("书名", FACE_M())), hof(txt("标签", FACE_L()))))
    end

    -- 已读完：先量此刻用掉多少高度，剩下的（扣掉页脚）全给它，装不下就截断
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
    -- 两个 12：一个是页脚上方的 gap(12)；另一个没有对应元素，是纯保守余量，
    -- 宁可"已读完"少放一行也不要顶出屏幕。
    local budget = avail_h - used_h - footer_h - Screen:scaleBySize(12) - Screen:scaleBySize(12)
    -- 一行"已读完"占多高：口径必须和 finishedRows 里的行高一致
    -- （同为辅助档 + Size.padding.large），否则 fit 循环会按错误的行高预留空间
    local fin_row_h = txt("2026-08", FACE_L()):getSize().h + Size.padding.large
    -- 「…更早还有 N 本」那行的高度（辅助档，不带 line_gap——finishedRows 里它是
    -- used + more:getSize().h <= budget_h，没有额外间距）。
    -- 把它算进 fit 的门槛，否则列表一被截断这行提示就没地方画了。
    local fin_hint_h = txt("…", FACE_S()):getSize().h
    table.insert(root, finishedRows(fin_data, usable, math.max(0, budget)))

    gap(12)
    table.insert(root, footer)
    root:resetLayout()

    -- 剩余高度先让区块间隙按各自基准值的比例吸收（单个最多长到基准的
    -- CFG.gap_max_ratio 倍），吸收不掉的对半塞进上下边距，让内容块整体垂直居中。
    -- 原来是一股脑均摊进所有间隙，"已读完"的书不够多时整屏看着松垮。
    -- 注意 getSize() 会缓存 _offsets，改完必须 resetLayout()，
    -- 否则 paintTo 时 _offsets[i] 为 nil 直接崩（verticalgroup.lua:51）。
    local ok_h, ch = pcall(function() return root:getSize().h end)
    if ok_h and ch then
        local bases = {}
        for i, sp in ipairs(flex) do bases[i] = sp._base end
        local alloc = Layout.distributeSlack(bases, avail_h - ch, CFG.gap_max_ratio)
        for i, sp in ipairs(flex) do
            sp.width = sp._base + alloc.gains[i]
        end
        -- 上下边距各插一个 span：顶部插到最前，底部追加在页脚之后。
        -- 这两个 span 不进 flex 表——它们是边距，不参与间隙分配。
        if alloc.top > 0 then
            table.insert(root, 1, VerticalSpan:new{ width = alloc.top })
        end
        if alloc.bottom > 0 then
            table.insert(root, VerticalSpan:new{ width = alloc.bottom })
        end
        root:resetLayout()

        if os.getenv("DENSESTATS_DEBUG") == "1" then
            -- distributeSlack 的效果在正常藏书量下只有几像素，目测验不出来；
            -- 触顶数是关键信号：0/N 说明余白还没多到需要封顶，N/N 才是"已读完"接近空的情形
            local given, capped = 0, 0
            for i = 1, #flex do
                given = given + alloc.gains[i]
                if alloc.limits[i] > 0 and alloc.gains[i] >= alloc.limits[i] then
                    capped = capped + 1
                end
            end
            logger.info(string.format(
                "densestats slack: rest=%d gains=%d 触顶=%d/%d top=%d bottom=%d",
                avail_h - ch, given, capped, #flex, alloc.top, alloc.bottom))
        end
    end

    local widget = CenterContainer:new{
        densestats = true,   -- 标记：用来验证屏保确实拿到了我们的部件
        dimen = Screen:getSize(),
        FrameContainer:new{
            width = W, height = H,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, padding = pad,
            root,
        },
    }
    return widget, budget, fin_row_h, (cut1 or cut2), fin_hint_h
end

-- 一屏排不下就整体降字号重排。KOReader 官方处理"铺满一屏"就是这个套路：
-- calendarview.lua:1305-1319 用最宽字符串当探针 while 循环降号，
-- keyvaluepage.lua:492-501 从行高反推字号并封顶，menu.lua:135-141 封顶到
-- "至少能显示一行"。这一条同时解决三件事：横屏、用户把「屏幕 DPI」调大、
-- 以及内容变长——它不假设任何设备参数，只问"这次放不放得下"。
local function buildWidget()
    local data = collect()
    if not data then return nil end
    local d = Stats.derive(data, os.time(), CFG)
    -- 已读完列表也只读一次：loadCache 是 dofile，重排 8 轮就解析 8 遍，
    -- 而这跑在入睡路径上（同 collect 外提的理由）
    -- 计时用单调墙钟，不能用 os.clock()：后者是进程 CPU 时间，看不见阻塞 I/O，
    -- 而 getFinished() 内部是 dofile 读缓存文件，主要成本恰恰是磁盘读。
    -- 桌面有 page cache 所以无感，真机 eMMC 冷读时 os.clock() 会持续低估。
    local t0 = time.now()
    local fin_data = getFinished()

    local widget, step, tries = Layout.fitScale(CFG.fscale_steps, function(k)
        FSCALE = k
        local w, budget, fin_row_h, truncated, fin_hint_h = layoutOnce(data, d, fin_data)
        -- 门槛里带上提示行的高度：列表被截断时末尾要画「…更早还有 N 本」，
        -- 不预留就会被挤掉。代价是字号可能降一档，这是有意的取舍。
        local need = CFG.min_fin_rows * fin_row_h + fin_hint_h
        local fits = (not truncated) and budget >= need
        return fits, w
    end)

    if os.getenv("DENSESTATS_DEBUG") == "1" then
        -- fin= 是回归哨兵：只看别的数字的话，fin_data 没送到（传了 nil）时
        -- 每个字段都会一字不差，这个回归模式完全是盲区。
        -- nil 记 -1，好和"有缓存但列表为空"的 0 区分开。
        logger.info(string.format("densestats fit: FSCALE=%.2f tries=%d fin=%d 耗时=%.1fms",
            step or -1, tries or 0, fin_data and #(fin_data.titles or {}) or -1,
            time.to_ms(time.since(t0))))
    end
    return widget
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
    self:_maybeAutoShow()
    maybeRescanLater()
    self:_hookStatistics()
end

-- 睡眠屏幕接管点（对 KOReader 2026.07 核实过）：
--   screensaver.lua:548  widget = self.ui.statistics:onShowReaderProgress(true)
-- 所以包 ReaderStatistics 的实例方法：get_widget 为真（屏保调用）时返回我们的
-- widget，为假（菜单调用）时原样走官方逻辑。
--
-- 时机很关键：插件按目录名字母序实例化，densestats 排在 statistics 前面，
-- 所以 init() 跑的时候 self.ui.statistics 还不存在，在那里挂钩子必然落空
-- （症状：菜单预览正常，屏保却没被接管）。onReaderReady 时才保证已经就绪。
function DenseStats:_hookStatistics()
    local stats = self.ui and self.ui.statistics
    if not stats then return false end
    if rawget(stats, "_densestats_wrapped") then return true end
    -- KOReader 2026.07 把插件的 onXxx 事件处理器包成了"可调用的表"
    -- （字段 f/fname/context，metatable 上有 __call，用于出错时打印插件栈），
    -- 所以不能只认 type == "function"，否则接管永远挂不上。
    if not isCallable(stats.onShowReaderProgress) then
        logger.warn("densestats: onShowReaderProgress 不可调用（类型 "
                    .. type(stats.onShowReaderProgress) .. "），睡眠屏幕接管失败；"
                    .. "菜单里的预览仍可用")
        return false
    end
    stats._densestats_wrapped = true

    local orig = stats.onShowReaderProgress
    stats.onShowReaderProgress = function(this, get_widget)
        if get_widget then
            -- 原版这里第一件事就是 insertDB()，把本次阅读还在内存里的记录落盘。
            -- 绕过它的话，屏保上的"今日"会少算当前这一段。
            pcall(function() this:insertDB() end)
            local ok, w = pcall(buildWidget)
            if ok and w then return w end
            logger.warn("densestats: build failed:", w)
        end
        return orig(this, get_widget)
    end
    logger.info("densestats: 睡眠屏幕接管已挂载")
    return true
end

-- 入睡时撤掉还没执行的扫描任务。UIManager 有待办任务时会推迟进入待机，
-- 让一个纯粹的后台活儿拖住待机是白费电；下次开书会重新排。
function DenseStats:onSuspend()
    if rescan_scheduled then
        UIManager:unschedule(rescan_task)
        rescan_scheduled = false
    end
end

-- 调试用：设 DENSESTATS_AUTOSHOW=1 启动时自动弹出预览，方便截图。
function DenseStats:onReaderReady()
    self:_maybeAutoShow()
    maybeRescanLater()
    local hooked = self:_hookStatistics()
    if hooked and os.getenv("DENSESTATS_DEBUG") == "1" then
        -- 直接走一遍屏保那条路，确认返回的是我们的部件而不是内置页面
        local ok, w = pcall(function()
            return self.ui.statistics:onShowReaderProgress(true)
        end)
        logger.info("densestats: 屏保路径自检 ok=" .. tostring(ok)
                    .. " 是我们的部件=" .. tostring(ok and type(w) == "table" and w.densestats == true))
    end
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
