# 装到 Kindle

## 复制什么

整个 `densestats.koplugin` 文件夹拷过去就行，里面是 4 个文件：

```
densestats.koplugin/
├── _meta.lua
├── main.lua
├── stats.lua
└── finished.lua
```

一个都不能少：`main.lua` 会 `require` 另外两个，缺了插件直接起不来。

**不要复制**仓库里的其他东西：`test/`、`dev.sh`、`sql/`、`.testdata/`、
`statistics.sqlite3`（那是从设备上拷出来的副本，回拷会覆盖真实统计数据）。

## 放在哪

设备上的 `koreader/plugins/` 目录下，保持文件夹名不变：

```
Kindle: /mnt/us/koreader/plugins/densestats.koplugin/
```

USB 连上电脑后，就是 Kindle 盘符根目录的 `koreader/plugins/`。

## 怎么启用

1. 复制完成后**重启 KOReader**（不是重启 Kindle）。
2. 插件默认就是启用的——KOReader 会扫描 `plugins/` 下所有 `.koplugin` 目录，
   只有被显式加进 `plugins_disabled` 的才不加载。可以在
   **主菜单 → 工具 → 更多工具 → 插件管理** 里确认 densestats 在列表里且已勾选。
3. 确认 **statistics（阅读统计）插件保持启用**。本插件的数据全部来自它的
   `statistics.sqlite3`，而且睡眠屏幕的接管点也挂在它身上。
4. 睡眠屏幕设置保持 **「在休眠屏幕上显示阅读进度」**（你现在就是这个）。
   本插件不新增屏保类型，而是替换掉这一项画出来的内容。

## 验证顺序

1. **按电源键锁屏** —— 屏保应该换成这个面板。这是唯一需要确认的事。
2. **主菜单 → 更多工具 → 「重新扫描已读完书籍」** —— 弹出的本数对不对。
   显示 0 的话，多半是书不在 KOReader 的主目录下，去
   文件管理器里把书库目录设为主目录再扫。
3. 回到文件浏览器（不开任何书）再锁一次屏 —— 也应该是这个面板。
   这里如果回到了旧壁纸，说明接管没挂上，看下面的排查。

## 出问题看哪里

日志在 `koreader/crash.log`，插件自己的输出都以 `densestats:` 开头。

- **锁屏还是旧壁纸** → 接管点没挂上。日志里搜 `睡眠屏幕接管已挂载`：
  没有这行的话，要么是 `onShowReaderProgress 不可调用`（设备上的 KOReader
  比 2026.07 老，走的是另一套接口），要么是 statistics 插件自己没起来
  （搜 `Failed to initialize statistics`，多半是统计库迁移中断）。
- **屏保是空白或构建失败** → 日志里会有 `densestats: build failed` 加具体错误。
- **每次熄屏很慢** → 日志里每次熄屏都有一行 `densestats build: 合计 Xms`，
  分了 SQL / 汇总 / 缓存 / 排版四段，直接看是哪一段贵。
- **数字看着不对** → 用 `sql/queries.sql` 在电脑上对着同一个库核一遍。

渲染整体包在 pcall 里，最坏情况是退回 KOReader 内置的阅读进度页，
不会让设备睡不着或醒不来。
