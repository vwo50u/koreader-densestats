#!/usr/bin/env bash
# 用 KOReader.app 自带的 luajit 跑单元测试，不需要启动 KOReader
set -e
cd "$(dirname "$0")/.."
KO="${KOREADER_APP:-/Applications/KOReader.app}/Contents/koreader"
env LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" \
         LUA_CPATH="$KO/?.so;$KO/libs/?.so;;" \
     "$KO/luajit" test/test_finished.lua
env LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" LUA_CPATH="$KO/?.so;$KO/libs/?.so;;" "$KO/luajit" test/test_stats.lua
env LUA_PATH="$KO/?.lua;$KO/frontend/?.lua;;" LUA_CPATH="$KO/?.so;$KO/libs/?.so;;" "$KO/luajit" test/test_layout.lua
