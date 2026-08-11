# 睡眠屏自适应排版 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 densestats 睡眠屏的字号在放得下的前提下尽量大，放不下自动降档，任何设备/方向/DPI 设置下都不溢出屏幕；同时收紧区块间隙，把填不满的空白变成对称的上下边距。

**Architecture:** 三档字号保留「按角色固定分配」的设计，基准值取 KOReader 命名档位的原始设计尺寸（25/20/15），整体乘一个自适应系数 `FSCALE`。`buildWidget` 的函数体拆成 `layoutOnce`，外层从 1.30 起逐档降 `FSCALE` 重排，直到四列不截断且「已读完」放得下 2 行。纯算术（间隙分配、降档搜索）抽进新模块 `layout.lua` 单独做单元测试。

**Tech Stack:** Lua 5.1 / LuaJIT，KOReader 插件 API（`ui/widget/*`、`ui/font`、`ui/size`）。测试用 KOReader.app 自带的 luajit 直接跑，不启动 KOReader。

**上游设计文档：** `docs/superpowers/specs/2026-08-11-layout-density-design.md`（v2）

## Global Constraints

- **注释用中文**（跟随本仓库既有风格）；**commit message 用英文**（conventional commits）。
- 信息项一个不加不减：不新增统计维度，不改数据层，不改版式结构（不拆两排、不换布局）。
- 不动 `stats.lua`、`finished.lua`、`_meta.lua`。
- `Font:getFace(name, size)` 的第二参是**未缩放的设计尺寸**，内部仍过 `Screen:scaleBySize`（`/Applications/KOReader.app/Contents/koreader/frontend/ui/font.lua:269-277`）。所以这里写的数字不是像素。
- `Screen:scaleBySize(px)` 按**屏幕短边 / 600** 缩放，默认完全不看 DPI（`ffi/framebuffer.lua:414-425`）。
- 三档基准值：强调 `BASE_V = 25`、正文 `BASE_M = 20`、辅助 `BASE_L = 15`。字体族分别保持 `largeffont` / `ffont` / `smallffont`（三者在 fontmap 里都指向 `NotoSans-Regular.ttf`，`font.lua:49-51`）。
- `CFG.fscale_steps = { 1.30, 1.20, 1.10, 1.00, 0.90, 0.80, 0.70, 0.60 }`，`CFG.min_fin_rows = 2`，`CFG.gap_max_ratio = 1.6`。
- **`resetLayout()` 铁律**：`VerticalGroup:getSize()` 会缓存 `_offsets`，改完子元素 `width` 或往 `root` 里 `table.insert` 之后**必须** `root:resetLayout()`，否则 `paintTo` 时 `_offsets[i]` 为 nil 直接崩（`frontend/ui/widget/verticalgroup.lua:51`）。
- 所有渲染路径已包在 `pcall` 里，不要拆掉。
- 禁止为了让测试通过而改测试或硬编码期望值。测试挂了修代码。

### 常用命令

```bash
./dev.sh check    # 语法检查（对 densestats.koplugin/*.lua 逐个 loadfile）
./dev.sh test     # 跑 test/run.sh 下的全部单元测试
./dev.sh run      # 启动 KOReader，主菜单 → 更多工具 → 预览：密集统计屏
./dev.sh log      # 只看日志
```

---

### Task 1: 新建 `layout.lua`，实现两个纯函数

**Files:**
- Create: `densestats.koplugin/layout.lua`
- Create: `test/test_layout.lua`
- Modify: `test/run.sh`

**Interfaces:**
- Consumes: 无
- Produces:
  - `Layout.distributeSlack(bases, rest, max_ratio)` → `{ gains = <与 bases 等长的数字数组>, top = <数字>, bottom = <数字> }`。`bases` 是各间隙基准宽度的数组（数字，像素）。Task 4 会用。
  - `Layout.fitScale(steps, probe)` → `payload, step, tries`。`steps` 是从大到小的候选系数数组；`probe(step)` 返回 `ok(boolean), payload`。Task 3 会用。

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

print("== distributeSlack: 余白小于总上限，按基准值比例分 ==")
-- bases {100,300} base_total 400, limit {60,180}
-- want {floor(40*100/400)=10, floor(40*300/400)=30} 都没触顶
local r3 = L.distributeSlack({ 100, 300 }, 40, 1.6)
ok(r3.gains[1] == 10 and r3.gains[2] == 30, "大间隙拿得多",
   tostring(r3.gains[1]) .. "/" .. tostring(r3.gains[2]))
ok(r3.top == 0 and r3.bottom == 0, "刚好分完则不加边距",
   tostring(r3.top) .. "/" .. tostring(r3.bottom))

print("== distributeSlack: 余白超过总上限，各自封顶 ==")
-- bases {100,100} limit {60,60}, want {100,100} -> add {60,60}, spare 200-120=80
local r4 = L.distributeSlack({ 100, 100 }, 200, 1.6)
ok(r4.gains[1] == 60 and r4.gains[2] == 60, "间隙各自封顶 0.6 倍基准",
   tostring(r4.gains[1]) .. "/" .. tostring(r4.gains[2]))
ok(r4.top == 40 and r4.bottom == 40, "剩下的 80 上下平分",
   tostring(r4.top) .. "/" .. tostring(r4.bottom))

print("== distributeSlack: 奇数余白，多的给底部 ==")
local r5 = L.distributeSlack({ 100, 100 }, 201, 1.6)
ok(r5.top == 40 and r5.bottom == 41, "多出的 1px 给底部",
   tostring(r5.top) .. "/" .. tostring(r5.bottom))

print("== distributeSlack: 部分触顶 ==")
-- bases {10,100} base_total 110, limit {6,60}
-- want {floor(200*10/110)=18, floor(200*100/110)=181} -> add {6,60}, spare 200-66=134
local r6 = L.distributeSlack({ 10, 100 }, 200, 1.6)
ok(r6.gains[1] == 6 and r6.gains[2] == 60, "小间隙先触顶，大间隙也触顶",
   tostring(r6.gains[1]) .. "/" .. tostring(r6.gains[2]))
ok(r6.top == 67 and r6.bottom == 67, "剩 134 上下平分",
   tostring(r6.top) .. "/" .. tostring(r6.bottom))

print("== distributeSlack: 退化情形 ==")
local r7 = L.distributeSlack({}, 100, 1.6)
ok(#r7.gains == 0 and r7.top == 50 and r7.bottom == 50, "没有间隙时全进边距")
local r8 = L.distributeSlack({ 100, 100 }, 100, 1)
ok(sum(r8.gains) == 0 and r8.top == 50 and r8.bottom == 50, "ratio=1 间隙不增长")
local r9 = L.distributeSlack(nil, 100, 1.6)
ok(#r9.gains == 0 and r9.top == 50 and r9.bottom == 50, "bases 为 nil 不炸")
local r10 = L.distributeSlack({ 0, 0 }, 100, 1.6)
ok(sum(r10.gains) == 0 and r10.top == 50 and r10.bottom == 50, "基准全 0 不除零")

print("== fitScale ==")
local tried = {}
local function mkprobe(accept)
    tried = {}
    return function(k)
        tried[#tried + 1] = k
        return accept(k), "payload@" .. tostring(k)
    end
end

local p1, s1, n1 = L.fitScale({ 1.3, 1.2, 1.1 }, mkprobe(function() return true end))
ok(p1 == "payload@1.3" and s1 == 1.3 and n1 == 1, "第一档就通过，只试一次",
   tostring(p1) .. " tries=" .. tostring(n1))
ok(#tried == 1, "没有多余的重排", #tried)

local p2, s2, n2 = L.fitScale({ 1.3, 1.2, 1.1 }, mkprobe(function(k) return k <= 1.2 end))
ok(p2 == "payload@1.2" and s2 == 1.2 and n2 == 2, "降一档后通过",
   tostring(p2) .. " tries=" .. tostring(n2))

local p3, s3, n3 = L.fitScale({ 1.3, 1.2, 1.1 }, mkprobe(function() return false end))
ok(p3 == "payload@1.1" and s3 == 1.1 and n3 == 3, "全都不通过时用最后一档兜底",
   tostring(p3) .. " tries=" .. tostring(n3))
ok(#tried == 3, "兜底也不会试超过档位数", #tried)

local p4, s4, n4 = L.fitScale({}, mkprobe(function() return true end))
ok(p4 == nil and s4 == nil and n4 == 0, "空档位表返回 nil，不崩")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
```

- [ ] **Step 2: 把新测试挂进 run.sh**

在 `test/run.sh` 末尾追加一行，使文件最后两行变成：

```bash
env LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" LUA_CPATH="$KO/?.so;$KO/libs/?.so;;" "$KO/luajit" test/test_stats.lua
env LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" LUA_CPATH="$KO/?.so;$KO/libs/?.so;;" "$KO/luajit" test/test_layout.lua
```

- [ ] **Step 3: 跑测试，确认它因为模块不存在而失败**

Run: `./dev.sh test`
Expected: 前两个测试文件全绿，然后在 `test_layout.lua` 处报错 `module 'layout' not found`，脚本因 `set -e` 非零退出。

- [ ] **Step 4: 写实现**

Create `densestats.koplugin/layout.lua`：

```lua
--[[
layout.lua — 排版算术（纯函数，不依赖任何 KOReader 模块）

从 main.lua 抽出来是为了能用 luajit 直接测：分配里的"按比例""封顶""余数"，
以及降档搜索的"全都不通过时兜底"，都是靠肉眼看屏幕验证不了的地方。
--]]

local M = {}

-- 把 rest 像素的剩余高度分掉：各区块间隙按各自基准值的比例增长，单个间隙最多
-- 再加 (max_ratio - 1) 倍基准值；吸收不掉的部分对半塞进上下边距，让内容块整体
-- 垂直居中。原来的做法是一股脑均摊进所有间隙，内容不够多时整屏看着松垮。
--
-- 按比例分而不是均分，是为了保住疏密节奏：基准 22 的间隙该比基准 5 的多拿。
-- 均分 + 封顶会让小间隙先触顶而大间隙还很空。
-- 官方同构先例：keyvaluepage.lua:493-495、calendarview.lua:1154-1156。
--
-- bases:     各间隙的基准宽度（像素，调用方传进来时已经缩放过）
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
    local base_total = 0
    for i = 1, n do base_total = base_total + (tonumber(bases[i]) or 0) end

    local given = 0
    if base_total > 0 then
        for i = 1, n do
            local b = tonumber(bases[i]) or 0
            local want  = math.floor(rest * b / base_total)
            local limit = math.floor(b * (ratio - 1))
            if limit < 0 then limit = 0 end
            local add = math.min(want, limit)
            gains[i] = add
            given = given + add
        end
    end

    -- floor 的零头也留在这里，跟着一起进边距；差几个像素不值得再分一轮
    local spare = rest - given
    local top = math.floor(spare / 2)
    return { gains = gains, top = top, bottom = spare - top }
end

-- 从大到小试各档系数，返回第一个通过的结果。
-- 全都不通过时返回最后一档——宁可字小，也不能把内容顶出屏幕。
-- 这是 KOReader 官方的套路（calendarview.lua:1307-1319 的探针降号循环、
-- keyvaluepage.lua:501 的从行高反推字号并封顶）。
--
-- steps: 从大到小的候选系数数组
-- probe(step) -> ok(boolean), payload
-- 返回 payload, 选中的 step, 实际试了几次
function M.fitScale(steps, probe)
    steps = steps or {}
    local n = #steps
    local payload, step
    for i = 1, n do
        local ok
        ok, payload = probe(steps[i])
        step = steps[i]
        if ok or i == n then return payload, step, i end
    end
    return nil, nil, 0
end

return M
```

- [ ] **Step 5: 跑测试，确认全绿**

Run: `./dev.sh test`
Expected: 三个测试文件全通过，`test_layout.lua` 末尾打印 `19 passed, 0 failed`，退出码 0。

- [ ] **Step 6: 语法检查**

Run: `./dev.sh check`
Expected: 五个文件全部 `OK`（含 `layout.lua`），退出码 0。

- [ ] **Step 7: Commit**

```bash
git add densestats.koplugin/layout.lua test/test_layout.lua test/run.sh
git commit -m "feat: add layout module for slack allocation and fit search

Pure arithmetic split out of main.lua so the proportional split, the
per-gap cap and the last-step fallback can be unit tested with plain
luajit."
```

---

### Task 2: 尺寸基准改为方向无关

**Files:**
- Modify: `densestats.koplugin/main.lua`（`curveWidget` 签名与曲线高度、进度条高度、`buildWidget` 里的 pad 计算与 `curveWidget` 调用点）
- Test: 无自动化测试（依赖 `Screen`）。验证走 `./dev.sh check` + `DENSESTATS_DEBUG` 日志。

**Interfaces:**
- Consumes: 无
- Produces: `curveWidget(curve, usable_w, avail_h)` —— 比现在多一个 `avail_h` 参数（数字，内容区可用高度像素）。返回值不变，仍是 `widget, peak`。

- [ ] **Step 1: 曲线高度改按可用高度**

在 `curveWidget` 里，把函数签名和高度那行改掉。原文：

```lua
local function curveWidget(curve, usable_w)
    local peak = 1
    for _, v in ipairs(curve) do if v > peak then peak = v end end
    return CurveWidget:new{
        values = curve,
        w = usable_w,
        h = math.floor(Screen:getHeight() * 0.10),   -- 曲线高度按屏幕比例，跨设备一致
```

改成：

```lua
local function curveWidget(curve, usable_w, avail_h)
    local peak = 1
    for _, v in ipairs(curve) do if v > peak then peak = v end end
    return CurveWidget:new{
        values = curve,
        w = usable_w,
        -- 按"内容区"的比例，不是按屏幕高度：横屏时两者差得远，
        -- 占内容区 12% 才是本意（screensaver.lua:330-335 不会把本模式转成竖屏）
        h = math.floor(avail_h * 0.12),
```

其余行（`scale`、`gap`、`end`）保持不变。

- [ ] **Step 2: 进度条高度对齐官方**

在 `currentBook` 里，把

```lua
        rect(fill, Screen:scaleBySize(10)),
```

改成

```lua
        rect(fill, Screen:scaleBySize(14)),   -- 与官方 readerprogress.lua:262 一致
```

- [ ] **Step 3: 留白按短边取比例**

在 `buildWidget` 里，把这三行（原 486-488 行附近）：

```lua
    local pad = math.max(Size.padding.fullscreen, math.floor(Screen:getWidth() * 0.06))
    local W, H = Screen:getWidth(), Screen:getHeight()
    local usable = W - pad * 2
```

改成（注意 `W, H` 要挪到前面）：

```lua
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- 留白按屏幕"短边"的 6%，不能按 getWidth()：横屏时宽度是长边，
    -- 按宽度取会白白吃掉本来就紧张的高度。下限用 KOReader 的
    -- Size.padding.fullscreen（原生全屏 widget 就是这个值，readerprogress.lua:30）。
    local pad = math.max(Size.padding.fullscreen, math.floor(math.min(W, H) * 0.06))
    local usable = W - pad * 2
```

同时把上方那段解释 6% 的旧注释（以 `-- 左右留白按屏幕宽度取比例。` 开头的整块）删掉——它已经被上面这段取代，留着会自相矛盾。

- [ ] **Step 4: 更新 `curveWidget` 调用点**

把 `buildWidget` 里的

```lua
    local curve, peak = curveWidget(d.curve, usable)
```

改成

```lua
    local curve, peak = curveWidget(d.curve, usable, H - pad * 2)
```

- [ ] **Step 5: 语法检查**

Run: `./dev.sh check`
Expected: 五个文件全 `OK`，退出码 0。

- [ ] **Step 6: 单元测试仍全绿**

Run: `./dev.sh test`
Expected: 三个测试文件全通过。本任务没碰 `stats.lua` / `finished.lua` / `layout.lua`，出现 FAIL 说明改错了文件，停下来查。

- [ ] **Step 7: 预览目测**

Run: `DENSESTATS_DEBUG=1 DENSESTATS_AUTOSHOW=1 ./dev.sh run`
（起来后等约 6 秒自动弹预览；看不到日志就另开终端跑 `./dev.sh log`）

Expected：预览正常渲染，没有「densestats: 构建失败」。日志里 `densestats layout:` 那行的 `pad` 与 `curve_h` 有变化。竖屏下 `pad` 应该和改动前一样（竖屏时短边就是宽度），`curve_h` 比原来略大。把这行日志贴进汇报。

- [ ] **Step 8: Commit**

```bash
git add densestats.koplugin/main.lua
git commit -m "fix: derive padding and curve height from orientation-safe bases

Padding came from getWidth() and the curve from getHeight(), both of
which flip meaning in landscape. Screensaver keeps readingprogress in
whatever rotation the device is in (screensaver.lua:330-335), so use
the short edge for padding and the content height for the curve.
Progress bar now matches readerprogress.lua:262."
```

---

### Task 3: 自适应字号 + fit 循环

这是本计划的核心任务。

**Files:**
- Modify: `densestats.koplugin/main.lua`（require 区、`CFG`、FACE_* 定义、`cellRow`、`finishedRows` 调用处附近、`buildWidget` 拆分）

**Interfaces:**
- Consumes: Task 1 的 `Layout.fitScale(steps, probe)`
- Produces:
  - `cellRow(items, usable_w)` → `group, truncated(boolean)`（新增第二个返回值）
  - `layoutOnce(data, d)` → `widget, budget(数字), fin_row_h(数字), truncated(boolean)`
  - `buildWidget()` → `widget`（对外签名不变，`Preview:init` 和屏保钩子照旧调用）

- [ ] **Step 1: 引入 layout 模块**

在 `main.lua` 顶部 require 区，`local Finished = require("finished")` 之前插入一行，使这三行变成：

```lua
local Layout = require("layout")
local Finished = require("finished")
local Stats = require("stats")
```

- [ ] **Step 2: CFG 加三个字段**

在 `CFG` 表里 `tz_offset` 那行之后追加：

```lua
    -- 字号自适应：从大到小试，第一个"放得下"的档位胜出。
    -- 放不下的判据见 layoutOnce 的返回值（截断 / 已读完行数）。
    fscale_steps = { 1.30, 1.20, 1.10, 1.00, 0.90, 0.80, 0.70, 0.60 },
    min_fin_rows = 2,           -- "已读完"至少要放得下几行，否则降档
    gap_max_ratio = 1.6,        -- 区块间隙最多长到基准值的几倍，吸收不掉的归上下边距
```

- [ ] **Step 3: 三档字号改成基准值 × 自适应系数**

把 262-272 行整块（从 `-- 字号一律用 KOReader 的命名档位` 那条注释开头，到 `local FACE_S = FACE_L` 结束）替换成：

```lua
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
--   强调 只给统计大数字；正文 给书名、日期这类主体内容；
--   辅助 给标签、说明、明细、页脚。
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
```

- [ ] **Step 4: `cellRow` 上报截断**

`cellRow` 现在要多返回一个布尔值。在它内部量宽度的循环里顺手问一下每个 `TextWidget` 是否被 `max_width` 截断。

`cell()` 返回的是一个 `VerticalGroup`，里面的元素就是 `TextWidget`（标签、数值、可选附注），所以直接遍历这个组即可。

把 `cellRow` 开头的构建循环：

```lua
    local cap_w = math.floor(usable_w / n)          -- 单块最大宽度，超了就截断
    local cells, widths, total = {}, {}, 0
    for i, it in ipairs(items) do
        local c = cell(it[1], it[2], cap_w, it[3])
        cells[i] = c
        local ok, sz = pcall(function() return c:getSize() end)
        widths[i] = (ok and sz and sz.w) or 0
        total = total + widths[i]
    end
```

替换成：

```lua
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
```

然后把 `cellRow` 的三个 `return` 都补上第二个返回值：

- 开头的 `if n == 0 then return VerticalGroup:new{} end` → `if n == 0 then return VerticalGroup:new{}, false end`
- `if n == 1 then ... return g end` 里的 `return g` → `return g, truncated`
- 函数末尾的 `return g` → `return g, truncated`

- [ ] **Step 5: 把 `buildWidget` 函数体改名为 `layoutOnce` 并返回四个值**

把 `local function buildWidget()` 这一行改成：

```lua
-- 按当前的 FSCALE 排一遍版。返回值供 fit 循环判断"放不放得下"：
--   widget     排好的部件
--   budget     留给"已读完"列表的高度预算（可能为负 = 溢出）
--   fin_row_h  "已读完"一行占多高
--   truncated  四列小块里有没有哪一格被截断
local function layoutOnce(data, d)
```

删掉函数开头这三行（数据改由调用方传入，避免每次重排都重查数据库）：

```lua
    local data = collect()
    if not data then return nil end
    local d = Stats.derive(data, os.time(), CFG)
```

- [ ] **Step 6: 在 `layoutOnce` 里收集截断标记**

两处 `cellRow` 调用改成接住第二个返回值。第一处：

```lua
    table.insert(root, cellRow({
        { "今日", fmtHM(d.today) }, { "本周", fmtHM(d.week) },
        { "本月", fmtHM(d.month) }, { "今年", fmtHM(d.year) },
    }, usable))
```

改成：

```lua
    local row1, cut1 = cellRow({
        { "今日", fmtHM(d.today) }, { "本周", fmtHM(d.week) },
        { "本月", fmtHM(d.month) }, { "今年", fmtHM(d.year) },
    }, usable)
    table.insert(root, row1)
```

第二处：

```lua
    table.insert(root, cellRow({
        { "连续天数", tostring(d.streak) },
        { "有效日均", fmtHM(d.avg_active) },
        { "累计", fmtHours(d.total) },
        { "今日页数", tostring(d.pages_today), string.format("本周 %d 页", d.pages_week) },
    }, usable))
```

改成：

```lua
    local row2, cut2 = cellRow({
        { "连续天数", tostring(d.streak) },
        { "有效日均", fmtHM(d.avg_active) },
        { "累计", fmtHours(d.total) },
        { "今日页数", tostring(d.pages_today), string.format("本周 %d 页", d.pages_week) },
    }, usable)
    table.insert(root, row2)
```

- [ ] **Step 7: 在 `layoutOnce` 里量出 `fin_row_h`，并返回四个值**

找到算 `budget` 的那两行：

```lua
    -- 12 是页脚上方的间距，也得从预算里扣，否则会顶出屏幕
    local budget = H - pad * 2 - used_h - footer_h - Screen:scaleBySize(12) - Screen:scaleBySize(12)
    table.insert(root, finishedRows(fin_data, usable, math.max(0, budget)))
```

改成：

```lua
    -- 两个 12：一个是页脚上方的 gap(12)，一个是"已读完"列表和它上方标题之间的
    -- 安全余量。都得从预算里扣，否则会顶出屏幕。
    local budget = H - pad * 2 - used_h - footer_h - Screen:scaleBySize(12) - Screen:scaleBySize(12)
    -- 一行"已读完"占多高：口径必须和 finishedRows 里一致（正文档字高 + line_gap）
    local fin_row_h = txt("2026-08", FACE_M()):getSize().h + Size.padding.large
    table.insert(root, finishedRows(fin_data, usable, math.max(0, budget)))
```

然后把函数末尾的 `return CenterContainer:new{ ... }` 整块改成先存进变量再连同三个值一起返回：

```lua
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
```

- [ ] **Step 8: 写新的 `buildWidget`（fit 循环）**

在 `layoutOnce` 的 `end` 之后、`-- ============================ 调试预览 ====================` 之前，插入：

```lua
-- 一屏排不下就整体降字号重排。KOReader 官方处理"铺满一屏"就是这个套路：
-- calendarview.lua:1305-1319 用最宽字符串当探针 while 循环降号，
-- keyvaluepage.lua:492-501 从行高反推字号并封顶，menu.lua:135-141 封顶到
-- "至少能显示一行"。这一条同时解决三件事：横屏、用户把「屏幕 DPI」调大、
-- 以及内容变长——它不假设任何设备参数，只问"这次放不放得下"。
local function buildWidget()
    local data = collect()
    if not data then return nil end
    local d = Stats.derive(data, os.time(), CFG)

    local t0 = os.clock()
    local widget, step, tries = Layout.fitScale(CFG.fscale_steps, function(k)
        FSCALE = k
        local w, budget, fin_row_h, truncated = layoutOnce(data, d)
        local fits = (not truncated) and budget >= CFG.min_fin_rows * fin_row_h
        return fits, w
    end)

    if os.getenv("DENSESTATS_DEBUG") == "1" then
        logger.info(string.format("densestats fit: FSCALE=%.2f tries=%d 耗时=%.1fms",
            step or -1, tries or 0, (os.clock() - t0) * 1000))
    end
    return widget
end
```

⚠️ `FSCALE` 是文件级 upvalue，被 `FACE_*` 闭包读取。fit 循环里赋值后
`layoutOnce` 内部新建的每个 `TextWidget` 都会拿到新字号——这正是设计意图，
但也意味着**不能把 widget 跨档位复用**。`layoutOnce` 每次都从头建树，满足这一点。

- [ ] **Step 9: 语法检查**

Run: `./dev.sh check`
Expected: 五个文件全 `OK`，退出码 0。

- [ ] **Step 10: 单元测试仍全绿**

Run: `./dev.sh test`
Expected: 三个测试文件全通过。

- [ ] **Step 11: 预览验证 + 记录耗时**

Run: `DENSESTATS_DEBUG=1 DENSESTATS_AUTOSHOW=1 ./dev.sh run`

Expected（逐条确认，不满足就停下来报告）：
1. 预览正常渲染，**没有**「densestats: 构建失败，看 crash.log」
2. 日志里有 `densestats fit: FSCALE=... tries=... 耗时=...ms` 这一行
3. 字号明显比改动前大
4. 四列小块不换行、不截断
5. **把 `耗时` 数字记进汇报**。超过 200ms 要标记出来——spec 里写明届时需要
   改成解析式预估高度，但那是另一个任务，本任务照常提交

- [ ] **Step 12: Commit**

```bash
git add densestats.koplugin/main.lua
git commit -m "feat: pick font scale by fitting the layout to the screen

Font tiers are now the named-tier design sizes times an adaptive
factor. buildWidget tries 1.30 downwards and keeps the first scale
where no stat cell truncates and the finished list still fits two
rows, falling back to the smallest step rather than overflowing.
This is what calendarview.lua and keyvaluepage.lua do."
```

---

### Task 4: 间隙分配换成 `distributeSlack`

**Files:**
- Modify: `densestats.koplugin/main.lua`（`layoutOnce` 里的 `gap()` 辅助函数与末尾的弹性分配块）

**Interfaces:**
- Consumes: Task 1 的 `Layout.distributeSlack(bases, rest, max_ratio)`；Task 3 的 `CFG.gap_max_ratio`
- Produces: 无（终点任务）

- [ ] **Step 1: 让 `gap()` 记下基准宽度**

在 `layoutOnce` 里，把

```lua
    local flex = {}
    local function gap(px)
        local sp = VerticalSpan:new{ width = Screen:scaleBySize(px) }
        flex[#flex + 1] = sp
        table.insert(root, sp)
    end
```

改成

```lua
    local flex = {}
    local function gap(px)
        local w = Screen:scaleBySize(px)
        local sp = VerticalSpan:new{ width = w }
        sp._base = w            -- 记下基准值：余白按基准比例分，不是均分
        flex[#flex + 1] = sp
        table.insert(root, sp)
    end
```

- [ ] **Step 2: 替换弹性分配块**

把 `layoutOnce` 末尾这一整块（从 `-- 把剩余高度平摊到各区块之间` 的注释开始，到对应的 `end` 结束）：

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
    -- 剩余高度先让区块间隙按各自基准值的比例吸收（单个最多长到基准的
    -- CFG.gap_max_ratio 倍），吸收不掉的对半塞进上下边距，让内容块整体垂直居中。
    -- 原来是一股脑均摊进所有间隙，"已读完"的书不够多时整屏看着松垮。
    -- 注意 getSize() 会缓存 _offsets，改完必须 resetLayout()，
    -- 否则 paintTo 时 _offsets[i] 为 nil 直接崩（verticalgroup.lua:51）。
    local ok_h, ch = pcall(function() return root:getSize().h end)
    if ok_h and ch then
        local bases = {}
        for i, sp in ipairs(flex) do bases[i] = sp._base end
        local alloc = Layout.distributeSlack(bases, H - pad * 2 - ch, CFG.gap_max_ratio)
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
    end
```

⚠️ 注意这里是 `sp.width = sp._base + alloc.gains[i]`（**赋值**，不是 `+=`）。
`layoutOnce` 在 fit 循环里会被调用多次，但每次都重建 `root` 和 `flex`，
所以 `sp.width` 此时还等于 `sp._base`；写成赋值是为了把这个不变式写死，
将来若有人复用 span 也不会累加两次。

- [ ] **Step 3: 语法检查**

Run: `./dev.sh check`
Expected: 五个文件全 `OK`，退出码 0。

- [ ] **Step 4: 单元测试仍全绿**

Run: `./dev.sh test`
Expected: 三个测试文件全通过。

- [ ] **Step 5: 预览目测**

Run: `DENSESTATS_DEBUG=1 DENSESTATS_AUTOSHOW=1 ./dev.sh run`

Expected（逐条确认）：
1. 预览正常渲染，没有构建失败
2. 日志里**没有** `_offsets` 相关报错（那是漏了 `resetLayout()` 的症状）
3. 区块之间的间隙比改动前紧凑，不再是均匀的大缝；分隔线两侧的间隙明显比
   曲线标题下方那个小间隙宽（这是"按基准比例分"的可见特征）
4. 内容块整体垂直居中：顶部第一排小块上方、底部页脚下方各有一块**大致相等**的空白
5. 页脚（日期 · 电量）完整可见

- [ ] **Step 6: Commit**

```bash
git add densestats.koplugin/main.lua
git commit -m "style: cap gap growth, turn leftover space into page margins

Spreading all leftover height evenly across the ten inter-section gaps
made the screen look slack whenever the finished-books list ran short,
and flattened the spacing rhythm. Gaps now grow in proportion to their
base value, capped at 1.6x, and the rest becomes symmetric top/bottom
margins that vertically center the content."
```

---

### Task 4b: 让间隙分配可观测（DEBUG 日志）

Task 4 验收发现的计划缺陷：`distributeSlack` 是本计划里**唯一一个完全没有运行时信号**的机制
（`fitScale` 至少有 `FSCALE=/tries=` 那行）。而按桌面实测参数推算，它的效果在正常藏书量下
只有 7px 量级——上下边距 3px/4px，**肉眼不可辨**。原计划里「间隙明显变紧」「上下大致相等的
空白」这两条目测标准因此是验不出来的，照着测只会误判成「改动没生效」。

用户 2026-08-11 裁决：加一行 DEBUG 日志，不靠目测。

顺带修掉 Task 3 验收提的度量口径问题：`t0 = os.clock()` 现在落在 `getFinished()` 之后，
所以报出来的耗时不含那次 `dofile` 缓存解析，真机报告会低估完整构建成本。

**Files:**
- Modify: `densestats.koplugin/main.lua`（`layoutOnce` 的 slack 块、`buildWidget` 的计时起点）

**Interfaces:**
- Consumes: Task 4 的 `alloc`（`{ gains, top, bottom }`）
- Produces: 无

- [ ] **Step 1: 把计时起点挪到 `getFinished()` 之前**

在 `buildWidget` 里，把 `local t0 = os.clock()` 移动到 `local fin_data = getFinished()`
**之前**，使 `collect()` 之后的整个构建过程都在计时区内。只挪位置，不改别的。

- [ ] **Step 2: 在 slack 块里打诊断日志**

在 `layoutOnce` 的 slack 块里、`root:resetLayout()` **之后**，加：

```lua
        if os.getenv("DENSESTATS_DEBUG") == "1" then
            -- distributeSlack 的效果在正常藏书量下只有几像素，目测验不出来；
            -- 触顶数是关键信号：0/N 说明余白还没多到需要封顶，N/N 才是"已读完"接近空的情形
            local given, capped = 0, 0
            for i, sp in ipairs(flex) do
                given = given + alloc.gains[i]
                if alloc.gains[i] >= math.floor(sp._base * (CFG.gap_max_ratio - 1)) then
                    capped = capped + 1
                end
            end
            logger.info(string.format(
                "densestats slack: rest=%d gains=%d 触顶=%d/%d top=%d bottom=%d",
                avail_h - ch, given, capped, #flex, alloc.top, alloc.bottom))
        end
```

- [ ] **Step 3: 语法检查**

Run: `./dev.sh check`
Expected: 五个文件全 `OK`，退出码 0。

- [ ] **Step 4: 单元测试仍全绿**

Run: `./dev.sh test`
Expected: 三个测试文件全通过（21 / 56 / 19）。

- [ ] **Step 5: 桌面预览，核对日志数字**

Run: 后台启动 `DENSESTATS_DEBUG=1 DENSESTATS_AUTOSHOW=1 ./dev.sh run`，等约 25 秒，
`pkill -f KOReader`，再 grep `/tmp/densestats-run.log`。

Expected：出现 `densestats slack:` 行。在这台桌面机（1146×1596、FSCALE=1.20）上，
验收模型推算的值是 `rest=37 gains=30 触顶=0/10 top=3 bottom=4`。
**实测与推算若有出入，如实报出来并说明差异**——模型是手工复刻的，可能漏算某个 span，
以实测为准，但差得离谱（比如 `rest` 是负数或几百）就要停下来查。

- [ ] **Step 6: 造一次空列表场景对照**

把缓存文件临时移走，再跑一次 Step 5：

```bash
D="$HOME/Library/Application Support/KOReader/settings"
mv "$D/densestats_finished.lua" "$D/densestats_finished.lua.bak" 2>/dev/null || true
# 跑 Step 5，记录日志
mv "$D/densestats_finished.lua.bak" "$D/densestats_finished.lua" 2>/dev/null || true
```

Expected：`触顶` 应该变成 `10/10`，`top`/`bottom` 升到 25 左右。这证明封顶和居中两个分支
都真的可达，而不是永远走不到的死代码。

**缓存文件路径可能不在上面这个位置**（`DataStorage:getSettingsDir()` 决定）。找不到就
先从日志或 `find` 定位；实在找不到就跳过本步，写进报告，不要反复试。**无论如何都要把
文件恢复回去。**

- [ ] **Step 7: Commit**

```bash
git add densestats.koplugin/main.lua
git commit -m "feat: log slack allocation under DENSESTATS_DEBUG

distributeSlack was the only mechanism in this change with no runtime
signal, and its effect is a few pixels at normal library sizes — too
small to eyeball. The cap count is the useful one: 0/N means there was
never enough leftover to cap, N/N is the near-empty finished list.
Also moves the fit timer above getFinished so the reported cost covers
the whole build."
```

---

### Task 5: 真机（PW3）验证

**Files:**
- Modify: `README.md`（「已知待验证点」小节）

**Interfaces:**
- Consumes: Task 2/3/4/4b 的全部改动
- Produces: 无

这一步**不可省**。计划里所有定量结论都来自源码复刻的模型，不是实测。

- [ ] **Step 1: 部署到设备**

把 `densestats.koplugin/` 整个文件夹拷进设备的 `koreader/plugins/`。**本次新增了
`layout.lua`，漏拷会导致 `require("layout")` 失败、整屏退回内置屏保。** 然后重启 KOReader。

- [ ] **Step 2: 竖屏睡眠，逐条核对**

让设备进入睡眠（设置里保持「在休眠屏幕上显示阅读进度」，statistics 插件启用）。

Expected：
1. 第一排「今日 / 本周 / 本月 / 今年」四列不换行、不截断
2. 第二排「连续天数 / 有效日均 / 累计 / 今日页数」四列不换行、不截断
3. 字号明显比改动前大
4. 页脚完整可见
5. 「已读完」至少 2 行

**不要目测「垂直居中」和「间隙变紧」**——按 Task 4 验收的推算，正常藏书量下上下边距只有
3px/4px、间隙总共只紧了 7px，肉眼不可辨。这两项改看 Task 4b 加的 `densestats slack:` 日志。

- [ ] **Step 3: 横屏——不测（用户决定，2026-08-11）**

用户明确表示不考虑横屏，本计划不做横屏验证。

Task 2 已提交的方向无关改动（留白按短边、曲线按内容区高度）保留不动：竖屏下
`math.min(W, H)` 就等于 `W`，行为与改前一致，无害。fit 循环也保留——它的价值
不止横屏，还覆盖用户调「屏幕 DPI」和内容变长这两种会溢出的情形，并且它就是
「字号能放多大」这个问题的答案本身。

- [ ] **Step 4: 抓 fit 循环日志**

设备上装了 SSH 插件的话 `tail -f koreader/crash.log`，否则重启后直接看该文件。
找 `densestats fit:` 和 `densestats slack:` 两行，记录竖屏下选中的 FSCALE、tries、耗时，
以及 slack 的 rest / gains / 触顶 / top / bottom。

**若耗时超过 200ms**：记进 README，并在汇报里明确指出——spec 说届时需要改成
解析式预估高度，那是后续任务，不在本计划内。

- [ ] **Step 5: 出问题时的退路**

- 两排四列仍被截断 → 把 `CFG.fscale_steps` 的起点从 1.30 降到 1.20，重跑 Step 1-2
- 「已读完」一行都放不下 → 检查 `CFG.min_fin_rows` 是否真的生效（看日志里的 FSCALE 有没有降）
- 整屏退回内置屏保 → 十有八九是 `layout.lua` 没拷过去，看 crash.log 里的
  `module 'layout' not found`

不要为了让某一项好看而自行改别的地方；卡住就停下来报告。

- [ ] **Step 6: 更新 README 的验证记录**

在 `README.md` 的「已知待验证点」小节末尾追加记录：设备型号、竖屏下选中的
FSCALE、fit 循环耗时、本次实际验证过的项。**明确写上横屏未验证**。
保持该小节现有的编号/格式风格。

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "docs: record PW3 portrait verification"
```

---

## 完成标准

- `./dev.sh check` 五个文件全 OK
- `./dev.sh test` 三个测试文件全绿（`test_layout.lua` 19 passed）
- PW3 **竖屏**：两排四列不截断，内容垂直居中，页脚可见，「已读完」≥ 2 行
- 横屏不在本计划范围内（用户决定）
- fit 循环耗时已实测并记录在 README
