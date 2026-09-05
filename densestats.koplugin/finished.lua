--[[
finished.lua — 从 sidecar 读取"已读完"的书

为什么不用数据库：KOReader 的完成状态存在书旁边的 sidecar 里
（`<书名>.sdr/metadata.<ext>.lua` 的 summary 表），statistics.sqlite3 里没有。
  ["summary"] = { ["status"] = "complete", ["modified"] = "2026-08-06", ... }
（字段来自 bookstatuswidget.lua 的注释与 readerstatus.lua:214-215）

本模块刻意不依赖任何 KOReader UI 模块，只依赖 lfs，方便用 luajit 单独跑测试。
--]]

local M = {}

-- 去掉结尾斜杠。KOReader 的 lastdir 之类的设置带不带尾斜杠不固定，
-- 不归一化的话 "/a/b" 和 "/a/b/" 会拼出两套不同的路径字符串，
-- 同一本书被数两次（实测 500 本变成 1000 本）。
function M.normDir(path)
    local p = tostring(path or ""):gsub("/+$", "")
    return p
end

-- 判断是不是 sidecar 元数据文件：metadata.<ext>.lua
function M.isSidecarFile(name)
    return name:match("^metadata%..+%.lua$") ~= nil
end

-- 解析单个 sidecar，返回 status, modified（都可能为 nil）
-- 优先用字符串扫描：sidecar 里可能存着大量标注，整个 dofile 解析一遍又慢又没必要，
-- 而且不必执行文件内容。扫不到再退回 loader。
-- 返回 status, modified, doc_path（都可能为 nil）
function M.readSidecar(path, loader)
    local f = io.open(path, "r")
    if f then
        local text = f:read("*a")
        f:close()
        if text then
            -- 只认**顶层**的 ["summary"] = {，而不是"文件里任何一处 summary 字样"。
            --
            -- sidecar 是按键名排序输出的（KOReader 的 dump.lua 走 orderedPairs），
            -- annotations 和 doc_props 都排在 summary 前面，而这两块装的是用户书摘
            -- 和出版方简介等任意文本。只按键名定位的话，书摘正文里出现一句
            -- 'see ["summary"] ... ["status"] = "complete"' 就能把作用域锚在假位置上，
            -- 随后读出的状态是错的，而且完全静默。
            --
            -- 判别依据是缩进：dump.lua 每层缩 4 格，所以顶层键必然是"行首 + 恰好
            -- 4 个空格"，而嵌套进 annotations 的正文至少缩 8 格，顶不上来。
            local at = text:find('\n    %["summary"%]%s*=%s*{')
            if at then
                local scope = text:sub(at)
                local status = scope:match('%["status"%]%s*=%s*"([^"]*)"')
                if status then
                    -- doc_path 也必须限定在顶层。它现在既是跨存放位置的去重键，
                    -- 又是 hash 模式下的书名来源——被书摘里的假值顶掉的话，
                    -- 两本不同的书会被合并成一本，计数直接少。
                    return status,
                           scope:match('%["modified"%]%s*=%s*"([^"]*)"'),
                           text:match('\n    %["doc_path"%]%s*=%s*"([^"]*)"')
                end
            end
            if not text:find("summary", 1, true) then return nil end
        end
    end
    loader = loader or dofile
    local ok, t = pcall(loader, path)
    if not ok or type(t) ~= "table" then return nil end
    local s = t.summary
    if type(s) ~= "table" then return nil end
    return s.status, s.modified, t.doc_path
end

-- 绝不进入的目录。前三个是系统伪文件系统；/mnt/base-us 是 Kindle 上 /mnt/us
-- 的另一个视图——同一份文件系统挂两次，不排除就会把每本书数两遍。
-- 这份名单抄自官方的文件搜索（filemanagerfilesearcher.lua 的 sys_folders）。
M.skip_dirs = {
    ["/dev"] = true, ["/proc"] = true, ["/sys"] = true, ["/mnt/base-us"] = true,
}

-- 名字层面的排除。官方 filechooser.lua 的 exclude_dirs 里这几个是非点开头的，
-- 只判"点开头"漏得掉：回收站里的残留 .sdr 会被算成已读完的书。
M.skip_names = {
    ["RECYCLED"] = true, ["RECYCLER"] = true, ["$RECYCLE.BIN"] = true,
    ["System Volume Information"] = true, ["KOBOeReader"] = true,
}

-- 递归扫描目录，收集所有 sidecar 路径。
-- max_depth 防止在整个文件系统上爬。注意 .sdr 目录本身要钻进去——sidecar 就在里面。
function M.collectSidecars(root, lfs, max_depth, out)
    out = out or {}
    root = M.normDir(root)
    if root == "" or M.skip_dirs[root] then return out end
    -- 默认 10 层而不是 6：集中存放模式下 sidecar 路径是
    -- "docsettings 根 + 书的绝对路径"，Android 上 /storage/emulated/0/Books/子目录/
    -- 一层就吃掉 5 层，6 层会静默漏书。
    max_depth = max_depth or 10
    if max_depth < 0 then return out end
    -- lfs.dir 返回 (迭代器, 目录对象)，两个都要接住，否则迭代器拿不到状态
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok or not iter then return out end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "."
           and not M.skip_names[name] then
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

-- 汇总：{ total = 读完本数 }。只要总数——屏幕上就一行"读完 N 本"。
-- 原来还带逐月计数和书名列表，那是已删掉的"已读完列表"的遗留，只会让缓存文件
-- 和子进程回传的负载变大。
function M.summarize(roots, lfs, loader)
    local total = 0
    -- 两张表，别合成一张：seen_path 记"这个 sidecar 文件已经读过"，
    -- seen_book 记"这本书已经计过数"。合用一张的话，没有 doc_path 时
    -- 书的键就等于文件路径，而它刚刚才被置位，于是一本都数不出来。
    local seen_path, seen_book, seen_root = {}, {}, {}
    for _, raw_root in ipairs(roots or {}) do
      local root = M.normDir(raw_root)
      if root ~= "" and not seen_root[root] then
        seen_root[root] = true
        for _, path in ipairs(M.collectSidecars(root, lfs)) do
            if not seen_path[path] then
                seen_path[path] = true
                local status, _, doc_path = M.readSidecar(path, loader)
                -- 书的去重键优先用 doc_path：同一本书可以在 doc / dir / hash
                -- 三个位置同时留下 sidecar（切换过存放位置而旧的还没被清），
                -- 只按文件路径去重会把它数两遍。
                local key = doc_path or path
                if status == "complete" and not seen_book[key] then
                    seen_book[key] = true
                    total = total + 1
                end
            end
        end
      end
    end
    return { total = total }
end

return M
