#!/bin/bash
# 凭证过期、断网时别马上放弃的测试（不需要音频设备、不触达 AWS）：
#   假 aws 命令行、假 boto3（生成纪要、认日历、发邮件）按计划先失败几次再恢复，或者一直失败；
#   MEETAP_RETRY_LIMIT_SEC 把每一步的 15 分钟缩成几秒。
# 覆盖：各步骤断了等着、恢复了接着跑完；通知只弹两次；等到上限放弃；again 复用 AWS 上已完成的转录任务；
# S3 只删这一场自己的文件；日志接着往后写；别的错误不空等；认日历时凭证问题等、别的问题马上兜底；
# 开麦录的双声道录音上传前定稿成单声道（查会议室回声）、原地替换，会话里不多留文件，混不出来就不上传。
#
# 用法: test/retry-test.sh
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

APP="$TMP/app"; FAKE="$TMP/fake"; FAKEBIN="$TMP/fakebin"; REC="$TMP/rec"
mkdir -p "$APP/i18n" "$APP/lib" "$APP/share/meetap/prompts" "$APP/meetap-venv/bin" "$FAKE/py/boto3" "$FAKE/py/botocore" "$FAKEBIN" "$REC"
cp "$REPO_ROOT/src/meetap" "$APP/meetap"
cp "$REPO_ROOT/src/i18n/"*.sh "$APP/i18n/"
cp "$REPO_ROOT/src/lib/ui.sh" "$APP/lib/"
cp "$REPO_ROOT/share/meetap/prompts/"*.md "$APP/share/meetap/prompts/"
chmod +x "$APP/meetap"
MEETAP="$APP/meetap"

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
export MEETAP_RETRY_LIMIT_SEC=4
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap"
use_cfg() {
    printf 'recording_dir = %s\nlanguage = %s\ncalendar = off\nai_backend = bedrock\nregion = us-east-1\nemail = someone@example.com\nemail_sender = meetap@example.com\n' \
        "$REC" "${1:-zh-CN}" > "$XDG_CONFIG_HOME/meetap/config"
}
use_cfg

# 失败计划：$FAKE/plan-<步骤> 写「<原因> <次数>」，原因 cred / net / other / gone，次数 always 表示一直失败
fail_msg() {
    case "$1" in
        cred)  echo "An error occurred (ExpiredToken) when calling the $2 operation: The security token included in the request is expired" ;;
        net)   echo "Could not connect to the endpoint URL: \"https://example.amazonaws.com/\"" ;;
        gone)  echo "An error occurred (BadRequestException) when calling the $2 operation: The requested job couldn't be found." ;;
        *)     echo "An error occurred (BadRequestException) when calling the $2 operation: something is wrong" ;;
    esac
}
plan() { echo "$2 $3" > "$FAKE/plan-$1"; rm -f "$FAKE/count-$1"; }   # plan <步骤> <原因> <次数>
clear_plans() { rm -f "$FAKE"/plan-* "$FAKE"/count-*; }

# 假 aws：每次调用记进 aws.log；按计划失败；下载那一步把 $FAKE/raw.json 拷到目标位置
cat > "$FAKEBIN/aws" <<EOF
#!/bin/bash
echo "\$*" >> "$FAKE/aws.log"
# 上传的那个文件留一份，看传上去的是什么
[[ "\$1 \$2" == "s3 cp" && "\$3" != s3://* ]] && cp "\$3" "$FAKE/uploaded.m4a" 2>/dev/null
step=""
case "\$1 \$2" in
    "sts get-caller-identity")          step=sts; op=GetCallerIdentity ;;
    "s3api head-bucket")                step=head; op=HeadBucket ;;
    "s3api put-public-access-block")    step=pab; op=PutPublicAccessBlock ;;
    "s3 mb")                            step=mb; op=CreateBucket ;;
    "s3 cp")                            if [[ "\$3" == s3://* ]]; then step=down; op=GetObject; else step=up; op=PutObject; fi ;;
    "s3 rm")                            step=rm; op=DeleteObject ;;
    "transcribe start-transcription-job")  step=start; op=StartTranscriptionJob ;;
    "transcribe get-transcription-job")    step=poll; op=GetTranscriptionJob ;;
    "transcribe delete-transcription-job") step=del; op=DeleteTranscriptionJob ;;
esac
if [[ -n "\$step" && -f "$FAKE/plan-\$step" ]]; then
    read -r why times < "$FAKE/plan-\$step"
    n=\$(( \$(cat "$FAKE/count-\$step" 2>/dev/null || echo 0) + 1 )); echo \$n > "$FAKE/count-\$step"
    if [[ "\$times" == always || \$n -le \$times ]]; then
        $(declare -f fail_msg)
        fail_msg "\$why" "\$op" >&2
        exit 254
    fi
fi
case "\$step" in
    sts)  echo 123456789012 ;;
    poll) if [[ "\$*" == *FailureReason* ]]; then echo None; else cat "$FAKE/job-status" 2>/dev/null || echo COMPLETED; fi ;;
    down) cp "$FAKE/raw.json" "\$4" ;;
    up)   echo "upload: \$3 to \$4" ;;
esac
exit 0
EOF
# 假 osascript：通知的文字记进 notify.log
cat > "$FAKEBIN/osascript" <<EOF
#!/bin/bash
[[ "\$2" == "display notification"* ]] && printf '%s\n' "\$2" | sed 's/^display notification "\(.*\)" with title.*/\1/' >> "$FAKE/notify.log"
exit 0
EOF
for c in open afplay; do printf '#!/bin/bash\nexit 0\n' > "$FAKEBIN/$c"; done

# 假 venv：真 python3 + 假 boto3 / botocore
PY3="$(command -v python3)"
printf '#!/bin/bash\nPYTHONPATH="%s" exec "%s" "$@"\n' "$FAKE/py" "$PY3" > "$APP/meetap-venv/bin/python3"
echo 'class Config:
    def __init__(self, **kw): pass' > "$FAKE/py/botocore/config.py"
: > "$FAKE/py/botocore/__init__.py"
cat > "$FAKE/py/boto3/__init__.py" <<EOF
import os
FAKE = "$FAKE"
def _gate(step, op):
    p = os.path.join(FAKE, "plan-" + step)
    with open(os.path.join(FAKE, "boto.log"), "a") as f:
        f.write(step + "\n")
    if not os.path.exists(p):
        return
    why, times = open(p).read().split()
    c = os.path.join(FAKE, "count-" + step)
    n = int(open(c).read()) + 1 if os.path.exists(c) else 1
    open(c, "w").write(str(n))
    if times == "always" or n <= int(times):
        if why == "cred":
            raise Exception("An error occurred (ExpiredTokenException) when calling the %s operation: The security token included in the request is expired" % op)
        if why == "net":
            raise Exception('Could not connect to the endpoint URL: "https://example.amazonaws.com/"')
        raise Exception("An error occurred (ValidationException) when calling the %s operation: bad request" % op)
NOTES = ('<!-- meetap-title: 测试纪要 -->\n# 测试纪要\n\n> **会议时间** 2026-11-19\n\n## 结论\n\n- 正文\n\n---\n\n'
         '<p align="center"><em>—— <strong>L</strong>isten · audio notes generator · '
         '<a href="https://github.com/henceman777/meetap">Meetap</a></em></p>\n')
class _Client:
    def __init__(self, service):
        self.service = service
    def converse_stream(self, **kw):
        # 认日历的提示词里有 <转录节选>，生成纪要的没有
        if "<转录节选>" in kw["messages"][0]["content"][0]["text"]:
            _gate("calendar", "ConverseStream")
            text = '{"pick": 1, "reason": "内容对得上"}'
        else:
            _gate("notes", "ConverseStream")
            text = NOTES
        return {"stream": [{"contentBlockDelta": {"delta": {"text": text}}}, {"messageStop": {"stopReason": "end_turn"}}]}
    def converse(self, **kw):
        raise Exception("AccessDeniedException: 最小权限策略里没有 bedrock:InvokeModel")
    def send_raw_email(self, **kw):
        _gate("email", "SendRawEmail")
        with open(os.path.join(FAKE, "sent.log"), "a") as f:
            f.write(",".join(kw["Destinations"]) + "\n")
def client(service, **kw):
    return _Client(service)
EOF
chmod +x "$FAKEBIN"/* "$APP/meetap-venv/bin/python3"
export PATH="$FAKEBIN:$PATH"
[[ "$(command -v aws)" == "$FAKEBIN/aws" && "$(command -v osascript)" == "$FAKEBIN/osascript" ]] || { echo "ABORT: aws / osascript 不是假的"; exit 1; }
"$APP/meetap-venv/bin/python3" -c 'import boto3, sys; sys.exit(0 if boto3.FAKE else 1)' || { echo "ABORT: boto3 不是假的"; exit 1; }

# 一份编的 Transcribe 结果：两个人各说一句
cat > "$FAKE/raw.json" <<'EOF'
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

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
new_session() {   # new_session <文件夹名> <音频时间戳>：带一段 3 秒测试音的会话
    local d="$REC/$1"
    mkdir -p "$d/materials"
    ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=3" -c:a aac "$d/meeting_$2.m4a" </dev/null
    printf '%s' "$d"
}
reset_logs() { rm -f "$FAKE/aws.log" "$FAKE/notify.log" "$FAKE/sent.log" "$FAKE/boto.log"; }
again() { reset_logs; t0=$(date +%s); OUT=$(cd "$TMP" && "$MEETAP" again "$1" </dev/null 2>&1); RC=$?; TOOK=$(( $(date +%s) - t0 )); LOG="$1/log/meetap.log"; }
# 只数「断了」「放弃」这两种通知（转录完成、纪要完成那些不算）
retry_notes() { grep -E '失败：|一直没成功|failed:|kept failing' "$FAKE/notify.log" 2>/dev/null; }
nnotify() { retry_notes | grep -c .; }
done_ok() {   # 转录、纪要、邮件都到了
    [[ -s "$1/log/transcript.txt" && -n "$(ls "$1"/2026-*_测试纪要.md 2>/dev/null)" && "$(cat "$FAKE/sent.log" 2>/dev/null)" == "someone@example.com" ]]
}

# ── 1. 开头查凭证时凭证过期，断了 4 次后恢复：接着跑完，通知只弹一次 ──
S1=$(new_session 20261119_0900 20261119_090005)
clear_plans; plan sts cred 4
again "$S1"
done_ok "$S1" && pass "凭证断了 4 次后恢复：转录、纪要、邮件都跑完了" || fail "没跑完 (rc=$RC): $(tail -20 "$LOG")"
[[ $(grep -c '^sts get-caller-identity' "$FAKE/aws.log") -eq 5 ]] && pass "查凭证试了 5 次（4 次失败 + 1 次成功）" || fail "查凭证次数: $(grep -c '^sts' "$FAKE/aws.log")"
grep -q '检查 AWS 凭证失败：AWS 凭证取不到或者已经过期。刷新凭证以后会自动接着跑，这一步最多等 1 分钟' "$LOG" \
    && grep -q '检查 AWS 凭证第 4 次失败' "$LOG" && grep -q '✅ 检查 AWS 凭证恢复了，接着跑' "$LOG" \
    && pass "日志写明是凭证的问题、第几次失败、恢复了" || fail "日志: $(grep -E '⚠️|✅|失败' "$LOG")"
[[ "$(nnotify)" == 1 && "$(retry_notes)" == "检查 AWS 凭证失败：AWS 凭证可能过期了。刷新凭证以后会自动接着跑" ]] \
    && pass "同一次断掉只弹一次通知，说清楚可能是凭证过期、刷新后自动接着跑" || fail "通知: $(cat "$FAKE/notify.log" 2>/dev/null)"

# ── 2. 各步骤都按同一套规则：上传、查状态、下载、生成纪要、发邮件 ──
# 生成纪要自己会把断流、断网的请求重发 3 次，这里不再测它的断网（凭证问题见下面）
i=0
for step in up poll down email; do
    case $step in up) name="上传录音" ;; poll) name="查转录进度" ;; down) name="下载转录结果" ;; notes) name="生成纪要" ;; email) name="发邮件" ;; esac
    i=$((i + 1))
    S=$(new_session "20261119_100$i" "20261119_100${i}05")
    clear_plans; plan $step net 2
    again "$S"
    done_ok "$S" && grep -q "${name}失败：连不上 AWS" "$LOG" && grep -q "✅ ${name}恢复了" "$LOG" && [[ "$(nnotify)" == 1 ]] \
        && pass "${name}断网 2 次后恢复：接着跑完，日志写明连不上 AWS，通知一次" || fail "${name}断网 (rc=$RC, 通知 $(nnotify)): $(grep -E '⚠️|✅|❌' "$LOG")"
done
S=$(new_session 20261119_1100 20261119_110005)
clear_plans; plan notes cred 2
again "$S"
[[ $(grep -c '^notes$' "$FAKE/boto.log") -eq 3 ]] && done_ok "$S" \
    && pass "生成纪要遇到凭证问题：不在里面空转 3 次，交给外面等，恢复后生成（共调 3 次）" || fail "生成纪要的凭证重试: $(grep -c '^notes$' "$FAKE/boto.log") 次"

# ── 3. 一直失败：每一步最多等上限（测试里 4 秒），然后放弃；通知第二次写明 meetap again ──
S3=$(new_session 20261119_1200 20261119_120005)
clear_plans; plan down cred always
again "$S3"
[[ ! -s "$S3/log/transcript.txt" && $TOOK -ge 4 && $TOOK -le 12 ]] && pass "下载一直失败：等了 ${TOOK}s（上限 4s）后放弃" || fail "放弃时机不对 (${TOOK}s): $(tail -5 "$LOG")"
[[ "$(nnotify)" == 2 ]] && retry_notes | sed -n 2p | grep -q '下载转录结果一直没成功，已放弃。恢复以后用 meetap again 20261119_1200 重跑' \
    && pass "通知一共两次：第一次失败、最后放弃（写明 meetap again <会话>）" || fail "通知: $(cat "$FAKE/notify.log" 2>/dev/null)"
grep -q '❌ 下载转录结果等了 1 分钟还是不行，先放弃。恢复以后用 meetap again 20261119_1200 重跑' "$LOG" && pass "日志写明放弃和怎么重跑" || fail "日志: $(tail -5 "$LOG")"
[[ -f "$S3/.meetap/transcribe-job.json" ]] && ! grep -qE '^s3 rm|^transcribe delete' "$FAKE/aws.log" \
    && pass "放弃时 AWS 上的任务和文件都留着，记下任务名等 again 接着用" || fail "放弃时清掉了: $(grep -E '^s3 rm|delete' "$FAKE/aws.log")"
JOB=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["job"])' "$S3/.meetap/transcribe-job.json")

# ── 4. again：上一次的任务在 AWS 上已经转完，直接取结果，不重新上传、不重新转录 ──
clear_plans
again "$S3"
[[ -s "$S3/log/transcript.txt" ]] && ! grep -q '^s3 cp .*m4a s3://' "$FAKE/aws.log" && ! grep -q '^transcribe start-transcription-job' "$FAKE/aws.log" \
    && grep -q "^transcribe get-transcription-job --transcription-job-name $JOB " "$FAKE/aws.log" \
    && pass "again 复用已完成的转录任务：没有重新上传、没有重新提交" || fail "again 没复用: $(cat "$FAKE/aws.log")"
grep -q "上一次的转录任务还在 AWS 上（${JOB}），直接接着用" "$LOG" && pass "日志写明复用了哪个任务" || fail "日志里没写复用"
B=$(grep -o 's3://meetap-transcribe-[^/ ]*' "$FAKE/aws.log" | head -1)
rms=$(grep '^s3 rm' "$FAKE/aws.log" | awk '{print $3}' | sort | tr '\n' ' ')
[[ "$rms" == "$B/$JOB.json $B/meeting_20261119_120005.m4a " ]] && ! grep -q -- '--recursive' "$FAKE/aws.log" \
    && pass "S3 只删这一场自己的音频和结果，不再 --recursive 清整个桶" || fail "删的不对: $rms"
grep -q "^transcribe delete-transcription-job --transcription-job-name $JOB " "$FAKE/aws.log" && [[ ! -e "$S3/.meetap/transcribe-job.json" ]] \
    && pass "转完以后删掉转录任务和本地的任务记录" || fail "任务没清掉"
grep -rq -- '--recursive' "$REPO_ROOT/src/meetap" && fail "代码里还有 --recursive" || pass "代码里没有 s3 rm --recursive"

# ── 5. 日志接着往后写，每次开头一行分隔 ──
[[ $(grep -c '^===== 20[0-9-]* [0-9:]* · meetap again ' "$LOG") -eq 2 ]] && grep -q '先放弃' "$LOG" && grep -q 'Transcript saved' "$LOG" \
    && pass "again 不冲掉上一次的日志：两次各有一行分隔（时间、命令），上一次放弃的记录还在" || fail "日志: $(grep '=====' "$LOG")"

# ── 6. again 时上一次的任务没了（或失败了）：从头转 ──
S6=$(new_session 20261119_1300 20261119_130005)
clear_plans; plan down cred always
again "$S6"
clear_plans; plan poll gone 1
again "$S6"
grep -q '^s3 cp .*m4a s3://' "$FAKE/aws.log" && grep -q '^transcribe start-transcription-job' "$FAKE/aws.log" && [[ -s "$S6/log/transcript.txt" ]] \
    && pass "上一次的任务在 AWS 上找不到了：重新上传、重新转录" || fail "任务没了时: $(cat "$FAKE/aws.log")"

# ── 7. 别的错误（不是凭证、不是网络）：最多试 3 次就停，不空等，也不弹「断了」的通知 ──
S7=$(new_session 20261119_1400 20261119_140005)
clear_plans; plan up other always
MEETAP_RETRY_LIMIT_SEC=900 again "$S7"
[[ $(grep -c '^s3 cp .*m4a s3://' "$FAKE/aws.log") -eq 3 && $TOOK -le 40 && "$(nnotify)" == 0 ]] && grep -q 'Upload failed' "$LOG" \
    && pass "上传遇到别的错误：试 3 次（${TOOK}s）就报上传失败，不等 15 分钟、不弹通知" || fail "别的错误 (${TOOK}s, 通知 $(nnotify)): $(tail -5 "$LOG")"

# ── 7b. 最小权限策略：查不到桶、建不了桶、锁公共访问报错，都不算失败（和以前一样），照常上传 ──
S7b=$(new_session 20261119_1450 20261119_145005)
clear_plans; plan head other always; plan mb other always; plan pab other always
again "$S7b"
done_ok "$S7b" && [[ $(grep -c '^s3 mb' "$FAKE/aws.log") -eq 1 && "$(nnotify)" == 0 ]] \
    && pass "查桶、建桶、锁公共访问报权限错误：不重试、不弹通知，照常上传转录" || fail "最小权限 (rc=$RC): $(tail -5 "$LOG")"

# ── 8. 提交任务时回应丢了、其实已经提交上去：再提交报「已存在」算成功 ──
S8=$(new_session 20261119_1500 20261119_150005)
clear_plans
cat > "$FAKE/plan-start" <<'EOF'
other 1
EOF
sed -i '' 's/something is wrong/The requested job name already exists. Use a different job name./' "$FAKEBIN/aws"
again "$S8"
sed -i '' 's/The requested job name already exists. Use a different job name./something is wrong/' "$FAKEBIN/aws"
[[ -s "$S8/log/transcript.txt" && $(grep -c '^transcribe start-transcription-job' "$FAKE/aws.log") -eq 1 ]] \
    && pass "提交任务报「任务名已存在」：当作已经提交，接着查进度" || fail "已存在: $(tail -5 "$S8/log/meetap.log")"

# ── 9. 认日历调模型：凭证问题等着恢复；别的问题（断网等）马上按时间兜底，不重试 ──
S9="$REC/20261119_1600"; mkdir -p "$S9/log" "$S9/.meetap" "$S9/materials"
echo "spk_0: 大家好。" > "$S9/log/transcript.txt"
cat > "$S9/.meetap/calendar-candidates.json" <<'EOF'
{"window": {}, "recording": [1795075200, 1795078800], "collected_at": "2026-11-19T16:00:00+08:00",
 "candidates": [{"title": "编的周会", "start": "2026-11-19T16:00:00+08:00", "end": "2026-11-19T17:00:00+08:00",
                 "time_score": 0.9, "overlap_sec": 3600, "organizer": "", "attendees": [], "attendee_count": 0,
                 "location": "", "notes": "", "notes_excerpt": ""}]}
EOF
printf 'recording_dir = %s\nlanguage = zh-CN\ncalendar = on\nai_backend = bedrock\nregion = us-east-1\n' "$REC" > "$XDG_CONFIG_HOME/meetap/config"
clear_plans; plan calendar cred 2; reset_logs
OUT=$(cd "$TMP" && "$MEETAP" _calendar-recognize "$S9" </dev/null 2>&1)
[[ $(grep -c '^calendar$' "$FAKE/boto.log") -eq 3 && "$OUT" == *"认日历失败：AWS 凭证取不到或者已经过期"* && "$OUT" == *"这场会是「编的周会」（时间最接近，内容也对得上：内容对得上）"* ]] \
    && pass "认日历遇到凭证问题：等恢复后再认（共调 3 次），认出来了" || fail "认日历凭证: $(grep -c '^calendar$' "$FAKE/boto.log") 次 / $OUT"
clear_plans; plan calendar net 5; reset_logs
OUT=$(cd "$TMP" && "$MEETAP" _calendar-recognize "$S9" </dev/null 2>&1)
[[ $(grep -c '^calendar$' "$FAKE/boto.log") -eq 1 && "$OUT" == *"按时间认作「编的周会」，内容没核对"* && "$(nnotify)" == 0 ]] \
    && pass "认日历遇到断网：不重试、不弹通知，马上按时间兜底" || fail "认日历断网: $(grep -c '^calendar$' "$FAKE/boto.log") 次 / $OUT"
use_cfg

# ── 10. 英文界面的日志 ──
S10=$(new_session 20261119_1700 20261119_170005)
use_cfg en-US
clear_plans; plan sts cred 1
again "$S10"
grep -q 'Checking AWS credentials failed: AWS credentials are missing or expired' "$LOG" && grep -q '✅ Checking AWS credentials recovered, continuing' "$LOG" \
    && pass "英文界面：日志也写明是凭证的问题" || fail "英文日志: $(grep -E '⚠️|✅' "$LOG")"
use_cfg

# ── 11. 中英两份提示语 key 一致 ──
diff <(grep -oE '^MSG_[A-Z_0-9]+' "$REPO_ROOT/src/i18n/messages-zh-CN.sh" | sort) \
     <(grep -oE '^MSG_[A-Z_0-9]+' "$REPO_ROOT/src/i18n/messages-en-US.sh" | sort) >/dev/null \
    && pass "中英两份提示语的 key 一致" || fail "中英提示语 key 不一致"

# ── 12. 开麦录的双声道录音：先定稿成单声道（原地替换），上传的就是会话里的那个文件 ──
# 两路是两个人（按随机音节开关的带通噪声），各垫一个轻音当记号：麦克风 5 kHz、电脑的声音 7 kHz
voice() {
    echo "anoisesrc=r=48000:c=pink:seed=$2:a=0.5,bandpass=f=1000:width_type=o:w=2[n$1];anoisesrc=r=1000:c=white:seed=$(($2 + 100)),lowpass=f=4,lowpass=f=4[s$1];anoisesrc=r=1000:c=white:seed=$(($2 + 200)),lowpass=f=0.3,lowpass=f=0.3[p$1];[s$1][p$1]amerge=inputs=2,aeval=gt(val(0)\,0)*gt(val(1)\,0):c=mono,aresample=48000[g$1];[n$1][g$1]amultiply"
}
# stereo_session <文件夹名> <音频时间戳> [room]：双声道录音；带 room 就是会议室设备也在会里
# （电脑的声音里有麦克风人声晚 1.5 秒的一遍，和远端一样响）；不带是普通线上会。都是 4 分钟（短了判断不了）
stereo_session() {
    local d="$REC/$1" sys="$(voice s 2)" secs=240 mic="$(voice m 1)"
    [[ "${3:-}" == room ]] && { mic="$(voice m 1),asplit[vm][r2];[r2]adelay=1500,volume=0.7[echo];$(voice s 2),volume=0.7[rem];[echo][rem]amix=inputs=2:normalize=0"; sys=""; }
    mkdir -p "$d/materials"
    if [[ -n "$sys" ]]; then
        mic="$mic[vm];$sys"
    fi
    ffmpeg -v quiet -filter_complex "$mic[vs];sine=f=5000:r=48000,volume=0.1[tm];[vm][tm]amix=inputs=2:normalize=0[mic];sine=f=7000:r=48000,volume=0.1[ts];[vs][ts]amix=inputs=2:normalize=0[sys];[mic][sys]join=inputs=2:channel_layout=stereo,atrim=0:$secs" \
        -c:a aac -b:a 128k "$d/meeting_$2.m4a" </dev/null
    printf '%s' "$d"
}
tone_db() {   # tone_db <文件> <频率> [起 止]：那个频率附近的平均音量（dB）
    ffmpeg -nostdin ${3:+-ss "$3" -to "$4"} -i "$1" -af "bandpass=f=$2:width_type=q:w=20,volumedetect" -f null - 2>&1 | sed -n 's/.*mean_volume: \([-0-9.]*\) dB.*/\1/p'
}
loud() { awk -v v="$1" 'BEGIN { exit !(v != "" && v > -50) }'; }
chans() { ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$1" 2>/dev/null; }
extra_audio() { find "$1" -name '*.m4a' ! -path "$1/meeting_*.m4a" | sed "s|^$1/||"; }
S12=$(stereo_session 20261119_1800 20261119_180005)
# 上次被强杀留下的定稿临时文件（那个进程已经不在了）：这次开头就清掉
sleep 0 & dead=$!; wait $dead
mkdir -p "$S12/.meetap"; echo stale > "$S12/.meetap/finalize.$dead.m4a"
clear_plans; rm -f "$FAKE/uploaded.m4a"
again "$S12"
up=$(grep '^s3 cp ' "$FAKE/aws.log" | grep -v '^s3 cp s3://' | head -1)
v5=$(tone_db "$FAKE/uploaded.m4a" 5000); v7=$(tone_db "$FAKE/uploaded.m4a" 7000)
done_ok "$S12" && [[ "$up" == "s3 cp $S12/meeting_20261119_180005.m4a s3://"*"/meeting_20261119_180005.m4a --region us-east-1" ]] \
    && [[ "$(chans "$FAKE/uploaded.m4a")" == 1 && "$(chans "$S12/meeting_20261119_180005.m4a")" == 1 ]] && loud "$v5" && loud "$v7" \
    && grep -q '🔁 回声检查：没认出会议室设备，两路相加' "$LOG" \
    && pass "普通线上会：会话里的录音定稿成两路相加的单声道（麦克风 ${v5} dB、电脑的声音 ${v7} dB），传的就是它" \
    || fail "普通线上会 (rc=$RC): 上传「${up}」，麦克风 $v5 dB、电脑的声音 $v7 dB / $(grep '🔁\|⚠️' "$LOG")"
[[ -z "$(extra_audio "$S12")" ]] && pass "会话里只有一个录音文件，上次留下的临时文件也清了" || fail "多出: $(extra_audio "$S12")"

# 会议室设备也在会里：整场只留电脑的声音，默认不留原始录音，会话里还是只有一个录音文件
S12r=$(stereo_session 20261119_1840 20261119_184005 room)
clear_plans; rm -f "$FAKE/uploaded.m4a" "$FAKE/notify.log"
again "$S12r"
# 结论里去掉麦克风的那些时段（日志里写着），挑最长的一段看：只有电脑的声音
rg=$(grep -o '其余时段两路相加：.*\|整场只留电脑的声音' "$LOG" | tail -1)
if [[ "$rg" == 整场* ]]; then a=0; b=240; else
    read -r a b <<< "$(sed 's/^其余时段两路相加：//' <<< "$rg" | tr ',' '\n' | awk -F'[-:]' '{ s = $1 * 60 + $2; e = $3 * 60 + $4; if (e - s > m) { m = e - s; r = s " " e } } END { print r }')"
fi
v5=$(tone_db "$FAKE/uploaded.m4a" 5000 $((a + 1)) $((b - 1))); v7=$(tone_db "$FAKE/uploaded.m4a" 7000)
done_ok "$S12r" && ! loud "$v5" && loud "$v7" && grep -q '去掉了麦克风' "$LOG" \
    && grep -q '去掉了麦克风' "$FAKE/notify.log" && [[ -z "$(extra_audio "$S12r")" ]] \
    && pass "会议室设备在会里：去掉麦克风的 ${a}~${b} 秒只有电脑的声音（麦克风 ${v5} dB、电脑的声音 ${v7} dB），弹了通知，没留多的音频" \
    || fail "会议室设备 (rc=$RC): 麦克风 $v5 dB、电脑的声音 $v7 dB，多出 $(extra_audio "$S12r") / $(grep '🔁\|⚠️' "$LOG")"
# again（已经定稿过）：不重判，echo_check 关了也退不回去，照实说
use_cfg; echo "echo_check = off" >> "$XDG_CONFIG_HOME/meetap/config"
rm -f "$S12r/log/transcript.txt"; clear_plans
again "$S12r"
[[ "$OUT" == *"麦克风那一路已经去掉"* ]] && done_ok "$S12r" && ! grep -q '回声检查：' <(tail -20 "$LOG") \
    && pass "定稿过的 again 不重判；没留原始录音时照实说退不回两路相加" || fail "again 时: $OUT"
use_cfg

# keep_stereo_original = true + audio_persist = false：转录完录音和原始录音都删掉
printf 'keep_stereo_original = true\naudio_persist = false\n' >> "$XDG_CONFIG_HOME/meetap/config"
S12k=$(stereo_session 20261119_1850 20261119_185005 room)
clear_plans
again "$S12k"
done_ok "$S12k" && [[ -z "$(find "$S12k" -name '*.m4a')" ]] && grep -q 'keep_stereo_original = true' "$LOG" \
    && pass "audio_persist = false：转录完录音和留下的原始录音都删了" || fail "audio_persist = false 时还剩: $(find "$S12k" -name '*.m4a')"
use_cfg

# echo_check = OFF（不分大小写）：不查，照样两路相加
echo "echo_check = OFF" >> "$XDG_CONFIG_HOME/meetap/config"
S12d=$(stereo_session 20261119_1830 20261119_183005 room)
clear_plans; rm -f "$FAKE/uploaded.m4a"
again "$S12d"
v5=$(tone_db "$FAKE/uploaded.m4a" 5000); v7=$(tone_db "$FAKE/uploaded.m4a" 7000)
done_ok "$S12d" && grep -q '配置 echo_check = off' "$LOG" && ! grep -q '回声检查：' "$LOG" && loud "$v5" && loud "$v7" \
    && pass "echo_check = OFF：不查回声，会议室设备在会里也照样两路相加" || fail "echo_check = OFF (rc=$RC): $(grep '🔁' "$LOG") / $v5 $v7"
use_cfg

# 上传失败：会话里留下定稿好的单声道录音，没有多的文件
S12b=$(stereo_session 20261119_1810 20261119_181005)
clear_plans; plan up other always
again "$S12b"
[[ -z "$(extra_audio "$S12b")" && "$(chans "$S12b/meeting_20261119_181005.m4a")" == 1 ]] && grep -q 'Upload failed' "$LOG" \
    && pass "上传失败：录音已经定稿、还在，没有多的文件" || fail "上传失败后: $(extra_audio "$S12b") / $(tail -3 "$LOG")"
clear_plans
# 混不出来（录音坏了，ffprobe、ffmpeg 都读不了）：报错、不上传，原文件不动
S12c="$REC/20261119_1820"; mkdir -p "$S12c/materials"; head -c 4096 /dev/urandom > "$S12c/meeting_20261119_182005.m4a"
sum0=$(md5 -q "$S12c/meeting_20261119_182005.m4a")
again "$S12c"
! grep -q '^s3 cp .* s3://' "$FAKE/aws.log" && grep -q '没能把双声道录音混成单声道，没有上传' "$LOG" && [[ -z "$(extra_audio "$S12c")" ]] \
    && [[ "$(md5 -q "$S12c/meeting_20261119_182005.m4a")" == "$sum0" ]] \
    && pass "混不出来：报错、不上传、原文件不动" || fail "混不出来时: $(grep '^s3 cp' "$FAKE/aws.log") / $(tail -3 "$LOG")"

# ── 13. 正在录的这一场不能 again：定稿会把 ffmpeg 还在写的录音换掉。只重写纪要也一样拒绝 ──
S13=$(stereo_session 20261130_0900 20261130_090005)
mkdir -p "$S13/log"; echo "旧转录" > "$S13/log/transcript.txt"
sum0=$(md5 -q "$S13/meeting_20261130_090005.m4a")
sleep 300 & live=$!
echo "$live" > "$MEETAP_STATE_DIR/ffmpeg.pid"; echo "$S13" > "$MEETAP_STATE_DIR/session-dir"
echo "$S13/meeting_20261130_090005.m4a" > "$MEETAP_STATE_DIR/output-file"
clear_plans
again ""   # 不带参数：默认最新一场，就是正在录的这一场
[[ $RC != 0 && "$OUT" == *"正在录音，现在不能 again"* && "$(md5 -q "$S13/meeting_20261130_090005.m4a")" == "$sum0" ]] \
    && ! grep -q . "$FAKE/aws.log" 2>/dev/null && [[ -z "$(ls "$S13"/2026-*.md 2>/dev/null)" ]] \
    && pass "正在录的这一场 again：拒绝，录音一个字节没动，也没重写纪要" || fail "正在录时 again (rc=$RC): $OUT"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
rm -f "$MEETAP_STATE_DIR/ffmpeg.pid" "$MEETAP_STATE_DIR/session-dir" "$MEETAP_STATE_DIR/output-file"

# ── 14. 退回两路相加失败（留下的原始录音坏了）：报错，旧纪要、录音都没动 ──
S14=$(stereo_session 20261119_1900 20261119_190005)
ffmpeg -v quiet -y -i "$S14/meeting_20261119_190005.m4a" -ac 1 -c:a aac "$S14/m.m4a" </dev/null && mv "$S14/m.m4a" "$S14/meeting_20261119_190005.m4a"
mkdir -p "$S14/.meetap" "$S14/log"; head -c 4096 /dev/urandom > "$S14/.meetap/meeting_20261119_190005.stereo-original.m4a"
echo "旧转录" > "$S14/log/transcript.txt"; echo "# 旧纪要" > "$S14/2026-11-19_1900_旧纪要.md"
use_cfg; echo "echo_check = off" >> "$XDG_CONFIG_HOME/meetap/config"
again "$S14"
[[ $RC != 0 && "$OUT" == *"没能用"*"重做两路相加的录音，什么都没动"* && -f "$S14/2026-11-19_1900_旧纪要.md" && ! -d "$S14/archive" ]] \
    && [[ -f "$S14/log/transcript.txt" && -f "$S14/.meetap/meeting_20261119_190005.stereo-original.m4a" ]] \
    && pass "退回失败：报错，旧纪要没被归档，转录稿和原始录音都还在" || fail "退回失败时 (rc=$RC): $OUT / $(ls "$S14")"
use_cfg

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
