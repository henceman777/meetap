#!/bin/bash
# 日历 meetap 这一侧的测试：用假的 audio-multi-output 吐 JSON、假的 claude 命令行当模型，
# 不读真实日历、不触达 AWS、不调真模型。
# 流程（2.0）：停止录音时只收候选（.meetap/calendar-candidates.json），转录完、生成纪要之前再认：
#   时间优先——起止时间最接近录音的那场；几场起止时间完全一样时按内容选；内容明显对不上就不用日历。
# 覆盖：收候选、去掉入会信息、参会人截断、meta.json、各种查不到的情况、配置开关、按音频算录音时段、
# 认会的几种结果和模型出错、again 重查（指纹 / 老文件按修改时间 / 被改过的不动）、纪要末尾那一行、
# build_prompt 读得到 calendar.md。测试数据全是编的（人名、标题、链接、会议号、密码都是假的）。
#
# 用法: test/calendar-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 真实录音在进行时一个用例都不跑
REAL_PID_FILE=/tmp/meeting-record/ffmpeg.pid
if [[ -f "$REAL_PID_FILE" ]] && kill -0 "$(cat "$REAL_PID_FILE")" 2>/dev/null; then
    echo "SKIP: 检测到正在录音（$REAL_PID_FILE → $(cat "$REAL_PID_FILE")），不跑测试"
    exit 2
fi

TMP="$(mktemp -d)"
trap '{ kill $(jobs -p); wait; } 2>/dev/null; [[ -n "${KEEP_CAL:-}" ]] && cp "$TMP/rec/20261118_1201/materials/calendar.md" "$KEEP_CAL" 2>/dev/null; rm -rf "$TMP"' EXIT

APP="$TMP/app"; FAKE="$TMP/fake"; FAKEBIN="$TMP/fakebin"
mkdir -p "$APP/i18n" "$APP/lib" "$APP/share/meetap/prompts" "$FAKE" "$FAKEBIN" "$TMP/rec" "$TMP/home"
cp "$REPO_ROOT/src/meetap" "$APP/meetap"
cp "$REPO_ROOT/src/i18n/"*.sh "$APP/i18n/"
cp "$REPO_ROOT/src/lib/ui.sh" "$APP/lib/"
cp "$REPO_ROOT/share/meetap/prompts/"*.md "$APP/share/meetap/prompts/"
MEETAP="$APP/meetap"

# 假 audio-multi-output：calendar-query 按 $FAKE/mode 吐 JSON / 卡住；每次调用记进 calls.log
cat > "$APP/audio-multi-output" <<EOF
#!/bin/bash
echo "\$*" >> "$FAKE/calls.log"
case "\$1" in
    calendar-query)
        case "\$(cat "$FAKE/mode" 2>/dev/null)" in
            hang) sleep 30 ;;
            *)    cat "$FAKE/query.json" ;;
        esac ;;
    calendar-status)  cat "$FAKE/status" 2>/dev/null || echo fullAccess ;;
    calendar-request) cat "$FAKE/status-after" 2>/dev/null || echo fullAccess ;;
    calendar-count)   echo 3 ;;
    *) exit 1 ;;
esac
EOF
# 假 claude（ai_backend = claude-code）：认会的提示词按 $FAKE/llm-mode 回答，并存下提示词；
# 生成纪要的提示词回一份带签名的假纪要
cat > "$FAKEBIN/claude" <<EOF
#!/bin/bash
[[ "\$1" == "-p" ]] || exit 2
if [[ "\$2" == *"<转录节选>"* ]]; then
    printf '%s' "\$2" > "$FAKE/cal-prompt.txt"
    echo cal >> "$FAKE/claude.log"
    case "\$(cat "$FAKE/llm-mode" 2>/dev/null)" in
        hang)    exec sleep 67 ;;
        fail)    echo "boom" >&2; exit 1 ;;
        garbage) echo "我觉得是第一场" ;;
        *)       cat "$FAKE/llm-answer" ;;
    esac
else
    echo notes >> "$FAKE/claude.log"
    printf '<!-- meetap-title: 测试纪要 -->\n# 测试纪要\n\n## 结论\n\n- 正文\n\n---\n\n<p align="center"><em>—— <strong>L</strong>isten · audio notes generator · <a href="https://github.com/henceman777/meetap">Meetap</a></em></p>\n'
fi
EOF
chmod +x "$APP"/meetap "$APP"/audio-multi-output "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
[[ "$(command -v claude)" == "$FAKEBIN/claude" ]] || { echo "ABORT: claude 不是假的"; exit 1; }
[[ ! -e "$APP/meetap-venv" ]] || { echo "ABORT: 沙盒里不该有 venv（会走真 Bedrock）"; exit 1; }

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
export MEETAP_CAL_LLM_TIMEOUT=3
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap"
use_cfg() { printf 'recording_dir = %s\nlanguage = zh-CN\nai_backend = claude-code\n%s\n' "$TMP/rec" "${1:-}" > "$XDG_CONFIG_HOME/meetap/config"; }
use_cfg

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
answer() { rm -f "$FAKE/llm-mode"; printf '%s\n' "$1" > "$FAKE/llm-answer"; }   # 假模型下一次的回答
llm_mode() { echo "$1" > "$FAKE/llm-mode"; }
S="$TMP/rec/20261118_1201"
mkdir -p "$S/materials" "$S/log"
echo "spk_0: 今天评审一下新的架构方案。" > "$S/log/transcript.txt"
echo "议程草稿" > "$S/materials/agenda.md"
CAL="$S/materials/calendar.md"
CANDS="$S/.meetap/calendar-candidates.json"
START=1794974466   # 2026-11-18 12:01:06 +08:00
END=$((START + 51 * 60))
# collect <会话> <开始> <结束>：只收候选；recognize <会话>：按内容认，OUT 里有日志和「footer: …」那一行
collect() { rm -f "$FAKE/calls.log"; OUT=$(cd "$TMP" && "$MEETAP" _calendar-collect "$1" "$2" "$3" </dev/null 2>&1); RC=$?; }
recognize() { rm -f "$FAKE/cal-prompt.txt"; OUT=$(cd "$TMP" && "$MEETAP" _calendar-recognize "$1" </dev/null 2>&1); RC=$?; }
lookup() { rm -f "$CAL"; collect "$S" "$START" "$END"; local o1="$OUT"; recognize "$S"; OUT="$o1"$'\n'"$OUT"; }
footer_of() { printf '%s\n' "$OUT" | sed -n 's/^footer: //p'; }
M="$S/.meetap/meta.json"   # 第一次写以后，根目录的老 meta.json 就挪到这里
mjson() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2])' "$@"; }   # mjson <meta.json> <python，d 是内容>

# ── 假数据 ──
python3 -I - "$FAKE" <<'PYEOF'
import json, sys
fake = sys.argv[1]
notes = """--------------------------------
议程：
1. Q4 复盘
2. 明年规划（请大家准时参加）
--------------------------------

Join Chime meeting: https://chime.aws/1234567890
Meeting ID: 1234 56 7890
One-click mobile: +1-206-555-0100,,1234567890#

Join Zoom Meeting
https://us02web.zoom.us/j/81234567890?pwd=abcDEF
Meeting ID: 812 3456 7890
Passcode: 123456
One tap mobile
+16465588656,,81234567890#,,,,*123456# US

背景材料见共享盘，有问题找 helper.person@example.com。
Dial
For better audio quality, dial a local number
________________________________________________________________________________
Microsoft Teams meeting
Join on your computer, mobile app or room device
Click here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x>
Meeting ID: 234 567 890 123
Passcode: aB3dE5
Download Teams | Join on the web
________________________________________________________________________________

会议主题：架构评审
会议时间：2026/11/18 12:00-13:00 (GMT+08:00)
点击链接入会，或添加至会议列表：
https://meeting.tencent.com/dm/AbCdEfGh
#腾讯会议：123-456-789
会议密码：4321
手机一键拨号入会
+8675536550000,,123456789# (中国大陆)
""" + "补充说明" * 200
def person(i, role="required", name=True):
    d = {"email": "user%02d@example.com" % i, "role": role, "status": "accepted", "type": "person"}
    if name:
        d["name"] = "同事%02d" % i
    return d
org = {"name": "组织者甲", "email": "boss@example.com", "role": "chair", "status": "accepted", "type": "person"}
small = [dict(org)] + [person(i) for i in range(1, 11)] + [person(11, name=False)] + \
        [{"name": "会议室 A", "email": "room-a@example.com", "role": "required", "status": "accepted", "type": "room"}]
big = [dict(org)] + [person(i, role="optional") for i in range(1, 11)] + [person(i) for i in range(11, 45)]
def cand(title, start, end, score, overlap, attendees=small, notes=notes,
         location="https://chime.aws/1234567890; 会议室 A (演示楼 101)"):
    return {"title": title, "start": start, "end": end, "overlap_sec": overlap, "time_score": score,
            "calendar": "Calendar", "organizer": org, "attendees": attendees, "attendee_count": len(attendees),
            "location": location, "notes": notes}
def query(cands, ws="2026-11-18T12:01:06+08:00", we="2026-11-18T12:52:06+08:00"):
    return {"status": "ok", "window": {"start": ws, "end": we},
            "candidates": cands, "match": cands[0] if cands else None}
def dump(name, q):
    json.dump(q, open(fake + "/" + name, "w"), ensure_ascii=False)
office = cand("迁移 office hour", "2026-11-18T12:30:00+08:00", "2026-11-18T13:00:00+08:00", 0.431, 1320,
              attendees=[], notes="", location="")
dump("q-base.json", query([cand("架构周会", "2026-11-18T12:00:00+08:00", "2026-11-18T13:00:00+08:00", 0.85, 3060), office]))
dump("q-big.json", query([cand("架构周会", "2026-11-18T12:00:00+08:00", "2026-11-18T13:00:00+08:00", 0.85, 3060, attendees=big), office]))
# 11-19 那次的真实情况（标题是编的）：09:00–12:00 的占位日程 + 11:00–12:00 的会，录音 10:53–12:09
dump("q-real.json", query([
    cand("产品分享会", "2026-11-19T11:00:00+08:00", "2026-11-19T12:00:00+08:00", 0.789, 3600, notes="议程：新功能演示"),
    cand("专注时间（占位）", "2026-11-19T09:00:00+08:00", "2026-11-19T12:00:00+08:00", 0.353, 4020, attendees=[], notes="", location="")],
    "2026-11-19T10:53:00+08:00", "2026-11-19T12:09:00+08:00"))
# 同一时段两场真会：都是 1 小时、时间完全一样
dump("q-twins.json", query([
    cand("预算评审", "2026-11-19T14:00:00+08:00", "2026-11-19T15:00:00+08:00", 0.95, 3420, notes="议程：明年预算"),
    cand("招聘同步", "2026-11-19T14:00:00+08:00", "2026-11-19T15:00:00+08:00", 0.95, 3420, notes="议程：岗位进展")],
    "2026-11-19T14:03:00+08:00", "2026-11-19T15:00:00+08:00"))
# 只有一场候选（09:44 那种：时段里有周会，录到的其实是别的）
dump("q-single.json", query([cand("团队周会", "2026-11-19T09:30:00+08:00", "2026-11-19T10:30:00+08:00", 0.72, 2760, notes="议程：周报")],
    "2026-11-19T09:44:00+08:00", "2026-11-19T10:30:00+08:00"))
PYEOF
cp "$FAKE/q-base.json" "$FAKE/query.json"

# ── 1. 停止录音时只收候选：存 .meetap/calendar-candidates.json，还不写 calendar.md ──
echo '{"schema": 1, "session": "20261118_1201", "tags": ["周会"], "future": {"x": 1}}' > "$S/meta.json"
collect "$S" "$START" "$END"
[[ $RC -eq 0 && -f "$CANDS" && ! -e "$CAL" ]] && pass "收候选：存进 .meetap/calendar-candidates.json，还不写 calendar.md" || fail "收候选 (rc=$RC): $OUT"
[[ "$OUT" == *"这个时段有 2 场会，转录完核对内容再定是哪一场"* ]] && pass "日志记一行：几场候选" || fail "日志: $OUT"
mjson "$M" '
c = d["calendar"]
assert d["tags"] == ["周会"] and d["future"] == {"x": 1}
assert c["matched_by"] == "pending" and "title" not in c, c
assert [sorted(x) for x in c["candidates"]] == [["end", "start", "time_score", "title"]] * 2, c
assert [x["title"] for x in c["candidates"]] == ["架构周会", "迁移 office hour"] and c["candidates"][0]["time_score"] == 0.85
' && pass "meta.json 的 calendar.candidates 只放标题、起止、时间分，matched_by 是 pending" || fail "meta 不对: $(cat "$M")"
[[ -f "$M" && ! -e "$S/meta.json" ]] && pass "根目录的老 meta.json 挪进了 .meetap/，不留两份" || fail "meta.json 位置: $(ls -A "$S")"
python3 -I - "$CANDS" <<'PYEOF' && pass "候选文件：正文去掉入会信息、摘录不超过 500 字、参会人没有邮箱" || fail "候选文件不对"
import json, sys
d = json.load(open(sys.argv[1]))
c = d["candidates"][0]
blob = json.dumps(d, ensure_ascii=False)
for bad in ("http", "chime.aws", "zoom.us", "123456", "aB3dE5", "example.com", "Passcode", "@"):
    assert bad not in blob, bad
assert len(c["notes_excerpt"]) <= 500 and c["notes"].startswith(c["notes_excerpt"]) and len(c["notes"]) > 500
assert c["attendees"][-1] == "user11" and "会议室 A" not in c["attendees"] and c["attendee_count"] == 12
PYEOF
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 </dev/null 2>&1)
[[ "$OUT" == *"  日历：候选 2 场，转录完按内容认"* ]] && pass "转录还没完：meetap <文件夹> 显示候选几场" || fail "信息页: $OUT"
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 -g </dev/null 2>&1)
[[ "$OUT" != *"日历标题："* ]] && pass "还没认出来：不给标签建议" || fail "不该建议: $OUT"

# ── 2. 转录完按内容认：时间最接近的只有一场，交给模型核对 ──
answer '{"pick": 1, "reason": "讨论的是架构评审"}'
recognize "$S"
[[ $RC -eq 0 && -f "$CAL" ]] && pass "认出来以后写 materials/calendar.md" || fail "没写 calendar.md (rc=$RC): $OUT"
P=$(cat "$FAKE/cal-prompt.txt" 2>/dev/null)
[[ "$P" == *"[1] 标题：架构周会"* && "$P" != *"office hour"* && "$P" != *"[2]"* ]] \
    && pass "交给模型的只有时间最接近的那场（时间优先）" || fail "提示词里的候选不对"
[[ "$P" == *"录音时间：2026-11-18 12:01–12:52"* && "$P" == *"今天评审一下新的架构方案"* && "$P" == *"agenda.md"* \
   && "$P" == *"组织者：组织者甲"* && "$P" == *"会议说明（摘录）：-------"* ]] \
    && pass "提示词里有录音时间、转录稿、materials 文件名、组织者、正文摘录" || fail "提示词缺东西: $P"
for bad in http chime.aws 123456 aB3dE5 example.com Passcode calendar.md; do
    [[ "$P" == *"$bad"* ]] && fail "提示词里有「${bad}」" || pass "提示词里没有「${bad}」"
done
grep -qF -- '- 怎么认出来的：按时间：和录音时间最接近；内容也对得上：讨论的是架构评审' "$CAL" \
    && pass "calendar.md 写明怎么认出来的" || fail "缺「怎么认出来的」: $(cat "$CAL")"
[[ "$(footer_of)" == "📅 对应日历：架构周会（时间最接近，内容也对得上：讨论的是架构评审）；同时段还有：迁移 office hour" ]] \
    && pass "纪要末尾那一行：对应哪场、凭什么、同时段还有哪些" || fail "footer: $(footer_of)"
[[ "$OUT" == *"这场会是「架构周会」（时间最接近，内容也对得上：讨论的是架构评审）"* ]] && pass "日志记一行认的结果" || fail "日志: $OUT"
grep -q '来自系统日历，是会前的安排，实际讨论以录音为准' "$CAL" && pass "开头写明来源、以录音为准" || fail "缺来源说明"
grep -q '^1. Q4 复盘$' "$CAL" && grep -q -- '^--------------------------------$' "$CAL" \
    && pass "议程夹在两条 ---- 之间：照样保留（只有下划线分隔线围起来的整段才删）" || fail "议程被分隔线规则删了"
for want in '- 标题：架构周会' '- 时间：2026-11-18 12:00–13:00（录音 12:01–12:52）' '- 组织者：组织者甲' \
            '- 地点：会议室 A (演示楼 101)' '## 会议说明' 'Q4 复盘' '明年规划（请大家准时参加）' '背景材料见共享盘' \
            '会议主题：架构评审' '会议时间：2026/11/18 12:00-13:00' '背景材料见共享盘，有问题找 helper.person。' '补充说明补充说明'; do
    grep -qF -- "$want" "$CAL" && pass "calendar.md 有「${want}」" || fail "calendar.md 缺「${want}」"
done

# 去掉入会信息（四种模板）：只查开头那句固定说明以外的内容
BODY=$(grep -v '^>' "$CAL")
for bad in 'http' 'chime.aws' 'zoom.us' 'teams.microsoft' 'meeting.tencent' '1234567890' '812 3456 7890' \
           '234 567 890 123' '123-456-789' '123456' 'aB3dE5' '4321' '+1' '+86' 'Passcode' 'Meeting ID' \
           '密码' '拨号' 'Join' '入会' '____' 'pwd' 'Dial' 'dial' 'example.com'; do
    grep -qF -- "$bad" <<< "$BODY" && fail "calendar.md 里还有「${bad}」" || pass "去掉了「${bad}」"
done

# 参会人：12 人全列，组织者单列不重复，会议室不算人，没名字的只写邮箱 @ 前面
line=$(grep '^- 参会人' "$CAL")
[[ "$line" == "- 参会人（12 人）：同事01、"*"同事10、user11" && "$line" != *"组织者甲"* && "$line" != *"会议室"* ]] \
    && pass "12 人全列：组织者单列、会议室不算、没名字的只写邮箱前缀" || fail "参会人: $line"
grep -q '@' "$CAL" && fail "calendar.md 里出现了邮箱" || pass "calendar.md 里没有邮箱"

# meta.json：calendar 字段对，tags 和不认识的字段原样保留
mjson "$M" '
import hashlib
c = d["calendar"]
assert d["tags"] == ["周会"] and d["future"] == {"x": 1} and d["schema"] == 1
assert c["title"] == "架构周会" and c["organizer"] == "组织者甲" and c["attendee_count"] == 12
assert c["start"] == "2026-11-18T12:00:00+08:00" and c["end"] == "2026-11-18T13:00:00+08:00"
assert c["matched_by"] == "time" and c["reason"] == "讨论的是架构评审" and c["looked_up_at"]
assert [x["title"] for x in c["candidates"]] == ["架构周会", "迁移 office hour"]
assert c["fingerprint"] == hashlib.sha256(open(sys.argv[1].replace(".meetap/meta.json", "materials/calendar.md"), "rb").read()).hexdigest()
' && pass "meta.json：这场会的字段、matched_by、理由、指纹都对，tags 和不认识的字段还在" || fail "meta.json 不对: $(cat "$M")"
grep -q 'office hour' "$CAL" && fail "别的候选写进了 calendar.md" || pass "别的候选只进 meta.json，不进 calendar.md"
python3 -m json.tool "$M" >/dev/null && pass "meta.json 是合法 JSON" || fail "meta.json 坏了"
[[ -z "$(find "$S" -name '.cal.*' -o -name '.calendar.*' -o -name '.meta.*')" ]] && pass "写完不留临时文件" || fail "有残留临时文件"

# ── 3. 超过 30 人：calendar.md 只留组织者、前 20 位和总人数，必选在可选前面；给模型的也只有 20 位 ──
cp "$FAKE/q-big.json" "$FAKE/query.json"
lookup
line=$(grep '^- 参会人' "$CAL")
n=$(printf '%s' "${line#*：*：}" | tr '、' '\n' | grep -c .)
[[ "$line" == "- 参会人：共 45 人，下面只列组织者和前 20 位："* && "$n" == 20 && "$line" == *"同事11"* && "$line" != *"同事01"* ]] \
    && grep -q '^- 组织者：组织者甲' "$CAL" \
    && pass "45 人：只列组织者和前 20 位、写明总人数，必选参会人排在可选前面" || fail "截断不对（$n 位）: $line"
pl=$(grep '参会人（共' "$FAKE/cal-prompt.txt")
[[ "$pl" == *"参会人（共 45 人，列前 20 位）"* && $(printf '%s' "${pl#*：}" | tr '、' '\n' | grep -c .) -eq 20 ]] \
    && pass "给模型的参会人只列前 20 位" || fail "提示词里的参会人: $pl"
cp "$FAKE/q-base.json" "$FAKE/query.json"

# ── 4. 查不到：不写文件、不报错、不动 meta.json，只记一行日志 ──
lookup
cp "$M" "$TMP/meta.before"
scenario() {   # scenario <说明> <期望日志片段> ：$FAKE/query.json 已就位
    cp "$TMP/cands.keep" "$CANDS"
    rm -f "$CAL"; collect "$S" "$START" "$END"
    if [[ $RC -eq 0 && ! -e "$CAL" && "$OUT" == *"$2"* && $(printf '%s\n' "$OUT" | grep -c .) -le 1 ]] \
       && cmp -s "$M" "$TMP/meta.before" && cmp -s "$CANDS" "$TMP/cands.keep"; then
        pass "$1：不写文件、不动 meta.json 和候选、退出码 0"
    else
        fail "$1 (rc=$RC): $OUT"
    fi
}
cp "$CANDS" "$TMP/cands.keep"
echo '{"status":"not_authorized","auth":"writeOnly","window":{}}' > "$FAKE/query.json"; scenario "只有写入权限" "没有读取权限（writeOnly）"
echo '{"status":"not_authorized","auth":"notDetermined","window":{}}' > "$FAKE/query.json"; scenario "还没授权" "没有读取权限（notDetermined）"
echo '{"status":"timeout","window":{}}' > "$FAKE/query.json";                          scenario "查询超时" "查询超时"
echo '{"status":"error","window":{}}' > "$FAKE/query.json";                            scenario "查询出错" "查询出错"
echo 'not json {' > "$FAKE/query.json";                                                scenario "JSON 坏了" "查询出错"
: > "$FAKE/query.json";                                                                scenario "什么都没输出" "查询出错"
echo hang > "$FAKE/mode"
t0=$(date +%s); scenario "查询程序卡住" "查询出错"; took=$(( $(date +%s) - t0 ))
[[ $took -le 14 ]] && pass "查询程序卡住时 ${took}s 内被强杀（上限 12s）" || fail "卡住时等了 ${took}s"
rm -f "$FAKE/mode"
cp "$FAKE/q-base.json" "$FAKE/query.json"
mv "$APP/audio-multi-output" "$APP/amo.off"
collect "$S" "$START" "$END"
[[ $RC -eq 0 && -z "$OUT" && ! -e "$CAL" ]] && pass "查询程序不存在：不出声、不写文件" || fail "查询程序不存在 (rc=$RC): $OUT"
mv "$APP/amo.off" "$APP/audio-multi-output"
# 这个时段一场会都没有：去掉候选和 meta 里过期的 calendar，标签照旧；没有 meta.json 的不为此新建
echo '{"status":"ok","window":{},"match":null,"candidates":[]}' > "$FAKE/query.json"
collect "$S" "$START" "$END"
[[ $RC -eq 0 && ! -e "$CAL" && ! -e "$CANDS" && "$OUT" == *"没有对应的会"* ]] \
    && mjson "$M" 'assert "calendar" not in d and d["tags"] == ["周会"]' \
    && pass "没有候选：去掉过期的候选和 calendar 字段，标签还在" || fail "没有候选 (rc=$RC): $OUT / $(cat "$M")"
recognize "$S"
[[ -z "$(footer_of)" && ! -e "$FAKE/cal-prompt.txt" ]] && pass "没有候选：不调模型，纪要末尾不加那一行" || fail "没有候选时: $OUT"
S0="$TMP/rec/20261118_0800"; mkdir -p "$S0"
collect "$S0" "$START" "$END"
[[ ! -e "$S0/.meetap/meta.json" && ! -e "$S0/meta.json" ]] && pass "没有候选、也没有 meta.json：不新建" || fail "新建了 meta.json"
cp "$FAKE/q-base.json" "$FAKE/query.json"

# ── 5. 配置 calendar = off：完全不碰日历，也不调认会的模型 ──
lookup
use_cfg "calendar = off"
rm -f "$CAL"
collect "$S" "$START" "$END"
[[ $RC -eq 0 && -z "$OUT" && ! -e "$CAL" && ! -e "$FAKE/calls.log" ]] && pass "calendar = off：查询程序一次都没被调用" || fail "off 时还是查了: $OUT"
recognize "$S"
[[ ! -e "$FAKE/cal-prompt.txt" && ! -e "$CAL" && -z "$(footer_of)" ]] && pass "calendar = off：候选文件还在也不调模型" || fail "off 时调了模型: $OUT"
use_cfg

# ── 6. 查询流程从不请求授权 ──
grep -rq 'calendar-request' "$FAKE/calls.log" 2>/dev/null && fail "查询流程调用了 calendar-request" || pass "查询流程从不调用 calendar-request"

# ── 7. 认会的各种情况（任务说明里点名的那几种） ──
R="$TMP/rec/20261119_1053"; mkdir -p "$R/log" "$R/materials"
echo "spk_0: 下面演示一下新功能。" > "$R/log/transcript.txt"
RS=$(date -j -f "%Y%m%d_%H%M%S" 20261119_105300 +%s); RE=$((RS + 76 * 60))
run_case() {   # run_case <查询 JSON> <会话> <开始> <结束>
    cp "$FAKE/$1" "$FAKE/query.json"; rm -f "$2/materials/calendar.md"
    collect "$2" "$3" "$4"; recognize "$2"
}
# 7a. 这次的真实情况：占位 09:00–12:00 + 会 11:00–12:00，录音 10:53–12:09 → 11:00 那场
answer '{"pick": 1, "reason": "在演示新功能"}'
run_case q-real.json "$R" "$RS" "$RE"
P=$(cat "$FAKE/cal-prompt.txt")
[[ "$P" == *"[1] 标题：产品分享会"* && "$P" != *"占位"* ]] && pass "真实情况：时间最接近的是 11:00 那场，占位日程不交给模型" || fail "真实情况的提示词: $P"
grep -qF -- '- 标题：产品分享会' "$R/materials/calendar.md" && mjson "$R/.meetap/meta.json" 'assert d["calendar"]["matched_by"] == "time"' \
    && [[ "$(footer_of)" == "📅 对应日历：产品分享会（时间最接近，内容也对得上：在演示新功能）；同时段还有：专注时间（占位）" ]] \
    && pass "真实情况：认出 11:00–12:00 那场，纪要末尾写明同时段还有占位日程" || fail "真实情况: $OUT"
# 假模型回了一个不存在的序号：当作出错，时间最接近的只有一场，照时间定
answer '{"pick": 2, "reason": "占位那场"}'
run_case q-real.json "$R" "$RS" "$RE"
grep -qF -- '- 标题：产品分享会' "$R/materials/calendar.md" && [[ "$(footer_of)" == "📅 对应日历：产品分享会（按时间认出；认会的模型回的序号不在候选里，内容没核对）；同时段还有：专注时间（占位）" ]] \
    && pass "模型回的序号不在候选里：按时间定，写明内容没核对" || fail "序号越界: $(footer_of) / $OUT"

# 7b. 同一时段两场真会（时间完全一样）：按模型选的那场定
T="$TMP/rec/20261119_1403"; mkdir -p "$T/log" "$T/materials"
echo "spk_0: 我们看一下几个岗位的进展。" > "$T/log/transcript.txt"
TS=$(date -j -f "%Y%m%d_%H%M%S" 20261119_140300 +%s); TE=$((TS + 57 * 60))
answer '{"pick": 2, "reason": "讨论的是岗位进展"}'
run_case q-twins.json "$T" "$TS" "$TE"
P=$(cat "$FAKE/cal-prompt.txt")
[[ "$P" == *"共 2 场"* && "$P" == *"[1] 标题：预算评审"* && "$P" == *"[2] 标题：招聘同步"* ]] && pass "两场时间完全一样：两场都交给模型" || fail "两场的提示词: $P"
grep -qF -- '- 标题：招聘同步' "$T/materials/calendar.md" && grep -qF -- '- 怎么认出来的：按内容：同一时间有 2 场，讨论的是岗位进展' "$T/materials/calendar.md" \
    && mjson "$T/.meetap/meta.json" 'assert d["calendar"]["matched_by"] == "content" and d["calendar"]["title"] == "招聘同步"' \
    && [[ "$(footer_of)" == "📅 对应日历：招聘同步（同一时间有 2 场，按内容认出：讨论的是岗位进展）；同时段还有：预算评审" ]] \
    && pass "两场时间完全一样：按模型选的第 2 场定，matched_by 记 content" || fail "两场: $(footer_of) / $OUT"
answer '{"pick": 1, "reason": "讨论的是预算"}'
run_case q-twins.json "$T" "$TS" "$TE"
grep -qF -- '- 标题：预算评审' "$T/materials/calendar.md" && pass "两场时间完全一样：模型选第 1 场就是第 1 场" || fail "两场选 1: $OUT"
OUT=$(cd "$TMP" && "$MEETAP" 20261119_1403 </dev/null 2>&1)
[[ "$OUT" == *"  日历：预算评审（14:00–15:00，同一时间有几场，按内容认出）"* ]] && pass "meetap <文件夹>：标明按内容认出" || fail "信息页: $OUT"

# 7c. 内容都对不上：只有一场候选，模型回 null → 不写 calendar.md，末尾那行写「都不是」
W="$TMP/rec/20261119_0944"; mkdir -p "$W/log" "$W/materials"
echo "spk_0: 今天的国际新闻评论。" > "$W/log/transcript.txt"
WS=$(date -j -f "%Y%m%d_%H%M%S" 20261119_094400 +%s); WE=$((WS + 46 * 60))
answer '{"pick": null, "reason": "录到的是新闻评论，不是周会"}'
run_case q-single.json "$W" "$WS" "$WE"
[[ ! -e "$W/materials/calendar.md" && -f "$W/.meetap/calendar-candidates.json" ]] \
    && mjson "$W/.meetap/meta.json" 'c = d["calendar"]; assert c["matched_by"] == "none" and "title" not in c and len(c["candidates"]) == 1 and c["reason"]' \
    && [[ "$(footer_of)" == "📅 同时段日历里有 团队周会，按内容判断都不是这场（录到的是新闻评论，不是周会）" ]] \
    && pass "只有一场、模型回 null：不写 calendar.md，matched_by 记 none，候选留着，末尾那行写都不是" || fail "null: $(footer_of) / $OUT"
[[ "$OUT" == *"同时段的 1 场会按内容判断都不是这场"* ]] && pass "日志记一行「都不是」" || fail "日志: $OUT"
OUT=$(cd "$TMP" && "$MEETAP" 20261119_0944 </dev/null 2>&1)
[[ "$OUT" == *"  日历：同时段有 1 场会，按内容判断都不是这场"* ]] && pass "meetap <文件夹>：显示都不是" || fail "信息页: $OUT"
OUT=$(cd "$TMP" && "$MEETAP" 20261119_0944 -g </dev/null 2>&1)
[[ "$OUT" != *"日历标题："* ]] && pass "matched_by 是 none：不给标签建议" || fail "不该建议: $OUT"

# 7d. 模型出错的三种情况：调用失败、超时、回的不是 JSON
for mode in fail hang garbage; do
    case $mode in fail) why="调用失败" ;; hang) why="超时" ;; garbage) why="回的不是 JSON" ;; esac
    llm_mode $mode
    t0=$(date +%s); run_case q-real.json "$R" "$RS" "$RE"; took=$(( $(date +%s) - t0 ))
    grep -qF -- '- 标题：产品分享会' "$R/materials/calendar.md" && mjson "$R/.meetap/meta.json" 'assert d["calendar"]["matched_by"] == "time"' \
        && [[ "$(footer_of)" == "📅 对应日历：产品分享会（按时间认出；认会的模型${why}，内容没核对）；同时段还有：专注时间（占位）" ]] \
        && pass "模型${why}：时间最接近的只有一场，按时间定（matched_by 记 time）" || fail "模型${why}: $(footer_of) / $OUT"
    llm_mode $mode
    run_case q-twins.json "$T" "$TS" "$TE"
    [[ ! -e "$T/materials/calendar.md" ]] && mjson "$T/.meetap/meta.json" 'assert d["calendar"]["matched_by"] == "none"' \
        && [[ "$(footer_of)" == "📅 同时段日历里有 预算评审、招聘同步，其中 2 场时间完全一样，认会的模型${why}，没能按内容认出是哪一场，没有用日历" ]] \
        && pass "模型${why}：两场时间完全一样，分不出就不用日历" || fail "模型${why}（两场）: $(footer_of) / $OUT"
    if [[ $mode != garbage ]]; then
        [[ "$OUT" == *"认会的模型没给出可用的回答"* ]] && pass "模型${why}：日志里记一行原因" || fail "模型${why}的日志: $OUT"
    fi
    if [[ $mode == hang ]]; then
        [[ $took -le 8 ]] && pass "模型卡住：${took}s 内放弃（测试里上限 3s）" || fail "模型卡住等了 ${took}s"
        sleep 0.5; pgrep -f 'sleep 67' >/dev/null && fail "模型卡住：留下了子进程" || pass "模型卡住：子进程一起杀掉，没有残留"
    fi
done
rm -f "$FAKE/llm-mode"
cp "$FAKE/q-base.json" "$FAKE/query.json"

# ── 8. 按音频算录音时段；again 重查：meetap 写的、没被改过的才重查 ──
if command -v ffmpeg >/dev/null; then
    S2="$TMP/rec/20261118_1400"; mkdir -p "$S2/materials" "$S2/log"
    echo "spk_0: 架构评审开始。" > "$S2/log/transcript.txt"
    ffmpeg -v quiet -f lavfi -i anullsrc=r=48000:cl=mono -t 95 -c:a aac "$S2/meeting_20261118_140006.m4a" </dev/null
    rm -f "$FAKE/calls.log"
    (cd "$TMP" && "$MEETAP" _calendar-collect "$S2" </dev/null >/dev/null 2>&1)
    want_start=$(date -j -f "%Y%m%d_%H%M%S" 20261118_140006 +%s)
    grep -q -- "--start $want_start --end $((want_start + 95)) " "$FAKE/calls.log" \
        && pass "按音频算录音时段：开始 = 文件名时间，结束 = 开始 + 音频时长" || fail "时段不对: $(cat "$FAKE/calls.log")"
    answer '{"pick": 1, "reason": "架构评审"}'
    recognize "$S2"
    S2CAL="$S2/materials/calendar.md"; S2M="$S2/.meetap/meta.json"
    recheck() { rm -f "$FAKE/calls.log" "$FAKE/claude.log"; OUT=$(cd "$TMP" && "$MEETAP" _calendar-collect "$S2" </dev/null 2>&1; "$MEETAP" _calendar-recognize "$S2" </dev/null 2>&1); }
    # 新文件：指纹对得上 → 重新收、重新认、覆盖
    answer '{"pick": 1, "reason": "第二次认"}'
    recheck
    [[ -f "$FAKE/calls.log" ]] && grep -q '第二次认' "$S2CAL" && pass "again：指纹对得上（meetap 写的、没改过）→ 重新查、覆盖" || fail "指纹对得上却没重查: $OUT"
    # 被人改过：指纹对不上 → 不动，提示一句
    echo "用户自己补的一行" >> "$S2CAL"; cp "$S2CAL" "$TMP/s2.before"
    recheck
    [[ ! -e "$FAKE/calls.log" && ! -e "$FAKE/claude.log" ]] && cmp -s "$S2CAL" "$TMP/s2.before" && [[ "$OUT" == *"不是 meetap 写的，或者被改过，原样留着"* ]] \
        && pass "again：被人改过的 calendar.md 不动、不重查、不调模型，提示一句" || fail "改过的被动了: $OUT"
    # 2.0 之前写的老文件（没有指纹）：修改时间和 looked_up_at 相差 60 秒以内 → 当作 meetap 写的，重查
    legacy() {   # legacy <looked_up_at 比文件修改时间晚几秒>
        python3 -I - "$S2M" "$1" <<'PYEOF'
import json, sys, os
from datetime import datetime, timedelta
p, lag = sys.argv[1], int(sys.argv[2])
d = json.load(open(p))
cal_md = p.replace(".meetap/meta.json", "materials/calendar.md")
open(cal_md, "w").write("# 日历里的这场会\n\n- 标题：老版本写的\n")
t = datetime.fromtimestamp(os.path.getmtime(cal_md)).astimezone() + timedelta(seconds=lag)
d["calendar"] = {"title": "老版本写的", "start": "2026-11-18T14:00:00+08:00", "end": "2026-11-18T15:00:00+08:00",
                 "candidates": ["老版本写的"], "looked_up_at": t.isoformat(timespec="seconds")}
json.dump(d, open(p, "w"), ensure_ascii=False)
PYEOF
    }
    legacy 30
    OUT=$(cd "$TMP" && "$MEETAP" 20261118_1400 </dev/null 2>&1)
    [[ "$OUT" == *"  日历：老版本写的（14:00–15:00）"* ]] && pass "老 meta.json（没有 matched_by）：信息页照老样子显示" || fail "老信息页: $OUT"
    answer '{"pick": 1, "reason": "老文件重认"}'
    recheck
    grep -q '老文件重认' "$S2CAL" && mjson "$S2M" 'assert d["calendar"]["fingerprint"]' \
        && pass "again：没有指纹的老文件、修改时间在 looked_up_at 前后 60 秒内 → 重查覆盖，补上指纹" || fail "老文件没重查: $OUT"
    legacy 600
    cp "$S2CAL" "$TMP/s2.before"
    recheck
    [[ ! -e "$FAKE/calls.log" ]] && cmp -s "$S2CAL" "$TMP/s2.before" && [[ "$OUT" == *"原样留着"* ]] \
        && pass "again：没有指纹的老文件、修改时间差了 10 分钟 → 当作被改过，不动" || fail "老文件（改过）被动了: $OUT"
    # 用户自己放进来的 calendar.md（meta 里没有日历记录）：不动
    rm -f "$S2CAL"; mjson "$S2M" 'd.pop("calendar"); json.dump(d, open(sys.argv[1], "w"))'
    echo "我自己写的会议背景" > "$S2CAL"
    recheck
    [[ ! -e "$FAKE/calls.log" && "$(cat "$S2CAL")" == "我自己写的会议背景" ]] && pass "用户自己放的 calendar.md：不查、不覆盖" || fail "自己放的被覆盖了: $OUT"
else
    echo "SKIP: 没装 ffmpeg，跳过按音频算时段和 again 重查的用例"
fi

# ── 9. build_prompt 会把 calendar.md 当资料读进去（不改纪要的提示词模板） ──
answer '{"pick": 1, "reason": "架构评审"}'
lookup
echo "spk_0: 100%" > "$S/log/speaker-stats.txt"
PROMPT=$(
    SCRIPT_DIR="$REPO_ROOT/src"
    _tn() { local k="MSG_$1"; shift; printf "${!k:-<missing>}" "$@"; }
    eval "$(sed -n '/^build_prompt() {/,/^}/p' "$REPO_ROOT/src/meetap")"
    build_prompt "$S" 2>/dev/null
)
[[ "$PROMPT" == *"<会议资料>"*"### 资料: calendar.md"*"日历里的这场会"*"以录音为准"*"</会议资料>"* ]] \
    && pass "build_prompt 把 calendar.md 放进 <会议资料>" || fail "提示词里没有 calendar.md"
git -C "$REPO_ROOT" diff --quiet HEAD -- share/meetap/prompts/meeting-notes.md && pass "纪要的提示词模板没改" || fail "纪要的提示词被改了"

# ── 10. meetap <文件夹>：显示日历标题和按什么认的 ──
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 </dev/null 2>&1)
[[ "$OUT" == *"  日历：架构周会（12:00–13:00，按时间认出）"* ]] && pass "meetap <文件夹> 显示日历标题、时段、按什么认的" || fail "信息页: $OUT"
S3="$TMP/rec/20261118_0900"; mkdir -p "$S3"
OUT=$(cd "$TMP" && "$MEETAP" 20261118_0900 </dev/null 2>&1)
[[ "$OUT" != *"日历："* ]] && pass "没有日历信息的会不显示日历那一行" || fail "不该显示日历: $OUT"

# ── 11. 列标签时把认出来的那场的标题当建议，只提示、不自动贴 ──
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 -g </dev/null 2>&1)
[[ "$OUT" == *"日历标题：架构周会，要贴的话：meetap 20261118_1201 -g 架构周会"* ]] \
    && pass "meetap <文件夹> -g：建议的命令里带上文件夹" || fail "指定文件夹的建议: $OUT"
mjson "$M" 'assert d["tags"] == ["周会"]' && pass "只提示，没有自动贴标签" || fail "被自动贴了标签: $(cat "$M")"
(cd "$TMP" && "$MEETAP" 20261118_1201 -g 架构周会 </dev/null >/dev/null 2>&1)
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 -g </dev/null 2>&1)
[[ "$OUT" != *"日历标题："* ]] && pass "日历标题已经是标签了就不再提示" || fail "还在提示: $OUT"
mjson "$M" 'd["calendar"]["title"] = "Weekly Sync"; d["tags"] = ["周会"]; json.dump(d, open(sys.argv[1], "w"), ensure_ascii=False)'
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 -g </dev/null 2>&1)
[[ "$OUT" == *"要贴的话：meetap 20261118_1201 -g 'Weekly Sync'"* ]] && pass "标题带空格时，建议的命令加了引号，照抄能用" || fail "带空格的建议: $OUT"
rm -rf "$S2" "$S3" "$R" "$T" "$W" "$S0"   # 下面要用「最新一场」，留 S 一场
OUT=$(cd "$TMP" && "$MEETAP" -g </dev/null 2>&1)
[[ "$OUT" == *"日历标题：Weekly Sync，要贴的话：meetap -g 'Weekly Sync'"* ]] \
    && pass "meetap -g：提示日历标题和要贴的话怎么写" || fail "默认目标的建议: $OUT"

# ── 12. setup 的日历授权一步：只有这里会请求授权；拒绝、跳过都算通过 ──
printf '#!/bin/bash\ncase "$1" in tap-supported) echo yes ;; tap-start) printf xxxx ;; *) exit 1 ;; esac\n' > "$APP/audio-tap"
for c in afplay osascript open; do printf '#!/bin/bash\necho "%s $*" >> "%s/sys.log"\n' "$c" "$TMP" > "$FAKEBIN/$c"; done
chmod +x "$APP/audio-tap" "$FAKEBIN/"*
setup_run() {   # setup_run <授权状态> <请求后的状态> <tty|notty> [TERM_PROGRAM]
    echo "$1" > "$FAKE/status"; echo "$2" > "$FAKE/status-after"; rm -f "$FAKE/calls.log"
    if [[ "$3" == tty ]]; then
        OUT=$({ sleep 1; sleep 3; } | HOME="$TMP/home" TERM_PROGRAM="${4:-}" script -q /dev/null "$MEETAP" setup 2>&1); RC=$?
    else
        OUT=$(cd "$TMP" && HOME="$TMP/home" TERM_PROGRAM="${4:-}" "$MEETAP" setup </dev/null 2>&1); RC=$?
    fi
    REQ=$(grep -c '^calendar-request' "$FAKE/calls.log" 2>/dev/null)
}
setup_run fullAccess fullAccess notty
[[ $RC -eq 0 && "$OUT" == *"【3/3】日历授权（可选）"* && "$OUT" == *"日历已授权，能读到 3 个日历"* && "$REQ" == 0 ]] \
    && pass "已授权：显示能读到几个日历，不请求" || fail "已授权 (rc=$RC req=$REQ): $OUT"
setup_run notDetermined fullAccess notty
[[ $RC -eq 0 && "$OUT" == *"需要在终端里交互运行 meetap setup"* && "$REQ" == 0 ]] \
    && pass "还没授权、没有终端：不请求，跳过" || fail "没终端 (rc=$RC req=$REQ): $OUT"
setup_run notDetermined fullAccess tty
[[ "$OUT" == *"马上会弹出授权框"* && "$OUT" == *"日历已授权，能读到 3 个日历"* && "$REQ" == 1 ]] \
    && pass "还没授权、有终端：先说明用途，再请求一次" || fail "有终端请求 (req=$REQ): $OUT"
setup_run notDetermined denied tty ghostty
[[ "$OUT" == *"没有授权读日历"*"给 Ghostty 打开「完全访问」"*"重新打开 Ghostty"* && "$REQ" == 1 ]] \
    && pass "用户拒绝：算通过，提示以后去哪儿打开（写出终端 App 名）" || fail "拒绝 (req=$REQ): $OUT"
setup_run writeOnly writeOnly tty ghostty
[[ "$OUT" == *"只有「写入」权限"*"系统设置 › 隐私与安全性 › 日历"*"把 Ghostty 改成「完全访问」"*"重新打开 Ghostty 才生效"* && "$REQ" == 1 ]] \
    && pass "只有写入权限：请求一次升级；还不行就写明去哪儿改、改完要重开终端" || fail "只写 (req=$REQ): $OUT"
setup_run writeOnly writeOnly notty Apple_Terminal
[[ "$OUT" == *"把 终端 改成「完全访问」"* && "$REQ" == 0 ]] \
    && pass "只有写入权限、没有终端：不请求，照样写明去哪儿改（苹果「终端」）" || fail "只写没终端 (req=$REQ): $OUT"
setup_run denied denied notty
[[ $RC -eq 0 && "$OUT" == *"没有授权读日历"* && "$REQ" == 0 ]] && pass "已拒绝：不再请求，退出码 0" || fail "已拒绝 (rc=$RC req=$REQ): $OUT"
use_cfg "calendar = off"
setup_run fullAccess fullAccess notty
[[ "$OUT" == *"calendar = off，不读日历"* ]] && ! grep -q '^calendar-' "$FAKE/calls.log" 2>/dev/null \
    && pass "calendar = off：setup 也不碰日历（没有任何 calendar- 调用）" || fail "off 时 setup: $(cat "$FAKE/calls.log")"
use_cfg
[[ ! -e "$TMP/sys.log" ]] || ! grep -qv '^afplay' "$TMP/sys.log" \
    && pass "setup 没有打开系统设置、没有调用 osascript" || fail "setup 调用了: $(cat "$TMP/sys.log")"

# ── 13. 挂接点：转录开始前收候选（stop 的后台流程和 again 从转录重跑走的是同一个 transcribe_recording）──
#        用 again 来测，不碰 stop 里的全局 pkill；假 aws 只让它走到凭证检查，不上传
if command -v ffmpeg >/dev/null; then
    printf '#!/bin/bash\necho "aws $*" >> "%s/aws.log"\nexit 1\n' "$TMP" > "$FAKEBIN/aws"
    chmod +x "$FAKEBIN/aws"
    S4="$TMP/rec/20261118_1500"; mkdir -p "$S4/materials"
    ffmpeg -v quiet -f lavfi -i "sine=frequency=1000:duration=65" -c:a aac "$S4/meeting_20261118_150005.m4a" </dev/null
    rm -f "$FAKE/calls.log" "$TMP/aws.log" "$FAKE/claude.log"
    OUT=$(cd "$TMP" && HOME="$TMP/home" "$MEETAP" again "$S4" </dev/null 2>&1)
    s4=$(date -j -f "%Y%m%d_%H%M%S" 20261118_150005 +%s)
    grep -q -- "calendar-query --start $s4 --end $((s4 + 65)) " "$FAKE/calls.log" && [[ -f "$S4/.meetap/calendar-candidates.json" && ! -e "$S4/materials/calendar.md" ]] \
        && grep -q '这个时段有 2 场会' "$S4/log/meetap.log" && [[ ! -e "$FAKE/claude.log" ]] \
        && pass "转录开始前收候选：按音频算时段、只存候选、日志里记一行；转录没完不调模型" || fail "转录前没收候选: $(cat "$FAKE/calls.log" 2>/dev/null)"
    # 假 aws 查凭证时报不认识的错：最多试 3 次就停（凭证、网络问题才会一直等）
    [[ -z "$(grep -v '^aws sts get-caller-identity' "$TMP/aws.log")" && $(grep -c . "$TMP/aws.log") -le 3 ]] \
        && pass "这条测试没有上传任何东西（假 aws 只被问了凭证）" || fail "aws 调用: $(cat "$TMP/aws.log" 2>/dev/null)"
    # again 只重跑纪要（已有转录）：收候选、认会、生成纪要（假 claude），末尾那一行插在签名前
    S5="$TMP/rec/20261118_1600"; mkdir -p "$S5/materials" "$S5/log"
    cp "$S4/meeting_20261118_150005.m4a" "$S5/meeting_20261118_160005.m4a"
    echo "spk_0: 架构评审开始。" > "$S5/log/transcript.txt"
    answer '{"pick": 1, "reason": "讨论的是架构评审"}'
    rm -f "$FAKE/calls.log" "$TMP/aws.log" "$FAKE/claude.log"
    OUT=$(cd "$TMP" && HOME="$TMP/home" "$MEETAP" again "$S5" </dev/null 2>&1)
    NOTES="$S5/2026-11-18_1600_测试纪要.md"
    [[ -f "$S5/materials/calendar.md" && "$OUT" == *"这场会是「架构周会」"* && ! -e "$TMP/aws.log" && "$(cat "$FAKE/claude.log")" == $'cal\nnotes' ]] \
        && pass "again 只重跑纪要：先认会、再生成纪要（认会在前，纪要能读到 calendar.md）" || fail "again 纪要路径: $OUT / $(cat "$FAKE/claude.log" 2>/dev/null)"
    python3 -I - "$NOTES" <<'PYEOF' && pass "纪要末尾那一行插在签名分割线前面，签名仍是最后一行" || fail "纪要末尾: $(tail -8 "$NOTES" 2>/dev/null)"
import sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().split("\n")]
body = [l for l in lines if l.strip()]
assert "github.com/henceman777/meetap" in body[-1], body[-3:]
assert body[-2] == "---" and body[-3] == "📅 对应日历：架构周会（时间最接近，内容也对得上：讨论的是架构评审）；同时段还有：迁移 office hour", body[-4:]
i = lines.index(body[-3])
assert lines[i - 1] == "" and lines[i + 1] == "", lines[i - 2:i + 3]
PYEOF
    grep -q 'calendar-request' "$FAKE/calls.log" && fail "转录 / again 流程请求了授权" || pass "转录 / again 流程从不请求授权"
    # 找不到签名：加在文件最后；没有候选：不加
    printf '# 纪要\n\n正文\n' > "$TMP/nosig.md"
    python3 -I -c "$(sed -n "/^_calendar_py() {/,/^CALPY/p" "$MEETAP" | sed '1,2d;$d')" footer-insert "$TMP/nosig.md" "📅 测试行" 2>/dev/null
    [[ "$(grep -v '^$' "$TMP/nosig.md" | tail -1)" == "📅 测试行" ]] && pass "找不到签名：那一行加在文件最后" || fail "没签名时: $(cat "$TMP/nosig.md")"
    use_cfg "calendar = off"
    rm -f "$FAKE/claude.log"
    OUT=$(cd "$TMP" && HOME="$TMP/home" "$MEETAP" again "$S5" </dev/null 2>&1)
    N2=$(ls -t "$S5"/2026-11-18_1600_*.md | head -1)
    [[ "$(cat "$FAKE/claude.log")" == "notes" ]] && ! grep -q '📅' "$N2" && pass "calendar = off：不调认会的模型，纪要末尾不加那一行" || fail "off 时纪要: $(cat "$FAKE/claude.log")"
    use_cfg
else
    echo "SKIP: 没装 ffmpeg，跳过挂接点的用例"
fi

# ── 14. 中英两份提示语 key 一致；认会的提示词模板占位符都在 ──
diff <(grep -oE '^MSG_[A-Z_0-9]+' "$REPO_ROOT/src/i18n/messages-zh-CN.sh" | sort) \
     <(grep -oE '^MSG_[A-Z_0-9]+' "$REPO_ROOT/src/i18n/messages-en-US.sh" | sort) >/dev/null \
    && pass "中英两份提示语的 key 一致" || fail "中英提示语 key 不一致"
for ph in recording candidate_count candidates materials_list transcript_excerpt; do
    grep -qF "\${$ph}" "$REPO_ROOT/share/meetap/prompts/calendar-match.md" && pass "认会模板里有 \${$ph}" || fail "认会模板缺 \${$ph}"
done

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
