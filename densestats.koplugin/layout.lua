--[[
layout.lua — 排版算术（纯函数，不依赖任何 KOReader 模块）

从 main.lua 抽出来是为了能用 luajit 直接测：分配里的"按比例""封顶""余数"，
以及降档搜索的"全都不通过时兜底"，都是靠肉眼看屏幕验证不了的地方。
--]]

local M = {}

-- 把 rest 像素的剩余高度分掉：各区块间隙按各自基准值的比例增长，单个间隙最多
-- 再加 (max_ratio - 1) 倍基准值；吸收不掉的部分对半塞进上下边距，让内容块整体
-- 垂直居中。原来的做法是一股脑均摊进所有间隙，内容不够多时整屏看着松垮。
--
-- 按比例分而不是均分，是为了保住疏密节奏：基准 22 的间隙该比基准 5 的多拿。
-- 均分 + 封顶会让小间隙先触顶而大间隙还很空。
-- 这一条没有官方先例，是本项目的选择。
--
-- bases:     各间隙的基准宽度（像素，调用方传进来时已经缩放过）
-- rest:      待分配的剩余高度（像素）；<= 0 表示没得分
-- max_ratio: 单个间隙最多长到基准值的几倍
-- 返回 { gains = {每个间隙该加多少}, limits = {每个间隙的上限},
--        top = 顶部边距, bottom = 底部边距 }
-- limits 一并返回，是为了让调用方的诊断日志判断"触顶"时不必自己复制这个公式。
function M.distributeSlack(bases, rest, max_ratio)
    bases = bases or {}
    local n = #bases
    local ratio = tonumber(max_ratio) or 1
    local gains, limits = {}, {}
    local base_total = 0
    for i = 1, n do
        local b = tonumber(bases[i]) or 0
        gains[i] = 0
        -- +0.5 与 main.lua 的 scaled() 用同一套取整约定。直接 floor 会因为
        -- (ratio - 1) 的浮点误差方向随 ratio 变化而偶尔少 1：
        -- ratio=1.6 时 1.6-1 略大于 0.6（安全），但 ratio=1.2 时 1.2-1 略小于 0.2，
        -- 10 * 它算出 1.999… 会被 floor 成 1，而精确值是 2。
        local lim = math.floor(b * (ratio - 1) + 0.5)
        limits[i] = lim > 0 and lim or 0
        base_total = base_total + b
    end

    -- 早退路径上 limits 也必须是真实上限：调用方用 gains[i] >= limits[i] 判触顶，
    -- 这里若返回 0 就会把"没得分"误报成"全触顶"。
    rest = math.floor(tonumber(rest) or 0)
    if rest <= 0 then return { gains = gains, limits = limits, top = 0, bottom = 0 } end

    local given = 0
    if base_total > 0 then
        for i = 1, n do
            local want = math.floor(rest * (tonumber(bases[i]) or 0) / base_total)
            local add = math.min(want, limits[i])
            gains[i] = add
            given = given + add
        end
    end

    -- floor 的零头也留在这里，跟着一起进边距；差几个像素不值得再分一轮。
    -- 余量归还边距的做法有官方先例：keyvaluepage.lua:493-495 把 floor 丢掉的像素
    -- 对半塞进标题与内容之间，calendarview.lua:1154-1156 把列宽算完的余量反推回
    -- outer_padding。
    local spare = rest - given
    local top = math.floor(spare / 2)
    return { gains = gains, limits = limits, top = top, bottom = spare - top }
end

-- 从大到小试各档系数，返回第一个通过的结果。
-- 全都不通过时返回最后一档——宁可字小，也不能把内容顶出屏幕。
-- 这是 KOReader 官方的套路（calendarview.lua:1307-1319 的探针降号循环、
-- keyvaluepage.lua:501 的从行高反推字号并封顶）。
--
-- steps: 从大到小的候选系数数组
-- probe(step) -> ok(boolean), payload
-- 返回 payload, 选中的 step, 实际试了几次
function M.fitScale(steps, probe)
    steps = steps or {}
    local n = #steps
    local payload, step
    for i = 1, n do
        local ok
        ok, payload = probe(steps[i])
        step = steps[i]
        if ok or i == n then return payload, step, i end
    end
    return nil, nil, 0
end

return M
