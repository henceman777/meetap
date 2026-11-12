#!/bin/bash
# 重采样自检（不需要音频设备）：audio-tap selftest-resample 用合成正弦波
# 校验 LinearResampler —— 各种蓝牙/USB 常见采样率转到 48k 后，样本数与波形都对。
#
# 用法: test/resample-selftest.sh
#
# 复现的 bug（v1.6.x 及更早）:
#   蓝牙耳机通话模式（HFP）下麦克风只有 16k/24k，tap 恒为 48k，audio-tap 按样本
#   1:1 混音、不做重采样 → 输出流每秒只有 24000 个样本却按 48k 解码 → 2 倍速 + 升调。
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

echo "== selftest-resample =="
"$BIN" selftest-resample
