local _ = require("gettext")
return {
    -- 字段名是 fullname，不是 fulltext：pluginloader.lua:108 读的是
    -- `plugin.fullname or plugin.name`，写错了插件管理列表里就只显示目录名。
    -- 这里不要写 name —— pluginloader.lua:256-259 把它当 deprecated 丢弃并打警告，
    -- 真正的 name 来自目录名。
    fullname = _("Dense reading stats"),
    description = _("极简阅读统计睡眠屏幕：今日时长、连续天数、累计、读完本数、30 天曲线、当前在读。"),
}
