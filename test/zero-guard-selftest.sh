#!/bin/bash
# 零段记账 / 静音报警判断逻辑自检（不需要音频设备）：audio-tap selftest-zero-guard 用合成的
# 逐秒序列驱动判断逻辑——没声音在放时只记账不报警；有声音在放、tap 全零时零段开始后第 20 秒
# 报警、只报一次；短于 3 秒的零不算；恢复后再坏再报；停止时还在交零要补记结束行。
#
# 用法: test/zero-guard-selftest.sh
#
# 真实的 tap 加故障注入（MEETAP_TAP_FAULT_ZERO_AFTER）要真机，见任务说明的验收步骤。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/audio-tap"

echo "== 编译 audio-tap =="
swiftc -O -framework CoreAudio -framework AudioToolbox \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$REPO_ROOT/src/audio-tap-Info.plist" \
    "$REPO_ROOT/src/audio-tap.swift" -o "$BIN" 2>"$TMP/build.log" \
    || { cat "$TMP/build.log"; exit 1; }

echo "== selftest-zero-guard =="
"$BIN" selftest-zero-guard
