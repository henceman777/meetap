#!/bin/bash
# 输出时长回归测试（真机）：tap-start 从启动到退出写出的总帧数 ÷ 墙钟时长，
# 必须等于 --output-rate（±1%），与麦克风/输出设备的实际采样率无关。
# 测整段而不是稳态：蓝牙耳机恰恰在开麦那一刻切通话模式，这一段必须算进去。
#
# 用法:
#   test/mic-rate-test.sh                          # 编译当前源码测
#   AUDIO_TAP_BIN=/path/to/audio-tap test/mic-rate-test.sh   # 测指定二进制（如旧版）
#   连着蓝牙耳机（如 AirPods）并设为默认输入/输出时跑，才能覆盖 bug 场景：
#   开麦后耳机切到通话模式，麦克风 16k/24k，tap 48k。
#
# 复现的 bug（v1.7.1 及更早）:
#   OutputWriter 按活跃源里可用样本最少的那路取数，24k 麦克风把输出拖成每秒
#   24000 个样本，ffmpeg 却按 48000 解码 → 录音 2 倍速 + 升调。
#   - 旧版：--with-mic 且麦克风出数据时 ≈ 50%，不开麦也因设备初始化空档偏短 → FAIL
#   - 新版：输出按墙钟出帧，两种模式都 ≈ 100% → PASS
#   另断言 CLOCK_DRIFT 保险丝在正常设备上不响。
#
# 前提: macOS 14.4+、终端已授予「系统音频录制」权限。
set -euo pipefail
# 防止测试期间空闲休眠/锁屏（休眠时系统不交付音频，结果作废）
[[ -z "${MEETAP_CAFFEINATED:-}" ]] && command -v caffeinate >/dev/null \
    && exec env MEETAP_CAFFEINATED=1 caffeinate -dims "$0" "$@"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RATE=48000
DUR=20             # 每种模式录 20 秒（启动开销 ~50ms 只占 0.25%）
TOL_PCT=1          # 与验收标准一致：60 秒录音允许 ±0.6 秒

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "${AUDIO_TAP_BIN:-}" ]]; then
    BIN="$AUDIO_TAP_BIN"
    echo "== 使用指定二进制: $BIN =="
else
    BIN="$TMP/audio-tap"
    echo "== 编译 audio-tap（含 Info.plist + ad-hoc 签名）=="
    swiftc -O -framework CoreAudio -framework AudioToolbox \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
        -Xlinker "$REPO_ROOT/src/audio-tap-Info.plist" \
        "$REPO_ROOT/src/audio-tap.swift" -o "$BIN" 2>"$TMP/build.log" \
        || { cat "$TMP/build.log"; exit 1; }
    codesign --force --sign - "$BIN" 2>/dev/null
fi

if ! "$BIN" tap-supported >/dev/null 2>&1; then
    echo "SKIP: 本机不支持 Process Tap（需 macOS 14.4+ 且有默认输出设备）"
    exit 0
fi
# 旧版不认 --output-rate（它按 tap 采样率输出，本机为 48k），不传，照样按 48k 计
RATE_ARGS=(--output-rate "$RATE")
"$BIN" 2>&1 | grep -q -- "--output-rate" || RATE_ARGS=()

echo "输入: $(SwitchAudioSource -c -t input 2>/dev/null || echo '?')  输出: $(SwitchAudioSource -c -t output 2>/dev/null || echo '?')"

now() { perl -MTime::HiRes=time -e 'printf "%.4f", time'; }

# 跑一次：墙钟从启动前一刻到进程退出，总帧数 = stdout 字节 / 4。
# 期间每 4 秒抽查一次麦克风电平，任何一次 > -91 dBFS 即说明麦克风真的出了数据。
run_once() {
    rm -f "$TMP/mic-level"
    local t0 t1 i
    t0=$(now)
    "$BIN" tap-start "$@" ${RATE_ARGS[@]+"${RATE_ARGS[@]}"} --duration "$DUR" \
        --mic-level-file "$TMP/mic-level" > "$TMP/pcm.raw" 2> "$TMP/stderr.log" &
    local pid=$!
    MIC_SEEN=false
    for i in $(seq 1 $(( DUR / 4 ))); do
        sleep 4
        if [[ -f "$TMP/mic-level" ]] && awk '{ exit !($1 > -91) }' "$TMP/mic-level"; then MIC_SEEN=true; fi
    done
    wait "$pid" || true
    t1=$(now)
    local bytes; bytes=$(stat -f%z "$TMP/pcm.raw")
    WALL=$(echo "$t1 - $t0" | bc -l)
    MEASURED=$(echo "$bytes / 4 / $WALL" | bc -l | xargs printf "%.0f")
    PCT=$(echo "100 * $bytes / 4 / $WALL / $RATE" | bc -l | xargs printf "%.2f")
}

FAIL=0
for MODE in "--with-mic" ""; do
    for try in 1 2 3; do
        run_once $MODE
        [[ -z "$MODE" ]] || $MIC_SEEN && break
        echo "（第 $try 次：麦克风全程没出数据，没覆盖到麦克风路径，重试）"
        sleep 2
    done
    echo ""
    echo "== [${MODE:-无麦克风}] audio-tap stderr =="
    cat "$TMP/stderr.log"
    printf "== [%s] 墙钟 %.2fs，实测 %s Hz = 声明的 %s%%（要求 100±%s%%）==\n" \
        "${MODE:-无麦克风}" "$WALL" "$MEASURED" "$PCT" "$TOL_PCT"
    if [[ -n "$MODE" ]] && ! $MIC_SEEN; then
        echo "FAIL: 麦克风 3 次都没出数据，无法验证麦克风路径"
        FAIL=1
    elif (( $(echo "$PCT < 100 - $TOL_PCT || $PCT > 100 + $TOL_PCT" | bc -l) )); then
        echo "FAIL: 输出时长与墙钟不符 → 录音变速。"
        FAIL=1
    elif grep -q "CLOCK_DRIFT" "$TMP/stderr.log"; then
        echo "FAIL: 正常设备上 CLOCK_DRIFT 保险丝不该响"
        FAIL=1
    else
        echo "PASS"
    fi
done
exit $FAIL
