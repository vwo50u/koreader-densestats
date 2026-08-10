#!/usr/bin/env bash
# densestats 开发脚本（macOS + KOReader.app）
# 用法：
#   ./dev.sh link     把插件软链进 KOReader.app
#   ./dev.sh db <path> 把真实 statistics.sqlite3 拷进 KOReader 数据目录
#   ./dev.sh run      启动 KOReader 并跟踪日志
#   ./dev.sh check    luajit 语法检查（需 brew install luajit）
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
    command -v luajit >/dev/null || { echo "没装 luajit：brew install luajit"; exit 1; }
    for f in "$PROJ"/densestats.koplugin/*.lua; do
        luajit -bl "$f" >/dev/null && echo "OK   $f"
    done
    ;;
log)
    D="$(datadir)"
    tail -f "$D/crash.log" 2>/dev/null || tail -f "$KO/crash.log"
    ;;
run)
    "$0" link || true
    echo "启动 KOReader… 打开后走：主菜单 → 更多工具 → 预览：密集统计屏"
    "$BIN" 2>&1 | tee /tmp/densestats-run.log
    ;;
*)
    sed -n '2,10p' "$0"
    ;;
esac
