#!/bin/bash
# 「只敲 meetap 就开始录音」命令分发测试（不需要音频设备、不触达 AWS、不会真的开录）
#
# 用法: test/bare-start-test.sh
#
# 原理：先造一个「正在录音」的假状态（ffmpeg.pid 指向一个 sleep 进程）。
# 凡是走进 start 的调用，都会在「已在录制」检查处报错退出，不会真的开录；
# 据此判断某个命令是否被分发到了 start。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap" "$TMP/rec"
cat > "$XDG_CONFIG_HOME/meetap/config" <<EOF
recording_dir = $TMP/rec
language = zh-CN
EOF

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

sleep 300 & FAKE_FFMPEG=$!
echo "$FAKE_FFMPEG" > "$MEETAP_STATE_DIR/ffmpeg.pid"

ALREADY="已有录制进程在运行"
USAGE="用法: meetap"

# run <参数...>：结果存进 OUT / RC
run() { OUT=$("$MEETAP" "$@" </dev/null 2>&1); RC=$?; }

# 1. 不带参数 ≡ start
run
if [[ "$OUT" == *"$ALREADY"* && $RC -ne 0 ]]; then
    pass "meetap（不带参数）走 start"
else
    fail "meetap（不带参数）没走 start (rc=$RC): $OUT"
fi

# 2. start 原有行为不变
run start
if [[ "$OUT" == *"$ALREADY"* && $RC -ne 0 ]]; then
    pass "meetap start 行为不变"
else
    fail "meetap start 行为变了 (rc=$RC): $OUT"
fi

# 3. help / -h / --help 打印用法，不开录
for h in help -h --help; do
    run "$h"
    if [[ "$OUT" == *"$USAGE"* && "$OUT" != *"$ALREADY"* && $RC -eq 0 ]]; then
        pass "meetap $h 打印用法"
    else
        fail "meetap $h 不对 (rc=$RC): $OUT"
    fi
done

# 4. 拼错的子命令：报错 + 用法，非 0 退出，不开录
run stauts
if [[ "$OUT" == *"stauts"* && "$OUT" == *"$USAGE"* && "$OUT" != *"$ALREADY"* && $RC -ne 0 ]]; then
    pass "拼错的子命令报错且不开录"
else
    fail "拼错的子命令处理不对 (rc=$RC): $OUT"
fi

# 5. 以上调用都没有动到正在进行的录音
kill -0 "$FAKE_FFMPEG" 2>/dev/null && pass "正在进行的录音未受影响" || fail "正在进行的录音被停了"

# 6. 用法里说明了「不带参数 = start」
run help
[[ "$OUT" == *"不带参数"* ]] && pass "用法说明了不带参数即开始录制" || fail "用法没说明不带参数的行为: $OUT"

# 7. 中英文消息表都有新增的消息
for k in MSG_ERR_UNKNOWN_COMMAND MSG_USAGE_BARE MSG_USAGE_HELP; do
    for lang in zh-CN en-US; do
        grep -q "^$k=" "$REPO_ROOT/src/i18n/messages-$lang.sh" \
            && pass "$lang 有 $k" || fail "$lang 缺 $k"
    done
done

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
