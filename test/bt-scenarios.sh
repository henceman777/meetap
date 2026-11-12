#!/bin/bash
# 蓝牙耳机真机验收：5 个设备场景各按墙钟录 60 秒，输出 m4a 时长必须在 59.4~60.6 秒，
# 系统在放 1kHz 测试音的场景再测录音里的音高与幅度（变速会让它偏离 1000Hz，切设备后
# 录丢系统声音会让幅度塌掉）。
# 管线与 meetap start 完全一致：audio-tap tap-start → FIFO → ffmpeg AAC。
#
# 用法（AirPods 连着、设为默认输入和输出时跑；约 7 分钟；期间会低音量播放测试音，
# 并临时切换默认输入/输出设备，结束时恢复）:
#   test/bt-scenarios.sh                 # 编译当前源码，跑 a b c d e e2
#   SCENARIOS="a e" test/bt-scenarios.sh # 只跑部分场景
#   BROKEN=1 test/bt-scenarios.sh        # 另跑「故意关掉麦克风重采样」的坏版本，看 CLOCK_DRIFT 几秒响
#   AUDIO_TAP_BIN=/path/to/audio-tap test/bt-scenarios.sh   # 测指定二进制
#
# 场景:
#   a  AirPods 开麦，系统在放声音        b  AirPods 开麦，系统静音
#   c  输入内置麦克风，AirPods 只当耳机  d  --mute-mic（不开麦）
#   e  AirPods 开麦，第 20 秒把输入切到内置麦克风
#   e2 同 e，但第 20 秒输入输出一起切走（模拟断开 AirPods）
# 录音留在 $OUT_DIR，可自己听。
set -uo pipefail
# 防止测试期间空闲休眠/锁屏（休眠时系统不交付音频，结果作废）
[[ -z "${MEETAP_CAFFEINATED:-}" ]] && command -v caffeinate >/dev/null \
    && exec env MEETAP_CAFFEINATED=1 caffeinate -dims "$0" "$@"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RATE=48000
SECS=60
SCENARIOS="${SCENARIOS:-a b c d e e2}"
BT="${BT_DEVICE:-$(SwitchAudioSource -c -t output)}"
BUILTIN_IN="MacBook Pro Microphone"
BUILTIN_OUT="MacBook Pro Speakers"
OUT_DIR="${OUT_DIR:-/tmp/meetap-bt-scenarios}"
TMP="$(mktemp -d)"
ORIG_IN="$(SwitchAudioSource -c -t input)"; ORIG_OUT="$(SwitchAudioSource -c -t output)"
TONE_PID=""
stop_tone() { [[ -n "$TONE_PID" ]] && kill "$TONE_PID" 2>/dev/null; wait "$TONE_PID" 2>/dev/null; TONE_PID=""; }
restore() {
    stop_tone
    SwitchAudioSource -t input -s "$ORIG_IN" >/dev/null 2>&1
    SwitchAudioSource -t output -s "$ORIG_OUT" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap restore EXIT
mkdir -p "$OUT_DIR"

build() {  # $1=源码 $2=输出
    swiftc -O -framework CoreAudio -framework AudioToolbox \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
        -Xlinker "$REPO_ROOT/src/audio-tap-Info.plist" "$1" -o "$2" 2>"$TMP/build.log" \
        || { cat "$TMP/build.log"; exit 1; }
    codesign --force --sign - "$2" 2>/dev/null
}
if [[ -n "${AUDIO_TAP_BIN:-}" ]]; then BIN="$AUDIO_TAP_BIN"; else BIN="$TMP/audio-tap"; build "$REPO_ROOT/src/audio-tap.swift" "$BIN"; fi
RATE_ARGS=(--output-rate "$RATE")
"$BIN" 2>&1 | grep -q -- "--output-rate" || RATE_ARGS=()

ffmpeg -v error -f lavfi -i "sine=frequency=1000:duration=$(( SECS + 15 ))" -ar 48000 -ac 2 "$TMP/tone.wav"
cat > "$TMP/pitch.py" <<'PY'
# 逐秒在 1000Hz 做 DFT，用相邻两秒的相位推进算真实频率（精度 ~0.01Hz，不受环境噪声影响）。
# 判定：[from,to] 秒内平均频率 1000±0.5Hz、逐秒都在 ±0.1Hz 内（无变速、无相位乱跳），
# 且测试音幅度不低于开头 2~8 秒的一半（切设备后系统声音没被录丢）。
import sys, struct, math, cmath
rate = 48000
lo, hi = int(sys.argv[1]), int(sys.argv[2])
raw = sys.stdin.buffer.read()
x = struct.unpack('<%df' % (len(raw) // 4), raw)
w = 2 * math.pi * 1000 / rate
rot = [cmath.exp(-1j * w * i) for i in range(rate)]
def dft(t):
    a = t * rate
    return sum(v * r for v, r in zip(x[a:a + rate], rot)) * cmath.exp(-1j * w * a)
ref = sum(2 * abs(dft(t)) / rate for t in range(2, 8)) / 6
if ref <= 0:
    print("BAD 无测试音(全程静音)"); sys.exit(0)
zs = [dft(t) for t in range(lo, hi)]
amp = min(2 * abs(z) / rate for z in zs)
fs = [1000 + ((cmath.phase(zs[i + 1]) - cmath.phase(zs[i]) + math.pi) % (2 * math.pi) - math.pi) / (2 * math.pi)
      for i in range(len(zs) - 1)]
mean = sum(fs) / len(fs); worst = max(abs(f - 1000) for f in fs)
ok = abs(mean - 1000) <= 0.5 and worst <= 0.1 and amp >= 0.5 * ref
print("%s %.3fHz(逐秒最大偏差%.3f,幅度%.0f%%)" % ("OK" if ok else "BAD", mean, worst, 100 * amp / ref))
PY

now() { perl -MTime::HiRes=time -e 'printf "%.4f", time'; }
T0=$(now)
setdev() { SwitchAudioSource -t "$1" -s "$2" >/dev/null && echo "    [$(printf %.1f "$(echo "$(now) - $T0" | bc -l)")s] $1 -> $2"; }

# 录一段：$1=名字 $2=是否开麦(1/0) $3=是否放测试音(1/0) $4=第 20 秒的动作（none/in/inout）
record() {
    local name=$1 mic=$2 tone=$3 action=$4
    local m4a="$OUT_DIR/scenario-$name.m4a" fifo="$TMP/tap.fifo" log="$OUT_DIR/scenario-$name.tap.log"
    rm -f "$m4a" "$fifo"; mkfifo "$fifo"
    local mic_args=(); [[ $mic == 1 ]] && mic_args=(--with-mic)
    if [[ $tone == 1 ]]; then afplay -v 0.03 "$TMP/tone.wav" & TONE_PID=$!; fi
    sleep 1
    T0=$(now)
    "$BIN" tap-start ${RATE_ARGS[@]+"${RATE_ARGS[@]}"} ${mic_args[@]+"${mic_args[@]}"} \
        < /dev/null > "$fifo" 2> "$log" &
    local tap=$!
    ffmpeg -y -f f32le -ar "$RATE" -ac 1 -i "$fifo" -c:a aac -b:a 128k -ac 1 \
        -movflags frag_keyframe+empty_moov "$m4a" < /dev/null > "$TMP/ffmpeg.log" 2>&1 &
    local ff=$!
    if [[ $action != none ]]; then
        while (( $(echo "$(now) - $T0 < 20" | bc -l) )); do sleep 0.1; done
        setdev input "$BUILTIN_IN"
        [[ $action == inout ]] && setdev output "$BUILTIN_OUT"
    fi
    while (( $(echo "$(now) - $T0 < $SECS" | bc -l) )); do sleep 0.05; done
    # 与 meetap stop 相同的收尾顺序：先 SIGINT ffmpeg 让它封口，再停 tap
    kill -INT $ff; wait $ff 2>/dev/null
    local wall; wall=$(echo "$(now) - $T0" | bc -l)
    kill $tap 2>/dev/null; wait $tap 2>/dev/null
    stop_tone
    local dur; dur=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$m4a")
    local pitch="n/a"
    if [[ $tone == 1 ]]; then
        pitch=$(ffmpeg -v error -i "$m4a" -f f32le -ac 1 -ar 48000 - | python3 -I "$TMP/pitch.py" 25 58)
    fi
    local drift=无; grep -q CLOCK_DRIFT "$log" && drift=有
    local verdict=PASS
    (( $(echo "$dur < $SECS - 0.6 || $dur > $SECS + 0.6" | bc -l) )) && verdict=FAIL
    # 墙钟远超预期 = 测试期间系统休眠/挂起，这一条作废（不是录音的问题）
    (( $(echo "$wall > $SECS + 2" | bc -l) )) && verdict="无效(系统休眠)"
    [[ $pitch == BAD* ]] && verdict=FAIL
    [[ $drift == 有 ]] && verdict=FAIL
    printf "%-3s 墙钟 %.2fs  文件时长 %.3fs  音高 %s  CLOCK_DRIFT %s  → %s\n" \
        "$name" "$wall" "$dur" "$pitch" "$drift" "$verdict" | tee -a "$TMP/summary"
    grep -E "^MIC=|MIC_DEVICE|MIC_STALLED|MIC_RESUMED|MIC_NO_DATA|TAP_REBUILD|SYNC_SUMMARY|CLOCK_DRIFT|RESAMPLE" "$log" | sed 's/^/      /'
    [[ $verdict == PASS ]] || FAILED=1
    setdev input "$ORIG_IN" >/dev/null; setdev output "$ORIG_OUT" >/dev/null
    sleep 3
}

FAILED=0
echo "蓝牙设备: $BT   二进制: $BIN   录音目录: $OUT_DIR"
for s in $SCENARIOS; do
    case $s in
        a)  echo "== a: AirPods 开麦，系统在放声音";   setdev input "$BT"; record a 1 1 none ;;
        b)  echo "== b: AirPods 开麦，系统静音";       setdev input "$BT"; record b 1 0 none ;;
        c)  echo "== c: 输入内置麦克风，AirPods 只当耳机"; setdev input "$BUILTIN_IN"; record c 1 1 none ;;
        d)  echo "== d: --mute-mic";                   setdev input "$BT"; record d 0 1 none ;;
        e)  echo "== e: 第 20 秒输入切到内置麦克风";   setdev input "$BT"; record e 1 1 in ;;
        e2) echo "== e2: 第 20 秒输入输出一起切走（模拟断开 AirPods）"; setdev input "$BT"; record e2 1 1 inout ;;
    esac
done

if [[ "${BROKEN:-0}" == 1 ]]; then
    echo "== 坏版本（故意关掉麦克风重采样）：CLOCK_DRIFT 应在 20 秒内响"
    # 只改麦克风那一处（MicCapture 在 TapCapture 之前），tap 保持正常
    python3 -I - "$REPO_ROOT/src/audio-tap.swift" "$TMP/broken.swift" <<'PY'
import sys
s = open(sys.argv[1]).read()
old = 'let rs = LinearResampler(inRate: sampleRate, outRate: source.outRate)'
assert s.count(old) == 2
open(sys.argv[2], 'w').write(s.replace(old, 'let rs = LinearResampler(inRate: source.outRate, outRate: source.outRate)', 1))
PY
    build "$TMP/broken.swift" "$TMP/audio-tap-broken"
    SwitchAudioSource -t input -s "$BT" >/dev/null
    for try in 1 2 3; do
        "$TMP/audio-tap-broken" tap-start --output-rate "$RATE" --with-mic --duration 25 > /dev/null 2> "$OUT_DIR/broken.tap.log"
        grep -q MIC_FIRST_DATA "$OUT_DIR/broken.tap.log" && ! grep -q "MIC_STALLED" "$OUT_DIR/broken.tap.log" && break
        echo "  （第 $try 次麦克风没全程出数据，重试）"; sleep 3
    done
    grep -E "MIC_FIRST|CLOCK_DRIFT|SYNC_SUMMARY mic" "$OUT_DIR/broken.tap.log" | sed 's/^/      /'
    at=$(sed -n 's/.*CLOCK_DRIFT mic.*(at \([0-9.]*\)s).*/\1/p' "$OUT_DIR/broken.tap.log" | head -1)
    if [[ -n "$at" ]] && (( $(echo "$at <= 20" | bc -l) )); then
        echo "坏版本 CLOCK_DRIFT 在 ${at}s 响 → PASS" | tee -a "$TMP/summary"
    else
        echo "坏版本 20 秒内未出现 CLOCK_DRIFT → FAIL" | tee -a "$TMP/summary"; FAILED=1
    fi
fi

echo ""; echo "======== 汇总 ========"; cat "$TMP/summary"
exit $FAILED
