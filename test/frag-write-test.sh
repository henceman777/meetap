#!/bin/bash
# 录音边录边落盘的测试：用 meetap 录音时一模一样的 ffmpeg 封装参数（FFMPEG_MUX_ARGS），
# 喂 ffmpeg 现做的测试音（不录真音频、不碰音频设备），看：
#   录到 30 秒时文件已经在长；中途强杀以后 ffprobe 读出的时长和实际只差一片（10 秒）以内；
#   正常停止（和 meetap stop 一样发 SIGINT）的成品时长差不到 1 秒；meetap <文件夹> 显示的时长对。
#
# 用法: test/frag-write-test.sh   （实时录音，约 40 秒）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 真实录音在进行时一个用例都不跑
REAL_PID_FILE=/tmp/meeting-record/ffmpeg.pid
if [[ -f "$REAL_PID_FILE" ]] && kill -0 "$(cat "$REAL_PID_FILE")" 2>/dev/null; then
    echo "SKIP: 检测到正在录音（$REAL_PID_FILE → $(cat "$REAL_PID_FILE")），不跑测试"
    exit 2
fi
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "SKIP: 没装 ffmpeg"; exit 2; }

TMP="$(mktemp -d)"
trap '{ kill $(jobs -p); wait; } 2>/dev/null; rm -rf "$TMP"' EXIT

eval "$(grep '^FFMPEG_MUX_ARGS=' "$REPO_ROOT/src/meetap")"
[[ ${#FFMPEG_MUX_ARGS[@]} -gt 0 ]] || { echo "ABORT: src/meetap 里找不到 FFMPEG_MUX_ARGS"; exit 1; }

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
size() { stat -f %z "$1" 2>/dev/null || echo 0; }
dur() { ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null; }
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a != "" && d <= t) }'; }   # |a-b| ≤ t

# rec <名字>：实时喂 70 秒测试音，录音参数和 meetap 一样（f32le 从 FIFO 读、AAC、FFMPEG_MUX_ARGS）
rec() {
    mkfifo "$TMP/$1.fifo"
    ffmpeg -nostdin -v quiet -re -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 70 -f f32le -ac 1 - > "$TMP/$1.fifo" 2>/dev/null &
    ffmpeg -y -f f32le -ar 48000 -ac 1 -i "$TMP/$1.fifo" -c:a aac -b:a 128k -ac 1 "${FFMPEG_MUX_ARGS[@]}" \
        "$TMP/$1.m4a" </dev/null >"$TMP/$1.log" 2>&1 &
    eval "PID_$1=\$!"
    eval "T0_$1=$(now)"
}

# 两路同时录：kill 那路到 32 秒强杀，stop 那路到 20 秒正常停止
rec kill
rec stop
sleep 12
s12=$(size "$TMP/kill.m4a")
sleep 8
kill -INT "$PID_stop"; t_stop=$(now)
for _ in $(seq 1 50); do kill -0 "$PID_stop" 2>/dev/null || break; sleep 0.2; done
kill -0 "$PID_stop" 2>/dev/null && fail "SIGINT 后 10 秒 ffmpeg 还没退出"
s20=$(size "$TMP/kill.m4a")
sleep 10
s30=$(size "$TMP/kill.m4a")
sleep 2
{ kill -9 "$PID_kill"; t_kill=$(now); wait "$PID_kill"; } 2>/dev/null
sleep 0.5

(( s12 > 100000 && s20 > s12 && s30 > s20 )) && pass "录音过程中文件一直在长（12 秒 ${s12}、20 秒 ${s20}、30 秒 ${s30} 字节）" \
    || fail "文件没在长：12 秒 ${s12}、20 秒 ${s20}、30 秒 ${s30} 字节"

actual_kill=$(echo "$t_kill - $T0_kill" | bc)
dk=$(dur "$TMP/kill.m4a")
near "$dk" "$actual_kill" 10 && awk -v a="$dk" -v b="$actual_kill" 'BEGIN { exit !(a <= b + 1) }' \
    && pass "强杀以后：ffprobe 读出 ${dk} 秒，实际录了约 ${actual_kill} 秒，差在一片（10 秒）以内" \
    || fail "强杀以后：ffprobe 读出「${dk}」秒，实际约 ${actual_kill} 秒"

actual_stop=$(echo "$t_stop - $T0_stop" | bc)
ds=$(dur "$TMP/stop.m4a")
near "$ds" "$actual_stop" 1 && pass "正常停止：ffprobe 读出 ${ds} 秒，实际录了约 ${actual_stop} 秒，差不到 1 秒" \
    || fail "正常停止：ffprobe 读出「${ds}」秒，实际约 ${actual_stop} 秒"
pk=$(ffprobe -v quiet -select_streams a -show_entries packet=duration_time -of csv=p=0 "$TMP/stop.m4a" | awk '{ s += $1 } END { printf "%.3f", s }')
near "$pk" "$ds" 0.1 && pass "正常停止：逐包累计时长（${pk}）和 ffprobe 的时长一致，转录读到的就是整段" || fail "逐包累计 ${pk} ≠ ${ds}"
ffmpeg -v error -i "$TMP/stop.m4a" -f null - </dev/null 2>"$TMP/decode.err"
[[ ! -s "$TMP/decode.err" ]] && pass "正常停止：整段解码没有报错" || fail "解码报错: $(head -3 "$TMP/decode.err")"

# meetap <文件夹> 显示的时长：同样的封装参数做一段 95 秒的（不用实时），应该显示 2 分钟
REC="$TMP/rec"; S="$REC/20261119_0900"; mkdir -p "$S" "$TMP/state" "$TMP/xdg/meetap"
ffmpeg -nostdin -v quiet -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 95 -f f32le -ac 1 - \
    | ffmpeg -nostdin -v quiet -y -f f32le -ar 48000 -ac 1 -i - -c:a aac -b:a 128k -ac 1 "${FFMPEG_MUX_ARGS[@]}" "$S/meeting_20261119_090005.m4a"
printf 'recording_dir = %s\nlanguage = zh-CN\ncalendar = off\n' "$REC" > "$TMP/xdg/meetap/config"
OUT=$(cd "$TMP" && MEETAP_STATE_DIR="$TMP/state" XDG_CONFIG_HOME="$TMP/xdg" "$REPO_ROOT/src/meetap" 20261119_0900 </dev/null 2>&1)
near "$(dur "$S/meeting_20261119_090005.m4a")" 95 1 && [[ "$OUT" == *"时长：2 分钟"* ]] \
    && pass "meetap <文件夹>：分片写入的 95 秒录音显示「2 分钟」" || fail "meetap <文件夹>: $OUT"
[[ $(python3 -I -c 'import sys; print(open(sys.argv[1], "rb").read().count(b"moof"))' "$S/meeting_20261119_090005.m4a") -ge 9 ]] \
    && pass "95 秒录音切成了 10 片左右（每片约 10 秒）" || fail "分片数不对"

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
