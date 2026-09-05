#!/usr/bin/env bash
# dev.sh install 的行为测试：用临时目录假装 /Volumes（DENSESTATS_VOLUMES），不碰真设备。
# 只能在 macOS 上跑（dev.sh 用的 cp -X 是 macOS 特有的）。
set -u
cd "$(dirname "$0")/.."
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() {   # ok <条件退出码> <名字> [附注]
    if [ "$1" -eq 0 ]; then pass=$((pass + 1)); echo "  ok   $2"
    else fail=$((fail + 1)); echo "  FAIL $2${3:+  -> $3}"; fi
}
KOBO="$T/vol/KOBOeReader/.adds/koreader"
KINDLE="$T/vol/Kindle/koreader"
reset() { rm -rf "$T/vol"; for d in "$@"; do mkdir -p "$d/plugins"; done; }
run() {  # run [KOREADER_DIR]  -> 退出码进 $rc，输出进 $T/out
    KOREADER_DIR="${1:-}" DENSESTATS_VOLUMES="$T/vol" ./dev.sh install >"$T/out" 2>&1
    rc=$?
}
same_as_repo() {  # 设备上的插件目录与仓库的 .lua 一一相同、不多不少
    local dest="$1" f
    for f in densestats.koplugin/*.lua; do cmp -s "$f" "$dest/${f##*/}" || return 1; done
    [ "$(ls "$dest"/*.lua 2>/dev/null | wc -l)" -eq "$(ls densestats.koplugin/*.lua | wc -l)" ]
}

echo "== 只挂了 Kobo =="
reset "$KOBO"; run
ok $rc "退出码 0" "$(cat "$T/out")"
same_as_repo "$KOBO/plugins/densestats.koplugin"; ok $? "装进 .adds/koreader/plugins，.lua 与仓库一致"
[ ! -e "$T/vol/KOBOeReader/koreader" ]; ok $? "没有在 Kobo 卷根凭空建 koreader/"

echo "== 只挂了 Kindle =="
reset "$KINDLE"; run
ok $rc "退出码 0" "$(cat "$T/out")"
same_as_repo "$KINDLE/plugins/densestats.koplugin"; ok $? "装进 koreader/plugins"

echo "== 两台都挂着 =="
reset "$KOBO" "$KINDLE"; run
[ $rc -ne 0 ]; ok $? "不猜，报错退出"
grep -q "KOBOeReader" "$T/out" && grep -q "Kindle" "$T/out"; ok $? "把两个候选都列出来" "$(cat "$T/out")"
[ ! -e "$KOBO/plugins/densestats.koplugin" ] && [ ! -e "$KINDLE/plugins/densestats.koplugin" ]
ok $? "哪台都没装"
run "$KOBO"
ok $rc "KOREADER_DIR 指定 Kobo 后退出码 0" "$(cat "$T/out")"
same_as_repo "$KOBO/plugins/densestats.koplugin"; ok $? "装到了指定的那台"
[ ! -e "$KINDLE/plugins/densestats.koplugin" ]; ok $? "另一台没动"

echo "== 什么都没挂 =="
reset; mkdir -p "$T/vol"; run
[ $rc -ne 0 ]; ok $? "报错退出"
[ -z "$(ls -A "$T/vol")" ]; ok $? "没有创建任何目录"

echo "== KOREADER_DIR 指错地方 =="
reset "$KOBO"; run "$T/nowhere"
[ $rc -ne 0 ]; ok $? "目录不存在就报错"
[ ! -e "$T/nowhere" ]; ok $? "不会 mkdir -p 出一套假目录（原来的 bug）"
run "$T/vol/KOBOeReader"     # 给的是卷根而不是 KOReader 目录
[ $rc -ne 0 ]; ok $? "给了卷根而不是 KOReader 目录也报错"
[ ! -e "$T/vol/KOBOeReader/plugins" ]; ok $? "同样不凭空建目录"

echo "== 设备上的残留 =="
reset "$KOBO"; mkdir -p "$KOBO/plugins/densestats.koplugin"
touch "$KOBO/plugins/densestats.koplugin/layout.lua" "$KOBO/plugins/densestats.koplugin/._main.lua" \
      "$KOBO/plugins/._densestats.koplugin"
run
ok $rc "退出码 0" "$(cat "$T/out")"
[ ! -e "$KOBO/plugins/densestats.koplugin/layout.lua" ]; ok $? "仓库里已删的模块也从设备上删掉"
[ ! -e "$KOBO/plugins/densestats.koplugin/._main.lua" ] && [ ! -e "$KOBO/plugins/._densestats.koplugin" ]
ok $? "AppleDouble 伪文件清掉"

echo "== 源目录里的 .DS_Store =="
had_ds=0; [ -e densestats.koplugin/.DS_Store ] && had_ds=1
[ $had_ds -eq 1 ] || touch densestats.koplugin/.DS_Store
reset "$KOBO"; run
[ $had_ds -eq 1 ] || rm -f densestats.koplugin/.DS_Store
ok $rc "Finder 留下的 .DS_Store 不该让校验报失败" "$(cat "$T/out")"
[ ! -e "$KOBO/plugins/densestats.koplugin/.DS_Store" ]; ok $? "也不会被拷到设备上"

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
