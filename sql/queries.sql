-- densestats 口径校验用。用法：
--   sqlite3 -header -column /path/to/statistics.sqlite3 < queries.sql
-- OFF = 本地时区偏移秒数，新加坡 UTC+8 = 28800
-- CAP = 单页时长上限（秒），与插件 CFG.max_sec 一致

.print '=== 1. 最近 30 天每日阅读（秒） ==='
SELECT date(start_time + 28800, 'unixepoch') AS day,
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
.print '=== 3. "读完"判定明细（人工核对误判用） ==='
SELECT b.title,
       ROUND(x.frac, 3) AS max_frac,
       date(x.last_ts + 28800, 'unixepoch') AS last_read,
       CASE WHEN x.frac >= 0.97 THEN 'FINISHED' ELSE '' END AS verdict
FROM (
    SELECT id_book, MAX(start_time) AS last_ts,
           MAX(page * 1.0 / NULLIF(total_pages, 0)) AS frac
    FROM page_stat_data GROUP BY id_book
) x JOIN book b ON b.id = x.id_book
ORDER BY x.frac DESC;

.print ''
.print '=== 4. 每月读完本数（估算） ==='
SELECT strftime('%Y-%m', x.last_ts + 28800, 'unixepoch') AS month, COUNT(*) AS books
FROM (
    SELECT id_book, MAX(start_time) AS last_ts,
           MAX(page * 1.0 / NULLIF(total_pages, 0)) AS frac
    FROM page_stat_data GROUP BY id_book
) x
WHERE x.frac >= 0.97
GROUP BY month ORDER BY month DESC;

.print ''
.print '=== 5. 总览 ==='
SELECT COUNT(DISTINCT date(start_time + 28800, 'unixepoch')) AS active_days,
       ROUND(SUM(MIN(duration, 120)) / 3600.0, 1)            AS total_h,
       date(MIN(start_time) + 28800, 'unixepoch')            AS first_day,
       date(MAX(start_time) + 28800, 'unixepoch')            AS last_day
FROM page_stat_data;
