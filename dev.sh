#!/usr/bin/env bash
# densestats 开发脚本（macOS + KOReader.app）
# 用法：
#   ./dev.sh link     把插件软链进 KOReader.app
#   ./dev.sh db <path> 把真实 statistics.sqlite3 拷进 KOReader 数据目录
#   ./dev.sh run      启动 KOReader 并跟踪日志
#   ./dev.sh check    语法检查（用 KOReader.app 自带的 luajit）
#   ./dev.sh test     跑单元测试
#   ./dev.sh log      只看日志
#   ./dev.sh install  拷到 USB 挂载的 Kindle 或 Kobo（KINDLE=/Volumes/xxx 可强制）
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
install)
    # 用 cp -X 而不是 Finder 拖拽：macOS 往 FAT 卷上拷文件会给每个文件配一个
    # AppleDouble 伪文件（._main.lua 之类，存扩展属性）。KOReader 会忽略它们，
    # 但它们会一直躺在设备上，diff -rq 时也碍眼。-X 就是"别拷扩展属性"。
    # 顺手清掉以前拖拽留下的，包括 plugins/ 目录层那个 ._densestats.koplugin。
    # 自动认设备：Kindle 挂成 /Volumes/Kindle，Kobo 挂成 /Volumes/KOBOeReader（KOReader 在 .adds 下）
    if [ -n "${KINDLE:-}" ]; then
        PLUGINS="$KINDLE/koreader/plugins"
    elif [ -d /Volumes/Kindle/koreader/plugins ]; then
        PLUGINS=/Volumes/Kindle/koreader/plugins
    elif [ -d /Volumes/KOBOeReader/.adds/koreader/plugins ]; then
        PLUGINS=/Volumes/KOBOeReader/.adds/koreader/plugins
    else
        echo "没有挂载的 Kindle 或 Kobo（找不到 koreader/plugins 目录）"; exit 1
    fi
    DEST="$PLUGINS/densestats.koplugin"
    mkdir -p "$DEST"
    cp -X "$PROJ"/densestats.koplugin/*.lua "$DEST"/
    rm -f "$DEST"/._* "$DEST"/.DS_Store "$PLUGINS/._densestats.koplugin"
    # 仓库里删掉的模块设备上也要删，否则 diff 报"Only in"，而且残留文件会误导排查
    for f in "$DEST"/*.lua; do
        [ -e "$PROJ/densestats.koplugin/$(basename "$f")" ] || rm -f "$f"
    done
    diff -rq "$PROJ/densestats.koplugin" "$DEST" && echo "已同步到 $DEST"
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
