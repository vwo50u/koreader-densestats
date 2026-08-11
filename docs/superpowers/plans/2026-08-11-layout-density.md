# 睡眠屏布局密度调整 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 densestats 睡眠屏的字号整体放大一档、间隙设上限，剩余空白变成对称的上下边距，让内容紧凑并垂直居中。

**Architecture:** 两个独立改动。其一，字号从 KOReader 命名档位改成 `Font:getFace("ffont", N)` 的显式尺寸（三档收进 `CFG.font`），并等比放大曲线与进度条。其二，把「剩余高度怎么分」的算术从 `main.lua` 抽成纯函数模块 `layout.lua`，先写测试再实现，然后在 `buildWidget` 末尾替换掉原来的平摊逻辑。

**Tech Stack:** Lua 5.1 / LuaJIT，KOReader 插件 API（`ui/widget/*`、`ui/font`、`ui/size`）。测试用 KOReader.app 自带的 luajit 直接跑，不启动 KOReader。

## Global Constraints

- **注释用中文**（跟随本仓库既有风格，全部注释都是中文）；**commit message 用英文**（conventional commits）。
- 信息项一个不加不减：不新增统计维度，不改数据层。
- 不动 `stats.lua`、`finished.lua`、`_meta.lua`。
- 字体族固定 `ffont`。fontmap 里 `ffont` / `smallffont` / `largeffont` 都指向 `NotoSans-Regular.ttf`（`/Applications/KOReader.app/Contents/koreader/frontend/ui/font.lua:49-51`），所以换显式尺寸不会改变字体。
- `Font:getFace(name, size)` 的第二参会覆盖 sizemap 查表（font.lua:273），且覆盖后仍走 `Screen:scaleBySize(size)`（同文件 276 行）——显式数字照样 DPI 无关。
- 三档尺寸：强调 `v = 34`、正文 `m = 24`、辅助 `l = 18`。
- 间隙增长上限：`gap_max_ratio = 1.6`。
- `VerticalGroup` 的 `getSize()` 会缓存 `_offsets`，改完子元素宽度必须 `resetLayout()`，否则 `paintTo` 时 `_offsets[i]` 为 nil 直接崩（`frontend/ui/widget/verticalgroup.lua:51`）。
- 所有渲染路径已包在 `pcall` 里，不要拆掉。

### 对 spec 的一处偏离

Spec 写的是「只改 `main.lua`」。本计划额外新建 `densestats.koplugin/layout.lua` 与 `test/test_layout.lua`：间隙分配有「上限」「按比例」「余数」三处容易写错的算术，靠肉眼看屏幕验证不了，抽成纯函数才能测。这是为了可验证性，不改变 spec 的行为定义。

### 常用命令

```bash
./dev.sh check    # 语法检查（对 densestats.koplugin/*.lua 逐个 loadfile）
./dev.sh test     # 跑 test/run.sh 下的全部单元测试
./dev.sh run      # 启动 KOReader，主菜单 → 更多工具 → 预览：密集统计屏
```

---

### Task 1: 字号三档改成显式尺寸，并等比放大曲线与进度条

**Files:**
- Modify: `densestats.koplugin/main.lua:52-60`（CFG 加字段）
- Modify: `densestats.koplugin/main.lua:262-272`（FACE_* 定义与其上方注释块）
- Modify: `densestats.koplugin/main.lua:391`（曲线高度）
- Modify: `densestats.koplugin/main.lua:410`（进度条高度）
- Test: 无自动化测试（纯常量 + 渲染尺寸）。验证走 `./dev.sh check` 与 `DENSESTATS_DEBUG=1` 的布局日志。

**Interfaces:**
- Consumes: 无
- Produces: `CFG.font = { v = 34, m = 24, l = 18 }` 和 `CFG.gap_max_ratio = 1.6`。Task 3 会读 `CFG.gap_max_ratio`。

- [ ] **Step 1: 给 CFG 加 `font` 与 `gap_max_ratio` 两个字段**

把 `main.lua` 里 `local CFG = {` 到对应 `}` 的整块（52-60 行）替换成：

```lua
local CFG = {
    max_sec = 120,          -- 单页停留时间上限（秒），与 statistics 插件默认一致
    week_start = 2,         -- 1=周日 2=周一
    curve_days = 30,
    window_days = 400,   -- 逐日明细只查这个窗口；累计另走 book 表汇总
    finished_cache_hours = 12,  -- sidecar 扫描结果缓存时长
    cache_titles = 60,          -- 缓存里最多保留多少本书名（渲染时要整份解析）
    tz_offset = 0,              -- start_time 与设备墙钟一致，真机上为 0；设 nil 则自动推断
    font = { v = 34, m = 24, l = 18 },  -- 强调 / 正文 / 辅助，见 FACE_* 上方注释
    gap_max_ratio = 1.6,        -- 区块间隙最多长到基准值的几倍，吸收不掉的余白归上下边距
}
```

- [ ] **Step 2: 替换 FACE_* 定义与注释块**

把 262-272 行（从 `-- 字号一律用 KOReader 的命名档位` 那条注释开头，到 `local FACE_S = FACE_L` 结束）整块替换成：

```lua
-- 字号走 Font:getFace 的显式尺寸参数：第二参会覆盖 sizemap 查表（font.lua:273），
-- 且覆盖后仍过 Screen:scaleBySize（同文件 276 行），所以显式数字照样是 DPI 无关的。
-- 不用 KOReader 的命名档位，是因为它最大只到 tfont = 26，比原来的 largeffont = 25
-- 只大 1，靠换档位放不大。字体族固定 ffont —— fontmap 里 ffont / smallffont /
-- largeffont 都指向 NotoSans-Regular.ttf（font.lua:49-51），换成显式尺寸不改字体。
-- 仍然只用三档，且按"角色"固定分配，同一角色全篇一致：
--   强调 只给统计大数字；正文 给书名、日期这类主体内容；
--   辅助 给标签、说明、明细、页脚。
-- 之前是哪里觉得不合适就单独调一处，屏幕上同时出现四五种大小，看着就乱。
local function FACE_V() return Font:getFace("ffont", CFG.font.v) end   -- 强调
local function FACE_M() return Font:getFace("ffont", CFG.font.m) end   -- 正文
local function FACE_L() return Font:getFace("ffont", CFG.font.l) end   -- 辅助
local FACE_S = FACE_L
```

- [ ] **Step 3: 放大曲线高度**

在 `curveWidget` 里（391 行附近），把

```lua
        h = math.floor(Screen:getHeight() * 0.10),   -- 曲线高度按屏幕比例，跨设备一致
```

替换成

```lua
        h = math.floor(Screen:getHeight() * 0.12),   -- 曲线高度按屏幕比例，跨设备一致
```

- [ ] **Step 4: 放大进度条高度**

在 `currentBook` 里（410 行附近），把

```lua
        rect(fill, Screen:scaleBySize(10)),
```

替换成

```lua
        rect(fill, Screen:scaleBySize(14)),
```

- [ ] **Step 5: 语法检查**

Run: `./dev.sh check`
Expected: 四个文件全部打印 `OK   .../xxx.lua`，退出码 0。

- [ ] **Step 6: 现有测试仍全绿**

Run: `./dev.sh test`
Expected: `test_finished.lua` 与 `test_stats.lua` 全部 ok，没有 FAIL 行。本任务没碰 `stats.lua` / `finished.lua`，若出现 FAIL 说明改错了文件，停下来查。

- [ ] **Step 7: 用调试日志确认字号真的变了**

Run: `DENSESTATS_DEBUG=1 DENSESTATS_AUTOSHOW=1 ./dev.sh run`
（KOReader 起来后等约 6 秒会自动弹出预览；看不到日志就另开一个终端跑 `./dev.sh log`）

在输出里找 `densestats layout:` 那一行，形如：

```
densestats layout: screen=WxH dpi_scale=N pad=N usable=N curve_w=N curve_h=N 大字高=N 正文高=N 小字高=N
```

Expected: `大字高` / `正文高` / `小字高` 三个值都比改动前明显变大（比例约 34:24:18），`curve_h` 约等于 `screen` 高度的 12%。目测预览页：四列小块不换行、不截断。

把这一行日志贴到 commit 前的汇报里。

- [ ] **Step 8: Commit**

```bash
git add densestats.koplugin/main.lua
git commit -m "style: enlarge font tiers to explicit sizes 34/24/18

KOReader named tiers cap at 26, so scaling up requires explicit sizes
passed to Font:getFace. Same NotoSans-Regular face either way. Curve
and progress bar grow proportionally so graphics match the larger type."
```

---

### Task 2: 抽出间隙分配算术为纯函数 `layout.distributeSlack`

**Files:**
- Create: `densestats.koplugin/layout.lua`
- Create: `test/test_layout.lua`
- Modify: `test/run.sh`

**Interfaces:**
- Consumes: 无
- Produces: `Layout.distributeSlack(bases, rest, max_ratio)` —— `bases` 是各间隙当前宽度的数组（数字，像素），`rest` 是待分配的剩余高度（数字，像素），`max_ratio` 是单个间隙可长到基准值的倍数（数字）。返回 `{ gains = <与 bases 等长的数字数组>, top = <数字>, bottom = <数字> }`。Task 3 会调它。

- [ ] **Step 1: 写测试文件（此时实现还不存在，必然失败）**

Create `test/test_layout.lua`：

```lua
package.path = "./densestats.koplugin/?.lua;" .. package.path
local L = require("layout")

local pass, fail = 0, 0
local function ok(c, n, extra)
    if c then pass = pass + 1; print("  ok   " .. n)
    else fail = fail + 1; print("  FAIL " .. n .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function sum(t)
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s
end

print("== distributeSlack: 没有余白 ==")
local r1 = L.distributeSlack({ 10, 20 }, 0, 1.6)
ok(sum(r1.gains) == 0 and r1.top == 0 and r1.bottom == 0, "rest=0 什么都不加")
local r2 = L.distributeSlack({ 10, 20 }, -50, 1.6)
ok(sum(r2.gains) == 0 and r2.top == 0 and r2.bottom == 0, "rest 为负不分配")

print("== distributeSlack: 余白小于松弛量 ==")
-- bases {100,100} + ratio 1.6 -> caps {60,60}, slack 120
local r3 = L.distributeSlack({ 100, 100 }, 40, 1.6)
ok(sum(r3.gains) == 40, "余白全被间隙吸收", sum(r3.gains))
ok(r3.gains[1] == 20 and r3.gains[2] == 20, "等宽间隙平分",
   tostring(r3.gains[1]) .. "/" .. tostring(r3.gains[2]))
ok(r3.top == 0 and r3.bottom == 0, "吸收得下就不加边距")

print("== distributeSlack: 余白超过松弛量 ==")
local r4 = L.distributeSlack({ 100, 100 }, 200, 1.6)
ok(r4.gains[1] == 60 and r4.gains[2] == 60, "间隙各自吃满上限 60",
   tostring(r4.gains[1]) .. "/" .. tostring(r4.gains[2]))
ok(r4.top == 40 and r4.bottom == 40, "剩下的 80 上下平分",
   tostring(r4.top) .. "/" .. tostring(r4.bottom))

print("== distributeSlack: 奇数余白 ==")
local r5 = L.distributeSlack({ 100, 100 }, 201, 1.6)
ok(r5.top == 40 and r5.bottom == 41, "多出的 1px 给底部",
   tostring(r5.top) .. "/" .. tostring(r5.bottom))

print("== distributeSlack: 按基准值比例分 ==")
-- caps {60,180}, slack 240, give 40 -> 10 / 30
local r6 = L.distributeSlack({ 100, 300 }, 40, 1.6)
ok(r6.gains[1] == 10 and r6.gains[2] == 30, "大间隙拿得多",
   tostring(r6.gains[1]) .. "/" .. tostring(r6.gains[2]))

print("== distributeSlack: 除不尽的余数 ==")
-- caps {60,60,60}, slack 180, give 10 -> floor(3.33)=3 三份，余 1 给最后一个
local r7 = L.distributeSlack({ 100, 100, 100 }, 10, 1.6)
ok(r7.gains[1] == 3 and r7.gains[2] == 3 and r7.gains[3] == 4, "余数给最后一个间隙",
   table.concat(r7.gains, "/"))
ok(sum(r7.gains) == 10, "总量守恒", sum(r7.gains))

print("== distributeSlack: 退化情形 ==")
local r8 = L.distributeSlack({}, 100, 1.6)
ok(#r8.gains == 0 and r8.top == 50 and r8.bottom == 50, "没有间隙时全进边距")
local r9 = L.distributeSlack({ 100, 100 }, 100, 1)
ok(sum(r9.gains) == 0 and r9.top == 50 and r9.bottom == 50, "ratio=1 间隙不增长")
local r10 = L.distributeSlack(nil, 100, 1.6)
ok(#r10.gains == 0 and r10.top == 50 and r10.bottom == 50, "bases 为 nil 不炸")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
```

- [ ] **Step 2: 把新测试挂进 run.sh**

把 `test/run.sh` 最后一行（跑 `test_stats.lua` 那行）之后追加一行，使文件结尾变成：

```bash
env LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" LUA_CPATH="$KO/?.so;$KO/libs/?.so;;" "$KO/luajit" test/test_stats.lua
env LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" LUA_CPATH="$KO/?.so;$KO/libs/?.so;;" "$KO/luajit" test/test_layout.lua
```

- [ ] **Step 3: 跑测试，确认它因为模块不存在而失败**

Run: `./dev.sh test`
Expected: 前两个测试文件全绿，然后在 `test_layout.lua` 处报错，形如 `module 'layout' not found`，脚本因 `set -e` 非零退出。

- [ ] **Step 4: 写实现**

Create `densestats.koplugin/layout.lua`：

```lua
--[[
layout.lua — 排版算术（纯函数，不依赖任何 KOReader 模块）

从 main.lua 抽出来是为了能用 luajit 直接测：分配逻辑里"上限""按比例""余数"
这几处容易写错，靠肉眼看屏幕验证不了。
--]]

local M = {}

-- 把 rest 像素的剩余高度分掉：先让各区块间隙按比例增长（每个最多长到基准值的
-- max_ratio 倍），吸收不掉的部分平分成上下边距，让内容块整体垂直居中。
-- 原来的做法是一股脑平摊进所有间隙，内容不够多时整屏看着松垮。
--
-- bases:     各间隙的当前宽度（像素，调用方传进来时已经缩放过）
-- rest:      待分配的剩余高度（像素）；<= 0 表示没得分
-- max_ratio: 单个间隙最多长到基准值的几倍
-- 返回 { gains = {每个间隙该加多少}, top = 顶部边距, bottom = 底部边距 }
function M.distributeSlack(bases, rest, max_ratio)
    bases = bases or {}
    local n = #bases
    local gains = {}
    for i = 1, n do gains[i] = 0 end

    rest = math.floor(tonumber(rest) or 0)
    if rest <= 0 then return { gains = gains, top = 0, bottom = 0 } end

    local ratio = tonumber(max_ratio) or 1
    local caps, slack = {}, 0
    for i = 1, n do
        local c = math.floor((tonumber(bases[i]) or 0) * (ratio - 1))
        if c < 0 then c = 0 end
        caps[i] = c
        slack = slack + c
    end

    local give = 0
    if slack > 0 then
        give = math.min(rest, slack)
        local allotted = 0
        for i = 1, n do
            gains[i] = math.floor(caps[i] * give / slack)
            allotted = allotted + gains[i]
        end
        -- 除不尽的余数全给最后一个间隙，保证 sum(gains) == give
        gains[n] = gains[n] + (give - allotted)
    end

    local leftover = rest - give
    local top = math.floor(leftover / 2)
    return { gains = gains, top = top, bottom = leftover - top }
end

return M
```

- [ ] **Step 5: 跑测试，确认全绿**

Run: `./dev.sh test`
Expected: 三个测试文件全部通过，`test_layout.lua` 末尾打印 `14 passed, 0 failed`，退出码 0。

- [ ] **Step 6: 语法检查（新文件也要过）**

Run: `./dev.sh check`
Expected: 五个文件全部 `OK`，含 `layout.lua`。

- [ ] **Step 7: Commit**

```bash
git add densestats.koplugin/layout.lua test/test_layout.lua test/run.sh
git commit -m "feat: add layout.distributeSlack for capped gap allocation

Pure arithmetic split out of main.lua so the cap, proportional split
and remainder handling can be unit tested with plain luajit."
```

---

### Task 3: 在 buildWidget 里换掉平摊逻辑

**Files:**
- Modify: `densestats.koplugin/main.lua`（顶部 require 区，约 33-35 行）
- Modify: `densestats.koplugin/main.lua:564-578`（`buildWidget` 末尾的弹性分配块）
- Test: 无新增自动化测试（算术已在 Task 2 覆盖；这里是接线）。验证走 `./dev.sh check` + 预览目测。

**Interfaces:**
- Consumes: Task 2 的 `Layout.distributeSlack(bases, rest, max_ratio)` → `{ gains, top, bottom }`；Task 1 的 `CFG.gap_max_ratio`
- Produces: 无（终点任务）

- [ ] **Step 1: 引入 layout 模块**

在 `main.lua` 顶部的 require 区里，`local Finished = require("finished")` 那一行之前插入一行，使这三行变成：

```lua
local Layout = require("layout")
local Finished = require("finished")
local Stats = require("stats")
```

- [ ] **Step 2: 替换弹性分配块**

把 `buildWidget` 末尾的这一整块（从 `-- 把剩余高度平摊到各区块之间` 的注释开始，到对应的 `end` 结束，约 564-578 行）：

```lua
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
```

替换成：

```lua
    -- 剩余高度先让区块间隙按比例吸收（每个最多长到基准的 CFG.gap_max_ratio 倍），
    -- 吸收不掉的平分成上下边距，让内容块整体垂直居中。
    -- 原来是一股脑平摊进所有间隙，"已读完"的书不够多时整屏看着松垮。
    -- 注意 getSize() 会缓存 _offsets，改完必须 resetLayout()，
    -- 否则 paintTo 时 _offsets[i] 为 nil 直接崩（verticalgroup.lua:51）。
    local ok_h, ch = pcall(function() return root:getSize().h end)
    if ok_h and ch then
        local bases = {}
        for i, sp in ipairs(flex) do bases[i] = sp.width end
        local alloc = Layout.distributeSlack(bases, H - pad * 2 - ch, CFG.gap_max_ratio)
        for i, sp in ipairs(flex) do
            sp.width = sp.width + alloc.gains[i]
        end
        -- 上下边距各插一个 span：顶部插到最前，底部追加在页脚之后
        if alloc.top > 0 then
            table.insert(root, 1, VerticalSpan:new{ width = alloc.top })
        end
        if alloc.bottom > 0 then
            table.insert(root, VerticalSpan:new{ width = alloc.bottom })
        end
        root:resetLayout()
    end
```

注意这两个新 span **不要**加进 `flex` 表——它们是边距，不参与下一轮分配（本函数只跑一轮，但把它们混进 `flex` 会让语义变脏）。

- [ ] **Step 3: 语法检查**

Run: `./dev.sh check`
Expected: 五个文件全部 `OK`，退出码 0。

- [ ] **Step 4: 全部单元测试仍全绿**

Run: `./dev.sh test`
Expected: 三个测试文件全通过，无 FAIL。

- [ ] **Step 5: 桌面预览目测**

Run: `DENSESTATS_DEBUG=1 DENSESTATS_AUTOSHOW=1 ./dev.sh run`

Expected（逐条确认，不满足就停下来报告）：
1. 预览页正常渲染，**没有**出现 "densestats: 构建失败，看 crash.log"
2. 日志里没有 `_offsets` 相关的报错（那是漏了 `resetLayout()` 的症状）
3. 区块之间的间隙明显比改动前紧凑，不再是均匀的大缝
4. 内容块整体垂直居中：顶部第一排小块上方、底部页脚下方各有一块**大致相等**的空白
5. 页脚（日期 · 电量）完整可见，没被顶出屏幕

- [ ] **Step 6: Commit**

```bash
git add densestats.koplugin/main.lua
git commit -m "style: cap gap growth, turn leftover space into page margins

Spreading all leftover height across the ten inter-section gaps made
the screen look slack whenever the finished-books list ran short.
Gaps now grow to at most 1.6x their base and the rest becomes
symmetric top/bottom margins, vertically centering the content."
```

---

### Task 4: 真机（PW3）验证

**Files:**
- Modify: `README.md`（「已知待验证点」小节，补一条已验证记录）

**Interfaces:**
- Consumes: Task 1 与 Task 3 的全部改动
- Produces: 无

这一步**不可省**。四列小块在 34px 下会变宽，桌面预览的屏幕尺寸与 PW3 不同，挤不挤只有真机说了算。

- [ ] **Step 1: 部署到设备**

把 `densestats.koplugin/` 整个文件夹拷进设备的 `koreader/plugins/`（注意本次新增了 `layout.lua`，漏拷会导致 `require("layout")` 失败、整屏退回内置屏保），然后重启 KOReader。

- [ ] **Step 2: 触发睡眠屏并逐条核对**

让设备进入睡眠（设置里需保持「在休眠屏幕上显示阅读进度」，且 statistics 插件启用）。

Expected（逐条确认）：
1. 第一排「今日 / 本周 / 本月 / 今年」四列不换行、不截断
2. 第二排「连续天数 / 有效日均 / 累计 / 今日页数」四列不换行；特别看「累计」那列的五字符数值（如 `210h` 或 `1024h`），和「今日页数」列下方的附注「本周 N 页」
3. 内容块整体垂直居中，上下空白大致相等
4. 页脚完整可见
5. 「已读完」列表在书多时仍能填满下半屏，没有突兀的空白

**若第 1 或第 2 条不满足**（挤了/换行了）：停下来报告，退路是把 `CFG.font.v` 从 34 降到 30，重跑 Step 1-2。不要自行改别的地方。

- [ ] **Step 3: 出问题时抓日志**

设备上装了 SSH 插件的话：`tail -f koreader/crash.log`；否则重启后直接看 `koreader/crash.log`。`logger.warn` 的输出会进这个文件。

- [ ] **Step 4: 更新 README 的验证记录**

在 `README.md` 的「已知待验证点」小节末尾追加一行，记下本次真机验证过的内容与设备型号、字号档位。保持该小节现有的编号/格式风格。

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: record PW3 verification of the enlarged layout"
```

---

## 完成标准

- `./dev.sh check` 五个文件全 OK
- `./dev.sh test` 三个测试文件全绿
- PW3 真机上两排四列均不换行，内容垂直居中，页脚可见
- `README.md` 记录了本次真机验证
