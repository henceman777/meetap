#!/bin/bash
# stop --sleep / 早期中断收尾 回归测试（不需要音频设备、不触达 AWS）
#
# 用法: test/sleep-stop-test.sh
#
# 注意：stop 会执行 pkill -f "audio-tap tap-start"，请勿在录音过程中运行本测试。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap" "$TMP/rec" "$TMP/fakebin"
cat > "$XDG_CONFIG_HOME/meetap/config" <<EOF
recording_dir = $TMP/rec
language = zh-CN
EOF

# 假 aws：sts 返回空 → 转录在凭证检查处返回，不上传
cat > "$TMP/fakebin/aws" <<'EOF'
#!/bin/bash
exit 0
EOF
# 假 osascript：只记录参数
cat > "$TMP/fakebin/osascript" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/osascript.log"
EOF
cat > "$TMP/fakebin/fake-sleep-watch" <<'EOF'
#!/bin/bash
while :; do sleep 1; done
EOF
chmod +x "$TMP/fakebin/"*
export PATH="$TMP/fakebin:$PATH"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# 造一场「正在录音」的假状态：假 ffmpeg / 假 sleep-watch 都是 sleep 进程
setup_recording() {
    local name="$1"
    SESSION="$TMP/rec/$name"
    mkdir -p "$SESSION/materials"
    AUDIO="$SESSION/meeting_test.m4a"
    ffmpeg -nostdin -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a aac -y "$AUDIO"
    sleep 300 & FAKE_FFMPEG=$!
    # 假 sleep-watch：命令行含 sleep-watch，才能通过 stop 的进程校验
    "$TMP/fakebin/fake-sleep-watch" & FAKE_WATCH=$!
    echo "$FAKE_FFMPEG" > "$MEETAP_STATE_DIR/ffmpeg.pid"
    echo "$FAKE_WATCH"  > "$MEETAP_STATE_DIR/sleepwatch.pid"
    echo "$SESSION" > "$MEETAP_STATE_DIR/session-dir"
    echo "$AUDIO"   > "$MEETAP_STATE_DIR/output-file"
}

alive() { kill -0 "$1" 2>/dev/null; }

echo "== 用例 1: stop --sleep 只收尾、不转录、不杀 sleep-watch =="
setup_recording "20261020_1000_sleep"
"$MEETAP" stop --sleep > "$TMP/out1.txt" 2>&1
sleep 2
alive "$FAKE_FFMPEG" && fail "ffmpeg 未被停止" || pass "ffmpeg 已停止"
alive "$FAKE_WATCH" && pass "sleep-watch 仍存活" || fail "sleep-watch 被误杀"
[[ "$(cat "$MEETAP_STATE_DIR/pending-again" 2>/dev/null)" == "20261020_1000_sleep" ]] \
    && pass "pending-again 记录了会话名" || fail "pending-again 内容不对: $(cat "$MEETAP_STATE_DIR/pending-again" 2>/dev/null)"
[[ ! -e "$SESSION/log/meetap.log" ]] && pass "未启动转录" || fail "启动了转录"
[[ -f "$AUDIO" ]] && pass "音频保留" || fail "音频丢失"
kill "$FAKE_WATCH" 2>/dev/null

echo "== 用例 2: 普通 stop 杀 sleep-watch 并启动转录 =="
rm -f "$MEETAP_STATE_DIR/pending-again"
setup_recording "20261020_1100_normal"
"$MEETAP" stop > "$TMP/out2.txt" 2>&1
sleep 3
alive "$FAKE_WATCH" && fail "sleep-watch 未被停止" || pass "sleep-watch 已停止"
[[ -s "$SESSION/log/meetap.log" ]] && pass "已启动后台转录" || fail "未启动转录"
[[ ! -e "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && pass "sleepwatch.pid 已清理" || fail "sleepwatch.pid 残留"

echo "== 用例 3: 无 ffmpeg PID、但 monitor 已起（启动阶段被打断）→ 照常收尾 =="
sleep 300 & FAKE_MON=$!
echo "$FAKE_MON" > "$MEETAP_STATE_DIR/monitor.pid"
"$MEETAP" stop > "$TMP/out3.txt" 2>&1; rc=$?
sleep 1
alive "$FAKE_MON" && fail "monitor 未被停止" || pass "monitor 已停止"
[[ $rc -eq 0 ]] && pass "exit 0" || fail "exit $rc"

echo "== 用例 4: 什么都没有 → 报无录音、exit 1（回归） =="
"$MEETAP" stop > "$TMP/out4.txt" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q "没有正在进行的录制" "$TMP/out4.txt" \
    && pass "无录音提示" || fail "rc=$rc out=$(cat "$TMP/out4.txt")"

echo "== 用例 5: _wake-notify 发通知，带会话名 =="
echo "20261020_1000_sleep" > "$MEETAP_STATE_DIR/pending-again"
rm -f "$TMP/osascript.log"
echo "$$" > "$MEETAP_STATE_DIR/sleepwatch.pid"
"$MEETAP" _wake-notify; rc=$?
[[ $rc -eq 0 ]] && grep -q "20261020_1000_sleep" "$TMP/osascript.log" 2>/dev/null \
    && pass "通知含会话名" || fail "rc=$rc osascript=$(cat "$TMP/osascript.log" 2>/dev/null)"
[[ ! -e "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && pass "唤醒后 sleepwatch.pid 已清理" || fail "sleepwatch.pid 残留"

echo "== 用例 6: 无待办时 _wake-notify 静默 =="
rm -f "$MEETAP_STATE_DIR/pending-again" "$TMP/osascript.log"
"$MEETAP" _wake-notify; rc=$?
[[ $rc -eq 0 && ! -e "$TMP/osascript.log" ]] && pass "静默" || fail "rc=$rc 或误发通知"

echo "== 用例 7: status 空闲时提示待办 =="
echo "20261020_1000_sleep" > "$MEETAP_STATE_DIR/pending-again"
"$MEETAP" status > "$TMP/out7.txt" 2>&1
grep -q "again 20261020_1000_sleep" "$TMP/out7.txt" \
    && pass "status 显示待办" || fail "status 输出: $(cat "$TMP/out7.txt")"

echo "== 用例 8: again 已有转录的待办会话 → 清除待办 =="
# 用 claude-code 后端 + 假 claude，避免调用 Bedrock
SESSION="$TMP/rec/20261020_1000_sleep"
mkdir -p "$SESSION/log"
echo "spk_0: 测试" > "$SESSION/log/transcript.txt"
cat > "$TMP/fakebin/claude" <<'EOF'
#!/bin/bash
echo "# 测试纪要"
EOF
chmod +x "$TMP/fakebin/claude"
printf 'recording_dir = %s\nlanguage = zh-CN\nai_backend = claude-code\n' "$TMP/rec" > "$XDG_CONFIG_HOME/meetap/config"
"$MEETAP" again 20261020_1000_sleep > "$TMP/out8.txt" 2>&1
[[ ! -e "$MEETAP_STATE_DIR/pending-again" ]] && pass "待办已清除" || fail "待办残留；again 输出: $(tail -5 "$TMP/out8.txt")"

echo "== 用例 9: sleepwatch.pid 指向非 sleep-watch 的活进程 → 普通 stop 不误杀、pid 文件删除 =="
setup_recording "20261020_1200_reuse"
kill "$FAKE_WATCH" 2>/dev/null
sleep 300 & INNOCENT=$!
echo "$INNOCENT" > "$MEETAP_STATE_DIR/sleepwatch.pid"
"$MEETAP" stop > "$TMP/out9.txt" 2>&1
sleep 1
alive "$INNOCENT" && pass "无关进程仍存活" || fail "无关进程被误杀"
[[ ! -e "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && pass "pid 文件已删" || fail "sleepwatch.pid 残留"
kill "$INNOCENT" 2>/dev/null

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
