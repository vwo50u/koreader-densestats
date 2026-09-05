#!/usr/bin/env bash
# 用 KOReader.app 自带的 luajit 跑单元测试，不需要启动 KOReader
set -e
cd "$(dirname "$0")/.."
KO="${KOREADER_APP:-/Applications/KOReader.app}/Contents/koreader"
if [ -x "$KO/luajit" ]; then
    LJ="$KO/luajit"
    export LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" LUA_CPATH="$KO/?.so;$KO/libs/?.so;;"
else
    # 没有 KOReader.app（CI 上）：用 PATH 里的 luajit，lfs 来自 luarocks 的 luafilesystem
    LJ=luajit
fi
"$LJ" test/test_finished.lua
"$LJ" test/test_stats.lua
# dev.sh install 的行为测试只能在 macOS 上跑（cp -X 是 macOS 特有的）
if [ "$(uname)" = Darwin ]; then test/test_install.sh; fi
