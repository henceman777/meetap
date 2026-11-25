#!/bin/bash
# 会话 log/ 的测试（不需要音频设备、不触达 AWS）：
#   转录成功、失败都一样 → log/ 里是 transcript.txt、meetap.log 和 Transcribe 原始结果 transcribe-raw.json
#   （唯一带逐词时间和置信度的文件，2.0.1 起不再删），speaker-stats.txt 在隐藏的 .meetap/ 里；
#   build_prompt 新老位置的发言统计都读得到；meetap tidy 整理老会话时一个 transcribe-raw.json 都不删。
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
    {"type": "pronunciation", "start_time": "0.5", "end_time": "0.9", "alternatives": [{"confidence": "0.93", "content": "大家好"}]},
    {"type": "punctuation", "alternatives": [{"confidence": "0.0", "content": "。"}]},
    {"type": "pronunciation", "start_time": "2.0", "end_time": "2.6", "alternatives": [{"confidence": "0.99", "content": "开始吧"}]}
  ],
  "speaker_labels": {"segments": [
    {"speaker_label": "spk_0", "start_time": "0.5", "end_time": "1.5", "items": [{"start_time": "0.5", "speaker_label": "spk_0"}]},
    {"speaker_label": "spk_1", "start_time": "2.0", "end_time": "5.0", "items": [{"start_time": "2.0", "speaker_label": "spk_1"}]}
  ]}
}}
EOF
echo 'not json {' > "$TMP/raw-bad.json"
# 没有说话人标签（录音只有几秒时 Transcribe 给的 speaker_labels 是 null）
cat > "$TMP/raw-nolabels.json" <<'EOF2'
{"results": {"speaker_labels": null, "items": [
    {"type": "pronunciation", "start_time": "0.5", "end_time": "0.9", "alternatives": [{"content": "大家好"}]},
    {"type": "punctuation", "alternatives": [{"content": "。"}]},
    {"type": "pronunciation", "start_time": "2.0", "end_time": "2.6", "alternatives": [{"content": "开始吧"}]}
]}}
EOF2
# 一个词都没识别出来（11-19 10:52 那场就是这样）
echo '{"results": {"language_code": "zh-CN", "transcripts": [{"transcript": ""}], "speaker_labels": null, "items": [], "audio_segments": []}}' > "$TMP/raw-empty.json"

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
for c in open afplay; do printf '#!/bin/bash\nexit 0\n' > "$FAKEBIN/$c"; done
printf '#!/bin/bash\necho "$*" >> "%s/notify.log"\nexit 0\n' "$TMP" > "$FAKEBIN/osascript"
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

# ── 1. 转录成功：log/ 里是 transcript.txt、meetap.log 和原始结果，诊断文件在 .meetap/ ──
cp "$TMP/raw-good.json" "$TMP/raw.json"
S1=$(new_session 20261119_0900 20261119_090005)
OUT=$(cd "$TMP" && "$MEETAP" again "$S1" </dev/null 2>&1)
[[ "$(ls -A "$S1/log" | tr '\n' ' ')" == "meetap.log transcribe-raw.json transcript.txt " ]] && pass "转录成功：log/ 里是 transcript.txt、meetap.log 和 transcribe-raw.json" || fail "log/ 里: $(ls -A "$S1/log")"
grep -q '^spk_0: 大家好。' "$S1/log/transcript.txt" && grep -q '^spk_1: 开始吧' "$S1/log/transcript.txt" \
    && pass "转录文本照常生成" || fail "转录文本不对: $(cat "$S1/log/transcript.txt" 2>/dev/null)"
[[ "$(ls -A "$S1/.meetap")" == "speaker-stats.txt" ]] \
    && pass "发言统计在隐藏的 .meetap/ 里，排错日志不在" || fail ".meetap/ 里: $(ls -A "$S1/.meetap" 2>/dev/null)"
grep -q '^total: 0m04s' "$S1/.meetap/speaker-stats.txt" && pass "发言统计内容照常" || fail "发言统计: $(cat "$S1/.meetap/speaker-stats.txt")"
cmp -s "$S1/log/transcribe-raw.json" "$TMP/raw-good.json" && [[ ! -e "$S1/.meetap/transcribe-raw.json" ]] \
    && pass "转录成功后 transcribe-raw.json 留在 log/，和 Transcribe 给的一字不差" || fail "log/transcribe-raw.json 没留下或被改过: $(ls -A "$S1/log" "$S1/.meetap" 2>/dev/null)"
python3 -I -c 'import json,sys; w=[i for i in json.load(open(sys.argv[1]))["results"]["items"] if i["type"]=="pronunciation"]; assert w and all(i["start_time"] and i["end_time"] and i["alternatives"][0]["confidence"] for i in w)' "$S1/log/transcribe-raw.json" 2>/dev/null \
    && pass "留下的原始结果里每个词都有开始、结束时间和置信度" || fail "原始结果里缺逐词时间或置信度"
grep -q 'Transcript saved' "$S1/log/meetap.log" && pass "排错日志照常记下转录过程" || fail "日志: $(cat "$S1/log/meetap.log")"
[[ "$OUT" == *"（日志: log/meetap.log）"* ]] && pass "提示里写的日志位置是 log/meetap.log" || fail "提示: $OUT"
other=$(grep -v -E '^(sts|s3|s3api|transcribe) ' "$TMP/aws.log")
[[ $(grep -c . "$TMP/aws.log") -ge 5 && -z "$other" ]] && grep -q '^transcribe start-transcription-job' "$TMP/aws.log" \
    && pass "整条转录走的是假 aws" || fail "aws 调用: $(cat "$TMP/aws.log")"

# ── 1b. audio_persist = false：音频转录完删掉，原始结果照样留在 log/（这时它是逐词时间唯一的来源）──
printf 'recording_dir = %s\nlanguage = zh-CN\ncalendar = off\naudio_persist = false\n' "$REC" > "$XDG_CONFIG_HOME/meetap/config"
S1b=$(new_session 20261119_0930 20261119_093005)
(cd "$TMP" && "$MEETAP" again "$S1b" </dev/null >/dev/null 2>&1)
[[ ! -e "$S1b/meeting_20261119_093005.m4a" && -s "$S1b/log/transcript.txt" ]] && cmp -s "$S1b/log/transcribe-raw.json" "$TMP/raw-good.json" \
    && pass "audio_persist = false：音频删了，transcribe-raw.json 留在 log/" || fail "audio_persist = false: $(ls -A "$S1b" "$S1b/log" 2>/dev/null)"
printf 'recording_dir = %s\nlanguage = zh-CN\ncalendar = off\n' "$REC" > "$XDG_CONFIG_HOME/meetap/config"

# ── 2. 转录失败（原始结果是坏的）：transcribe-raw.json 留在 log/，它是唯一一份 ──
cp "$TMP/raw-bad.json" "$TMP/raw.json"
S2=$(new_session 20261119_1000 20261119_100005)
(cd "$TMP" && "$MEETAP" again "$S2" </dev/null >/dev/null 2>&1)
cmp -s "$S2/log/transcribe-raw.json" "$TMP/raw-bad.json" && [[ ! -s "$S2/log/transcript.txt" && ! -e "$S2/.meetap/transcribe-raw.json" ]] \
    && pass "生成不出转录时，transcribe-raw.json 留在 log/" || fail "失败时原始结果没留在 log/: $(ls -A "$S2/log" "$S2/.meetap" 2>/dev/null)"
! grep -q 'Traceback' "$S2/log/meetap.log" && grep -q 'Transcription failed: transcript' "$S2/log/meetap.log" && ! grep -q 'Generating meeting notes' "$S2/log/meetap.log" \
    && pass "原始结果坏了：日志只记一行原因，没有 Traceback，不去生成纪要" || fail "坏结果的日志: $(tail -5 "$S2/log/meetap.log")"

# ── 2b. 没有说话人标签：全部当作 spk_0，发言统计照常 ──
cp "$TMP/raw-nolabels.json" "$TMP/raw.json"
S2b=$(new_session 20261119_1030 20261119_103005)
(cd "$TMP" && "$MEETAP" again "$S2b" </dev/null >/dev/null 2>&1)
[[ "$(cat "$S2b/log/transcript.txt" 2>/dev/null)" == "spk_0: 大家好。 开始吧" ]] && ! grep -q 'Traceback' "$S2b/log/meetap.log" \
    && pass "没有说话人标签：转录稿全部记在 spk_0 名下，不崩" || fail "没有标签时: $(cat "$S2b/log/transcript.txt" 2>/dev/null) / $(grep -A3 Traceback "$S2b/log/meetap.log")"
[[ "$(cat "$S2b/.meetap/speaker-stats.txt" 2>/dev/null)" == $'spk_0: 0m02s (100.0%)\ntotal: 0m02s' && -f "$S2b/log/transcribe-raw.json" ]] \
    && pass "没有说话人标签：发言统计按第一个词到最后一个词算，原始结果照常留在 log/" || fail "发言统计: $(cat "$S2b/.meetap/speaker-stats.txt" 2>/dev/null)"

# ── 2c. 一个词都没识别出来：日志和通知写明，不生成纪要，不报 Traceback ──
cp "$TMP/raw-empty.json" "$TMP/raw.json"
S2c=$(new_session 20261119_1052 20261119_105258)
# 停止录音时收下了日历候选，还在等转录完认（pending）
mkdir -p "$S2c/.meetap"
echo '{"schema": 1, "session": "20261119_1052", "tags": [], "calendar": {"candidates": [{"title": "编的分享会", "start": "2026-11-19T11:00:00+08:00", "end": "2026-11-19T12:00:00+08:00", "time_score": 0.1}], "matched_by": "pending"}}' > "$S2c/.meetap/meta.json"
rm -f "$TMP/notify.log"
OUT=$(cd "$TMP" && "$MEETAP" again "$S2c" </dev/null 2>&1)
L="$S2c/log/meetap.log"
grep -q '录音里没有识别出说话内容，不生成纪要' "$L" && ! grep -q 'Traceback' "$L" && ! grep -q 'Generating meeting notes' "$L" \
    && [[ ! -e "$S2c/log/transcript.txt" && -f "$S2c/meeting_20261119_105258.m4a" && -z "$(ls "$S2c"/*.md 2>/dev/null)" ]] \
    && pass "没识别出说话内容：日志写明，不生成纪要、不写转录稿，音频留着，没有 Traceback" || fail "没识别出内容: $(tail -6 "$L")"
cmp -s "$S2c/log/transcribe-raw.json" "$TMP/raw-empty.json" && pass "没识别出说话内容：原始结果留在 log/ 备查" || fail "没识别出内容时原始结果: $(ls -A "$S2c/log" "$S2c/.meetap" 2>/dev/null)"
grep -q '录音里没有识别出说话内容，没有生成纪要' "$TMP/notify.log" && ! grep -q '转录完成' "$TMP/notify.log" \
    && pass "没识别出说话内容：弹通知写明，不弹「转录完成」" || fail "通知: $(cat "$TMP/notify.log" 2>/dev/null)"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["calendar"]; assert d["no_speech"] is True and c["matched_by"] == "no_speech" and len(c["candidates"]) == 1 and c["looked_up_at"]' "$S2c/.meetap/meta.json" \
    && pass "没识别出说话内容：meta.json 里日历不再停在 pending，定成 no_speech，候选留着" || fail "meta.json: $(cat "$S2c/.meetap/meta.json")"
OUT=$(cd "$TMP" && "$MEETAP" 20261119_1052 </dev/null 2>&1)
[[ "$OUT" == *"  纪要：没有（录音里没有说话内容）"* && "$OUT" == *"  日历：录音里没有说话内容，没认日历"* && "$OUT" != *"转录完按内容认"* ]] \
    && pass "meetap <文件夹>：纪要一行写「没有（录音里没有说话内容）」，日历一行写「录音里没有说话内容，没认日历」" || fail "信息页: $OUT"
# 以前没有 meta.json 的会话：也记下来；后来又转出了内容（比如换了音频再 again）就把记号去掉
S2d=$(new_session 20261119_1053 20261119_105305)
(cd "$TMP" && "$MEETAP" again "$S2d" </dev/null >/dev/null 2>&1)
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["no_speech"] is True and "calendar" not in d' "$S2d/.meetap/meta.json" \
    && pass "没有 meta.json 的会话没识别出内容：新建一份记下 no_speech" || fail "没有新建 meta.json: $(ls -A "$S2d/.meetap" 2>/dev/null)"
cp "$TMP/raw-good.json" "$TMP/raw.json"
(cd "$TMP" && "$MEETAP" again "$S2d" </dev/null >/dev/null 2>&1)
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "no_speech" not in d' "$S2d/.meetap/meta.json" && [[ -s "$S2d/log/transcript.txt" ]] \
    && pass "后来又转出了内容：去掉 no_speech 记号" || fail "记号没去掉: $(cat "$S2d/.meetap/meta.json")"

# ── 3. again 只重跑纪要（已有转录）：日志追加到 log/meetap.log ──
before=$(wc -l < "$S1/log/meetap.log")
(cd "$TMP" && "$MEETAP" again "$S1" </dev/null >/dev/null 2>&1)
[[ $(wc -l < "$S1/log/meetap.log") -gt $before && ! -e "$S1/.meetap/meetap.log" ]] \
    && pass "again 只重跑纪要时，日志追加到 log/meetap.log" || fail "again 的日志位置不对: $(ls -A "$S1/.meetap")"

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

# ── 5. meetap tidy：整理老会话 ──
R2="$TMP/rec2"
mk() { mkdir -p "$(dirname "$1")"; head -c "${2:-10}" /dev/zero | tr '\0' 'x' > "$1"; }   # mk <文件> [字节数]
# A：第一层，有音频、有转录、三个诊断文件都在 log/
mk "$R2/20261101_0900/meeting_20261101_090005.m4a"; mk "$R2/20261101_0900/log/transcript.txt"
mk "$R2/20261101_0900/log/transcribe-raw.json" 2048
for f in meetap.log speaker-stats.txt audio-tap.log; do mk "$R2/20261101_0900/log/$f"; done
mk "$R2/20261101_0900/materials/agenda.md"; mk "$R2/20261101_0900/2026-11-01_0900_周会.md"
# B：月份文件夹里，没有音频
mk "$R2/2026-10/20261008_1046/log/transcript.txt"; mk "$R2/2026-10/20261008_1046/log/transcribe-raw.json" 3072
mk "$R2/2026-10/20261008_1046/log/meetap.log"
# D：老版本布局，JSON 和转录直接在会话根目录，没有音频
mk "$R2/2026-04/0417_1216/transcript.txt"; mk "$R2/2026-04/0417_1216/transcribe-raw.json" 4096
# E：更深一层的子文件夹，有音频
mk "$R2/2026-07/temp/20260723_1055/meeting_20260723_105505.m4a"; mk "$R2/2026-07/temp/20260723_1055/log/transcript.txt"
mk "$R2/2026-07/temp/20260723_1055/log/transcribe-raw.json" 5120; mk "$R2/2026-07/temp/20260723_1055/log/speaker-stats.txt"
# C：有音频、有 JSON，但没有转录文本
mk "$R2/20261102_0900/meeting_20261102_090005.m4a"; mk "$R2/20261102_0900/log/transcribe-raw.json" 1024
# F：.meetap/ 里已经有同名的 speaker-stats.txt
mk "$R2/20261103_0900/meeting_20261103_090005.m4a"; mk "$R2/20261103_0900/log/transcript.txt"
mk "$R2/20261103_0900/log/speaker-stats.txt" 7; mk "$R2/20261103_0900/.meetap/speaker-stats.txt" 9
# H：以前被挪进 .meetap/ 的 meetap.log（log-cleanup 早期版本录的会）
mk "$R2/20261105_0900/meeting_20261105_090005.m4a"; mk "$R2/20261105_0900/log/transcript.txt"
mk "$R2/20261105_0900/.meetap/meetap.log" 11
# G：新会话转录失败时故意留在 .meetap/ 的原始结果
mk "$R2/20261104_0900/meeting_20261104_090005.m4a"; mk "$R2/20261104_0900/.meetap/transcribe-raw.json" 512
# I：根目录还放着老的 meta.json；J：两处都有
mk "$R2/20261106_0900/meeting_20261106_090005.m4a"; mk "$R2/20261106_0900/log/transcript.txt"
printf '{"schema": 1, "tags": ["周会"]}\n' > "$R2/20261106_0900/meta.json"
mk "$R2/20261107_0900/log/transcript.txt"; mk "$R2/20261107_0900/meta.json" 5; mk "$R2/20261107_0900/.meetap/meta.json" 6
# recording_dir 以外的目录（比如 ~/Record-2）
mk "$TMP/Record-2/20261101_0900/log/transcribe-raw.json"; mk "$TMP/Record-2/20261101_0900/log/transcript.txt"
printf 'recording_dir = %s\nlanguage = zh-CN\ncalendar = off\n' "$R2" > "$XDG_CONFIG_HOME/meetap/config"
snap() { (cd "$TMP" && find rec2 Record-2 -type f -exec md5 -r {} + | sort); }
tidy() { OUT=$(cd "$TMP" && "$MEETAP" tidy "$@" </dev/null 2>&1); RC=$?; }

# 5a. 默认只列清单：一个字节都不改；两组分开列，最后两行写两组各能腾出多少
before=$(snap)
tidy
[[ $RC -eq 0 && "$(snap)" == "$before" ]] && pass "tidy 默认只列清单，什么都没改" || fail "清单模式改了文件 (rc=$RC)"
[[ "$OUT" == *"【有音频】"*"20261101_0900：transcribe-raw.json（2 KB），诊断文件 2 个挪进 .meetap/"* \
   && "$OUT" == *"2026-07/temp/20260723_1055：transcribe-raw.json（5 KB），诊断文件 1 个"* ]] \
    && pass "有音频的一组：第一层和更深的子文件夹都扫到了" || fail "有音频的一组: $OUT"
[[ "$OUT" == *"【没有音频】transcribe-raw.json 是逐词时间唯一的来源，默认留着"*"2026-04/0417_1216：transcribe-raw.json（4 KB）"* \
   && "$OUT" == *"2026-10/20261008_1046：transcribe-raw.json（3 KB）"* && "$OUT" != *"2026-10/20261008_1046：transcribe-raw.json（3 KB），"* ]] \
    && pass "没有音频的一组单独列出（月份文件夹、老版本布局都在）" || fail "没有音频的一组: $OUT"
[[ "$OUT" == *"【没有转录文本】"*"20261102_0900：transcribe-raw.json（1 KB）"* ]] && pass "没有转录文本的单独列出" || fail "没转录的: $OUT"
[[ "$OUT" == *"有音频的会话：2 场，删掉 transcribe-raw.json 能腾出 7 KB"* \
   && "$OUT" == *"没有音频的会话：2 场，transcribe-raw.json 合计 7 KB，默认不删"* ]] \
    && pass "最后两行写明两组各能腾出多少" || fail "汇总: $OUT"
[[ "$OUT" == *"挪进 .meetap/ 的诊断文件：3 个"* && "$OUT" == *"2 个诊断文件在 .meetap/ 里已有同名文件"* && "$OUT" == *"tidy --yes"* ]] \
    && pass "写明要挪几个、冲突几个，并提示确认后加 --yes（meetap.log 不挪）" || fail "挪动汇总: $OUT"
[[ "$OUT" == *"20261105_0900：meetap.log 挪回 log/"* && "$OUT" == *"挪回 log/ 的 meetap.log：1 个"* ]] \
    && pass "以前挪进 .meetap/ 的 meetap.log 列为挪回 log/" || fail "挪回: $OUT"
[[ "$OUT" == *"20261106_0900：meta.json 挪进 .meetap/"* && "$OUT" == *"挪进 .meetap/ 的 meta.json：1 个"* \
   && "$OUT" == *"20261107_0900：1 个在 .meetap/ 里已有同名文件、跳过"* ]] \
    && pass "根目录的 meta.json 列为挪进 .meetap/；两处都有的列为跳过" || fail "meta.json 清单: $OUT"
[[ "$OUT" != *"Record-2"* && "$OUT" != *"20261104_0900"* ]] && pass "不碰 recording_dir 以外的目录，也不碰 .meetap/ 里留下的原始结果" || fail "扫到了不该扫的: $OUT"

# 5b. --yes：有音频的删 JSON；没有音频的、没有转录的留着；诊断文件挪进 .meetap/
keep_before=$(cd "$TMP" && find rec2 -type f \( -name '*.m4a' -o -name '*.md' -o -path '*/materials/*' -o -name 'transcript.txt' \) -exec md5 -r {} + | sort)
r2_before=$(cd "$TMP" && find Record-2 -type f -exec md5 -r {} + | sort)
tidy --yes
[[ $RC -eq 0 && ! -e "$R2/20261101_0900/log/transcribe-raw.json" && ! -e "$R2/2026-07/temp/20260723_1055/log/transcribe-raw.json" ]] \
    && pass "--yes：有音频的会话删掉了 transcribe-raw.json" || fail "有音频的没删 (rc=$RC): $OUT"
[[ -f "$R2/2026-10/20261008_1046/log/transcribe-raw.json" && -f "$R2/2026-04/0417_1216/transcribe-raw.json" ]] \
    && pass "--yes：没有音频的会话不加 --include-no-audio 时 JSON 留着" || fail "没有音频的 JSON 被删了"
[[ -f "$R2/20261102_0900/log/transcribe-raw.json" ]] && pass "--yes：没有转录文本的 JSON 留着" || fail "没转录的 JSON 被删了"
[[ "$(ls -A "$R2/20261101_0900/log" | tr '\n' ' ')" == "meetap.log transcript.txt " && "$(ls -A "$R2/20261101_0900/.meetap" | tr '\n' ' ')" == "audio-tap.log speaker-stats.txt " ]] \
    && pass "--yes：log/ 里是 transcript.txt 和 meetap.log，另外两个诊断文件进了 .meetap/" || fail "挪动不对: $(ls -A "$R2/20261101_0900/log")"
[[ -f "$R2/20261105_0900/log/meetap.log" && ! -e "$R2/20261105_0900/.meetap/meetap.log" && $(wc -c < "$R2/20261105_0900/log/meetap.log") -eq 11 ]] \
    && pass "--yes：以前挪进 .meetap/ 的 meetap.log 挪回了 log/" || fail "没挪回 log/"
[[ -f "$R2/20261103_0900/log/speaker-stats.txt" && $(wc -c < "$R2/20261103_0900/.meetap/speaker-stats.txt") -eq 9 ]] \
    && pass "--yes：.meetap/ 里已有同名文件的没挪、没覆盖" || fail "冲突处理不对"
[[ -f "$R2/20261106_0900/.meetap/meta.json" && ! -e "$R2/20261106_0900/meta.json" ]] \
    && grep -q '周会' "$R2/20261106_0900/.meetap/meta.json" && pass "--yes：根目录的 meta.json 挪进 .meetap/，内容不变" || fail "meta.json 没挪"
[[ $(wc -c < "$R2/20261107_0900/meta.json") -eq 5 && $(wc -c < "$R2/20261107_0900/.meetap/meta.json") -eq 6 ]] \
    && pass "--yes：两处都有 meta.json 的不动、不覆盖" || fail "两处都有的被动了"
[[ -f "$R2/20261104_0900/.meetap/transcribe-raw.json" ]] && pass "--yes：转录失败时留下的原始结果没动" || fail ".meetap/ 里的原始结果被删了"
keep_after=$(cd "$TMP" && find rec2 -type f \( -name '*.m4a' -o -name '*.md' -o -path '*/materials/*' -o -name 'transcript.txt' \) -exec md5 -r {} + | sort)
[[ "$keep_after" == "$keep_before" ]] && pass "--yes：音频、纪要、materials/、转录文本一个字节都没动" || fail "动了不该动的文件"
[[ "$(cd "$TMP" && find Record-2 -type f -exec md5 -r {} + | sort)" == "$r2_before" ]] && pass "--yes：Record-2 没动" || fail "Record-2 被动了"

# 5c. 再跑一次：没有可删的了，只剩没有音频和没有转录的两组
tidy
[[ "$OUT" == *"有音频的会话：0 场"* && "$OUT" == *"没有音频的会话：2 场"* ]] && pass "整理过的再跑一次：有音频的一组为 0" || fail "第二次: $OUT"

# 5d. --include-no-audio：没有音频的也删
tidy --yes --include-no-audio
[[ ! -e "$R2/2026-10/20261008_1046/log/transcribe-raw.json" && ! -e "$R2/2026-04/0417_1216/transcribe-raw.json" \
   && "$OUT" == *"没有音频的会话：2 场，按 --include-no-audio 一并删掉，能腾出 7 KB"* && -f "$R2/20261102_0900/log/transcribe-raw.json" ]] \
    && pass "--include-no-audio：没有音频的会话也删掉 JSON（没有转录的照样留着）" || fail "--include-no-audio (rc=$RC): $OUT"

# 5e. 不认识的选项：报错，不动文件
before=$(snap)
tidy --yse
[[ $RC -ne 0 && "$(snap)" == "$before" ]] && pass "选项写错：报错退出，什么都没改" || fail "写错选项 (rc=$RC): $OUT"

# ── 6. 代码里没有「$变量 后面紧跟全角字符」的写法（bash 3.2 会把全角字符当成变量名的一部分） ──
bad=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z_0-9]*[^ -~]' "$REPO_ROOT/src/meetap")
[[ -z "$bad" ]] && pass "src/meetap 里没有 \$变量 紧跟全角字符的写法" || fail "要加花括号: $bad"

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
