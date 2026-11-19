#!/bin/bash
# 日历匹配规则自检（不读日历）：audio-multi-output selftest-calendar 用合成事件验证——
# 按重叠最长取这场会、并列取开始最近的、门槛 5 分钟（短录音按一半）、全天/取消/我已拒绝不算、
# 候选最多 5 个、--start/--end 认 epoch 和 ISO 8601。
#
# 用法: test/calendar-selftest.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/audio-multi-output"

echo "== 编译 audio-multi-output =="
swiftc -O -framework CoreAudio -framework AudioToolbox -framework IOKit -framework EventKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$REPO_ROOT/src/audio-multi-output-Info.plist" \
    "$REPO_ROOT/src/audio-multi-output.swift" -o "$BIN" 2>"$TMP/build.log" \
    || { cat "$TMP/build.log"; exit 1; }

echo "== selftest-calendar =="
"$BIN" selftest-calendar
