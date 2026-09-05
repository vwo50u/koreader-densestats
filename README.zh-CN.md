# densestats.koplugin

[English](README.md) · **简体中文**

高密度阅读统计睡眠屏幕。接管 KOReader 内置的 `readingprogress` 睡眠屏幕类型：
该模式下 `frontend/ui/screensaver.lua` 通过 `ui.statistics:onShowReaderProgress(true)`
向统计插件要部件，本插件包住这个方法。设置里仍然选「在休眠屏幕上显示阅读进度」，
画出来的换成本插件的版本。

数据只读 statistics 插件的 `statistics.sqlite3`，不写。**statistics 插件必须保持启用**
（screensaver.lua 会检查 `ui.statistics`，不在就退回随机图片）。

## 显示内容

自上而下：

- **今日阅读时长**：整屏唯一的大字，写成 `1:20`。今天还没读就退到昨天，昨天也没有就退到本周，标签跟着换
- **一行小字**：连读天数 · 累计时长 · 读完本数，零值不写
- **最近 30 天曲线**：细柱、深灰、柱间留缝，没读的日子留空。不标题、不标数。今天那根浅灰，因为多半只读了一半
- **当前在读**：书名（一行放不下就丢副标题），作者 · 百分比（向下取整）· 约剩多久（按这本书自己的速度估，只算当前排版下读过的页），一条细线进度（读过的黑、未读的浅灰）
- **电量**：右下角极小灰字。不放时钟——屏保一渲染就静止了，停住的钟只会误导

### 排版原则

极简、留白、左对齐。三条规矩：

- 字号只有三档，大字只给一个数；
- 墨色分黑 / 深灰 / 浅灰三级，黑只给今日时长和书名；
- 分区靠留白，一条分隔线都不画。

字号写的是 KOReader 的「设计尺寸」，`Font:getFace` 内部按屏幕短边 / 600 缩放，
跨分辨率自动成立。内容量固定，竖屏横屏都放得下，所以没有字号自适应循环。
间距按屏高比例写，横屏自动收紧。

## 目录

```
densestats.koplugin/
  main.lua       渲染与插件挂载（唯一碰 KOReader widget 的地方）
  stats.lua      时长格式化 + 时间序列推导（纯 Lua，可单测）
  finished.lua   扫 sidecar 统计读完的书（纯 Lua，可单测）
sql/queries.sql  口径校验用的独立 SQL
test/            单元测试，用 KOReader 自带的 luajit 直接跑
dev.sh           开发脚本
```

## 调试路线

### 1. SQL 层（先做这个，跟 KOReader 无关）

```
sqlite3 -header -column /path/to/statistics.sqlite3 < sql/queries.sql
```

读完本数在这里核不了：它来自 sidecar，不在数据库里（见下面的口径说明）。

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

**桌面平台没有睡眠屏幕功能**，所以钩子不会被触发。改用 `DENSESTATS_AUTOSHOW=1`
启动，六秒后会自动弹出同一份部件；再加 `DENSESTATS_SHOT=/path/to/shot.png`
会在两秒后把它存成 PNG。真机上直接锁屏就是。

不建议从源码 `./kodev build` —— 本机缺 cmake / autoconf / nasm / luarocks，
在 macOS arm64 上从零编译 koreader-base 是几小时起的活，调 UI 用不上。

### 3. 真机

设备 USB 挂载后 `./dev.sh install` 会把插件拷到正确位置（Kindle 是
`koreader/plugins/`，Kobo 是 `.adds/koreader/plugins/`）并 diff 校验，手动拷法见
INSTALL.md。拷完重启 KOReader。日志在 `koreader/crash.log`（`logger.warn` 的输出
会进去），每次熄屏都有一行 `densestats build:`，带 SQL / 排版耗时、库大小和用的
时区偏移。装 KOReader 自带的 SSH 插件可以远程 tail。

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
  前面，所以 `init()` 时 `self.ui.statistics` 还不存在。钩子挂在
  `registerPostInitCallback` 里，ReaderUI 和文件管理器都会在全部模块注册完之后
  跑它；`onReaderReady` 只有 ReaderUI 有，留作兜底。KOReader 2026.07 还把插件的
  `onXxx` 处理器包成了「可调用的表」（带 `__call` 的 metatable），判断时不能只认
  `type == "function"`。

## 验证状态

已在 Kindle Paperwhite 3（1072×1448）竖屏下真机验证通过。以下是仍未解决的部分。

## 已知限制

- **横屏未验证**。方向无关的尺寸基准已经就位，但没在真机上转横屏跑过。
- **内容比屏幕还高时只会先吃掉顶部留白**。内容量固定，正常 DPI 下横竖屏都放得下，
  本不该发生；真发生的话，方向是砍掉整块内容，而不是缩字号。
- **只数在 KOReader 里标记为「已读完」的书**，见下面的口径说明。

渲染整体包在 `pcall` 里，失败会退回内置页面，不会导致设备睡不着。

## 口径说明

- **单页时长截断**：原始 duration 含"忘了合上"的脏数据，逐日数字按统计插件自己的
  「单页最长时间」设置截断（`CFG.max_sec = 120` 只是该设置缺失时的兜底）。
- **累计就是 KOReader 自己的累计**：取 `book.total_read_time` 之和，也就是统计插件
  页面上显示的那个数，不从逐页表重算，两边永远一致。
- **读完的书**：sidecar 里 `summary.status` 为 `complete` 的，即在 KOReader 里标记
  为已读完的书。书库和 docsettings 目录由子进程扫描，最多 12 小时一次，结果缓存；
  菜单里的「重新扫描已读完书籍」（也可绑手势）会强制重扫。
- **时区**：`start_time` 是 UTC 秒。按进程时区在本地零点切日，与统计插件的
  `localtime` 分组口径相同；Kindle 系统时区是 UTC，偏移为 0。实际用的值打在 build
  日志行的 `tz=` 里；在别的机器上读设备的库时用 `DENSESTATS_TZ_OFFSET` 覆盖。
- **连续天数**：今天还没读不算断，从昨天往回数。

## 许可

[AGPL-3.0](LICENSE)，与 KOReader 本体一致。
