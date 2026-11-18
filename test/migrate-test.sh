#!/bin/bash
# 2.0 系统版本门槛 + 升级迁移检查测试（不需要音频设备、不触达 AWS、不动真实的系统输出设备）
#
# 用法: test/migrate-test.sh
#
# 做法：把 meetap 拷进临时目录，旁边放假的 audio-multi-output / audio-tap（设备状态存在
# 临时文件里）；PATH 里放假的 sw_vers / pkill / osascript / open / afplay，且故意不放
# ffmpeg——start 走完迁移检查后会停在「找不到 ffmpeg」，不会真的开录。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 真实录音在进行时一个用例都不跑
REAL_PID_FILE=/tmp/meeting-record/ffmpeg.pid
if [[ -f "$REAL_PID_FILE" ]] && kill -0 "$(cat "$REAL_PID_FILE")" 2>/dev/null; then
    echo "SKIP: 检测到正在录音（$REAL_PID_FILE → $(cat "$REAL_PID_FILE")），不跑测试"
    exit 2
fi

TMP="$(mktemp -d)"
trap '{ kill $(jobs -p); wait; } 2>/dev/null; rm -rf "$TMP"' EXIT

APP="$TMP/app"; FAKE="$TMP/fakebin"; DEV="$TMP/dev"
mkdir -p "$APP/i18n" "$APP/lib" "$FAKE" "$DEV" "$TMP/home" "$TMP/rec"
cp "$REPO_ROOT/src/meetap" "$APP/meetap"
cp "$REPO_ROOT/src/i18n/"*.sh "$APP/i18n/"
cp "$REPO_ROOT/src/lib/ui.sh" "$APP/lib/"
MEETAP="$APP/meetap"

# 假 audio-multi-output：设备表 $DEV/devices（name|uid|id），默认输出 $DEV/default
cat > "$APP/audio-multi-output" <<EOF
#!/bin/bash
D="$DEV"
case "\$1" in
    default-output-name) cat "\$D/default" ;;
    default-input-name)  echo "MacBook Pro Microphone" ;;
    default-output-uid)  grep "^\$(cat "\$D/default")|" "\$D/devices" | cut -d'|' -f2 ;;
    list)                cat "\$D/devices" ;;
    find-uid)            awk -F'|' -v u="\$2" '\$2==u {print \$3; f=1} END {exit !f}' "\$D/devices" ;;
    set-default)         echo "\$2" >> "\$D/set-default.log"
                         awk -F'|' -v i="\$2" '\$3==i {print \$1}' "\$D/devices" > "\$D/default" ;;
    blackhole-uid)       grep -q BlackHole "\$D/devices" && echo BlackHole2ch_UID || exit 1 ;;
    *)                   exit 1 ;;
esac
EOF
# 假 audio-tap：支持 Tap，授权自检时交出非零数据（setup 走 Tap 路径，不碰会议 App 配置）
cat > "$APP/audio-tap" <<'EOF'
#!/bin/bash
case "$1" in
    tap-supported) echo yes ;;
    tap-start)     printf 'xxxx' ;;
    *)             exit 1 ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$APP/audio-monitor"
printf '#!/bin/bash\necho "$*" >> "%s/osascript.log"\n' "$TMP" > "$FAKE/osascript"
printf '#!/bin/bash\necho "$*" >> "%s/open.log"\n' "$TMP" > "$FAKE/open"
printf '#!/bin/bash\nexit 0\n' > "$FAKE/afplay"
printf '#!/bin/bash\necho "$*" >> "%s/pkill.log"\nexit 1\n' "$TMP" > "$FAKE/pkill"
printf '#!/bin/bash\ncat "%s/macos-version"\n' "$TMP" > "$FAKE/sw_vers"
chmod +x "$APP"/meetap "$APP"/audio-* "$FAKE"/*

export PATH="$FAKE:/usr/bin:/bin"
export HOME="$TMP/home"
export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap"
printf 'recording_dir = %s\nlanguage = zh-CN\n' "$TMP/rec" > "$XDG_CONFIG_HOME/meetap/config"

# 安全核对：PATH 里的 pkill 必须是假的，且 PATH 里没有 ffmpeg
[[ "$(command -v pkill)" == "$FAKE/pkill" ]] || { echo "ABORT: pkill 不是假的"; exit 1; }
command -v ffmpeg >/dev/null && { echo "ABORT: PATH 里有 ffmpeg"; exit 1; }

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
run() { OUT=$(cd "$TMP" && "$MEETAP" "$@" </dev/null 2>&1); RC=$?; }
set_version() { echo "$1" > "$TMP/macos-version"; }
devices() { printf '%s\n' "$@" > "$DEV/devices"; }
set_default() { echo "$1" > "$DEV/default"; rm -f "$DEV/set-default.log"; }
FFMISSING="找不到 ffmpeg"
grep -q '^MSG_ERR_FFMPEG_MISSING=' "$APP/i18n/messages-zh-CN.sh" && \
    FFMISSING="$(sed -n 's/^MSG_ERR_FFMPEG_MISSING="\(.*\)"$/\1/p' "$APP/i18n/messages-zh-CN.sh" | cut -c1-12)"

devices "MacBook Pro Speakers|BuiltInSpeakerDevice|91" "External Headphones|BuiltInHeadphoneOutputDevice|92" \
        "BlackHole 2ch|BlackHole2ch_UID|93"
set_default "MacBook Pro Speakers"

# ── 1. 系统版本门槛 ──
for v in 13.6.1 14.3.1 14.0; do
    set_version "$v"
    for cmd in start "-m" setup; do
        run $cmd
        if [[ $RC -ne 0 && "$OUT" == *"当前 macOS 是 $v"*"14.4"* && -z "$(ls "$TMP/rec")" && ! -e "$TMP/pkill.log" ]]; then
            pass "macOS ${v}：meetap $cmd 报错退出，不开录、不清扫进程"
        else
            fail "macOS ${v}：meetap $cmd (rc=$RC): $OUT"
        fi
    done
done
for v in 14.4 14.4.1 15.1 26.0; do
    set_version "$v"
    run start
    if [[ "$OUT" != *"当前 macOS 是"* && "$OUT" == *"$FFMISSING"* ]]; then
        pass "macOS ${v}：过了门槛"
    else
        fail "macOS ${v}：没过门槛 (rc=$RC): $OUT"
    fi
done
rm -f "$TMP/pkill.log"; rm -rf "$TMP/rec/"*
set_version 15.1

# ── 2. 系统输出不在 BlackHole 上：不提示、不切，清掉无用的旧状态文件 ──
echo "BuiltInSpeakerDevice" > "$MEETAP_STATE_DIR/original-output.uid"
run start
[[ "$OUT" != *"BlackHole"* && ! -e "$DEV/set-default.log" && ! -e "$MEETAP_STATE_DIR/original-output.uid" ]] \
    && pass "输出不在 BlackHole：不提示、不切，旧状态文件清掉" || fail "输出不在 BlackHole (rc=$RC): $OUT"

# ── 3. 停在 BlackHole + 旧状态文件在、原设备找得到 → 自动切回 ──
set_default "BlackHole 2ch"
echo "BuiltInHeadphoneOutputDevice" > "$MEETAP_STATE_DIR/original-output.uid"
echo "External Headphones" > "$MEETAP_STATE_DIR/original-output.name"
run start
[[ "$(cat "$DEV/set-default.log" 2>/dev/null)" == "92" && "$OUT" == *"已切回：External Headphones"* \
   && ! -e "$MEETAP_STATE_DIR/original-output.uid" ]] \
    && pass "start：旧状态文件在、原设备找得到 → 自动切回，并说明切到了哪个设备" || fail "自动切回 (rc=$RC): $OUT"

# ── 4. 停在 BlackHole、旧状态文件里的设备已经不在 → 不自动切；没终端只提示 ──
set_default "BlackHole 2ch"
echo "GoneDevice_UID" > "$MEETAP_STATE_DIR/original-output.uid"
echo "AirPods" > "$MEETAP_STATE_DIR/original-output.name"
run start
[[ ! -e "$DEV/set-default.log" && "$OUT" == *"系统输出现在是 BlackHole 2ch"* ]] \
    && pass "原设备找不到：不自动切，没终端只提示" || fail "原设备找不到 (rc=$RC): $OUT"
rm -f "$MEETAP_STATE_DIR"/original-output.*

# ── 5. 停在 BlackHole、没有旧状态文件、有终端 → 让用户选，默认「保持不变」 ──
pty() {   # 等程序开始等输入再喂答案（script 在 stdin 结束时会发 ^D）
    OUT=$({ sleep 1; printf '%s\n' "$1"; sleep 2; } | script -q /dev/null "$MEETAP" "${@:2}" 2>&1); RC=$?
}
set_default "BlackHole 2ch"
pty "" start
[[ ! -e "$DEV/set-default.log" && "$OUT" == *"要切到哪个设备"* && "$OUT" == *"1) 保持不变"* \
   && "$OUT" == *"保持 BlackHole 2ch 不变"* && "$OUT" != *"3) BlackHole"* ]] \
    && pass "有终端：列出设备（不含 BlackHole），直接回车＝保持不变" || fail "有终端直接回车 (rc=$RC): $OUT"
set_default "BlackHole 2ch"
pty "3" start
[[ "$(cat "$DEV/set-default.log" 2>/dev/null)" == "92" && "$OUT" == *"已切到：External Headphones"* ]] \
    && pass "有终端：选了设备才切，并说明切到了哪个" || fail "有终端选设备 (rc=$RC): $OUT"

# ── 6. 正在录音时 setup 不动输出设备 ──
set_default "BlackHole 2ch"
sleep 300 & FAKE_FFMPEG=$!
echo "$FAKE_FFMPEG" > "$MEETAP_STATE_DIR/ffmpeg.pid"
run setup
[[ ! -e "$DEV/set-default.log" && "$OUT" == *"正在录音，先不检查系统输出设备"* ]] \
    && pass "正在录音时 setup 不动输出设备" || fail "录音中 setup (rc=$RC): $OUT"
kill "$FAKE_FFMPEG" 2>/dev/null; wait "$FAKE_FFMPEG" 2>/dev/null; rm -f "$MEETAP_STATE_DIR/ffmpeg.pid"

# ── 7. setup：Zoom 扬声器还是 BlackHole → 提示怎么改；配置文件一字不动 ──
set_default "MacBook Pro Speakers"
ZOOM_INI="$HOME/Library/Application Support/zoom.us/data/viper.ini"
mkdir -p "$(dirname "$ZOOM_INI")"
hex() { printf '%s' "$1" | xxd -p | tr -d '\n'; }
printf '[General]\nAECSPK=%s\nAECBSSPK=%s\n' "$(hex 'BlackHole 2ch')" "$(hex 'Same as System')" > "$ZOOM_INI"
cp "$ZOOM_INI" "$TMP/viper.orig"
rm -f "$TMP/osascript.log"
run setup
[[ "$OUT" == *"Zoom 的扬声器还设成了 BlackHole 2ch"* && "$OUT" == *"Teams 或腾讯会议"* ]] \
    && cmp -s "$ZOOM_INI" "$TMP/viper.orig" && [[ ! -e "$TMP/osascript.log" ]] \
    && pass "setup：查出 Zoom 指着 BlackHole、提示 Teams/腾讯会议；不改 Zoom 配置、不退出 Zoom" \
    || fail "setup 会议 App 检查 (rc=$RC): $OUT"
# Zoom 跟随系统、系统里没有 BlackHole → 两条都不提示
printf '[General]\nAECSPK=%s\n' "$(hex 'Same as System')" > "$ZOOM_INI"
devices "MacBook Pro Speakers|BuiltInSpeakerDevice|91"
run setup
[[ "$OUT" != *"Zoom 的扬声器还设成了"* && "$OUT" != *"Teams 或腾讯会议"* ]] \
    && pass "setup：Zoom 跟随系统、没装 BlackHole 时不提示" || fail "setup 不该提示 (rc=$RC): $OUT"

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
