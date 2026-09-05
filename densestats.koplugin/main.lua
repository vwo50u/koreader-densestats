--[[
densestats.koplugin — 高密度阅读统计睡眠屏幕

接管内置的 "readingprogress" 睡眠屏幕类型：screensaver.lua 在该模式下调用
ui.statistics:onShowReaderProgress(true) 取 widget，本插件包住这个方法。
设置里仍选「在休眠屏幕上显示阅读进度」。
数据只读 statistics 插件的 statistics.sqlite3，不写。
statistics 插件必须保持启用。

设备上想看效果，直接锁屏就是。
桌面/模拟器上睡眠屏幕功能不可用，用 DENSESTATS_AUTOSHOW=1 启动，
六秒后会自动弹出同一份部件（见 _maybeAutoShow）——这是纯开发用的口子，
菜单里没有入口。
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
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local RightContainer = require("ui/widget/container/rightcontainer")
local SQ3 = require("lua-ljsqlite3/init")
local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Finished = require("finished")
local Stats = require("stats")
local Widget = require("ui/widget/widget")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
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
    tz_offset = nil,            -- 分日用的时区偏移（秒）。nil = 按进程时区自动推断，见 tzOffset
}
-- =================================================================

-- 分日的时区偏移，跟 statistics 插件同一口径：它按 SQLite 的 'localtime' 分日
-- （statistics.koplugin/main.lua:273），也就是进程时区，所以这里取"本地时间 − UTC"。
-- Kindle 的系统时区是 UTC，算出来是 0，与 KOReader 自身的日历完全一致（已用真实库
-- 核对）；Android 这类时区正常的平台上是真实偏移。原来写死 0，在非 UTC 设备上
-- 早晨的阅读会被记到前一天，而 stats.derive 的 today_key 走本地日期，"今日"就漏了。
-- 偏移按"现在"算一次，跨夏令时切换的那一天边界差一小时，不管。
-- 在别的机器上读 Kindle 的库做对比时，用 DENSESTATS_TZ_OFFSET=0 压成 Kindle 的口径。
-- 实际用了多少写在 build 日志行的 tz= 里，换设备先看它。
local function tzOffset()
    -- 显式覆盖优先：环境变量 > CFG.tz_offset > 自动推断
    local env = os.getenv("DENSESTATS_TZ_OFFSET")
    if env then return math.floor(tonumber(env) or 0) end
    if CFG.tz_offset then return CFG.tz_offset end
    return Stats.tzOffsetAt(os.time())
end

-- 天号 ↔ 日期、截断点、时区偏移这三个纯函数放在 stats.lua 里，好用 luajit 单测；
-- 对齐和口径的说明见那边。
local fmtHM, fmtClock, rowsOf = Stats.fmtHM, Stats.fmtClock, Stats.rowsOf
local dayKeyOf, dayCutoff = Stats.dayKeyOf, Stats.dayCutoff

-- ============================ 取数 ============================

-- 上次 collect() 时数据库有多大。查询耗时几乎只跟这个数走（逐日那条要扫
-- page_stat_data，其余都是索引或主键点查），日志里带上它，才能把"这台设备慢"
-- 和"这个库大"分开看。
local last_db_bytes = -1
local last_tz_off = 0      -- 上次 collect() 用的时区偏移，同样只为进日志

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
    -- 用 "rw" 而不是默认的 "rwc"：单纯是"我们只读别人的库，不该带上创建语义"。
    -- （别把它当安全网：SQLite 把 0 字节文件也视为合法的空库，rwc 并不会
    -- "重建"什么，两种模式在损坏文件上的结局一样——查表失败、pcall 兜住、返回 nil。）
    -- 不用 "ro" 是实测过的：这个库跑 WAL，而 statistics 查完就关连接、顺带
    -- checkpoint 掉 -shm，所以熄屏时 -shm 通常不存在，只读模式此时会直接失败
    -- （unable to open database file）。
    local ok_conn, conn = pcall(SQ3.open, db_path, "rw")
    if not ok_conn or not conn then
        logger.warn("densestats: 打开数据库失败:", conn)
        return nil
    end

    local off = tzOffset()
    last_tz_off = off
    local cap = maxSec()
    local data = {}
    local function query()

    -- 逐日那条要对几十万行做 GROUP BY，不设这个就会落临时文件。
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

    -- 页数不查：crengine 下页码随字号浮动，"今日 46 页"说明不了什么。

    -- 累计时长直接取 book 表的汇总列，比全表求和快一个数量级。
    -- 口径说明（原来这里的注释写的是"和逐行截断的结果一致"，那是错的）：
    -- book.total_read_time 是**未截断**的累加（statistics.koplugin/main.lua:965
    -- 的注释原话是 "the plain uncapped sum"），而且是对重排过的 page_stat 视图求和。
    -- 今天两者几乎相等，只是因为 insertDB 在写入时就已经按 max_sec 截过一遍，
    -- duration > max_sec 的行根本不存在。留用它是有意的取舍：它正是 KOReader
    -- 自己在统计页上显示的那个"累计"，屏保跟它保持一致比自己重算更有意义。
    -- 注意 SUM 会忽略 NULL，长期没打开过的书 total_read_time 可能为 NULL。
    --
    -- 原来这里还顺带 COUNT(DISTINCT 天号) 数全量的有记录天数。那是整表扫描，
    -- 而它喂的"有效日均"在极简版里根本不上屏，每次熄屏白扫一遍。
    local totals = queryRows(conn, "SELECT SUM(total_read_time) FROM book;", 1)[1]
    if totals then
        -- 千万别写成 `or 0`。SUM 忽略 NULL，全表 total_read_time 都是 NULL 时它
        -- 返回 NULL；强行折成 0 会把 stats.lua 里"没有全量汇总就退回按窗口算"
        -- 那条回退路径彻底封死，屏幕上的累计时长直接变成 0，
        -- 而逐日明细里明明是有数据的。留 nil 才走得到回退。
        data.total_all = tonumber(totals[1])
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
        -- 只要书名和作者，按主键查 book 表就够了。原来这里 JOIN page_stat_data
        -- 把这本书的时长也 SUM 了一遍，那个数从来没上过屏。
        -- SQLite 默认不强制外键，孤儿 id_book 是可能出现的：查不到行就整块不显示；
        -- 查到了但 title 为 NULL 是"这本书没有书名元数据"，显示 "?" 加上正确的页码。
        local cur = queryRows(conn, string.format(
            "SELECT title, authors FROM book WHERE id = %d;", id), 2)[1]
        if cur then
            -- statistics 插件拿不到作者时写的是字面量 "N/A"（main.lua:162），
            -- 不是 NULL；多作者用换行分隔（与 doc_props.authors 同一约定）。
            local authors = cur[2] and tostring(cur[2]) or ""
            if authors == "N/A" then authors = "" end
            authors = authors:gsub("\n", " · ")
            data.current = {
                title   = tostring(cur[1] or "?"),
                authors = authors,
                page  = page,
                pages = pages,
                -- 夹到 1：记录当时的 total_pages 比当前页码小的话（换过字号）会超 100%
                frac  = pages > 0 and math.min(page / pages, 1) or 0,
            }
        end
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

-- 缓存时间戳的内存副本。maybeRescanLater 在每次唤醒都要判"缓存过期了没"，
-- 原来是整份 dofile 只为读一个 ts。有了这个副本，只在它说"过期"时才去碰盘确认，
-- 12 小时窗口内的唤醒一次盘都不读。
-- 只能当"可能新鲜"用，不能当"确定过期"用：子进程写完缓存后父进程的副本仍是旧值，
-- 所以过期判断必须回到磁盘再看一眼，否则会在每次唤醒时重复派子进程。
-- nil = 还没读过盘；0 = 读过但没有缓存。
local cache_ts_mem

local function loadCache()
    cache_ts_mem = 0
    local ok, s = pcall(LuaSettings.open, LuaSettings, cachePath())
    if not ok or not s then return nil end
    local total = tonumber(s:readSetting("total"))
    if not total then return nil end
    local c = { ts = tonumber(s:readSetting("ts")) or 0, total = total }
    cache_ts_mem = c.ts
    return c
end

local function cacheFresh(ts)
    return ts ~= nil and (os.time() - ts) < CFG.finished_cache_hours * 3600
end

local function saveCache(summary)
    -- 缓存里只有时间戳和总数：屏幕上就一行"读完 N 本"。原来还存最近几十本的
    -- 书名和逐月计数，那是已删掉的"已读完列表"的遗留，却让每次熄屏都多解析一遍。
    --
    -- 先写临时文件再 rename 覆盖过去。LuaSettings:flush 内部是
    -- io.open(path, "wb")（util.lua:1130），**原地截断**，不是原子替换；
    -- 而扫描现在跑在子进程里，父进程随时可能在熄屏路径上 loadCache()，
    -- 正好读到写了一半的文件就会 dofile 失败。LuaSettings 的 .old 回退兜不住这个：
    -- backup() 只在原文件 mtime 超过 60 秒时才做（luasettings.lua:252-267）。
    -- 同一文件系统内的 rename 是原子的，读者要么看到旧的完整文件、要么看到新的。
    --
    -- 两个副作用，知道就行，都不影响功能：
    -- 一是 util.writeToFile 会把目标路径写成文件首行的注释，所以缓存文件里那行
    -- 自述路径带着 ".new" 后缀（它只是个 Lua 注释）；
    -- 二是 .old 备份从此不再产生——backup() 作用在临时文件上，随后就被删了。
    -- 后者是有意的取舍：rename 保证了读者永远读不到半截文件，备份的意义本来
    -- 就在于此，而它原先还有"原文件不满 60 秒就不备份"的空窗。
    local final, tmp = cachePath(), cachePath() .. ".new"
    local ts = os.time()
    local ok, err = pcall(function()
        local s = LuaSettings:open(tmp)
        s:saveSetting("ts", ts)
        s:saveSetting("total", summary.total)
        s:flush()
    end)
    if ok then
        ok, err = os.rename(tmp, final)
        os.remove(tmp)              -- rename 成功时这是空操作
        os.remove(tmp .. ".old")    -- flush 可能给临时文件也留了个备份
    end
    -- 在子进程里这行改的是子进程自己的副本，没意义但也无害；
    -- 父进程走手动重扫（_rescanWithFeedback）时靠它免掉下一次的磁盘确认。
    if ok then cache_ts_mem = ts end
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
-- 已经派出去的子进程大约干到什么时候。double_fork 之后子进程被 init 收养，
-- 我们拿不到可 waitpid 的 pid，只能用时间兜住"别再派一个"。
-- 需要它是因为 rescan_scheduled 在任务**触发**时就清零了，而不是子进程结束时：
-- 首次安装（无缓存 → 1 秒后就扫）叠加一次挂起/唤醒或 UI 重建，就会在缓存还没
-- 写出来的时候再派一个，两个子进程写同一个文件。
local rescan_busy_until = 0

local function rescanInBackground()
    local ok, pid, err = pcall(ffiUtil.runInSubProcess, function()
        scanAndSave()
    end, false, true)
    -- runInSubProcess 失败时返回的是 (false, errmsg)，所以要接第三个值，
    -- 否则日志里只会打印一个光秃秃的 false，看不出原因。
    if not ok or not pid then
        logger.warn("densestats: 起子进程失败，退回同步扫描:", err or pid)
        return scanAndSave()
    end
    rescan_busy_until = os.time() + 600
    logger.info("densestats: sidecar 扫描已交给子进程")
    return nil
end

local rescan_scheduled = false
local rescan_task              -- 存下来才能 unschedule
local function maybeRescanLater()
    if rescan_scheduled then return end   -- ReaderUI 与 FileManager 各有一个插件实例
    if os.time() < rescan_busy_until then return end   -- 上一个子进程多半还在跑
    -- 内存副本说新鲜就信它，不碰盘；说过期才读盘确认（理由见 cache_ts_mem）
    if cacheFresh(cache_ts_mem) then return end
    local cache = loadCache()
    if cache and cacheFresh(cache.ts) then return end
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

-- ============================ 画面 ============================
--
-- 极简版：整屏只有一个大数字（今日时长），其余全部退成小字，大量用灰不用黑，
-- 零分隔线，统一左对齐。上一版是四列网格 + 八个大数字 + 黑柱 + 粗进度条，
-- 真机上看着满、重、黑。这一版三条原则各去掉一样：
--   字号只有三档，大字只给一个数；
--   墨色分黑 / 深灰 / 浅灰三级，黑只给今日时长和书名；
--   分区靠留白，不画线。
--
-- 字号写的是"未缩放的设计尺寸"，getFace 内部按屏幕短边 / 600 缩放
-- （font.lua:269-277、ffi/framebuffer.lua:414-425），跨分辨率自动成立。
-- 内容量是固定的，竖屏横屏都放得下，所以不再需要上一版的字号自适应循环。
local SIZE_HERO, SIZE_BODY, SIZE_SMALL = 64, 24, 20
local INK_BLACK = Blitbuffer.COLOR_BLACK
local INK_DIM   = Blitbuffer.COLOR_GRAY_4       -- 0x44：标签、辅助信息、柱子。真机上 0x88、0x66 都偏淡
local INK_FAINT = Blitbuffer.COLOR_LIGHT_GRAY   -- 0xCC：进度线的未读部分

local function faceHero()  return Font:getFace("largeffont", SIZE_HERO) end
local function faceBody()  return Font:getFace("ffont",      SIZE_BODY) end
local function faceSmall() return Font:getFace("smallffont", SIZE_SMALL) end

local function txt(s, face, color, max_width)
    return TextWidget:new{ text = tostring(s), face = face, fgcolor = color, max_width = max_width }
end

local function vspace(px)
    return VerticalSpan:new{ width = math.max(0, math.floor(px)) }
end

-- 30 天曲线：细柱、深灰、柱间留缝，没读的日子只留 1px 刻度。不画标题、峰值、日均线、
-- 横轴文字——这版里它是一段节奏纹理，不是一张要读数的图表。
-- 纵轴刻度取 max(峰值, 1 小时)，读得少的日子不会把柱子顶满整图。
-- 最后一根是今天：熄屏时今天多半只读了一半，画成浅灰，免得曲线结尾看着总像塌了一截。
local CurveWidget = Widget:extend{ values = nil, w = 0, h = 0, scale = 3600, gap = 1 }

function CurveWidget:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function CurveWidget:paintTo(bb, x, y)
    local n = #(self.values or {})
    if n == 0 or self.w <= 0 or self.h <= 0 then return end
    local gap = self.gap
    local bar_w = math.max(1, math.floor((self.w - gap * (n - 1)) / n))
    -- 读过的日子至少这么高，才和下面 1px 的空日刻度分得开（读 5 秒的日子原来也是 1px）
    local min_h = math.max(2, Screen:scaleBySize(2))
    for i, v in ipairs(self.values) do
        local bx = x + (i - 1) * (bar_w + gap)
        if v > 0 then
            local h = math.max(min_h, math.floor(self.h * v / self.scale))
            bb:paintRect(bx, y + self.h - h, bar_w, h, i == n and INK_FAINT or INK_DIM)
        else
            -- 没读的日子留一道 1px 刻度。原来什么都不画，空档和柱间缝分不开，
            -- 看不出曲线到底画到哪一天；深灰不用浅灰，1px 浅灰在墨水屏上会消失。
            bb:paintRect(bx, y + self.h - 1, bar_w, 1, INK_DIM)
        end
    end
end

-- 进度：一条细线，读过的黑、未读的浅灰。上一版是带描边的粗条，在这版里太重。
local function progressLine(frac, w)
    local h = Screen:scaleBySize(2)
    local done = math.floor(w * math.max(0, math.min(tonumber(frac) or 0, 1)))
    local g = HorizontalGroup:new{ align = "center" }
    if done > 0 then
        table.insert(g, LineWidget:new{ background = INK_BLACK, dimen = Geom:new{ w = done, h = h } })
    end
    if w - done > 0 then
        table.insert(g, LineWidget:new{ background = INK_FAINT, dimen = Geom:new{ w = w - done, h = h } })
    end
    return g
end

-- 整屏排版。垂直方向不拉伸：顶部留 15%，内容按固定间距往下排，电量贴底。
-- 间距按屏高的比例写，横屏时自动收紧。内容比屏幕还高（不该发生）时先吃顶部留白。
local function layout(data, d, fin_data)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad_x = math.floor(W * 0.12)
    local usable = W - pad_x * 2
    local col = VerticalGroup:new{ align = "left" }
    local function add(w) table.insert(col, w) end

    -- 唯一的大字：今天，没读就退到昨天 / 本周（见 Stats.hero）
    local hero_sec, hero_label = Stats.hero(d)
    add(txt(fmtClock(hero_sec), faceHero(), INK_BLACK, usable))
    add(vspace(Screen:scaleBySize(2)))
    add(txt(hero_label, faceSmall(), INK_DIM, usable))
    add(vspace(H * 0.04))

    -- 一行小字把连续、累计、读完本数收在一起，零值不写
    add(txt(Stats.summaryLine(d, fin_data and fin_data.total), faceSmall(), INK_DIM, usable))
    add(vspace(H * 0.09))

    -- 曲线
    local peak = 1
    for _, v in ipairs(d.curve) do if v > peak then peak = v end end
    add(CurveWidget:new{
        values = d.curve, w = usable, h = math.floor(H * 0.07),
        scale = math.max(peak, 3600), gap = Screen:scaleBySize(2),
    })
    add(vspace(H * 0.09))

    -- 当前在读：书名、作者 · 百分比、细线进度。没有在读的书就整块不画。
    -- 书名一行放不下就丢副标题；百分比向下取整，没读完就不许显示 100%。
    local cur = data.current
    if cur then
        local title = txt(cur.title, faceBody(), INK_BLACK)
        if title:getSize().w > usable then
            title = txt(Stats.shortTitle(cur.title), faceBody(), INK_BLACK, usable)
        end
        add(title)
        add(vspace(Screen:scaleBySize(6)))
        local sub = string.format("%d%%", math.floor(cur.frac * 100))
        if cur.authors and cur.authors ~= "" then sub = cur.authors .. "  ·  " .. sub end
        add(txt(sub, faceSmall(), INK_DIM, usable))
        add(vspace(Screen:scaleBySize(12)))
        add(progressLine(cur.frac, usable))
    end

    -- 电量：极小灰字，右下角。不放时钟——这屏一渲染就静止了，停住的钟只会误导。
    local batt
    local ok_p, pd = pcall(function() return Device:getPowerDevice() end)
    if ok_p and pd then
        batt = txt(string.format("%d%%", pd:getCapacity()), faceSmall(), INK_DIM)
    end

    col:resetLayout()
    local body_h = col:getSize().h
    local batt_h = batt and batt:getSize().h or 0
    local top, bottom = math.floor(H * 0.15), math.floor(H * 0.06)
    local rest = H - top - bottom - body_h - batt_h
    if rest < 0 then
        top = math.max(Screen:scaleBySize(16), top + rest)
        rest = 0
    end

    local root = VerticalGroup:new{ align = "left", vspace(top), col, vspace(rest) }
    if batt then
        table.insert(root, RightContainer:new{ dimen = Geom:new{ w = usable, h = batt_h }, batt })
    end
    table.insert(root, vspace(bottom))

    return CenterContainer:new{
        densestats = true,   -- 标记：用来验证屏保确实拿到了我们的部件
        dimen = Screen:getSize(),
        FrameContainer:new{
            width = W, height = H,
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, padding = 0,
            padding_left = pad_x, padding_right = pad_x,
            root,
        },
    }
end

-- 计时用单调墙钟，不能用 os.clock()：后者是进程 CPU 时间，看不见阻塞 I/O，
-- 而这条路径上 collect() 要读数据库、getFinished() 要 dofile 读缓存文件，
-- 主要成本恰恰是磁盘读。
-- 分段计时，而且是无条件 logger.info：这段代码在每次熄屏时跑一遍，而且跑在
-- 设备还醒着的时候（kindle/device.lua 里 Screensaver:show() 排在
-- powerd:beforeSuspend() 之前），所以它的开销记在"亮屏"账上。要判断这个插件
-- 对续航的实际影响，唯一的办法就是让真机把每次的耗时写进 crash.log。
local function buildWidget()
    local t_begin = time.now()
    local data = collect()
    local ms_sql = time.to_ms(time.since(t_begin))
    if not data then return nil end

    local d = Stats.derive(data, os.time(), CFG)
    local fin_data = getFinished()

    local t_layout = time.now()
    local widget = layout(data, d, fin_data)
    local ms_layout = time.to_ms(time.since(t_layout))

    -- fin= 是回归哨兵：fin_data 没送到（传了 nil）时别的数字一字不差。
    -- nil 记 -1，好和"有缓存但一本都没读完"的 0 分开。
    logger.info(string.format(
        "densestats build: 合计 %.0fms = SQL %.0f + 排版 %.0f | 库 %.1fMB | tz=%+d | fin=%d",
        time.to_ms(time.since(t_begin)), ms_sql, ms_layout,
        last_db_bytes / 1048576, last_tz_off, fin_data and (fin_data.total or 0) or -1))
    return widget
end

-- ==================== 开发用预览（菜单里没有入口）====================

-- 只由 DENSESTATS_AUTOSHOW=1 触发，用来在桌面上看一眼屏保长什么样——
-- 桌面/模拟器不会真的进睡眠，没有别的办法走通这条渲染路径。
-- 设备上不需要它：锁屏看到的就是同一份部件。
local Preview = InputContainer:extend{}

function Preview:init()
    self.dimen = Screen:getSize()
    self.covers_fullscreen = true   -- 提示 UIManager:_repaint() 不必重画下层（readerprogress.lua:49）
    local ok_b, w = pcall(buildWidget)
    if not ok_b then logger.warn("densestats: preview build failed:", w); w = nil end
    self[1] = w or CenterContainer:new{
        dimen = Screen:getSize(),
        TextWidget:new{ text = "densestats: 构建失败，看 crash.log", face = faceBody() },
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
                    .. "统计数据本身不受影响")
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
        -- DENSESTATS_SHOT=/path/x.png：画完两秒后把帧缓冲存成 PNG。纯开发用，
        -- 桌面上拿不到设备截图，评审排版只能靠这个。
        local shot = os.getenv("DENSESTATS_SHOT")
        if shot and shot ~= "" then
            UIManager:scheduleIn(2, function()
                local ok, err = pcall(function() Screen:shot(shot) end)
                logger.info("densestats: 截图", shot, ok and "ok" or err)
            end)
        end
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
end

return DenseStats
