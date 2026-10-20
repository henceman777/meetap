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
    sleep 300 & FAKE_WATCH=$!
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

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
