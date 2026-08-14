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
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local SQ3 = require("lua-ljsqlite3/init")
local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Layout = require("layout")
local Finished = require("finished")
local Stats = require("stats")
local Widget = require("ui/widget/widget")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
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

-- 天号转回日期字符串。天号 = (start_time + 时区偏移) / 86400，乘回去正好是
-- "当地那天零点"对应的 UTC 秒数，所以这里必须用 os.date("!...") 按 UTC 格式化；
-- 用本地格式化会把偏移再叠一次，跨时区设备上日期会整体错一天。
local function dayKeyOf(n)
    return os.date("!%Y-%m-%d", (tonumber(n) or 0) * 86400)
end

-- 往回 days 天的截断点，对齐到"当地日期的零点"。
-- 不对齐的话最早那个桶只覆盖半天，它的汇总值是残缺的。逐日时长那条只影响
-- 400 天前的边界（谁也用不到），但页数那条只查 9 天，边界离「本周」很近，
-- 必须对齐——实测不对齐时正好有一天的页数偏小。
local function dayCutoff(now, off, days)
    return (math.floor((now + off) / 86400) - days) * 86400 - off
end

local fmtHM, rowsOf = Stats.fmtHM, Stats.rowsOf

-- ============================ 取数 ============================

-- 上次 collect() 时数据库有多大。查询耗时几乎只跟这个数走（三条 SQL 里两条要扫
-- page_stat_data），日志里带上它，才能把"这台设备慢"和"这个库大"分开看。
local last_db_bytes = -1

-- 每次查询都必须带上 conn:exec 的第二个返回值当行数，理由见 stats.lua 的 rowsOf。
-- 包成函数是因为 Lua 的 f(g(), n) 会把 g() 截成一个返回值，写在调用点就得多两行。
local function queryRows(conn, sql, ncol)
    local res, n = conn:exec(sql)
    return rowsOf(res, ncol, n)
end

-- 单页停留时间上限。这是 statistics 插件的用户可调设置（双滑块，默认 120），
-- 不是常量——用户调低之后我们还按 120 截断就会比 KOReader 自己多算。
local function maxSec()
    local s = G_reader_settings and G_reader_settings:readSetting("statistics")
    return (type(s) == "table" and tonumber(s.max_sec)) or CFG.max_sec
end

local function collect()
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    -- 不存在就别开：SQ3.open 默认是 rwc，会凭空建一个空库，后面查表全是错。
    local db_attr = lfs.attributes(db_path)
    if not db_attr then
        logger.warn("densestats: statistics.sqlite3 不存在:", db_path)
        return nil
    end
    last_db_bytes = db_attr.size or -1
    -- 用 "rw" 而不是默认的 "rwc"：上面的存在性检查挡不住 0 字节或损坏的文件被
    -- rwc 重新初始化成空库。不用 "ro" 是实测过的——这个库跑 WAL，而 statistics
    -- 是查完就关连接、顺带 checkpoint 掉 -shm，所以熄屏时 -shm 通常不存在，
    -- 此时只读模式会直接失败（unable to open database file）。
    local ok_conn, conn = pcall(SQ3.open, db_path, "rw")
    if not ok_conn or not conn then
        logger.warn("densestats: 打开数据库失败:", conn)
        return nil
    end

    local off = tzOffset()
    local cap = maxSec()
    local data = {}
    local function query()

    -- 两条查询都要对几十万行做 GROUP BY / COUNT(DISTINCT)，不设这个就会落临时文件。
    -- 官方在重活前一律先设（statistics.koplugin/main.lua:347、
    -- coverbrowser 的 bookinfomanager.lua:239、vocabbuilder 的 db.lua:516）。
    -- 连接级 PRAGMA，不写库。busy_timeout 是给 WAL 关闭的老机器兜底（K2/DXG），
    -- 那些机器上写会阻塞读，而默认超时是 0，会立刻抛错。
    pcall(function()
        conn:exec("PRAGMA temp_store = 2;")
        conn:set_busy_timeout(2000)
    end)

    -- 逐日时长。只取近 window_days 天——曲线只要 30 天，今日/本周/本月/今年
    -- 最多回溯到年初，400 天足够覆盖，全表扫描留给下面那条便宜的汇总。
    --
    -- 这里原来把页数一起扫了，理由写的是"分开查等于把整表扫两遍"。那笔账算错了：
    -- 页数只喂给「今日页数」「本周页数」两个格子（stats.lua:83-88），却让
    -- COUNT(DISTINCT) 白扫了 400 天。拆开之后第二遍只扫 9 天，330k 行实测
    -- 200ms → 106ms + 2ms —— 扫两遍反而便宜一倍。
    --
    -- 另一处改动是用整数除法分桶，不再每行调一次 date() 做日历换算：
    -- 那一项占这条查询近三成（106ms → 72ms）。天号在 Lua 侧转回日期字符串，
    -- 一年也就几百次，可以忽略。
    --
    -- start_time > 0 不只是洁癖：SQLite 的整数除法是向零截断，不是向下取整，
    -- 所以负时间戳会把 [-86399, 86399] 这两天挤进同一个桶，并让所有更早的日号
    -- 整体偏后一天。1970 年前的脏数据和时钟回拨都会造出负值。
    local since = dayCutoff(os.time(), off, CFG.window_days)
    local by_day = {}
    for _, r in ipairs(queryRows(conn, string.format([[
        SELECT (start_time + %d) / 86400   AS d,
               SUM(MIN(duration, %d))      AS s
        FROM page_stat_data
        WHERE start_time >= %d AND start_time > 0
        GROUP BY d;
    ]], off, cap, since), 2)) do
        by_day[dayKeyOf(r[1])] = tonumber(r[2]) or 0
    end
    data.by_day = by_day

    -- 逐日页数只要够算「今日」和「本周」。本周最多回溯 6 天（周日往回到周一），
    -- 取 9 天是留给时区偏移和跨日边界的余量。
    local pages_by_day = {}
    for _, r in ipairs(queryRows(conn, string.format([[
        SELECT (start_time + %d) / 86400                 AS d,
               -- 乘数要大于任何可能的页码；SQLite 是 64 位整数，
               -- 就算 id 到十亿、页码到百万也不会溢出，不同书之间也不会撞车。
               COUNT(DISTINCT id_book * 10000000 + page) AS n
        FROM page_stat_data
        WHERE start_time >= %d AND start_time > 0
        GROUP BY d;
    ]], off, dayCutoff(os.time(), off, 9)), 2)) do
        pages_by_day[dayKeyOf(r[1])] = tonumber(r[2]) or 0
    end
    data.pages_by_day = pages_by_day

    -- 累计时长直接取 book 表的汇总列，比全表求和快一个数量级。
    -- 口径说明（原来这里的注释写的是"和逐行截断的结果一致"，那是错的）：
    -- book.total_read_time 是**未截断**的累加（statistics.koplugin/main.lua:965
    -- 的注释原话是 "the plain uncapped sum"），而且是对重排过的 page_stat 视图求和。
    -- 今天两者几乎相等，只是因为 insertDB 在写入时就已经按 max_sec 截过一遍，
    -- duration > max_sec 的行根本不存在。留用它是有意的取舍：它正是 KOReader
    -- 自己在统计页上显示的那个"累计"，屏保跟它保持一致比自己重算更有意义。
    -- 注意 SUM 会忽略 NULL，长期没打开过的书 total_read_time 可能为 NULL。
    local totals = queryRows(conn, string.format([[
        SELECT (SELECT SUM(total_read_time) FROM book),
               (SELECT COUNT(DISTINCT (start_time + %d) / 86400)
                  FROM page_stat_data WHERE start_time > 0);
    ]], off), 2)[1]
    if totals then
        data.total_all = tonumber(totals[1]) or 0
        data.active_days_all = tonumber(totals[2]) or 0
    end

    -- 当前在读 = 最近一条记录所属的那本。
    --
    -- 页码和总页数必须取自**同一条记录**。total_pages 记的是"写这条记录时的排版
    -- 页数"，换字号就会变——真实库里《当呼吸化为空气》有 7 个不同取值。原来
    -- MAX(p.page) 和 MAX(p.total_pages) 是两个独立聚合，各取自不同的行，屏幕上
    -- 就渲染成了 "100%  ·  278 / 286 页" 这种自相矛盾的结果（已复现）。
    -- 改成读最新那条记录，百分比也由它算，三个数字从此同源。
    local last = queryRows(conn, [[
        SELECT id_book, page, total_pages FROM page_stat_data
        WHERE start_time > 0 ORDER BY start_time DESC LIMIT 1;
    ]], 3)[1]
    if last then
        local id = tonumber(last[1]) or 0
        local page, pages = tonumber(last[2]) or 0, tonumber(last[3]) or 0
        local cur = queryRows(conn, string.format([[
            SELECT b.title, SUM(MIN(p.duration, %d))
            FROM page_stat_data p JOIN book b ON b.id = p.id_book
            WHERE p.id_book = %d;
        ]], cap, id), 2)[1]
        data.current = {
            title = tostring((cur and cur[1]) or "?"),
            sec   = tonumber(cur and cur[2]) or 0,
            page  = page,
            pages = pages,
            -- 夹到 1：记录当时的 total_pages 比当前页码小的话（换过字号）会超 100%
            frac  = pages > 0 and math.min(page / pages, 1) or 0,
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

-- 缓存走 LuaSettings，不再自己拼 Lua 源码。原来是 io.open("w") 立刻截断 + 逐行
-- write，写到一半断电或拔 USB 就留下半截文件，dofile 从此永远失败 → loadCache()
-- 恒为 nil → 12 小时节流永久失效 → 退化成"每次开书全库重扫一遍 sidecar"，而那
-- 是同步跑在亮屏路径上的活儿。LuaSettings 自带三件我们本来要自己写的事：
-- 写前把旧文件改名成 .old（luasettings.lua:252-267）、写完 fsync 文件和目录
-- （util.lua:1124-1143）、读失败自动回退 .old（luasettings.lua:31-45）。
local function cachePath()
    return DataStorage:getSettingsDir() .. "/densestats_finished.lua"
end

local function loadCache()
    local ok, s = pcall(LuaSettings.open, LuaSettings, cachePath())
    if not ok or not s then return nil end
    local months = s:readSetting("months")
    if type(months) ~= "table" then return nil end
    return {
        ts     = tonumber(s:readSetting("ts")) or 0,
        total  = tonumber(s:readSetting("total")) or 0,
        months = months,
        titles = s:readSetting("titles") or {},
    }
end

local function saveCache(summary)
    -- 只留最近 CFG.cache_titles 本：屏幕上最多显示十几行，而这个文件每次构建
    -- 屏保都要解析一遍，无上限增长会把成本压到入睡路径上。
    -- 总数 total 仍是全量，标题栏的"共 N 本"不受影响。
    local sorted = {}
    for _, t in ipairs(summary.titles or {}) do sorted[#sorted + 1] = t end
    table.sort(sorted, function(a, b)
        return (a.date or a.month or "") > (b.date or b.month or "")
    end)
    local titles = {}
    for i = 1, math.min(#sorted, CFG.cache_titles) do
        local t = sorted[i]
        titles[i] = { title = t.title, month = t.month, date = t.date or "" }
    end

    local ok, err = pcall(function()
        local s = LuaSettings:open(cachePath())
        s:saveSetting("ts", os.time())
        s:saveSetting("total", summary.total)
        s:saveSetting("months", summary.months)
        s:saveSetting("titles", titles)
        s:flush()
    end)
    -- 静默失败的后果很重（见上），必须让日志里看得见
    if not ok then
        logger.warn("densestats: 写缓存失败，已读完列表会每次开书重扫:", err)
    end
end

-- 扫描根目录：集中存放的 docsettings 目录 + 书库主目录（sidecar 默认在书旁边）
local function scanRoots()
    local roots, seen = {}, {}
    local function add(d)
        d = d and Finished.normDir(d) or ""   -- 尾斜杠不归一化会导致重复计数
        if d == "" then return end
        -- realpath 解开符号链接和多挂载点。只归一化尾斜杠只挡得住最表层的一种
        -- 等价路径；官方一律走 realpath（readcollection.lua:23、readhistory.lua:9）。
        -- Kindle 上尤其要紧：/mnt/base-us 和 /mnt/us 是同一份文件系统的两个视图，
        -- 两个都进 roots 的话每本书会被数两遍。
        local real = ffiUtil.realpath(d)
        d = real and Finished.normDir(real) or d
        if not seen[d] then seen[d] = true; roots[#roots + 1] = d end
    end
    -- 三种 sidecar 存放位置都要覆盖（docsettings.lua:22-28 的 doc / dir / hash）。
    -- hash 模式漏掉的话，用它的用户（只读书库、SD 卡、Calibre 同步）屏保上的
    -- "已读完"永远是空的，而且不会有任何报错。
    add(DataStorage:getDocSettingsDir())       -- "dir"：集中存放
    add(DataStorage:getDocSettingsHashDir())   -- "hash"：按 md5 分桶存放
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

-- 同步扫描 + 落盘。只该在子进程里跑，或者在起不了子进程时兜底。
-- 计时必须留着，否则"12 小时一次"到底是 200ms 还是 20s，只能靠猜。
local function scanAndSave()
    local t0 = time.now()
    local ok, summary = pcall(Finished.summarize, scanRoots(), lfs)
    if not ok then
        logger.warn("densestats: sidecar scan failed:", summary)
        return nil
    end
    saveCache(summary)
    logger.info(string.format("densestats: 扫描 sidecar 耗时 %.0fms，已读完 %d 本",
        time.to_ms(time.since(t0)), summary.total or -1))
    return summary
end

-- 自动重扫：扔进子进程，父进程立刻返回。
--
-- 全库递归 + 逐个 sidecar 读全文是这个插件最贵的动作，原来它同步跑在
-- UIManager 的定时任务里——也就是阻塞 UI 主线程，而且必然发生在亮屏的时候。
-- 官方做全库遍历一律走子进程（coverbrowser 的 bookinfomanager.lua:721、
-- 文件搜索的 filemanagerfilesearcher.lua:75-78）。
--
-- double_fork 让子进程被 init 收养，父进程完全不必回收僵尸
-- （ffi/util.lua:344-348 的注释写明了这一点），省掉 coverbrowser 那一整套
-- isSubProcessDone 轮询 + 看门狗。子进程自己把缓存写出来，父进程下次
-- loadCache() 自然就读到了，不需要任何回传通道。
local function rescanInBackground()
    local ok, pid = pcall(ffiUtil.runInSubProcess, function()
        scanAndSave()
    end, false, true)
    if not ok or not pid then
        logger.warn("densestats: 起子进程失败，退回同步扫描:", pid)
        return scanAndSave()
    end
    logger.info("densestats: sidecar 扫描已交给子进程")
    return nil
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
        rescanInBackground()
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

-- 小块内部居中：标签与数值共用中轴，短标签配长数值时不会一头沉。
-- 这里曾经是左对齐，理由是"位数变化只往右长，数字不会左右晃"——
-- 但这是睡眠屏，一次渲染就静止在那儿，看不到位数变化的过程，那条理由不成立。
local function cell(label, value, col_w, extra)
    local g = VerticalGroup:new{
        align = "center",
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

-- 一排小块：等宽列，每列居中。列宽只由 usable_w 和列数决定，与内容无关，
-- 所以上下两排的列边界完全一致，块与块自然对齐成网格。
--
-- 这里的历史值得留一句：最早是"等宽列 + 列内左对齐"，末列的字只占列宽一小截、
-- 右边空出一大块，看着像左右边距不等；于是改成了"两端对齐 + 按实测宽度均分"。
-- 那修掉了边距问题，却让两排的块宽不同、中间几块上下对不齐。
-- 病根其实在左对齐——它让首列贴死左边而末列悬在中间。居中之后首列左边也有留白，
-- 整排左右对称，等宽列才立得住，两个毛病一起消失。
local function cellRow(items, usable_w)
    local n = #items
    if n == 0 then return VerticalGroup:new{}, false end
    local col_w = math.floor(usable_w / n)          -- 列宽，也是单块最大宽度（超了截断）
    local truncated = false
    local g = HorizontalGroup:new{ align = "top" }
    for i, it in ipairs(items) do
        local c = cell(it[1], it[2], col_w, it[3])
        local ok, sz = pcall(function() return c:getSize() end)
        -- 有没有哪一格被 col_w 截成 "1234h5…"。isTruncated 走的是真实排版
        -- （含 kerning 和 CJK 回退字体），比自己量宽度可靠（textwidget.lua:307-310）。
        -- 截了就让外层的 fit 循环降一档字号重排：FSCALE 变小而 col_w 不变，
        -- 所以截断是单调消失的，循环必然收敛。
        for _, w in ipairs(c) do
            if type(w) == "table" and type(w.isTruncated) == "function" then
                local ok_t, cut = pcall(function() return w:isTruncated() end)
                if ok_t and cut then truncated = true end
            end
        end
        -- 除不尽的余数补给末列，整排才正好占满 usable_w，不会窄几个像素
        table.insert(g, CenterContainer:new{
            dimen = Geom:new{
                w = col_w + (i == n and (usable_w - col_w * n) or 0),
                h = (ok and sz and sz.h) or 0,
            },
            c,
        })
    end
    return g, truncated
end

-- 柱状曲线自绘：顺便画一条有效日均的参考虚线。
-- 纵轴刻度取 max(峰值, 1 小时)——这个兜底防止读得少的时候柱子顶满整图。
local CurveWidget = Widget:extend{ values = nil, w = 0, h = 0, scale = 3600, gap = 1, avg = 0 }

function CurveWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

-- 日均虚线距曲线顶端的偏移。paintTo 和外面摆标签的地方都要它，
-- 所以只在这里算一次——两边各写一份表达式，改一处漏一处就会错位。
function CurveWidget:lineOffset()
    return self.h - math.floor(self.h * (self.avg or 0) / self.scale)
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
    -- 有效日均参考线：虚线，画满整宽。原来这里画的是"1 小时"，那是个外部标准；
    -- 换成日均之后它是读者自己的基准，一眼能看出这 30 天里哪些天超过了平均。
    -- 日均为 0（没有任何记录）时不画，否则线会贴在底边和柱子根部糊在一起。
    if (self.avg or 0) <= 0 then return end
    local ry = y + self:lineOffset()
    local dash, step = Screen:scaleBySize(5), Screen:scaleBySize(10)
    local px = x
    while px < x + self.w do
        bb:paintRect(px, ry, math.min(dash, x + self.w - px), Screen:scaleBySize(1),
                     Blitbuffer.COLOR_GRAY)
        px = px + step
    end
end

-- 第三个返回值 line_y 是日均虚线距曲线顶端的偏移，调用方拿它把左侧的时长标签
-- 对齐到同一高度。
local function curveWidget(curve, usable_w, avail_h, avg)
    local peak = 1
    for _, v in ipairs(curve) do if v > peak then peak = v end end
    avg = avg or 0
    -- 按"内容区"的比例，不是按屏幕高度：横屏时两者差得远，
    -- 占内容区 12% 才是本意（screensaver.lua:330-335 不会把本模式转成竖屏）
    local h = math.floor(avail_h * 0.12)
    -- avg 必须进刻度。它是"终身"日均（stats.lua 用 book 表全量汇总算的），
    -- 而 peak 只是最近 30 天的单日峰值——两个窗口不同。只要这 30 天比平时清淡
    -- （放假、忙、生病），avg 就会超过 peak，虚线被算到曲线框外、横穿上方的标题。
    -- 纳入之后 lineOffset() ∈ [0, h] 恒成立；副作用是柱子整体压低、虚线贴顶，
    -- 而那正是"这 30 天没有一天达到我的平均水平"的正确表达。
    local scale = math.max(peak, avg, 3600)
    local w = CurveWidget:new{
        values = curve,
        w = usable_w,
        h = h,
        scale = scale,
        gap = Screen:scaleBySize(1),
        avg = avg,
    }
    return w, peak, w:lineOffset()
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
            math.floor(cur.frac * 100 + 0.5), cur.page, cur.pages, fmtHM(cur.sec))
    else
        line = string.format("累计 %s", fmtHM(cur.sec))
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
    probe:free()   -- 只用来量宽度，量完就脱离了树，free() 再也够不到它
    local date_w = ((ok_p and psz and psz.w) or Screen:scaleBySize(80))
                   + Screen:scaleBySize(6)
    local gap_w = Screen:scaleBySize(14)
    local line_gap = Size.padding.large
    -- 装得下几行放几行，装不下就截断，末尾不再提示"还有 N 本"——
    -- 区块标题那行的"已读完 · 共 N 本"已经给出了总数，提示行是重复信息。
    local used = 0
    for _, t in ipairs(items) do
        local dw = txt(t.label, FACE_L(), date_w)
        local tw = txt(t.title or "", FACE_L(), usable_w - date_w - gap_w)
        local h = math.max(dw:getSize().h, tw:getSize().h)
        if used + h + line_gap > budget_h then
            -- 这一对已经建好但放不进树，跳出前自己放掉
            dw:free(); tw:free()
            break
        end
        table.insert(g, HorizontalGroup:new{ align = "center",
            LeftContainer:new{ dimen = Geom:new{ w = date_w, h = h }, dw },
            HorizontalSpan:new{ width = gap_w },
            tw })
        table.insert(g, VerticalSpan:new{ width = line_gap })
        used = used + h + line_gap
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

    -- 有效日均不再占一格：它画成了曲线上的参考线（见下）。腾出来的位置让
    -- 累计、今日页数、本周页数各进一格，四列变成"天数 / 时长 / 页数 / 页数"。
    -- 原来"今日页数"底下挂着"本周 N 页"的附注，四列里只有它有附注，看着是个疙瘩。
    -- 标签一律"2 字限定词 + 2 字单位名"，这一排内部字数才齐。上一排是纯时间段、
    -- 值全是时长，不需要单位名，所以维持 2 字——两排各自统一，中间隔着分隔线。
    -- 不把这排压成 2 字是因为"今日页数"只能叫"今日"，会和上一排的"今日"撞名。
    local row2, cut2 = cellRow({
        { "连续天数", tostring(d.streak) },
        { "累计时长", fmtHM(d.total) },
        { "今日页数", tostring(d.pages_today) },
        { "本周页数", tostring(d.pages_week) },
    }, usable)
    table.insert(root, row2)
    gap(22)

    -- 日均的时长标签摆在曲线左边、图外，与虚线同高。放图内会遮住最左边两三天的
    -- 柱子；而放回格子里就只是个孤立数字，画成线才看得出哪些天超过了自己的平均。
    -- 日均为 0（全新安装、一条记录都没有）时不画参考线，标签也别摆——
    -- 否则会出现一个指向虚空的"0m"。这种情况下曲线占满整宽。
    local avg_label = d.avg_active > 0 and txt(fmtHM(d.avg_active), FACE_L()) or nil
    local avg_gap = avg_label and Screen:scaleBySize(8) or 0
    local avg_w = avg_label and avg_label:getSize().w or 0
    local curve, peak, line_y = curveWidget(d.curve, usable - avg_w - avg_gap,
                                            avail_h, d.avg_active)
    table.insert(root, txt(string.format("最近 30 天 · 共 %s · 峰值 %s",
        fmtHM(d.curve_total), fmtHM(peak)), FACE_L()))
    gap(5)
    if avg_label then
        -- 标签垂直居中对齐到虚线，并夹在曲线高度范围内。刻度已经把 avg 纳入
        -- （见 curveWidget），line_y 不会越界，这层钳位只兜极端字号下的取整误差。
        local label_h = avg_label:getSize().h
        local label_top = math.max(0, math.min(curve:getSize().h - label_h,
                                               line_y - math.floor(label_h / 2)))
        table.insert(root, HorizontalGroup:new{ align = "top",
            VerticalGroup:new{ align = "left",
                VerticalSpan:new{ width = label_top },
                avg_label,
            },
            HorizontalSpan:new{ width = avg_gap },
            curve,
        })
    else
        table.insert(root, centered(usable, curve))
    end
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
        -- 这三个纯探针不进树，量完当场放掉（curve 在树上，绝不能碰）
        local p_v, p_m, p_l = txt("8h26", FACE_V()), txt("书名", FACE_M()), txt("标签", FACE_L())
        logger.info(string.format(
            "densestats layout: screen=%dx%d dpi_scale=%d pad=%d usable=%d curve_w=%d curve_h=%d "
            .. "大字高=%d 正文高=%d 小字高=%d",
            W, H, Screen:scaleBySize(100), pad, usable, wof(curve), hof(curve),
            hof(p_v), hof(p_m), hof(p_l)))
        p_v:free(); p_m:free(); p_l:free()
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
    local row_probe = txt("2026-08", FACE_L())
    local fin_row_h = row_probe:getSize().h + Size.padding.large
    row_probe:free()   -- 同 finishedRows 里那个 probe：量完即弃，不在树上
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
    return widget, budget, fin_row_h, (cut1 or cut2)
end

-- 一屏排不下就整体降字号重排。KOReader 官方处理"铺满一屏"就是这个套路：
-- calendarview.lua:1305-1319 用最宽字符串当探针 while 循环降号，
-- keyvaluepage.lua:492-501 从行高反推字号并封顶，menu.lua:135-141 封顶到
-- "至少能显示一行"。这一条同时解决三件事：横屏、用户把「屏幕 DPI」调大、
-- 以及内容变长——它不假设任何设备参数，只问"这次放不放得下"。
-- 计时用单调墙钟，不能用 os.clock()：后者是进程 CPU 时间，看不见阻塞 I/O，
-- 而这条路径上 collect() 要读数据库、getFinished() 要 dofile 读缓存文件，
-- 主要成本恰恰是磁盘读。桌面有 page cache 所以无感，真机 eMMC 冷读时
-- os.clock() 会持续低估。
--
-- 分段计时，而且是无条件 logger.info（不挂在 DENSESTATS_DEBUG 后面）：
-- 这段代码在每次熄屏时跑一遍，而且跑在设备还醒着的时候
-- （kindle/device.lua 里 Screensaver:show() 排在 powerd:beforeSuspend() 之前），
-- 所以它的开销记在"亮屏"账上。要判断这个插件对续航的实际影响，
-- 唯一的办法就是让真机把每次的耗时写进 crash.log，估算代替不了。
-- 原来的计时起点在 collect() 之后，SQL 和数据库冷读整个是盲区。
-- 上次胜出的字号档位下标。这一屏的内容在相邻两次熄屏之间几乎不变，
-- 每次都从最大档一路降下来等于把同一份排版白算几遍。
local last_fit_idx = 1

local function buildWidget()
    local t_begin = time.now()
    local data = collect()
    local ms_sql = time.to_ms(time.since(t_begin))
    if not data then return nil end

    local t_derive = time.now()
    local d = Stats.derive(data, os.time(), CFG)
    local ms_derive = time.to_ms(time.since(t_derive))

    -- 已读完列表只读一次：loadCache 是 dofile，重排 8 轮就解析 8 遍，
    -- 而这跑在入睡路径上（同 collect 外提的理由）
    local t_cache = time.now()
    local fin_data = getFinished()
    local ms_cache = time.to_ms(time.since(t_cache))

    local t_layout = time.now()
    -- 从"上次胜出的档位再大一档"开始试：命中就一轮结束，内容变短时也能一次
    -- 升一档地回去，不会被永久钉在小字号上。
    -- 没胜出的那几棵树必须显式 free()：TextWidget 持有 xtext 的 C 侧 malloc 对象
    -- （textwidget.lua:190），LuaJIT 的 GC 看不见那些字节、不会因此被触发，而这段
    -- 跑在熄屏路径上。官方在完全相同的字号探针循环里也是逐轮 free
    -- （calendarview.lua:1314/1318、keyvaluepage.lua:635-636）。
    -- 放在下一轮开头而不是当场放，是因为回调不知道自己是不是最后一轮——
    -- 全都放不下时 fitScale 会把最后一棵当兜底返回，当场 free 就会返回一棵死树。
    local pending_free
    local widget, step, tries, fit_idx = Layout.fitScale(CFG.fscale_steps, function(k)
        if pending_free then
            pcall(function() pending_free:free() end)
            pending_free = nil
        end
        FSCALE = k
        local w, budget, fin_row_h, truncated = layoutOnce(data, d, fin_data)
        local fits = (not truncated) and budget >= CFG.min_fin_rows * fin_row_h
        if not fits then pending_free = w end
        return fits, w
    end, math.max(1, last_fit_idx - 1))
    last_fit_idx = fit_idx or 1
    local ms_layout = time.to_ms(time.since(t_layout))

    -- fin= 是回归哨兵：只看别的数字的话，fin_data 没送到（传了 nil）时
    -- 每个字段都会一字不差，这个回归模式完全是盲区。
    -- nil 记 -1，好和"有缓存但列表为空"的 0 区分开。
    logger.info(string.format(
        "densestats build: 合计 %.0fms = SQL %.0f + 汇总 %.0f + 缓存 %.0f + 排版 %.0f"
        .. " | 排版 %d 轮 FSCALE=%.2f | 库 %.1fMB | fin=%d",
        time.to_ms(time.since(t_begin)), ms_sql, ms_derive, ms_cache, ms_layout,
        tries or 0, step or -1, last_db_bytes / 1048576,
        fin_data and #(fin_data.titles or {}) or -1))
    return widget
end

-- ============================ 调试预览 ============================

local Preview = InputContainer:extend{}

function Preview:init()
    self.dimen = Screen:getSize()
    self.covers_fullscreen = true   -- 提示 UIManager:_repaint() 不必重画下层（readerprogress.lua:49）
    local ok_b, w = pcall(buildWidget)
    if not ok_b then logger.warn("densestats: preview build failed:", w); w = nil end
    self[1] = w or CenterContainer:new{
        dimen = Screen:getSize(),
        TextWidget:new{ text = "densestats: 构建失败，看 crash.log", face = FACE_M() },
    }
    -- 两条腿都要上。原来只注册了 Tap，按键机型（无触摸的 Kindle）进了这个全屏页
    -- 就再也出不来，只能重启 KOReader。官方的全屏 widget 一律两条都给：
    -- readerprogress.lua:492-500、screensaverwidget.lua:19-26。
    if Device:hasKeys() then
        self.key_events = { AnyKeyPressed = { { Device.input.group.Any } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    end
end

function Preview:onClose()
    UIManager:close(self)
    return true
end
Preview.onTap = Preview.onClose
Preview.onAnyKeyPressed = Preview.onClose
-- 全屏 widget 的惯例：上下滑关不掉时，任意多指滑动都可以关（readerprogress.lua:500）
Preview.onMultiSwipe = Preview.onClose

function Preview:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

-- ============================ 插件挂载 ============================

local DenseStats = WidgetContainer:extend{
    name = "densestats",
    is_doc_only = false,
    -- 声明这个，插件管理里"禁用并删除设置""删除插件和设置"两个入口才会出现
    -- （pluginloader.lua:377-378 就查 deletePluginSettings / settings_file /
    -- settings_key 三者之一）。不声明的话卸载后缓存文件永久残留。
    settings_file = DataStorage:getSettingsDir() .. "/densestats_finished.lua",
}

function DenseStats:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
    self:_maybeAutoShow()
    maybeRescanLater()
    self:_hookStatisticsLater()
end

-- 让两个动作能绑手势、实体键和 Profiles。Dispatcher:registerAction 自身幂等
-- （dispatcher.lua:656-662 判 nil 才写），所以每个实例都调一次是安全的，
-- 官方模板（hello.koplugin/main.lua:23-28）就是在 init 里直接调。
function DenseStats:onDispatcherRegisterActions()
    Dispatcher:registerAction("densestats_preview",
        { category = "none", event = "DenseStatsPreview", title = _("Preview dense stats screen"), general = true })
    Dispatcher:registerAction("densestats_rescan",
        { category = "none", event = "DenseStatsRescan", title = _("Rescan finished books"), general = true })
end

-- 睡眠屏幕接管点（对 KOReader 2026.07 核实过）：
--   screensaver.lua:548  widget = self.ui.statistics:onShowReaderProgress(true)
-- 所以包 ReaderStatistics 的实例方法：get_widget 为真（屏保调用）时返回我们的
-- widget，为假（菜单调用）时原样走官方逻辑。
--
-- 时机很关键：插件按目录路径字母序实例化（pluginloader.lua 里
-- table.sort(..., v1.path < v2.path)），densestats 排在 statistics 前面，
-- 而两个 UI 都是"先 createPluginInstance（跑 init()）再 registerModule"
-- （filemanager.lua:418-429、readerui.lua:463-476），所以 init() 里
-- self.ui.statistics 必然还不存在，在那儿挂钩子一定落空。
--
-- 原来靠 onReaderReady 补挂，但那是 ReaderUI 独有的事件（readerui.lua:517），
-- FileManager 从不广播它 —— 于是在文件浏览器里锁屏永远走不到我们的屏，
-- 而是回退成内置逻辑（症状：显示回之前的壁纸）。
-- registerPostInitCallback 是两种 UI 下唯一对称、且保证"全部模块已注册"
-- 的时机（filemanager.lua:391/434、readerui.lua:106/484）。
function DenseStats:_hookStatisticsLater()
    local ui = self.ui
    -- postInitCallback 跑完会被置 nil，那之后再 register 会往 nil 里 insert 直接崩；
    -- 真遇到这种时序就当场试一次，至少 ReaderUI 那条路还有 onReaderReady 兜底。
    if ui and isCallable(ui.registerPostInitCallback) and ui.postInitCallback then
        ui:registerPostInitCallback(function() self:_hookStatistics() end)
    else
        self:_hookStatistics()
    end
end

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

-- 醒来重排。onSuspend 撤了任务却没人负责放回去的话，"阅读中途熄屏、醒来接着读"
-- 这条最常见的路径上，本次会话的重扫就被静默跳过了——重排只发生在 init() 和
-- onReaderReady()，而这两个入口在唤醒时都不会再触发。官方的 onSuspend/onResume
-- 也是成对的（autosuspend.koplugin/main.lua:344-390）。
function DenseStats:onResume()
    maybeRescanLater()
end

-- UI 被拆掉时撤干净：定时任务活在 UIManager 的队列里，比这个实例活得久。
-- 官方同样在这里收尾（autosuspend.koplugin/main.lua:233-244、
-- readtimer.koplugin/main.lua:573-579）。
function DenseStats:onCloseWidget()
    if rescan_scheduled then
        UIManager:unschedule(rescan_task)
        rescan_scheduled = false
    end
end

function DenseStats:onDenseStatsPreview()
    UIManager:show(Preview:new{})
    return true
end

function DenseStats:onDenseStatsRescan()
    self:_rescanWithFeedback()
    return true
end

-- 调试用：设 DENSESTATS_AUTOSHOW=1 启动时自动弹出预览，方便截图。
function DenseStats:onReaderReady()
    self:_maybeAutoShow()
    maybeRescanLater()
    -- 这里的 _hookStatistics 现在是兜底：readerui.lua:485-489 在广播 ReaderReady
    -- 之前就把 postInitCallback 抽干了，所以正常路径下钩子早已挂上，这一次必然
    -- 走 _densestats_wrapped 的早退。留着是防 postInitCallback 那条路失效。
    local hooked = self:_hookStatistics()
    if hooked and os.getenv("DENSESTATS_DEBUG") == "1" then
        -- 直接走一遍屏保那条路，确认返回的是我们的部件而不是内置页面
        local ok, w = pcall(function()
            return self.ui.statistics:onShowReaderProgress(true)
        end)
        logger.info("densestats: 屏保路径自检 ok=" .. tostring(ok)
                    .. " 是我们的部件=" .. tostring(ok and type(w) == "table" and w.densestats == true))
        -- 自检建出来的树只用来读一个字段，不 show 也不进任何容器，自己放掉
        if ok and type(w) == "table" and type(w.free) == "function" then
            pcall(function() w:free() end)
        end
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

-- 手动重扫走 Trapper：扫描仍在子进程里跑，但结果会回传，所以还能报出本数；
-- 传字符串时 Trapper 自己负责建、显示和关闭那个可点掉的提示窗
-- （trapper.lua:511-524 + 尾部的 UIManager:close）。没包在 Trapper:wrap 里
-- 调用的话它会退化成阻塞执行并打 warn，不会崩。
function DenseStats:_rescanWithFeedback()
    local InfoMessage = require("ui/widget/infomessage")
    Trapper:wrap(function()
        local completed, summary = Trapper:dismissableRunInSubprocess(function()
            return Finished.summarize(scanRoots(), lfs)
        end, "正在扫描已读完的书……（点击可取消）")
        if not completed then return end   -- 用户点掉了
        if type(summary) ~= "table" then
            UIManager:show(InfoMessage:new{ text = "扫描失败" })
            return
        end
        saveCache(summary)
        UIManager:show(InfoMessage:new{ text = string.format("已读完 %d 本", summary.total) })
    end)
end

function DenseStats:addToMainMenu(menu_items)
    menu_items.densestats_rescan = {
        text = "重新扫描已读完书籍",
        sorting_hint = "more_tools",
        -- 回调会弹 InfoMessage，不加这个的话主菜单会被一起关掉
        -- （官方同类项的惯例，statistics.koplugin/main.lua:1274-1278）
        keep_menu_open = true,
        callback = function()
            self:_rescanWithFeedback()
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
