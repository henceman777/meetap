#!/bin/bash
# again / mark 找会话回归测试（共用 resolve_session 之后，报错文案和选中的会话都不变）
# 不需要音频设备、不触达 AWS：用例都停在「没有音频」「没有纪要」这一步。
#
# 用法: test/resolve-session-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="${MEETAP:-$REPO_ROOT/src/meetap}"   # 可指向旧版本做对照

# 真实录音在进行时一个用例都不跑：start 里的 pkill 作用到整台机器
REAL_PID_FILE=/tmp/meeting-record/ffmpeg.pid
if [[ -f "$REAL_PID_FILE" ]] && kill -0 "$(cat "$REAL_PID_FILE")" 2>/dev/null; then
    echo "SKIP: 检测到正在录音（$REAL_PID_FILE → $(cat "$REAL_PID_FILE")），不跑测试"
    exit 2
fi

TMP="$(mktemp -d)"
trap '{ kill $(jobs -p); wait; } 2>/dev/null; rm -rf "$TMP"' EXIT

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
REC="$TMP/rec"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap" "$REC"
cat > "$XDG_CONFIG_HOME/meetap/config" <<EOF
recording_dir = $REC
language = zh-CN
EOF

# 假录音进程：万一哪个调用误进了 start，也会停在「已在录制」，碰不到 pkill
sleep 300 & FAKE_FFMPEG=$!
echo "$FAKE_FFMPEG" > "$MEETAP_STATE_DIR/ffmpeg.pid"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
run() { OUT=$(cd "$TMP" && "$MEETAP" "$@" </dev/null 2>&1); RC=$?; }

# 1. 一场会都没有
run again
[[ "$OUT" == *"下没有任何会议目录"* && $RC -ne 0 ]] && pass "again：没有会话时报错" || fail "again 没有会话 (rc=$RC): $OUT"
run mark
[[ "$OUT" == *"下没有任何会话记录"* && $RC -ne 0 ]] && pass "mark：没有会话时报错" || fail "mark 没有会话 (rc=$RC): $OUT"

# 2. 写了不存在的名字
run again 20991231_2359
[[ "$OUT" == *"找不到会议目录: 20991231_2359"* && $RC -ne 0 ]] && pass "again：找不到时报错" || fail "again 找不到 (rc=$RC): $OUT"
run mark 20991231_2359
[[ "$OUT" == *"找不到会话「20991231_2359」"* && $RC -ne 0 ]] && pass "mark：找不到时报错" || fail "mark 找不到 (rc=$RC): $OUT"

# 3. 不写名字：取第一层最新一场
mkdir -p "$REC/20260101_0900" "$REC/20260102_0900_周会"
run again
[[ "$OUT" == *"重新执行会议任务: 20260102_0900_周会"* && "$OUT" == *"没有音频文件"* ]] \
    && pass "again：默认取最新一场" || fail "again 默认目标不对: $OUT"
run mark
[[ "$OUT" == *"没有找到纪要"*"20260102_0900_周会"* ]] && pass "mark：默认取最新一场" || fail "mark 默认目标不对: $OUT"

# 4. 写名字：在 recording_dir 里找
run again 20260101_0900
[[ "$OUT" == *"重新执行会议任务: 20260101_0900"* ]] && pass "again：按名字找到" || fail "again 按名字: $OUT"

# 5. 写路径：月份文件夹里的老会议（相对 recording_dir）和任意名字的目录（绝对路径）照旧都认
mkdir -p "$REC/2026-10/20261008_1046" "$TMP/手工整理 的会议"
run again 2026-10/20261008_1046
[[ "$OUT" == *"重新执行会议任务: 20261008_1046"* ]] && pass "again：月份文件夹里的会议写相对路径能找到" || fail "again 相对路径: $OUT"
run again "$TMP/手工整理 的会议"
[[ "$OUT" == *"重新执行会议任务: 手工整理 的会议"* ]] && pass "again：非标准名字的目录写路径照旧能用" || fail "again 非标准目录: $OUT"
run mark "$TMP/手工整理 的会议"
[[ "$OUT" == *"没有找到纪要"*"手工整理 的会议"* ]] && pass "mark：非标准名字的目录写路径照旧能用" || fail "mark 非标准目录: $OUT"

kill -0 "$FAKE_FFMPEG" 2>/dev/null && pass "假录音进程未受影响" || fail "假录音进程被停了"

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
