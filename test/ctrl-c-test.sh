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

# pty 驱动：启动 meetap start -m，按 trigger 发 ^C，打印退出所用秒数。
#   trigger = 秒数        → 固定延时后发 ^C
#   trigger = file:<路径> → 等该文件出现（最多 10s，否则输出 NOFILE）后立刻发 ^C
#   trigger = none        → 不发 ^C，只等 start 自行退出（由别的进程结束录音）
# 发 ^C 前 start 已退出 → 输出 EARLY_EXIT；40s 内未退出 → TIMEOUT。
# 第 3 个参数为 pty 输出落盘路径（可选）。
# 必须持续读 master fd，否则 bash 退出时卡在 tty 输出（实测 STAT=E）。
run_pty_ctrl_c() {
    local trigger="$1" name="$2" out="${3:-/dev/null}"
    python3 - "$PREFIX/meetap" "$trigger" "$name" "$out" <<'PYEOF'
import os, pty, sys, threading, time
meetap, trigger, name, out = sys.argv[1:5]
pid, fd = pty.fork()
if pid == 0:
    os.execv(meetap, [meetap, "start", "-m", name])
log = open(out, "wb")
def drain():
    try:
        while True:
            b = os.read(fd, 4096)
            if not b: break
            log.write(b); log.flush()
    except OSError: pass
threading.Thread(target=drain, daemon=True).start()
def exited():
    return os.waitpid(pid, os.WNOHANG)[0] != 0
def send_ctrl_c():
    try: os.write(fd, b"\x03"); return True
    except OSError: return False
result = None
if trigger.startswith("file:"):
    path, t0 = trigger[5:], time.time()
    while not os.path.exists(path) and time.time() - t0 < 10:
        if exited(): result = "EARLY_EXIT"; break
        time.sleep(0.02)
    if result is None and not os.path.exists(path):
        result = "NOFILE"
        send_ctrl_c()          # 仍发 ^C 收尾，避免留下录音
elif trigger != "none":
    t0 = time.time()
    while time.time() - t0 < float(trigger):
        if exited(): result = "EARLY_EXIT"; break
        time.sleep(0.05)
if result is None and trigger != "none":
    if exited() or not send_ctrl_c():
        result = "EARLY_EXIT"
t0 = time.time()
done = result == "EARLY_EXIT"
while not done and time.time() - t0 < 40:
    if exited(): done = True; break
    time.sleep(0.2)
if result is None:
    result = f"{time.time() - t0:.1f}" if done else "TIMEOUT"
time.sleep(0.3)   # 让 drain 读完尾部输出
print(result)
PYEOF
}

# 驱动结果是否为正常退出秒数（EARLY_EXIT / NOFILE / TIMEOUT / 空 均视为失败）
exited_ok() { [[ "$1" =~ ^[0-9]+\.[0-9]$ ]]; }

no_leftovers() {
    ! pgrep -f "$PREFIX/audio-tap tap-start" >/dev/null && ! pgrep -f "ffmpeg.*$TMP/rec" >/dev/null
}

echo "== 用例 1: 录音中 Ctrl-C → 有序 stop =="
r=$(run_pty_ctrl_c 6 ctrlc)
exited_ok "$r" && pass "start 已退出（${r}s）" || fail "Ctrl-C 后 start 未正常退出: ${r:-空}"
sleep 2
no_leftovers && pass "无残留 tap/ffmpeg" || fail "残留进程: $(pgrep -fl "$PREFIX/|$TMP/rec")"
M4A=$(find "$TMP/rec" -name '*.m4a' -path '*ctrlc*' | head -1)
DUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$M4A" 2>/dev/null)
[[ -n "$DUR" ]] && pass "m4a 可读（${DUR}s）" || fail "m4a 不可读: $M4A"
[[ -s "$(dirname "$M4A")/log/meetap.log" ]] && pass "已启动转录" || fail "未启动转录"
[[ ! -e "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && ! pgrep -f "$PREFIX/audio-multi-output sleep-watch" >/dev/null \
    && pass "sleep-watch 已结束" || fail "sleep-watch 残留"

echo "== 用例 2: 启动阶段 Ctrl-C → 无残留 =="
# tap.pid 出现时 tap 已拉起、健康探测进行中，此刻发 ^C
r=$(run_pty_ctrl_c "file:$MEETAP_STATE_DIR/tap.pid" early)
exited_ok "$r" && pass "start 已退出（${r}s）" || fail "start 未正常退出: ${r:-空}"
sleep 2
no_leftovers && pass "无残留 tap/ffmpeg" || fail "残留进程: $(pgrep -fl "$PREFIX/|$TMP/rec")"
left=""
for f in ffmpeg.pid tap.pid monitor.pid sleepwatch.pid; do
    [[ -e "$MEETAP_STATE_DIR/$f" ]] && left+=" $f"
done
[[ -z "$left" ]] && pass "无残留 pid 文件" || fail "残留 pid 文件:$left"

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

echo "== 用例 4: 前台录音中被 stop --sleep 结束 → 💤 提示且 start 自行退出 =="
run_pty_ctrl_c none sleepy "$TMP/sleepy.out" > "$TMP/sleepy.r" &
drv=$!
for _ in $(seq 1 100); do [[ -f "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && break; sleep 0.1; done
sleep 5
"$PREFIX/meetap" stop --sleep < /dev/null > "$TMP/sleepy-stop.txt" 2>&1
wait "$drv"
r=$(cat "$TMP/sleepy.r")
exited_ok "$r" && pass "start 自行退出（${r}s）" || fail "start 未自行退出: ${r:-空}"
SESS=$(cat "$MEETAP_STATE_DIR/pending-again" 2>/dev/null)
[[ "$SESS" == *sleepy ]] && pass "待办会话: $SESS" || fail "未写待办: ${SESS:-空}"
grep -q "again $SESS" "$TMP/sleepy.out" 2>/dev/null && grep -q "💤" "$TMP/sleepy.out" \
    && pass "pty 输出含 💤 again $SESS" || fail "pty 输出缺休眠提示: $(tail -c 300 "$TMP/sleepy.out" | LC_ALL=C tr -d '\033')"
sleep 1
no_leftovers && pass "无残留 tap/ffmpeg" || fail "残留进程: $(pgrep -fl "$PREFIX/|$TMP/rec")"

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
