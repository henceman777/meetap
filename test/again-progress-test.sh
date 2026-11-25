#!/bin/bash
# meetap again 从音频重跑时，过程要显示在终端、照常记进日志，成败要说清楚（不需要音频设备、不触达 AWS）。
#
# 复现的 bug（v2.0.1 及更早）:
#   没有转录文本时 again 调 transcribe_recording，它把整个 stdout 改到 log/meetap.log。
#   转录加生成纪要要十来分钟，终端一直空白；纪要失败（比如 Bedrock 报错）也看不到，
#   退出码还是 0。用户只看到「没反应」，以为第一次只转录、要再跑一次 again 才生成纪要。
#
# 断言:
#   1. 从音频重跑、纪要失败：终端看得到转录完成和纪要失败，有重跑提示，退出码非 0，日志里也有、不重复
#   2. 只重跑纪要、纪要失败：同样有重跑提示、退出码非 0；会话不在 recording_dir 下时提示写完整路径
#   2b. 路径有空格时加引号；recording_dir 以 / 结尾时会话名照样对；录音整段静音时不提示重跑
#   2c/2d. 转录或生成纪要时凭证一直不行、_retry 放弃：重跑提示只出现一次；路径有撇号时通知照样能弹
#   2e. 日历那一步放弃不算：后面纪要因为别的错失败，照样提示重跑
#   3. 从音频重跑、纪要成功（假 claude 后端）：一次 again 就生成纪要，退出码 0，没有重跑提示
#
# 用法: test/again-progress-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REAL_PID_FILE=/tmp/meeting-record/ffmpeg.pid
if [[ -f "$REAL_PID_FILE" ]] && kill -0 "$(cat "$REAL_PID_FILE")" 2>/dev/null; then
    echo "SKIP: 检测到正在录音（$REAL_PID_FILE → $(cat "$REAL_PID_FILE")），不跑测试"
    exit 2
fi
command -v ffmpeg >/dev/null || { echo "SKIP: 没装 ffmpeg"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APP="$TMP/app"; FAKEBIN="$TMP/fakebin"; REC="$TMP/rec"
mkdir -p "$APP/i18n" "$APP/lib" "$FAKEBIN" "$REC"
cp "$REPO_ROOT/src/meetap" "$APP/meetap"
cp "$REPO_ROOT/src/i18n/"*.sh "$APP/i18n/"
cp "$REPO_ROOT/src/lib/ui.sh" "$APP/lib/"
mkdir -p "$APP/share" && cp -R "$REPO_ROOT/share/meetap" "$APP/share/"   # 提示词模板
chmod +x "$APP/meetap"
MEETAP="$APP/meetap"

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap"
CONF="$XDG_CONFIG_HOME/meetap/config"
printf 'recording_dir = %s\nlanguage = zh-CN\ncalendar = off\nai_backend = claude-code\n' "$REC" > "$CONF"

cat > "$TMP/raw.json" <<'EOF'
{"results": {
  "items": [
    {"type": "pronunciation", "start_time": "0.5", "end_time": "0.9", "alternatives": [{"content": "大家好"}]},
    {"type": "pronunciation", "start_time": "2.0", "end_time": "2.6", "alternatives": [{"content": "开始吧"}]}
  ],
  "speaker_labels": {"segments": [
    {"speaker_label": "spk_0", "start_time": "0.5", "end_time": "1.5", "items": [{"start_time": "0.5", "speaker_label": "spk_0"}]},
    {"speaker_label": "spk_1", "start_time": "2.0", "end_time": "5.0", "items": [{"start_time": "2.0", "speaker_label": "spk_1"}]}
  ]}
}}
EOF

cat > "$FAKEBIN/aws" <<EOF
#!/bin/bash
case "\$1 \$2" in
    "sts get-caller-identity")
        if [[ -f "$TMP/sts-fail" ]]; then echo "An error occurred (ExpiredToken) when calling the GetCallerIdentity operation" >&2; exit 255; fi
        echo 123456789012 ;;
    "transcribe get-transcription-job") echo COMPLETED ;;
    "s3 cp") if [[ "\$3" == s3://* ]]; then cp "$TMP/raw.json" "\$4"; fi ;;
esac
exit 0
EOF
# 假 claude 后端：有 $TMP/claude-fail 时什么都不吐（退回 Bedrock，没有 venv，纪要生成失败），否则吐一份纪要
cat > "$FAKEBIN/claude" <<EOF
#!/bin/bash
[[ -f "$TMP/claude-fail" ]] && exit 0
printf '# 测试纪要\n\n内容\n'
EOF
for c in open afplay; do printf '#!/bin/bash\nexit 0\n' > "$FAKEBIN/$c"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify.log"\nexit 0\n' "$TMP" > "$FAKEBIN/osascript"   # 通知内容记下来
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"
[[ "$(command -v aws)" == "$FAKEBIN/aws" ]] || { echo "ABORT: aws 不是假的"; exit 1; }

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
new_session() {
    local d="$REC/$1"
    mkdir -p "$d/materials"
    ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=3" -c:a aac "$d/meeting_$2.m4a" </dev/null
    printf '%s' "$d"
}

# ── 1. 从音频重跑，纪要失败（claude 什么都没吐，退回 Bedrock 也没有 venv，走到 NOTES_FAILED）──
touch "$TMP/claude-fail"
S1=$(new_session 20261125_0900 20261125_090005)
OUT=$(cd "$TMP" && "$MEETAP" again "$S1" </dev/null 2>&1); RC=$?
[[ "$OUT" == *"Transcript saved"* && "$OUT" == *"✅"* ]] && pass "终端看得到转录过程和转录完成" || fail "终端输出: $OUT"
[[ "$OUT" == *"Meeting notes generation failed"* ]] && pass "终端看得到纪要失败" || fail "终端没有纪要失败: $OUT"
[[ "$OUT" == *"meetap again 20261125_0900"* ]] && pass "失败时提示怎么重跑" || fail "没有重跑提示: $OUT"
(( RC != 0 )) && pass "纪要失败时退出码非 0（${RC}）" || fail "退出码是 0"
[[ $(grep -c 'Transcript saved' "$S1/log/meetap.log") -eq 1 ]] && grep -q 'Meeting notes generation failed' "$S1/log/meetap.log" \
   && grep -q 'meetap again 20261125_0900' "$S1/log/meetap.log" \
    && pass "日志照常记下全过程和重跑提示，没有重复" || fail "日志: $(cat "$S1/log/meetap.log")"

# ── 2. 已有转录，只重跑纪要，纪要失败 ──
OUT=$(cd "$TMP" && "$MEETAP" again "$S1" </dev/null 2>&1); RC=$?
[[ "$OUT" == *"meetap again 20261125_0900"* ]] && (( RC != 0 )) \
    && pass "只重跑纪要失败时也有重跑提示、退出码非 0" || fail "RC=$RC 输出: $OUT"

# ── 2b. 会话不在 recording_dir 下：重跑提示写完整路径（只写文件夹名会找不到）──
OTHER="$TMP/other/20261125_1100"; mkdir -p "$OTHER/materials"
ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=3" -c:a aac "$OTHER/meeting_20261125_110005.m4a" </dev/null
OUT=$(cd "$TMP" && "$MEETAP" again "$OTHER" </dev/null 2>&1); RC=$?
[[ "$OUT" == *"meetap again $OTHER"* ]] && (( RC != 0 )) && pass "recording_dir 外的会话：提示里是完整路径、退出码非 0" || fail "RC=$RC 提示: $OUT"
SP="$TMP/other dir/20261125_1300"; mkdir -p "$SP/materials"
ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=3" -c:a aac "$SP/meeting_20261125_130005.m4a" </dev/null
OUT=$(cd "$TMP" && "$MEETAP" again "$SP" </dev/null 2>&1)
[[ "$OUT" == *"meetap again '$SP'"* ]] && pass "路径有空格：提示里加了引号，能直接复制" || fail "提示: $OUT"

# ── 2b2. recording_dir 写成以 / 结尾：提示里还是 20261125_0900，不是 /20261125_0900 ──
cp "$CONF" "$CONF.bak"
sed -i '' "s|^recording_dir = .*|recording_dir = $REC/|" "$CONF"
OUT=$(cd "$TMP" && "$MEETAP" again 20261125_0900 </dev/null 2>&1)
mv "$CONF.bak" "$CONF"
[[ "$OUT" == *"再跑一次：meetap again 20261125_0900"* && "$OUT" != *"meetap again /20261125_0900"* ]] \
    && pass "recording_dir 以 / 结尾：提示里的会话名对" || fail "提示: $OUT"

# ── 2b3. 录音整段静音：说明原因，不提示重跑（重跑也一样），退出码非 0 ──
SL="$REC/20261125_1400"; mkdir -p "$SL/materials"
ffmpeg -v quiet -f lavfi -i "anullsrc=r=48000:cl=mono" -t 3 -c:a aac "$SL/meeting_20261125_140005.m4a" </dev/null
OUT=$(cd "$TMP" && "$MEETAP" again "$SL" </dev/null 2>&1); RC=$?
[[ "$OUT" != *"meetap again 20261125_1400"* ]] && (( RC != 0 )) && [[ ! -s "$SL/log/transcript.txt" ]] \
    && pass "静音录音：不提示重跑、退出码非 0" || fail "RC=$RC 输出: $OUT"

# ── 2c. 凭证一直不行、_retry 等到上限放弃：它已经提示过怎么重跑，again 不再重复 ──
S2c=$(new_session 20261125_1200 20261125_120005)
touch "$TMP/sts-fail"
OUT=$(cd "$TMP" && MEETAP_RETRY_LIMIT_SEC=2 "$MEETAP" again "$S2c" </dev/null 2>&1); RC=$?
rm -f "$TMP/sts-fail"
n=$(grep -o 'meetap again 20261125_1200' <<<"$OUT" | wc -l | tr -d ' ')
(( RC != 0 )) && [[ "$n" == 1 && "$OUT" == *"先放弃"* ]] && pass "_retry 放弃时重跑提示只出现一次、退出码非 0" || fail "RC=$RC 提示 $n 次: $OUT"
SP2="$TMP/other dir/20261125_1500"; mkdir -p "$SP2/materials"
ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=3" -c:a aac "$SP2/meeting_20261125_150005.m4a" </dev/null
touch "$TMP/sts-fail"
OUT=$(cd "$TMP" && MEETAP_RETRY_LIMIT_SEC=2 "$MEETAP" again "$SP2" </dev/null 2>&1)
rm -f "$TMP/sts-fail"
[[ "$OUT" == *"先放弃"*"meetap again '$SP2'"* ]] && pass "_retry 放弃时的提示里，有空格的路径也加了引号" || fail "提示: $OUT"
# 路径里有撇号：终端里照样加引号，通知原样写（AppleScript 不认 '\'' 这种转义，会弹不出来）
AP="$TMP/Bob's notes/20261125_1600"; mkdir -p "$AP/materials"
ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=3" -c:a aac "$AP/meeting_20261125_160005.m4a" </dev/null
touch "$TMP/sts-fail"; rm -f "$TMP/notify.log"
OUT=$(cd "$TMP" && MEETAP_RETRY_LIMIT_SEC=2 "$MEETAP" again "$AP" </dev/null 2>&1)
rm -f "$TMP/sts-fail"
grep -q "meetap again $AP" "$TMP/notify.log" 2>/dev/null && ! grep -qF "'\''" "$TMP/notify.log" && [[ "$OUT" == *"meetap again '"* ]] \
    && pass "路径有撇号：通知里原样写，终端里加引号" || fail "通知: $(cat "$TMP/notify.log" 2>/dev/null) / 终端: $OUT"

# ── 2d. 只重跑纪要时 Bedrock 凭证一直不行、_retry 放弃：重跑提示也只出现一次 ──
# 假的 venv python：生成纪要的脚本（import boto3）报凭证过期，别的脚本交给真的 python3
mkdir -p "$APP/meetap-venv/bin"
cat > "$APP/meetap-venv/bin/python3" <<VENVPY
#!/bin/bash
if [[ "\$1" == - ]]; then
    script=\$(cat)
    if [[ "\$script" == *"import sys, time, re, boto3"* ]]; then
        echo "An error occurred (ExpiredToken) when calling the ConverseStream operation" >&2; exit 1
    fi
    shift; exec "$(command -v python3)" - "\$@" <<<"\$script"
fi
exec "$(command -v python3)" "\$@"
VENVPY
chmod +x "$APP/meetap-venv/bin/python3"
OUT=$(cd "$TMP" && MEETAP_RETRY_LIMIT_SEC=2 "$MEETAP" again "$S1" </dev/null 2>&1); RC=$?
rm -rf "$APP/meetap-venv"
n=$(grep -o 'meetap again 20261125_0900' <<<"$OUT" | wc -l | tr -d ' ')
(( RC != 0 )) && [[ "$n" == 1 && "$OUT" == *"先放弃"* ]] && pass "只重跑纪要、_retry 放弃：重跑提示只出现一次、退出码非 0" || fail "RC=$RC 提示 $n 次: $OUT"

# ── 2e. 日历那一步凭证不行、放弃了（按时间兜底，不耽误纪要），后面生成纪要又因为别的错失败：照样提示重跑 ──
CS="$REC/20261125_1700"; mkdir -p "$CS/materials" "$CS/log" "$CS/.meetap"
echo "spk_0: 今天评审一下新的架构方案。" > "$CS/log/transcript.txt"
python3 -I - "$CS/.meetap/calendar-candidates.json" <<'CANDS'
import json, sys
c = {"title": "架构周会", "start": "2026-11-25T17:00:00+08:00", "end": "2026-11-25T18:00:00+08:00", "time_score": 0.85,
     "overlap_sec": 3000, "organizer": "组织者甲", "attendees": [], "attendee_count": 0, "notes_excerpt": "议程：架构"}
json.dump({"candidates": [c], "recording": [1795942805, 1795945800]}, open(sys.argv[1], "w"), ensure_ascii=False)
CANDS
mkdir -p "$APP/meetap-venv/bin"
cat > "$APP/meetap-venv/bin/python3" <<VENVPY
#!/bin/bash
if [[ "\$1" == - ]]; then
    script=\$(cat)
    case "\$script" in
        *"import sys, time, re, boto3"*) echo "ValidationException: something the model rejected" >&2; exit 1 ;;
        *"import sys, boto3"*)           echo "ExpiredTokenException: The security token included in the request is expired" >&2; exit 1 ;;
    esac
    shift; exec "$(command -v python3)" - "\$@" <<<"\$script"
fi
exec "$(command -v python3)" "\$@"
VENVPY
chmod +x "$APP/meetap-venv/bin/python3"
sed -i '' 's/^calendar = off$/calendar = on/' "$CONF"
touch "$TMP/claude-fail"
OUT=$(cd "$TMP" && MEETAP_RETRY_LIMIT_SEC=2 "$MEETAP" again "$CS" </dev/null 2>&1); RC=$?
rm -f "$TMP/claude-fail"; rm -rf "$APP/meetap-venv"
sed -i '' 's/^calendar = on$/calendar = off/' "$CONF"
[[ "$OUT" == *"先放弃"* && "$OUT" == *"再跑一次：meetap again 20261125_1700"* ]] && (( RC != 0 )) \
    && pass "日历那一步放弃不算：后面纪要失败照样提示重跑" || fail "RC=$RC 输出: $OUT"

# ── 3. 从音频重跑，纪要成功：一次 again 就够 ──
rm -f "$TMP/claude-fail"
S3=$(new_session 20261125_1000 20261125_100005)
OUT=$(cd "$TMP" && "$MEETAP" again "$S3" </dev/null 2>&1); RC=$?
notes=$(find "$S3" -maxdepth 1 -name '*.md' ! -name prompt.md ! -name extra-requirements.md | head -1)
[[ -n "$notes" ]] && grep -q '测试纪要' "$notes" && pass "一次 again 就生成了纪要" || fail "没生成纪要: $(ls "$S3") / $OUT"
(( RC == 0 )) && [[ "$OUT" != *"meetap again 20261125_1000"* ]] \
    && pass "成功时退出码 0、没有重跑提示（邮件没配不算失败）" || fail "RC=$RC 输出: $OUT"

(( FAIL == 0 )) && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
