--[[
finished.lua — 从 sidecar 读取"已读完"的书

为什么不用数据库：KOReader 的完成状态存在书旁边的 sidecar 里
（`<书名>.sdr/metadata.<ext>.lua` 的 summary 表），statistics.sqlite3 里没有。
  ["summary"] = { ["status"] = "complete", ["modified"] = "2026-08-06", ... }
（字段来自 bookstatuswidget.lua 的注释与 readerstatus.lua:214-215）

本模块刻意不依赖任何 KOReader UI 模块，只依赖 lfs，方便用 luajit 单独跑测试。
--]]

local M = {}

-- 判断是不是 sidecar 元数据文件：metadata.<ext>.lua
function M.isSidecarFile(name)
    return name:match("^metadata%..+%.lua$") ~= nil
end

-- 解析单个 sidecar，返回 status, modified（都可能为 nil）
function M.readSidecar(path, loader)
    loader = loader or dofile
    local ok, t = pcall(loader, path)
    if not ok or type(t) ~= "table" then return nil end
    local s = t.summary
    if type(s) ~= "table" then return nil end
    return s.status, s.modified
end

-- 递归扫描目录，收集所有 sidecar 路径。
-- max_depth 防止在整个文件系统上爬；遇到 .sdr 目录就不再往下钻。
function M.collectSidecars(root, lfs, max_depth, out)
    out = out or {}
    max_depth = max_depth or 6
    if max_depth < 0 then return out end
    -- lfs.dir 返回 (迭代器, 目录对象)，两个都要接住，否则迭代器拿不到状态
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok or not iter then return out end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
            local full = root .. "/" .. name
            local attr = lfs.attributes(full)
            if attr and attr.mode == "directory" then
                M.collectSidecars(full, lfs, max_depth - 1, out)
            elseif attr and attr.mode == "file" and M.isSidecarFile(name) then
                out[#out + 1] = full
            end
        end
    end
    return out
end

-- 汇总：{ months = { ["2026-08"] = 2, ... }, total = n, titles = { {title=,month=} } }
-- title 从 sidecar 路径的 .sdr 目录名反推（够用，且不必解析整个 metadata）
function M.summarize(roots, lfs, loader)
    local months, titles, total = {}, {}, 0
    local seen = {}
    for _, root in ipairs(roots) do
        for _, path in ipairs(M.collectSidecars(root, lfs)) do
            if not seen[path] then
                seen[path] = true
                local status, modified = M.readSidecar(path, loader)
                if status == "complete" then
                    total = total + 1
                    local m = modified and tostring(modified):sub(1, 7) or "?"
                    months[m] = (months[m] or 0) + 1
                    local dir = path:match("([^/]+)%.sdr/[^/]+$") or path
                    titles[#titles + 1] = { title = dir, month = m }
                end
            end
        end
    end
    return { months = months, total = total, titles = titles }
end

-- 取最近 n 个月，降序，返回 { {month=, n=}, ... }
function M.recentMonths(summary, n)
    local keys = {}
    for m in pairs(summary.months) do
        if m ~= "?" then keys[#keys + 1] = m end
    end
    table.sort(keys, function(a, b) return a > b end)
    local out = {}
    for i = 1, math.min(n, #keys) do
        out[i] = { month = keys[i], n = summary.months[keys[i]] }
    end
    return out
end

return M
