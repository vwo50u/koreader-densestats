--[[
moon.lua — 由日期算月相

用的是朔望月平均周期的近似（不是星历表）：
  参考朔（新月）：2000-01-06 18:14 UTC = JD 2451550.09766
  朔望月平均长度：29.530588861 天
真实的朔望间隔在 29.27~29.83 天之间摆动，所以本算法的月龄误差可达 ±0.6 天左右，
判断"今天是盈是亏、大概几分圆"足够，不能拿来当天文历用。

纯逻辑，不依赖 KOReader，可用 luajit 直接跑测试。
--]]

local M = {}

M.SYNODIC = 29.530588861
M.EPOCH_JD = 2451550.09766   -- 已知新月时刻

function M.toJD(ts)
    return ts / 86400.0 + 2440587.5
end

-- 返回 0..1 的相位：0=朔(新月) 0.25=上弦 0.5=望(满月) 0.75=下弦
function M.phase01(ts)
    local k = (M.toJD(ts) - M.EPOCH_JD) / M.SYNODIC
    local p = k - math.floor(k)
    if p < 0 then p = p + 1 end
    return p
end

function M.age(ts)              -- 月龄（天）
    return M.phase01(ts) * M.SYNODIC
end

function M.illumination(ts)     -- 被照亮的比例 0..1
    return (1 - math.cos(2 * math.pi * M.phase01(ts))) / 2
end

-- 中文相名。边界按月龄取整天划分，贴近日常说法。
local NAMES = {
    { 0.02,  "新月" },
    { 0.22,  "蛾眉月" },
    { 0.28,  "上弦月" },
    { 0.47,  "盈凸月" },
    { 0.53,  "满月" },
    { 0.72,  "亏凸月" },
    { 0.78,  "下弦月" },
    { 0.98,  "残月" },
    { 1.01,  "新月" },
}

function M.name(ts)
    local p = M.phase01(ts)
    for _, e in ipairs(NAMES) do
        if p < e[1] then return e[2] end
    end
    return "新月"
end

function M.isWaxing(ts)         -- 盈（渐圆）还是亏
    return M.phase01(ts) < 0.5
end

-- 下一次满月/新月的时间戳
function M.nextPhase(ts, target)  -- target: 0=新月 0.5=满月
    local p = M.phase01(ts)
    local d = target - p
    if d <= 0 then d = d + 1 end
    return ts + d * M.SYNODIC * 86400
end

return M
