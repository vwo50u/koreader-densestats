package.path = "./densestats.koplugin/?.lua;" .. package.path
local L = require("layout")

local pass, fail = 0, 0
local function ok(c, n, extra)
    if c then pass = pass + 1; print("  ok   " .. n)
    else fail = fail + 1; print("  FAIL " .. n .. (extra and ("  -> " .. tostring(extra)) or "")) end
end
local function sum(t)
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s
end

print("== distributeSlack: 没有余白 ==")
local r1 = L.distributeSlack({ 10, 20 }, 0, 1.6)
ok(sum(r1.gains) == 0 and r1.top == 0 and r1.bottom == 0, "rest=0 什么都不加")
local r2 = L.distributeSlack({ 10, 20 }, -50, 1.6)
ok(sum(r2.gains) == 0 and r2.top == 0 and r2.bottom == 0, "rest 为负不分配")

print("== distributeSlack: 余白小于总上限，按基准值比例分 ==")
-- bases {100,300} base_total 400, limit {60,180}
-- want {floor(40*100/400)=10, floor(40*300/400)=30} 都没触顶
local r3 = L.distributeSlack({ 100, 300 }, 40, 1.6)
ok(r3.gains[1] == 10 and r3.gains[2] == 30, "大间隙拿得多",
   tostring(r3.gains[1]) .. "/" .. tostring(r3.gains[2]))
ok(r3.top == 0 and r3.bottom == 0, "刚好分完则不加边距",
   tostring(r3.top) .. "/" .. tostring(r3.bottom))

print("== distributeSlack: 余白超过总上限，各自封顶 ==")
-- bases {100,100} limit {60,60}, want {100,100} -> add {60,60}, spare 200-120=80
local r4 = L.distributeSlack({ 100, 100 }, 200, 1.6)
ok(r4.gains[1] == 60 and r4.gains[2] == 60, "间隙各自封顶 0.6 倍基准",
   tostring(r4.gains[1]) .. "/" .. tostring(r4.gains[2]))
ok(r4.top == 40 and r4.bottom == 40, "剩下的 80 上下平分",
   tostring(r4.top) .. "/" .. tostring(r4.bottom))

print("== distributeSlack: 奇数余白，多的给底部 ==")
local r5 = L.distributeSlack({ 100, 100 }, 201, 1.6)
ok(r5.top == 40 and r5.bottom == 41, "多出的 1px 给底部",
   tostring(r5.top) .. "/" .. tostring(r5.bottom))

print("== distributeSlack: 部分触顶 ==")
-- bases {10,100} base_total 110, limit {6,60}
-- want {floor(200*10/110)=18, floor(200*100/110)=181} -> add {6,60}, spare 200-66=134
local r6 = L.distributeSlack({ 10, 100 }, 200, 1.6)
ok(r6.gains[1] == 6 and r6.gains[2] == 60, "小间隙先触顶，大间隙也触顶",
   tostring(r6.gains[1]) .. "/" .. tostring(r6.gains[2]))
ok(r6.top == 67 and r6.bottom == 67, "剩 134 上下平分",
   tostring(r6.top) .. "/" .. tostring(r6.bottom))

print("== distributeSlack: 退化情形 ==")
local r7 = L.distributeSlack({}, 100, 1.6)
ok(#r7.gains == 0 and r7.top == 50 and r7.bottom == 50, "没有间隙时全进边距")
local r8 = L.distributeSlack({ 100, 100 }, 100, 1)
ok(sum(r8.gains) == 0 and r8.top == 50 and r8.bottom == 50, "ratio=1 间隙不增长")
local r9 = L.distributeSlack(nil, 100, 1.6)
ok(#r9.gains == 0 and r9.top == 50 and r9.bottom == 50, "bases 为 nil 不炸")
local r10 = L.distributeSlack({ 0, 0 }, 100, 1.6)
ok(sum(r10.gains) == 0 and r10.top == 50 and r10.bottom == 50, "基准全 0 不除零")

print("== fitScale ==")
local tried = {}
local function mkprobe(accept)
    tried = {}
    return function(k)
        tried[#tried + 1] = k
        return accept(k), "payload@" .. tostring(k)
    end
end

local p1, s1, n1 = L.fitScale({ 1.3, 1.2, 1.1 }, mkprobe(function() return true end))
ok(p1 == "payload@1.3" and s1 == 1.3 and n1 == 1, "第一档就通过，只试一次",
   tostring(p1) .. " tries=" .. tostring(n1))
ok(#tried == 1, "没有多余的重排", #tried)

local p2, s2, n2 = L.fitScale({ 1.3, 1.2, 1.1 }, mkprobe(function(k) return k <= 1.2 end))
ok(p2 == "payload@1.2" and s2 == 1.2 and n2 == 2, "降一档后通过",
   tostring(p2) .. " tries=" .. tostring(n2))

local p3, s3, n3 = L.fitScale({ 1.3, 1.2, 1.1 }, mkprobe(function() return false end))
ok(p3 == "payload@1.1" and s3 == 1.1 and n3 == 3, "全都不通过时用最后一档兜底",
   tostring(p3) .. " tries=" .. tostring(n3))
ok(#tried == 3, "兜底也不会试超过档位数", #tried)

local p4, s4, n4 = L.fitScale({}, mkprobe(function() return true end))
ok(p4 == nil and s4 == nil and n4 == 0, "空档位表返回 nil，不崩")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
