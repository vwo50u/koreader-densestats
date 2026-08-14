#!/usr/bin/env bash
# densestats 开发脚本（macOS + KOReader.app）
# 用法：
#   ./dev.sh link     把插件软链进 KOReader.app
#   ./dev.sh db <path> 把真实 statistics.sqlite3 拷进 KOReader 数据目录
#   ./dev.sh run      启动 KOReader 并跟踪日志
#   ./dev.sh check    语法检查（用 KOReader.app 自带的 luajit）
#   ./dev.sh test     跑单元测试
#   ./dev.sh log      只看日志
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
APP="${KOREADER_APP:-/Applications/KOReader.app}"
KO="$APP/Contents/koreader"
BIN="$APP/Contents/MacOS/koreader"

# KOReader 在 macOS 上的数据目录：优先 XDG 风格，回落到 app 内目录
datadir() {
    for d in "$HOME/Library/Application Support/KOReader" \
             "$HOME/.config/koreader" \
             "$KO"; do
        [ -d "$d" ] && { echo "$d"; return; }
    done
    echo "$KO"
}

case "${1:-run}" in
link)
    [ -d "$KO/plugins" ] || { echo "找不到 $KO/plugins，先装 KOReader.app 或设 KOREADER_APP"; exit 1; }
    ln -sfn "$PROJ/densestats.koplugin" "$KO/plugins/densestats.koplugin"
    ls -l "$KO/plugins/densestats.koplugin"
    ;;
db)
    SRC="${2:?用法: ./dev.sh db /path/to/statistics.sqlite3}"
    D="$(datadir)"
    mkdir -p "$D/settings"
    cp "$SRC" "$D/settings/statistics.sqlite3"
    echo "已拷到 $D/settings/statistics.sqlite3"
    ;;
check)
    # 用 KOReader.app 自带的 luajit，不需要另外装
    LJ="$KO/luajit"
    [ -x "$LJ" ] || { echo "找不到 $LJ"; exit 1; }
    for f in "$PROJ"/densestats.koplugin/*.lua; do
        "$LJ" -e "local fn,e=loadfile('$f'); if fn then print('OK   '..'$f') else print('FAIL '..tostring(e)); os.exit(1) end"
    done
    ;;
test)
    exec "$PROJ/test/run.sh"
    ;;
log)
    D="$(datadir)"
    tail -f "$D/crash.log" 2>/dev/null || tail -f "$KO/crash.log"
    ;;
run)
    "$0" link || true
    echo "启动 KOReader…（要看屏保长什么样，用 DENSESTATS_AUTOSHOW=1 启动）"
    "$BIN" 2>&1 | tee /tmp/densestats-run.log
    ;;
*)
    sed -n '2,10p' "$0"
    ;;
esac
