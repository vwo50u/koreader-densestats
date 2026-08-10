# 装到 Kindle

## 复制什么

只复制 `densestats.koplugin` 这一个文件夹里的 4 个文件：

```
densestats.koplugin/
├── _meta.lua
├── main.lua
├── stats.lua
└── finished.lua
```

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

1. **主菜单 → 更多工具 → 「预览：密集统计屏」** —— 先确认能画出来。
2. **主菜单 → 更多工具 → 「重新扫描已读完书籍」** —— 弹出的本数对不对。
   显示 0 的话，多半是书不在 KOReader 的主目录下，去
   文件管理器里把书库目录设为主目录再扫。
3. 按电源键睡眠，看屏保是不是换成了这个面板。

## 出问题看哪里

日志在 `koreader/crash.log`，插件自己的输出都以 `densestats:` 开头。

- **预览能画、屏保没变** → 接管点没挂上。日志里会有
  「未找到 onShowReaderProgress」，说明设备上的 KOReader 版本比 2026.07 老，
  那个版本走的是另一套接口。
- **预览也画不出来** → 日志里会有「preview build failed」加具体错误。
- **数字看着不对** → 用 `sql/queries.sql` 在电脑上对着同一个库核一遍。

渲染整体包在 pcall 里，最坏情况是退回 KOReader 内置的阅读进度页，
不会让设备睡不着或醒不来。
