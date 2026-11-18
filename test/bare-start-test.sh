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

# 4b. 第一个参数是开录选项（白名单）≡ meetap start …
for args in "-m -d 60" "-d 60 周会" "-t" "--test" "-b" "--background" "-m" "--mute-mic" \
            "--mute-microphone" "--duration 60"; do
    # shellcheck disable=SC2086
    run $args
    if [[ "$OUT" == *"$ALREADY"* && $RC -ne 0 ]]; then
        pass "meetap $args 走 start"
    else
        fail "meetap $args 没走 start (rc=$RC): $OUT"
    fi
done

# 4c. 贴标签、列标签、撤标签、显示信息：一律不进 start，退出码 0
S="$(date +%Y%m%d_%H%M)"   # 刚开始的一场，不触发 12 小时护栏
mkdir -p "$TMP/rec/$S/materials"
for args in "-g 周会" "--tag 周会" "$S -g 周会" "-g 周会 -g 客户A" "-g" "$S -g" \
            "$S --untag 周会" "--untag 客户A" "$S"; do
    # shellcheck disable=SC2086
    run $args
    if [[ "$OUT" != *"$ALREADY"* && $RC -eq 0 ]]; then
        pass "meetap $args 不进 start"
    else
        fail "meetap $args 不对 (rc=$RC): $OUT"
    fi
done
rm -f "$TMP/rec/$S/meta.json"

# 4d. 报错、不开录、不写文件：开录选项和 -g 混用、不认识的命令、真实存在但不是会话的目录
for args in "-m -g 周会" "-g 周会 -m" "-d 60 --untag 周会" "周会" "stpo" "." "src" "20991231_2359"; do
    # shellcheck disable=SC2086
    OUT=$(cd "$REPO_ROOT" && "$MEETAP" $args </dev/null 2>&1); RC=$?
    if [[ "$OUT" != *"$ALREADY"* && $RC -ne 0 && ! -e "$TMP/rec/$S/meta.json" ]]; then
        pass "meetap $args 报错且不开录"
    else
        fail "meetap $args 不对 (rc=$RC): $OUT"
    fi
done

# 4e. meetap start 周会：照旧走 start，名字不会变成标签
run start 周会
if [[ "$OUT" == *"$ALREADY"* && $RC -ne 0 && -z "$(find "$TMP/rec" -name meta.json)" ]]; then
    pass "meetap start 周会 走 start，不生成标签"
else
    fail "meetap start 周会 不对 (rc=$RC): $OUT"
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
