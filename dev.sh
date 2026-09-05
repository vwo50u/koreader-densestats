#!/usr/bin/env bash
# densestats 开发脚本（macOS + KOReader.app）
# 用法：
#   ./dev.sh link     把插件软链进 KOReader.app
#   ./dev.sh db <path> 把真实 statistics.sqlite3 拷进 KOReader 数据目录
#   ./dev.sh run      启动 KOReader 并跟踪日志
#   ./dev.sh check    语法检查（用 KOReader.app 自带的 luajit）
#   ./dev.sh test     跑单元测试
#   ./dev.sh log      只看日志
#   ./dev.sh install  拷到 USB 挂载的 Kindle 或 Kobo（KOREADER_DIR=<KOReader 目录> 可指定）
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
    # 装到 KOReader 目录下的 plugins/。两种布局：Kindle 的 KOReader 在卷根 koreader/，
    # Kobo 在卷根隐藏的 .adds/koreader/。不指定就在 /Volumes 下按这两种布局找；
    # 找到不止一台（Kindle 和 Kobo 同时插着）时报错而不是猜——猜错了会静默装到另一台。
    # KOREADER_DIR=<KOReader 目录> 指定一台，例如 /Volumes/KOBOeReader/.adds/koreader。
    # 无论哪条路，目标下都必须已有 plugins/：以前的版本对指定路径不检查，mkdir -p
    # 会在任何可写位置凭空造出一套 koreader/plugins 然后报"已同步"。
    # DENSESTATS_VOLUMES 只给 test/test_install.sh 用，指向一个假的 /Volumes。
    VOL="${DENSESTATS_VOLUMES:-/Volumes}"
    KO_DIR="${KOREADER_DIR:-}"
    if [ -z "$KO_DIR" ]; then
        list=""; n=0
        for d in "$VOL"/*/koreader "$VOL"/*/.adds/koreader; do
            [ -d "$d/plugins" ] || continue
            KO_DIR="$d"; list="$list  $d"$'\n'; n=$((n + 1))
        done
        if [ "$n" -eq 0 ]; then
            echo "没有挂载的 Kindle 或 Kobo（$VOL 下找不到 */koreader/plugins 或 */.adds/koreader/plugins）"; exit 1
        elif [ "$n" -gt 1 ]; then
            echo "挂着不止一台，用 KOREADER_DIR=<KOReader 目录> 指定一台："; printf '%s' "$list"; exit 1
        fi
    fi
    PLUGINS="$KO_DIR/plugins"
    # 变量后面紧跟全角标点要写成 ${VAR}：macOS 自带的 bash 3.2 会把多字节字符
    # 吞进变量名，报 "unbound variable"。
    [ -d "$PLUGINS" ] || { echo "找不到 ${PLUGINS}。KOREADER_DIR 要指向 KOReader 目录本身（Kindle 是 <卷>/koreader，Kobo 是 <卷>/.adds/koreader）"; exit 1; }
    DEST="$PLUGINS/densestats.koplugin"
    mkdir -p "$DEST"
    # 用 cp -X 而不是 Finder 拖拽：macOS 往 FAT 卷上拷文件会给每个文件配一个
    # AppleDouble 伪文件（._main.lua 之类，存扩展属性）。KOReader 会忽略它们，
    # 但它们会一直躺在设备上碍眼。-X 就是"别拷扩展属性"。
    # 顺手清掉以前拖拽留下的，包括 plugins/ 目录层那个 ._densestats.koplugin。
    cp -X "$PROJ"/densestats.koplugin/*.lua "$DEST"/
    rm -f "$DEST"/._* "$DEST"/.DS_Store "$PLUGINS/._densestats.koplugin"
    # 仓库里删掉的模块设备上也要删，残留文件会误导排查
    for f in "$DEST"/*.lua; do
        [ -e "$PROJ/densestats.koplugin/${f##*/}" ] || rm -f "$f"
    done
    # 逐个 .lua 比对。原来是整目录 diff -rq，Finder 在源目录留个 .DS_Store 就会让
    # 一次成功的安装报失败——它根本不在拷贝范围内。
    for f in "$PROJ"/densestats.koplugin/*.lua; do
        cmp -s "$f" "$DEST/${f##*/}" || { echo "校验失败：$DEST/${f##*/} 与仓库不一致"; exit 1; }
    done
    echo "已同步到 ${DEST}；重启设备上的 KOReader 生效"
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
