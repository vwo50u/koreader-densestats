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
-- 官方同构先例：keyvaluepage.lua:493-495、calendarview.lua:1154-1156。
--
-- bases:     各间隙的基准宽度（像素，调用方传进来时已经缩放过）
-- rest:      待分配的剩余高度（像素）；<= 0 表示没得分
-- max_ratio: 单个间隙最多长到基准值的几倍
-- 返回 { gains = {每个间隙该加多少}, top = 顶部边距, bottom = 底部边距 }
function M.distributeSlack(bases, rest, max_ratio)
    bases = bases or {}
    local n = #bases
    local gains = {}
    for i = 1, n do gains[i] = 0 end

    rest = math.floor(tonumber(rest) or 0)
    if rest <= 0 then return { gains = gains, top = 0, bottom = 0 } end

    local ratio = tonumber(max_ratio) or 1
    local base_total = 0
    for i = 1, n do base_total = base_total + (tonumber(bases[i]) or 0) end

    local given = 0
    if base_total > 0 then
        for i = 1, n do
            local b = tonumber(bases[i]) or 0
            local want  = math.floor(rest * b / base_total)
            local limit = math.floor(b * (ratio - 1))
            if limit < 0 then limit = 0 end
            local add = math.min(want, limit)
            gains[i] = add
            given = given + add
        end
    end

    -- floor 的零头也留在这里，跟着一起进边距；差几个像素不值得再分一轮
    local spare = rest - given
    local top = math.floor(spare / 2)
    return { gains = gains, top = top, bottom = spare - top }
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
