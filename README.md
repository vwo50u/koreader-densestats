# densestats.koplugin

高密度阅读统计睡眠屏幕。接管 KOReader 内置的 `readingprogress` 睡眠屏幕类型
（`frontend/ui/screensaver.lua` 里 `widget = Screensaver.getReaderProgress()`），
设置里仍然选「在休眠屏幕上显示阅读进度」，画出来的换成本插件的版本。

数据只读 statistics 插件的 `statistics.sqlite3`，不写。**statistics 插件必须保持启用**
（screensaver.lua 会检查 `ui.statistics`，不在就退回随机图片）。

## 显示内容

自上而下：

- **两排统计**：今日 / 本周 / 本月 / 今年 阅读时长；连续天数 / 累计时长 / 今日页数 / 本周页数
- **最近 30 天柱状曲线**，横穿一条有效日均的参考虚线（左侧标注日均时长），
  一眼能看出哪些天超过了自己的平均水平
- **当前在读**：书名、进度条、百分比 / 页码 / 该书累计时长
- **已读完**：按日期倒序的书单，同月只在第一行标月份
- **页脚**：日期时间 · 电量

### 字号是自适应的

三档字号（强调 / 正文 / 辅助）取 KOReader 命名档位的设计尺寸 25 / 20 / 15，
再整体乘一个系数 `FSCALE`。渲染时从 1.30 起逐档往下试，第一个「放得下」的档位胜出——
判据是四列统计没有任何一格被截断，且「已读完」至少放得下 2 行。全都不满足就用
最小档兜底，宁可字小也不把页脚顶出屏幕。

这是 KOReader 官方处理「铺满一屏」的套路（见 `calendarview.lua`、`keyvaluepage.lua`、
`menu.lua`），比写死一组「在我这台机器上刚好」的数字可靠：它不假设任何设备参数，
只问「在这次的屏幕尺寸和缩放系数下放不放得下」，分辨率、宽高比、方向、用户的
「屏幕 DPI」覆盖、内容长度全都自动被覆盖。

`DENSESTATS_DEBUG=1` 会在日志里打出选中的档位、试了几次、以及排版耗时。

## 目录

```
densestats.koplugin/
  main.lua       渲染与插件挂载（唯一碰 KOReader widget 的地方）
  stats.lua      时长格式化 + 时间序列推导（纯 Lua，可单测）
  finished.lua   扫 sidecar 统计读完的书（纯 Lua，可单测）
  layout.lua     排版算术：余白分配、降档搜索（纯 Lua，可单测）
sql/queries.sql  口径校验用的独立 SQL
test/            单元测试，用 KOReader 自带的 luajit 直接跑
dev.sh           开发脚本
```

## 调试路线

### 1. SQL 层（先做这个，跟 KOReader 无关）

```
sqlite3 -header -column /path/to/statistics.sqlite3 < sql/queries.sql
```

重点核对第 3 段「读完判定明细」——那是启发式，肯定有误判。

### 2. macOS 桌面调试

macOS 版 KOReader **不在 Releases 里**，要从 GitHub Actions 的构建产物下载
（arm64），见 wiki: Installation on MacOS。macOS 15.7 以上首次打开会被 Gatekeeper 拦，
需到「系统设置 → 隐私与安全性」最下方点「仍要打开」。

装好之后：

```
./dev.sh link                                  # 软链插件进 KOReader.app
./dev.sh db ~/Downloads/statistics.sqlite3     # 灌真实数据
./dev.sh run                                   # 启动
```

**桌面平台没有睡眠屏幕功能**，所以钩子不会被触发。用插件自带的调试入口：
主菜单 → 更多工具 → 「预览：密集统计屏」，点一下屏幕关闭。

不建议从源码 `./kodev build` —— 本机缺 cmake / autoconf / nasm / luarocks，
在 macOS arm64 上从零编译 koreader-base 是几小时起的活，调 UI 用不上。

### 3. 真机

插件文件夹丢进设备的 `koreader/plugins/`，重启。日志在 `koreader/crash.log`
（`logger.warn` 的输出会进去）。装 KOReader 自带的 SSH 插件可以远程 tail。

## 已核实的 KOReader 行为

这几条当初列为「待验证」，后来读源码逐条确认过，写在这里省得再查
（行号对应 KOReader 2026.07）：

- **`Screen:scaleBySize(px)` 按屏幕短边缩放，默认完全不看 DPI**
  （`ffi/framebuffer.lua:414-425`）：`size_scale = min(w, h) / 600`，只有用户在
  设置里手动指定过「屏幕 DPI」时 DPI 才参与。所以「写死一个数字会不会在别的
  分辨率上崩」这个担心是多余的——它在每台设备上放大同样的倍数。
- **`Font:getFace(name, size)` 的第二参是「未缩放的设计尺寸」**，内部仍会过
  `scaleBySize`（`frontend/ui/font.lua:269-277`）。
- **`FrameContainer` 的 `width` / `height` 不被 `getSize()` 采纳**
  （`framecontainer.lua:53-66` 完全忽略它们，只有 `paintTo` 在 116-117 行拿去画
  背景和边框）。本插件正好依赖这个行为：`getSize()` 返回内容高 + 上下 padding，
  外层 `CenterContainer` 才能算出 0 偏移。
- **`readingprogress` 模式不会被强制转成竖屏**（`screensaver.lua:330-335` 把它
  明确排除在 `modeExpectsPortrait()` 之外）。本插件的尺寸基准因此一律取屏幕短边
  或内容区高度，不取 `getWidth()` / `getHeight()`。**但横屏未做真机验证。**
- **`TextWidget` 的高度只取决于 face，与文本内容无关**
  （`textwidget.lua:112-113`），所以量行高用任意等档文字当探针都准。
- **插件加载顺序**：插件按目录名字母序实例化，`densestats` 排在 `statistics`
  前面，所以 `init()` 时 `self.ui.statistics` 还不存在，钩子必须挂在
  `onReaderReady`。KOReader 2026.07 还把插件的 `onXxx` 处理器包成了「可调用的表」
  （带 `__call` 的 metatable），判断时不能只认 `type == "function"`。

## 已知限制

- **横屏未验证**。方向无关的尺寸基准已经就位，但没在真机上转横屏跑过。
- **降到最小档仍然放不下时没有降级手段**。竖屏 + 正常 DPI 下够不着，但真发生
  的话内容会被裁切。要补的话方向是砍掉整块内容，而不是继续缩字号。
- **读完判定是启发式的**，见下面的口径说明。

渲染整体包在 `pcall` 里，失败会退回内置页面，不会导致设备睡不着。

## 口径说明

- **单页时长截断**：原始 duration 含"忘了合上"的脏数据，按 `CFG.max_sec = 120` 截断，
  与 statistics 插件自身做法一致。因此累计值会小于 `book.total_read_time`。
- **读完判定**：完成状态存在书旁边的 sidecar 里，不在数据库中。这里用
  `MAX(page/total_pages) >= 0.97` 且取最后一次阅读的月份，属于估算。
- **时区**：`start_time` 是 UTC 秒，偏移在 Lua 里算好再传进 SQL（不依赖 SQLite 的
  `localtime` 修饰符，Kindle 系统时区常为 UTC）。
- **连续天数**：今天还没读不算断，从昨天往回数。
