#!/bin/bash
# 麦克风主时钟回归测试：系统静音时，--with-mic 的 PCM 输出必须持续。
#
# 用法:
#   test/mic-clock-test.sh
#
# 复现的 bug（v1.6.0 及更早）:
#   audio-tap 的唯一 stdout 写出口挂在系统音 Process Tap 的 IO 回调里，
#   麦克风数据靠该回调「搭车」输出。电脑不放声音时，输出设备 idle、tap
#   回调不触发 → 麦克风（一直在采）的数据全烂在 ring buffer → stdout 0 字节。
#   线下会议（电脑无播放、只有房间人声）因此录不到任何声音。
#
# 断言:
#   系统不播放任何音频时，跑 tap-start --with-mic --duration N，stdout 应
#   持续收到 PCM 字节（麦克风按 IO 周期产帧，即便静音也是零值样本、仍是字节）。
#   - 修复前：tap 回调不触发 → 约 0 字节 → 本测试 FAIL（复现 bug）
#   - 修复后：麦克风作主时钟驱动 stdout → 字节数 >> 0 → PASS
#
# 前提: macOS 14.4+、终端已授予「系统音频录制」权限、有可用输入设备。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/src/audio-tap.swift"
PLIST="$REPO_ROOT/src/audio-tap-Info.plist"

DUR=3                                  # 采集时长（秒）
RATE=48000                             # 本机 tap/mic 均为 48k（脚本内仅用于阈值估算）
# 阈值：0.5 秒 mono Float32 = 48000*4*0.5 = 96000 字节。远低于 3 秒理论量
# (~576KB)，留足调度抖动余量；又远高于「回调没触发」的 0 字节，判别清晰。
MIN_BYTES=96000

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/audio-tap"
OUT="$TMP/pcm.raw"
ERRLOG="$TMP/stderr.log"

echo "== 编译 audio-tap（含 Info.plist + ad-hoc 签名）=="
swiftc -O -framework CoreAudio -framework AudioToolbox \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$PLIST" \
    "$SRC" -o "$BIN"
codesign --force --sign - "$BIN"

# 支持性前置检查：非 14.4+ 或无输出设备直接跳过（不算失败）
if ! "$BIN" tap-supported >/dev/null 2>&1; then
    echo "SKIP: 本机不支持 Process Tap（需 macOS 14.4+ 且有默认输出设备）"
    exit 0
fi

echo "== 采集 ${DUR}s（期间【不要】播放任何音频，模拟线下会议电脑静音）=="
echo "   （可对着麦克风说话，但不说话也应通过——静音样本仍是字节流）"
# 关键：全程不 afplay、不放音乐/视频，让系统音保持静默。
"$BIN" tap-start --with-mic --duration "$DUR" > "$OUT" 2> "$ERRLOG" || true

BYTES=$(wc -c < "$OUT" | tr -d ' ')
echo ""
echo "== audio-tap stderr =="
cat "$ERRLOG"
echo ""
echo "== 结果：stdout PCM 字节数 = ${BYTES} (阈值 ${MIN_BYTES}) =="

if [[ "$BYTES" -ge "$MIN_BYTES" ]]; then
    echo "PASS: 系统静音时麦克风仍持续输出 PCM，链路健康。"
    exit 0
else
    echo "FAIL: 系统静音时 stdout 几乎无数据（$BYTES < $MIN_BYTES）。"
    echo "      说明 PCM 写出仍依赖系统音 tap 回调——线下会议会录成空。"
    exit 1
fi
