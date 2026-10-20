#!/bin/bash
# Ctrl-C ≡ stop 回归测试（真实录音，pty 驱动）
#
# 用法: test/ctrl-c-test.sh
# 前提: macOS 14.4+、已 make all、终端已授予「系统音频录制」权限。
#       测试期间请勿播放音频；不录麦克风（-m），不触达 AWS（假 aws）。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PREFIX="$TMP/bin"
cleanup() {
    pkill -f "$PREFIX/" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "== 组装临时安装目录 =="
[[ -x "$REPO_ROOT/build/audio-tap" ]] || { echo "请先 make all"; exit 1; }
mkdir -p "$PREFIX/i18n" "$PREFIX/lib"
cp "$REPO_ROOT/src/meetap" "$PREFIX/"
cp "$REPO_ROOT/src/i18n/"*.sh "$PREFIX/i18n/"
cp "$REPO_ROOT/src/lib/ui.sh" "$PREFIX/lib/"
cp "$REPO_ROOT/build/audio-tap" "$REPO_ROOT/build/audio-multi-output" "$REPO_ROOT/build/audio-monitor" "$PREFIX/"
codesign --force --sign - "$PREFIX/audio-tap"   # cp 会破坏 ad-hoc 签名

if ! "$PREFIX/audio-tap" tap-supported >/dev/null 2>&1; then
    echo "SKIP: 本机不支持 Process Tap"; exit 0
fi

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap" "$TMP/rec" "$TMP/fakebin"
printf 'recording_dir = %s\nlanguage = zh-CN\naudio_capture = tap\n' "$TMP/rec" > "$XDG_CONFIG_HOME/meetap/config"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fakebin/aws"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fakebin/osascript"
chmod +x "$TMP/fakebin/"*
export PATH="$TMP/fakebin:$PATH"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# pty 驱动：启动 meetap start -m，delay 秒后写入 ^C，返回退出所用秒数（超时 40 输出 TIMEOUT）。
# 必须持续读 master fd，否则 bash 退出时卡在 tty 输出（实测 STAT=E）。
run_pty_ctrl_c() {
    local delay="$1" name="$2"
    python3 - "$PREFIX/meetap" "$delay" "$name" <<'PYEOF'
import os, pty, sys, threading, time
meetap, delay, name = sys.argv[1], float(sys.argv[2]), sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(meetap, [meetap, "start", "-m", name])
def drain():
    try:
        while os.read(fd, 4096): pass
    except OSError: pass
threading.Thread(target=drain, daemon=True).start()
time.sleep(delay)
os.write(fd, b"\x03")
t0 = time.time()
while time.time() - t0 < 40:
    if os.waitpid(pid, os.WNOHANG)[0]:
        print(f"{time.time() - t0:.1f}"); sys.exit(0)
    time.sleep(0.2)
print("TIMEOUT")
PYEOF
}

no_leftovers() {
    ! pgrep -f "$PREFIX/audio-tap tap-start" >/dev/null && ! pgrep -f "ffmpeg.*$TMP/rec" >/dev/null
}

echo "== 用例 1: 录音中 Ctrl-C → 有序 stop =="
r=$(run_pty_ctrl_c 6 ctrlc)
[[ "$r" != "TIMEOUT" ]] && pass "start 已退出（${r}s）" || fail "Ctrl-C 后 start 未退出"
sleep 2
no_leftovers && pass "无残留 tap/ffmpeg" || fail "残留进程: $(pgrep -fl "$PREFIX/|$TMP/rec")"
M4A=$(find "$TMP/rec" -name '*.m4a' -path '*ctrlc*' | head -1)
DUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$M4A" 2>/dev/null)
[[ -n "$DUR" ]] && pass "m4a 可读（${DUR}s）" || fail "m4a 不可读: $M4A"
[[ -s "$(dirname "$M4A")/log/meetap.log" ]] && pass "已启动转录" || fail "未启动转录"
[[ ! -e "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && ! pgrep -f "$PREFIX/audio-multi-output sleep-watch" >/dev/null \
    && pass "sleep-watch 已结束" || fail "sleep-watch 残留"

echo "== 用例 2: 启动阶段 Ctrl-C → 无残留 =="
r=$(run_pty_ctrl_c 0.8 early)
[[ "$r" != "TIMEOUT" ]] && pass "start 已退出（${r}s）" || fail "start 未退出"
sleep 2
no_leftovers && pass "无残留 tap/ffmpeg" || fail "残留进程: $(pgrep -fl "$PREFIX/|$TMP/rec")"

echo "== 用例 3: 无 TTY → 立即返回（回归），stop 正常 =="
t0=$(date +%s)
"$PREFIX/meetap" start -m notty < /dev/null > "$TMP/notty.txt" 2>&1
el=$(( $(date +%s) - t0 ))
(( el < 20 )) && pass "无 TTY 立即返回（${el}s）" || fail "无 TTY 阻塞 ${el}s"
[[ -f "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && kill -0 "$(cat "$MEETAP_STATE_DIR/sleepwatch.pid")" 2>/dev/null \
    && pass "sleep-watch 已启动" || fail "sleep-watch 未启动"
sleep 2
"$PREFIX/meetap" stop < /dev/null > "$TMP/notty-stop.txt" 2>&1
sleep 2
no_leftovers && pass "stop 后无残留" || fail "stop 后残留"

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
