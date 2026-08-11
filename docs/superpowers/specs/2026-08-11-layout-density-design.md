# 睡眠屏布局密度调整：自适应字号 + 收紧留白

日期：2026-08-11
状态：待实现（v2，调研后重写）

## 问题

真机（PW3，1072×1448）上字偏小、版面偏空。但调研 KOReader 源码后发现，
底下压着三个更要紧的问题：

1. **没有「装不下就缩」的路径。** `main.lua:568` 是 `if rest > 0 then`——
   `rest < 0` 时什么都不做，内容直接画出屏幕、页脚消失。这是现有缺陷。
2. **横屏必翻车。** `screensaver.lua:330-335` 明确把 `readingprogress` 排除在
   「强制转竖屏」之外，本插件正好接管这个模式。官方 `readerprogress.lua:41-47`
   有横竖屏分支，本插件没有。
3. **空旷的来源**：`main.lua:567-578` 把全部剩余高度平摊进 10 个区块间隙。
   「已读完」列表填完预算后，只要书不够多，剩下的空白全被摊成缝隙。

## 调研结论（全部经源码核实）

**`Screen:scaleBySize(px)` 按屏幕短边缩放，默认完全不看 DPI**
（`ffi/framebuffer.lua:414-425`）：

```lua
local size_scale = math.min(self:getWidth(), self:getHeight()) / 600
local dpi_scale = size_scale
if self.dpi_override then dpi_scale = self.dpi / 160 end
return math.ceil(px * (size_scale + dpi_scale) / 2)
```

推论：`Font:getFace(name, size)` 的 size 是**未缩放的设计尺寸**，内部仍过
`scaleBySize`（`frontend/ui/font.lua:269-277`）。所以写死一个数字**不会**破坏
跨分辨率一致性——它在每台设备上放大同样的倍数。真正会让版面崩掉的变量是
**横屏、用户的「屏幕 DPI」覆盖、内容长度**，跟分辨率和 DPI 本身无关。

**官方处理「铺满一屏」的做法是从可用空间反推字号，装不下就降号重试**：

- `plugins/statistics.koplugin/calendarview.lua:1305-1319`：先用
  `TextBoxWidget:getFontSizeToFitHeight` 从可用高度算字号，再用「最宽可能字符串」
  当探针 `while` 循环降号，直到 `test_w:getWidth() <= day_inner_width`
- `frontend/ui/widget/keyvaluepage.lua:492-501`：行高 = 可用高度 / 每页条目数，
  字号从行高反推并封顶 22；floor 损失的像素对半分给上下
- `frontend/ui/widget/menu.lua:135-141`：把用户设的字号封顶到「至少能显示一行」

**`TextWidget:isTruncated()`（`frontend/ui/widget/textwidget.lua:307-310`）**
可以直接问「这段文字被 `max_width` 截断了吗」，比自己量宽度可靠。

**官方同位置竞品 `readerprogress.lua`** 只用命名档位、不做字号自适应
（`:36-38`），但有横竖屏间距分支（`:41-47`），进度条高度用
`Screen:scaleBySize(14)`（`:262`）。

## 目标

信息项一个不加不减。字号在**放得下的前提下**尽量大，放不下自动降档，
任何设备/方向/DPI 设置下都不溢出屏幕。

**非目标**：不新增统计维度，不改数据层，不改版式结构（不拆两排、不换布局）。

## 方案

### 1. 三档字号 = 命名档位基准值 × 自适应系数

保留现有「三档、按角色固定分配」的设计，基准值就取 KOReader 命名档位的原始
设计尺寸（`font.lua:90-92`）：强调 25、正文 20、辅助 15。整体乘一个系数
`FSCALE`，由下面的 fit 循环决定。

```lua
local BASE_V, BASE_M, BASE_L = 25, 20, 15
local FSCALE = 1.0   -- 由 buildWidget 的 fit 循环设定
local function FACE_V() return Font:getFace("largeffont", math.max(8, math.floor(BASE_V * FSCALE + 0.5))) end
local function FACE_M() return Font:getFace("ffont",      math.max(8, math.floor(BASE_M * FSCALE + 0.5))) end
local function FACE_L() return Font:getFace("smallffont", math.max(8, math.floor(BASE_L * FSCALE + 0.5))) end
```

字体族保持各自原样（三者在 fontmap 里都指向 `NotoSans-Regular.ttf`，
`font.lua:49-51`，所以换不换名字都不影响字形）。

### 2. fit 循环

`buildWidget` 的函数体拆成 `layoutOnce(data, d)`，返回
`widget, budget, fin_row_h, truncated`。外层从大到小试系数：

```lua
CFG.fscale_steps = { 1.30, 1.20, 1.10, 1.00, 0.90, 0.80, 0.70, 0.60 }
CFG.min_fin_rows = 2
```

接受条件：**四列小块没有任何一格被截断**，且 **`budget >= min_fin_rows * fin_row_h`**。
全部档位都不满足时用最后一档兜底——宁可字小，也不能把页脚顶出屏幕。

起点 1.30 使 PW3 竖屏的观感接近「强调 32 / 正文 26 / 辅助 20」，比现状大约三成。
`min_fin_rows = 2` 是用户的选择：字号优先，「已读完」保底 2 行。

截断检测走 `TextWidget:isTruncated()`。`cellRow` 增加第二个返回值报告本排是否有截断。
随着 FSCALE 下降文字变窄而 `cap_w` 不变，截断是单调消失的，循环必然收敛。

**为什么这在多设备上成立**：它不假设任何设备参数，只问「在这次的
`Screen:getWidth()/getHeight()` 和这次的 `scaleBySize` 之下放不放得下」。
分辨率、宽高比、方向、DPI 覆盖、内容长度全部自动覆盖。

**成本**：最坏 8 次重排，只做 `getSize()`（触发 xtext shaping），不 paint；
freetype face 按 `realname..size` 缓存（`font.lua:288-293`）。多数情况第一档就通过。
这发生在入睡路径上，**必须实测耗时**，超过 200ms 就要改成解析式预估高度。

### 3. 留白按短边取比例

```lua
local W, H = Screen:getWidth(), Screen:getHeight()
local pad = math.max(Size.padding.fullscreen, math.floor(math.min(W, H) * 0.06))
```

原来按 `getWidth()` 取，横屏时宽度是长边，会白白吃掉本就紧张的高度。
PW3 横屏下这一条把 pad 从 86 降到 64。

### 4. 曲线高度按可用高度，进度条对齐官方

- 曲线：`Screen:getHeight() * 0.10` → `(H - pad*2) * 0.12`。横屏下按屏高取
  和按可用高度取差得远，后者才是「占内容区 12%」的本意。
- 进度条：`Screen:scaleBySize(10)` → `scaleBySize(14)`，与
  `readerprogress.lua:262` 一致。

### 5. 间隙按基准值比例分配，封顶 1.6 倍，余白对称归上下

替换 `main.lua:567-578` 的均匀平摊：

```
want_i  = floor(rest * base_i / base_total)
limit_i = floor(base_i * (gap_max_ratio - 1))
add_i   = min(want_i, limit_i)
spare   = rest - Σ add_i
top     = floor(spare / 2)
bottom  = spare - top
```

`top` / `bottom` 各造一个 `VerticalSpan`，分别插到 `root` 最前和追加在页脚之后，
**不加入 `flex` 表**。效果是内容块紧凑并整体垂直居中。

按基准值比例分（而不是均分）是为了保住疏密节奏：`gap(22)` 该比 `gap(5)` 多拿。
均分 + 封顶会让 `gap(5)` 先触顶而 `gap(22)` 还很空。

官方先例：`keyvaluepage.lua:493-495`（floor 损失的像素对半分给上下）、
`calendarview.lua:1154-1156`（列宽算完把余量反推回 `outer_padding`）。

`gap()` 需要记下基准宽度（`sp._base`）供比例计算使用。

### 6. 保持不变

- `cellRow` 的两端对齐算法（只加截断上报，不改分配逻辑）
- 「已读完」列表的预算逻辑（`main.lua:551-558`）
- 日期列宽按实测文字宽度（`main.lua:441-443`）——字号会变，这条尤其重要
- 整体 `pcall` 兜底
- **`resetLayout()`**：`getSize()` 会缓存 `_offsets`，改完子元素宽度或往 `root` 里
  插东西必须重置，否则 `paintTo` 时 `_offsets[i]` 为 nil 直接崩
  （`frontend/ui/widget/verticalgroup.lua:51`）

## 改动范围

- 新建 `densestats.koplugin/layout.lua`：纯排版算术（`distributeSlack`、`fitScale`）
- 新建 `test/test_layout.lua`，挂进 `test/run.sh`
- 改 `densestats.koplugin/main.lua`：CFG、FACE_*、`curveWidget`、`currentBook`、
  `cellRow`、`buildWidget` 拆分与 fit 循环、间隙分配
- 改 `README.md`：记录真机验证

`stats.lua`、`finished.lua`、`_meta.lua` 不动。

## 验证

1. `./dev.sh check` —— 语法检查通过
2. `./dev.sh test` —— 含新增的 `test_layout.lua` 全绿
3. `DENSESTATS_DEBUG=1 ./dev.sh run` —— 日志里确认选中的 FSCALE 和重排次数，
   **并记录 fit 循环耗时**
4. 桌面预览目测：间隙紧凑、内容垂直居中、页脚可见
5. **真机（PW3）验证**：
   - 两排四列不换行、不截断
   - 内容垂直居中，页脚完整可见
   - 「已读完」至少 2 行

**横屏不在验证范围内**（用户 2026-08-11 决定）。方向无关的改动仍然保留——竖屏下
`math.min(W, H)` 就等于 `W`，与改前行为一致，无害；fit 循环的价值也不止横屏，
它同时覆盖用户调「屏幕 DPI」和内容变长这两种会溢出的情形。

## 已知取舍与风险

- `min_fin_rows = 2`：字号优先，「已读完」从命名档位下的 3 行减到 2 行。
- fit 循环最坏 8 次重排，耗时未实测。超 200ms 需改成解析式预估。
- 调研中的高度数字来自源码复刻的模型，**不是真机实测**，模型可能漏算某个 span。
  所有定量结论都以第 5 步真机为准。
- 字符串宽度估算未走 HarfBuzz（无 kerning / CJK 回退字体的真实 advance），
  截断阈值是边缘判断——但 `isTruncated()` 走的是真实排版，所以运行时判断是准的。
