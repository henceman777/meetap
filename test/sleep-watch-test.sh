#!/bin/bash
# sleep-watch 回归测试：模拟休眠调用顺序 + PID 文件消失即退出
# 用法: test/sleep-watch-test.sh   （真实休眠/唤醒见计划 Task 6 手动验证）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
BIN="$TMP/audio-multi-output"

echo "== 编译 audio-multi-output =="
swiftc -O -framework CoreAudio -framework AudioToolbox -framework IOKit \
    "$REPO_ROOT/src/audio-multi-output.swift" -o "$BIN" || exit 1

cat > "$TMP/fake-meetap" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/calls.log"
EOF
chmod +x "$TMP/fake-meetap"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

echo "== 用例 1: 模拟休眠 → 先 stop --sleep 再 _wake-notify =="
"$BIN" sleep-watch "$TMP/fake-meetap" "$TMP/none.pid" --simulate-sleep; rc=$?
expected=$'stop --sleep\n_wake-notify'
[[ $rc -eq 0 && "$(cat "$TMP/calls.log" 2>/dev/null)" == "$expected" ]] \
    && pass "调用顺序正确" || fail "rc=$rc calls=$(cat "$TMP/calls.log" 2>/dev/null)"

echo "== 用例 2: PID 文件存在时常驻，删除后 2s 内退出 =="
rm -f "$TMP/calls.log"
touch "$TMP/ffmpeg.pid"
"$BIN" sleep-watch "$TMP/fake-meetap" "$TMP/ffmpeg.pid" & W=$!
sleep 3
kill -0 $W 2>/dev/null && pass "常驻" || fail "提前退出"
rm -f "$TMP/ffmpeg.pid"
sleep 3
kill -0 $W 2>/dev/null && fail "PID 文件删除后未退出" || pass "已退出"
[[ ! -e "$TMP/calls.log" ]] && pass "未调用 meetap" || fail "误调用: $(cat "$TMP/calls.log")"

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
