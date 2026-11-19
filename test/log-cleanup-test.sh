#!/bin/bash
# 会话 log/ 只留 transcript.txt 的测试（不需要音频设备、不触达 AWS）：
#   转录成功 → transcribe-raw.json 删掉，meetap.log、speaker-stats.txt 在隐藏的 .meetap/ 里；
#   转录失败 → transcribe-raw.json 留着；build_prompt 新老位置的发言统计都读得到。
# 用假的 aws 模拟整条转录流程（建桶、上传、开任务、查状态、下载一份编的 Transcribe JSON、清理），
# 用 meetap again <会话> 走「从音频重跑」那条路；没有 venv，生成纪要那步会失败，但不碰 AWS。
#
# 用法: test/log-cleanup-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 真实录音在进行时一个用例都不跑
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
chmod +x "$APP/meetap"
MEETAP="$APP/meetap"

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap"
printf 'recording_dir = %s\nlanguage = zh-CN\ncalendar = off\n' "$REC" > "$XDG_CONFIG_HOME/meetap/config"

# 一份编的 Transcribe 结果：两个人各说一句
cat > "$TMP/raw-good.json" <<'EOF'
{"results": {
  "items": [
    {"type": "pronunciation", "start_time": "0.5", "end_time": "0.9", "alternatives": [{"content": "大家好"}]},
    {"type": "punctuation", "alternatives": [{"content": "。"}]},
    {"type": "pronunciation", "start_time": "2.0", "end_time": "2.6", "alternatives": [{"content": "开始吧"}]}
  ],
  "speaker_labels": {"segments": [
    {"speaker_label": "spk_0", "start_time": "0.5", "end_time": "1.5", "items": [{"start_time": "0.5", "speaker_label": "spk_0"}]},
    {"speaker_label": "spk_1", "start_time": "2.0", "end_time": "5.0", "items": [{"start_time": "2.0", "speaker_label": "spk_1"}]}
  ]}
}}
EOF
echo 'not json {' > "$TMP/raw-bad.json"

# 假 aws：每次调用记进 aws.log；下载那一步把 $TMP/raw.json 拷到目标位置
cat > "$FAKEBIN/aws" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/aws.log"
case "\$1 \$2" in
    "sts get-caller-identity")                 echo 123456789012 ;;
    "transcribe get-transcription-job")        echo COMPLETED ;;
    "s3 cp")
        if [[ "\$3" == s3://* ]]; then cp "$TMP/raw.json" "\$4"; fi ;;
esac
exit 0
EOF
for c in osascript open afplay; do printf '#!/bin/bash\nexit 0\n' > "$FAKEBIN/$c"; done
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"
[[ "$(command -v aws)" == "$FAKEBIN/aws" ]] || { echo "ABORT: aws 不是假的"; exit 1; }

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
new_session() {   # new_session <文件夹名> <音频时间戳>：带一段 3 秒测试音的会话
    local d="$REC/$1"
    mkdir -p "$d/materials"
    ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=3" -c:a aac "$d/meeting_$2.m4a" </dev/null
    printf '%s' "$d"
}
listing() { (cd "$1" && find . -type f | sort | tr '\n' ' '); }

# ── 1. 转录成功：log/ 只剩 transcript.txt，诊断文件在 .meetap/，原始 JSON 删掉 ──
cp "$TMP/raw-good.json" "$TMP/raw.json"
S1=$(new_session 20261119_0900 20261119_090005)
OUT=$(cd "$TMP" && "$MEETAP" again "$S1" </dev/null 2>&1)
[[ "$(ls -A "$S1/log")" == "transcript.txt" ]] && pass "转录成功：log/ 里只剩 transcript.txt" || fail "log/ 里还有: $(ls -A "$S1/log")"
grep -q '^spk_0: 大家好。' "$S1/log/transcript.txt" && grep -q '^spk_1: 开始吧' "$S1/log/transcript.txt" \
    && pass "转录文本照常生成" || fail "转录文本不对: $(cat "$S1/log/transcript.txt" 2>/dev/null)"
[[ -s "$S1/.meetap/meetap.log" && -s "$S1/.meetap/speaker-stats.txt" ]] \
    && pass "排错日志、发言统计在隐藏的 .meetap/ 里" || fail ".meetap/ 里: $(ls -A "$S1/.meetap" 2>/dev/null)"
grep -q '^total: 0m04s' "$S1/.meetap/speaker-stats.txt" && pass "发言统计内容照常" || fail "发言统计: $(cat "$S1/.meetap/speaker-stats.txt")"
[[ ! -e "$S1/.meetap/transcribe-raw.json" && ! -e "$S1/log/transcribe-raw.json" ]] \
    && pass "转录成功后删掉 transcribe-raw.json" || fail "transcribe-raw.json 还在"
grep -q 'Transcript saved' "$S1/.meetap/meetap.log" && pass "排错日志照常记下转录过程" || fail "日志: $(cat "$S1/.meetap/meetap.log")"
[[ "$OUT" == *".meetap/meetap.log"* ]] && pass "提示里写的日志位置是 .meetap/meetap.log" || fail "提示: $OUT"
other=$(grep -v -E '^(sts|s3|s3api|transcribe) ' "$TMP/aws.log")
[[ $(grep -c . "$TMP/aws.log") -ge 5 && -z "$other" ]] && grep -q '^transcribe start-transcription-job' "$TMP/aws.log" \
    && pass "整条转录走的是假 aws" || fail "aws 调用: $(cat "$TMP/aws.log")"

# ── 2. 转录失败（原始结果是坏的）：transcribe-raw.json 留着，它是唯一一份 ──
cp "$TMP/raw-bad.json" "$TMP/raw.json"
S2=$(new_session 20261119_1000 20261119_100005)
(cd "$TMP" && "$MEETAP" again "$S2" </dev/null >/dev/null 2>&1)
[[ -f "$S2/.meetap/transcribe-raw.json" && ! -s "$S2/log/transcript.txt" ]] \
    && pass "生成不出转录时，transcribe-raw.json 留在 .meetap/" || fail "失败时原始结果没留下: $(ls -A "$S2/.meetap" 2>/dev/null)"

# ── 3. again 只重跑纪要（已有转录）：日志追加到 .meetap/meetap.log ──
before=$(wc -l < "$S1/.meetap/meetap.log")
(cd "$TMP" && "$MEETAP" again "$S1" </dev/null >/dev/null 2>&1)
[[ $(wc -l < "$S1/.meetap/meetap.log") -gt $before && ! -e "$S1/log/meetap.log" ]] \
    && pass "again 只重跑纪要时，日志追加到 .meetap/meetap.log" || fail "again 的日志位置不对: $(ls -A "$S1/log")"

# ── 4. build_prompt：新位置、老位置的发言统计都读得到，两处都有时用新位置 ──
prompt_of() {
    (
        SCRIPT_DIR="$REPO_ROOT/src"
        _tn() { local k="MSG_$1"; shift; printf "${!k:-<missing>}" "$@"; }
        eval "$(sed -n '/^build_prompt() {/,/^}/p' "$REPO_ROOT/src/meetap")"
        build_prompt "$1" 2>/dev/null
    )
}
S4="$REC/20261119_1100"; mkdir -p "$S4/log" "$S4/.meetap"
echo "spk_0: 你好" > "$S4/log/transcript.txt"
echo "spk_0: 9m09s (100.0%)  老位置" > "$S4/log/speaker-stats.txt"
[[ "$(prompt_of "$S4")" == *"老位置"* ]] && pass "还没整理的老会话：读 log/speaker-stats.txt" || fail "老位置没读到"
echo "spk_0: 1m01s (100.0%)  新位置" > "$S4/.meetap/speaker-stats.txt"
P=$(prompt_of "$S4")
[[ "$P" == *"新位置"* && "$P" != *"老位置"* ]] && pass "两处都有时读 .meetap/ 里的新位置" || fail "没读新位置"

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
