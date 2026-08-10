# densestats.koplugin

高密度阅读统计睡眠屏幕。接管 KOReader 内置的 `readingprogress` 睡眠屏幕类型
（`frontend/ui/screensaver.lua` 里 `widget = Screensaver.getReaderProgress()`），
设置里仍然选「在休眠屏幕上显示阅读进度」，画出来的换成本插件的版本。

数据只读 statistics 插件的 `statistics.sqlite3`，不写。**statistics 插件必须保持启用**
（screensaver.lua 会检查 `ui.statistics`，不在就退回随机图片）。

## 显示内容

- 今日 / 本周 / 本月 / 今年 阅读时长
- 连续阅读天数、30 天日均、有效日均（只算有记录的天）、累计
- 最近 30 天柱状曲线
- 各书累计时长（Top 6，带条形）
- 每月读完本数（估算）

## 目录

```
densestats.koplugin/   插件本体（_meta.lua + main.lua）
sql/queries.sql        口径校验用的独立 SQL
dev.sh                 开发脚本
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

## 已知待验证点（未在真机/模拟器跑过）

1. `SQ3.open(path, "ro")` 的只读第二参数
2. `LineWidget` 的 `dimen` + `background` 组合是否按预期画实心矩形
3. `FrameContainer` 的 `width` / `height` 是否被 `getSize()` 采纳
4. 插件加载顺序：本插件包的是 `Screensaver.setup`，理论上不受 statistics 插件
   重新赋值 `getReaderProgress` 的影响，但没实测过

渲染整体包在 `pcall` 里，失败会退回内置页面，不会导致设备睡不着。

## 口径说明

- **单页时长截断**：原始 duration 含"忘了合上"的脏数据，按 `CFG.max_sec = 120` 截断，
  与 statistics 插件自身做法一致。因此累计值会小于 `book.total_read_time`。
- **读完判定**：完成状态存在书旁边的 sidecar 里，不在数据库中。这里用
  `MAX(page/total_pages) >= 0.97` 且取最后一次阅读的月份，属于估算。
- **时区**：`start_time` 是 UTC 秒，偏移在 Lua 里算好再传进 SQL（不依赖 SQLite 的
  `localtime` 修饰符，Kindle 系统时区常为 UTC）。
- **连续天数**：今天还没读不算断，从昨天往回数。
