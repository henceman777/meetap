#!/bin/bash
# 会话 log/ 只留 transcript.txt 的测试（不需要音频设备、不触达 AWS）：
#   转录成功 → transcribe-raw.json 删掉，log/ 里是 transcript.txt 和 meetap.log，speaker-stats.txt 在隐藏的 .meetap/ 里；
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
[[ "$(ls -A "$S1/log" | tr '\n' ' ')" == "meetap.log transcript.txt " ]] && pass "转录成功：log/ 里只有 transcript.txt 和 meetap.log" || fail "log/ 里: $(ls -A "$S1/log")"
grep -q '^spk_0: 大家好。' "$S1/log/transcript.txt" && grep -q '^spk_1: 开始吧' "$S1/log/transcript.txt" \
    && pass "转录文本照常生成" || fail "转录文本不对: $(cat "$S1/log/transcript.txt" 2>/dev/null)"
[[ "$(ls -A "$S1/.meetap")" == "speaker-stats.txt" ]] \
    && pass "发言统计在隐藏的 .meetap/ 里，排错日志不在" || fail ".meetap/ 里: $(ls -A "$S1/.meetap" 2>/dev/null)"
grep -q '^total: 0m04s' "$S1/.meetap/speaker-stats.txt" && pass "发言统计内容照常" || fail "发言统计: $(cat "$S1/.meetap/speaker-stats.txt")"
[[ ! -e "$S1/.meetap/transcribe-raw.json" && ! -e "$S1/log/transcribe-raw.json" ]] \
    && pass "转录成功后删掉 transcribe-raw.json" || fail "transcribe-raw.json 还在"
grep -q 'Transcript saved' "$S1/log/meetap.log" && pass "排错日志照常记下转录过程" || fail "日志: $(cat "$S1/log/meetap.log")"
[[ "$OUT" == *"（日志: log/meetap.log）"* ]] && pass "提示里写的日志位置是 log/meetap.log" || fail "提示: $OUT"
other=$(grep -v -E '^(sts|s3|s3api|transcribe) ' "$TMP/aws.log")
[[ $(grep -c . "$TMP/aws.log") -ge 5 && -z "$other" ]] && grep -q '^transcribe start-transcription-job' "$TMP/aws.log" \
    && pass "整条转录走的是假 aws" || fail "aws 调用: $(cat "$TMP/aws.log")"

# ── 2. 转录失败（原始结果是坏的）：transcribe-raw.json 留着，它是唯一一份 ──
cp "$TMP/raw-bad.json" "$TMP/raw.json"
S2=$(new_session 20261119_1000 20261119_100005)
(cd "$TMP" && "$MEETAP" again "$S2" </dev/null >/dev/null 2>&1)
[[ -f "$S2/.meetap/transcribe-raw.json" && ! -s "$S2/log/transcript.txt" ]] \
    && pass "生成不出转录时，transcribe-raw.json 留在 .meetap/" || fail "失败时原始结果没留下: $(ls -A "$S2/.meetap" 2>/dev/null)"

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
[[ "$OUT" == *"挪进 .meetap/ 的诊断文件：3 个"* && "$OUT" == *"1 个诊断文件在 .meetap/ 里已有同名文件"* && "$OUT" == *"tidy --yes"* ]] \
    && pass "写明要挪几个、冲突几个，并提示确认后加 --yes（meetap.log 不挪）" || fail "挪动汇总: $OUT"
[[ "$OUT" == *"20261105_0900：meetap.log 挪回 log/"* && "$OUT" == *"挪回 log/ 的 meetap.log：1 个"* ]] \
    && pass "以前挪进 .meetap/ 的 meetap.log 列为挪回 log/" || fail "挪回: $OUT"
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
