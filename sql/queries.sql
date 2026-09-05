-- densestats 口径校验用。用法：
--   sqlite3 -header -column /path/to/statistics.sqlite3 < queries.sql
-- OFF = 0：Kindle 的系统时区是 UTC，插件在它上面用的偏移就是 0；别的设备把
--   下面的 "+ 0" 换成插件 build 日志行里 tz= 的值
-- CAP = 单页时长上限（秒），与统计插件的「单页最长时间」设置一致，默认 120
-- 读完本数不在库里（来自 sidecar），这里核不了

.print '=== 1. 最近 30 天每日阅读（秒） ==='
SELECT date(start_time + 0, 'unixepoch') AS day,
       SUM(MIN(duration, 120)) AS sec,
       ROUND(SUM(MIN(duration, 120)) / 60.0, 1) AS min
FROM page_stat_data
GROUP BY day ORDER BY day DESC LIMIT 30;

.print ''
.print '=== 2. 各书累计时长（截断后 vs book 表原始值） ==='
SELECT b.title,
       ROUND(SUM(MIN(p.duration, 120)) / 3600.0, 2) AS capped_h,
       ROUND(b.total_read_time / 3600.0, 2)         AS raw_h,
       b.pages
FROM page_stat_data p JOIN book b ON b.id = p.id_book
GROUP BY p.id_book ORDER BY capped_h DESC LIMIT 20;

.print ''
.print '=== 3. 总览 ==='
SELECT COUNT(DISTINCT date(start_time + 0, 'unixepoch')) AS active_days,
       ROUND(SUM(MIN(duration, 120)) / 3600.0, 1)            AS total_h,
       date(MIN(start_time) + 0, 'unixepoch')            AS first_day,
       date(MAX(start_time) + 0, 'unixepoch')            AS last_day
FROM page_stat_data;
