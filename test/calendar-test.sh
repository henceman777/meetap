#!/bin/bash
# 日历（第三批）meetap 这一侧的测试：用假的 audio-multi-output 吐 JSON，不读真实日历、不触达 AWS。
# 覆盖：写 materials/calendar.md、去掉入会信息、参会人截断、meta.json、各种查不到的情况、
# 配置开关、按音频算录音时段、build_prompt 读得到 calendar.md。
# 测试数据全是编的（人名、链接、会议号、密码都是假的）。
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

APP="$TMP/app"; FAKE="$TMP/fake"
mkdir -p "$APP/i18n" "$APP/lib" "$FAKE" "$TMP/rec"
cp "$REPO_ROOT/src/meetap" "$APP/meetap"
cp "$REPO_ROOT/src/i18n/"*.sh "$APP/i18n/"
cp "$REPO_ROOT/src/lib/ui.sh" "$APP/lib/"
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
chmod +x "$APP"/meetap "$APP"/audio-multi-output

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap"
use_cfg() { printf 'recording_dir = %s\nlanguage = zh-CN\n%s\n' "$TMP/rec" "${1:-}" > "$XDG_CONFIG_HOME/meetap/config"; }
use_cfg

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
S="$TMP/rec/20261118_1201"
mkdir -p "$S/materials" "$S/log"
CAL="$S/materials/calendar.md"
START=1794974466   # 2026-11-18 12:01:06 +08:00
END=$((START + 51 * 60))
lookup() { rm -f "$CAL" "$FAKE/calls.log"; OUT=$(cd "$TMP" && "$MEETAP" _calendar-lookup "$S" "$START" "$END" </dev/null 2>&1); RC=$?; }
meta_cal() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get("calendar"), ensure_ascii=False, sort_keys=True))' "$S/meta.json" 2>/dev/null; }

# ── 假数据：一场 12 人的会，正文里带 Chime / Zoom / Teams / 腾讯会议四种入会信息 ──
python3 -I - "$FAKE/query.json" "$FAKE" <<'PYEOF'
import json, sys
path, fake = sys.argv[1], sys.argv[2]
notes = """议程：
1. Q4 复盘
2. 明年规划（请大家准时参加）

Join Chime meeting: https://chime.aws/1234567890
Meeting ID: 1234 56 7890
One-click mobile: +1-206-555-0100,,1234567890#

Join Zoom Meeting
https://us02web.zoom.us/j/81234567890?pwd=abcDEF
Meeting ID: 812 3456 7890
Passcode: 123456
One tap mobile
+16465588656,,81234567890#,,,,*123456# US

背景材料见共享盘。
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
"""
def person(i, role="required", name=True):
    d = {"email": "user%02d@example.com" % i, "role": role, "status": "accepted", "type": "person"}
    if name:
        d["name"] = "同事%02d" % i
    return d
org = {"name": "组织者甲", "email": "boss@example.com", "role": "chair", "status": "accepted", "type": "person"}
small = [dict(org)] + [person(i) for i in range(1, 11)] + [person(11, name=False)] + \
        [{"name": "会议室 A", "email": "room-a@example.com", "role": "required", "status": "accepted", "type": "room"}]
big = [dict(org)] + [person(i, role="optional") for i in range(1, 11)] + [person(i) for i in range(11, 45)]
def query(attendees, notes=notes, location="https://chime.aws/1234567890; 会议室 A (演示楼 101)"):
    return {"status": "ok",
            "window": {"start": "2026-11-18T12:01:06+08:00", "end": "2026-11-18T12:52:06+08:00"},
            "match": {"title": "架构周会", "start": "2026-11-18T12:00:00+08:00", "end": "2026-11-18T13:00:00+08:00",
                      "overlap_sec": 3060, "calendar": "Calendar", "organizer": org, "attendees": attendees,
                      "attendee_count": len(attendees), "location": location, "notes": notes},
            "candidates": [{"title": "迁移 office hour", "start": "2026-11-18T12:30:00+08:00",
                            "end": "2026-11-18T13:00:00+08:00", "overlap_sec": 1320}]}
json.dump(query(small), open(path, "w"), ensure_ascii=False)
json.dump(query(big), open(fake + "/query-big.json", "w"), ensure_ascii=False)
PYEOF

# ── 1. 匹配到：写 calendar.md，开头写明来源和以录音为准 ──
echo '{"schema": 1, "session": "20261118_1201", "tags": ["周会"], "future": {"x": 1}}' > "$S/meta.json"
lookup
[[ $RC -eq 0 && -f "$CAL" ]] && pass "匹配到时写 materials/calendar.md" || fail "没写 calendar.md (rc=$RC): $OUT"
grep -q '来自系统日历，是会前的安排，实际讨论以录音为准' "$CAL" && pass "开头写明来源、以录音为准" || fail "缺来源说明"
for want in '- 标题：架构周会' '- 时间：2026-11-18 12:00–13:00（录音 12:01–12:52）' '- 组织者：组织者甲' \
            '- 地点：会议室 A (演示楼 101)' '## 会议说明' 'Q4 复盘' '明年规划（请大家准时参加）' '背景材料见共享盘' \
            '会议主题：架构评审' '会议时间：2026/11/18 12:00-13:00'; do
    grep -qF -- "$want" "$CAL" && pass "calendar.md 有「${want}」" || fail "calendar.md 缺「${want}」"
done
[[ "$OUT" == *"这场会是「架构周会」（和录音重叠 51 分钟）"* ]] && pass "日志记一行匹配结果" || fail "日志: $OUT"

# ── 2. 去掉入会信息（四种模板）：只查开头那句固定说明以外的内容 ──
BODY=$(grep -v '^>' "$CAL")
for bad in 'http' 'chime.aws' 'zoom.us' 'teams.microsoft' 'meeting.tencent' '1234567890' '812 3456 7890' \
           '234 567 890 123' '123-456-789' '123456' 'aB3dE5' '4321' '+1' '+86' 'Passcode' 'Meeting ID' \
           '密码' '拨号' 'Join' '入会' '____' 'pwd'; do
    grep -qF -- "$bad" <<< "$BODY" && fail "calendar.md 里还有「${bad}」" || pass "去掉了「${bad}」"
done

# ── 3. 参会人：12 人全列，组织者单列不重复，会议室不算人，没名字的只写邮箱 @ 前面 ──
line=$(grep '^- 参会人' "$CAL")
[[ "$line" == "- 参会人（12 人）：同事01、"*"同事10、user11" && "$line" != *"组织者甲"* && "$line" != *"会议室"* ]] \
    && pass "12 人全列：组织者单列、会议室不算、没名字的只写邮箱前缀" || fail "参会人: $line"
grep -q '@' "$CAL" && fail "calendar.md 里出现了邮箱" || pass "calendar.md 里没有邮箱"

# ── 4. meta.json：calendar 字段对，tags 和不认识的字段原样保留 ──
cal=$(meta_cal)
python3 -I - "$S/meta.json" <<'PYEOF' && pass "meta.json 的 calendar 字段对，tags 和不认识的字段还在" || fail "meta.json 不对: $(cat "$S/meta.json")"
import json, sys
d = json.load(open(sys.argv[1]))
c = d["calendar"]
assert d["tags"] == ["周会"] and d["future"] == {"x": 1} and d["schema"] == 1
assert c["title"] == "架构周会" and c["organizer"] == "组织者甲" and c["attendee_count"] == 12
assert c["start"] == "2026-11-18T12:00:00+08:00" and c["end"] == "2026-11-18T13:00:00+08:00"
assert c["candidates"] == ["迁移 office hour"] and c["looked_up_at"]
PYEOF
grep -q 'office hour' "$CAL" && fail "候选会议写进了 calendar.md" || pass "候选只进 meta.json，不进 calendar.md"
python3 -m json.tool "$S/meta.json" >/dev/null && pass "meta.json 是合法 JSON" || fail "meta.json 坏了"
[[ -z "$(find "$S" -name '.calendar.*' -o -name '.meta.*')" ]] && pass "写完不留临时文件" || fail "有残留临时文件"

# ── 5. 超过 30 人：只留组织者、前 20 位和总人数；必选在可选前面 ──
cp "$FAKE/query.json" "$FAKE/query-small.json"; cp "$FAKE/query-big.json" "$FAKE/query.json"
lookup
line=$(grep '^- 参会人' "$CAL")
n=$(printf '%s' "${line#*：*：}" | tr '、' '\n' | grep -c .)
[[ "$line" == "- 参会人：共 45 人，下面只列组织者和前 20 位："* && "$n" == 20 && "$line" == *"同事11"* && "$line" != *"同事01"* ]] \
    && grep -q '^- 组织者：组织者甲' "$CAL" \
    && pass "45 人：只列组织者和前 20 位、写明总人数，必选参会人排在可选前面" || fail "截断不对（$n 位）: $line"
cp "$FAKE/query-small.json" "$FAKE/query.json"

# ── 6. 查不到：不写文件、不报错、不改 meta.json，只记一行日志 ──
cp "$S/meta.json" "$TMP/meta.before"
scenario() {   # scenario <说明> <期望日志片段> ：$FAKE/query.json 已就位
    lookup
    if [[ $RC -eq 0 && ! -e "$CAL" && "$OUT" == *"$2"* && $(printf '%s\n' "$OUT" | grep -c .) -le 1 ]] \
       && cmp -s "$S/meta.json" "$TMP/meta.before"; then
        pass "$1：不写文件、不改 meta.json、退出码 0"
    else
        fail "$1 (rc=$RC): $OUT"
    fi
}
cp "$FAKE/query.json" "$TMP/good.json"
echo '{"status":"ok","window":{},"match":null,"candidates":[]}' > "$FAKE/query.json";  scenario "没匹配到" "没有对应的会"
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
cp "$TMP/good.json" "$FAKE/query.json"
mv "$APP/audio-multi-output" "$APP/amo.off"
lookup
[[ $RC -eq 0 && -z "$OUT" && ! -e "$CAL" ]] && pass "查询程序不存在：不出声、不写文件" || fail "查询程序不存在 (rc=$RC): $OUT"
mv "$APP/amo.off" "$APP/audio-multi-output"

# ── 7. 配置 calendar = off：完全不碰日历 ──
use_cfg "calendar = off"
lookup
[[ $RC -eq 0 && -z "$OUT" && ! -e "$CAL" && ! -e "$FAKE/calls.log" ]] && pass "calendar = off：查询程序一次都没被调用" || fail "off 时还是查了: $OUT"
use_cfg

# ── 8. 查询流程从不请求授权 ──
grep -rq 'calendar-request' "$FAKE/calls.log" 2>/dev/null && fail "查询流程调用了 calendar-request" || pass "查询流程从不调用 calendar-request"

# ── 9. 按音频算录音时段；calendar.md 已经有了就不再查、不覆盖 ──
if command -v ffmpeg >/dev/null; then
    S2="$TMP/rec/20261118_1400"; mkdir -p "$S2/materials"
    ffmpeg -v quiet -f lavfi -i anullsrc=r=48000:cl=mono -t 95 -c:a aac "$S2/meeting_20261118_140006.m4a" </dev/null
    rm -f "$FAKE/calls.log"
    (cd "$TMP" && "$MEETAP" _calendar-lookup "$S2" </dev/null >/dev/null 2>&1)
    want_start=$(date -j -f "%Y%m%d_%H%M%S" 20261118_140006 +%s)
    grep -q -- "--start $want_start --end $((want_start + 95)) " "$FAKE/calls.log" \
        && pass "按音频算录音时段：开始 = 文件名时间，结束 = 开始 + 音频时长" || fail "时段不对: $(cat "$FAKE/calls.log")"
    [[ -f "$S2/materials/calendar.md" ]] && cp "$S2/materials/calendar.md" "$TMP/s2.before"
    echo "用户自己改过" >> "$S2/materials/calendar.md"; cp "$S2/materials/calendar.md" "$TMP/s2.before"
    rm -f "$FAKE/calls.log"
    (cd "$TMP" && "$MEETAP" _calendar-lookup "$S2" </dev/null >/dev/null 2>&1)
    [[ ! -e "$FAKE/calls.log" ]] && cmp -s "$S2/materials/calendar.md" "$TMP/s2.before" \
        && pass "calendar.md 已经有了：不再查、不覆盖" || fail "覆盖了已有的 calendar.md"
else
    echo "SKIP: 没装 ffmpeg，跳过按音频算时段的用例"
fi

# ── 10. build_prompt 会把 calendar.md 当资料读进去（不改提示词模板） ──
lookup
mkdir -p "$S/log"; echo "spk_0: 你好" > "$S/log/transcript.txt"; echo "spk_0: 100%" > "$S/log/speaker-stats.txt"
PROMPT=$(
    SCRIPT_DIR="$REPO_ROOT/src"
    _tn() { local k="MSG_$1"; shift; printf "${!k:-<missing>}" "$@"; }
    eval "$(sed -n '/^build_prompt() {/,/^}/p' "$REPO_ROOT/src/meetap")"
    build_prompt "$S" 2>/dev/null
)
[[ "$PROMPT" == *"<会议资料>"*"### 资料: calendar.md"*"日历里的这场会"*"以录音为准"*"</会议资料>"* ]] \
    && pass "build_prompt 把 calendar.md 放进 <会议资料>" || fail "提示词里没有 calendar.md"

# ── 12. meetap <文件夹>：多显示一行日历标题 ──
lookup
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 </dev/null 2>&1)
[[ "$OUT" == *"  日历：架构周会（12:00–13:00）"* ]] && pass "meetap <文件夹> 显示日历标题和时段" || fail "信息页: $OUT"
S3="$TMP/rec/20261118_0900"; mkdir -p "$S3"
OUT=$(cd "$TMP" && "$MEETAP" 20261118_0900 </dev/null 2>&1)
[[ "$OUT" != *"日历："* ]] && pass "没有日历信息的会不显示日历那一行" || fail "不该显示日历: $OUT"

# ── 13. 列标签时把日历标题当建议，只提示、不自动贴 ──
OUT=$(cd "$TMP" && "$MEETAP" -g </dev/null 2>&1)
[[ "$OUT" == *"日历标题：架构周会，要贴的话：meetap -g 架构周会"* ]] \
    && pass "meetap -g：提示日历标题和要贴的话怎么写" || fail "默认目标的建议: $OUT"
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 -g </dev/null 2>&1)
[[ "$OUT" == *"日历标题：架构周会，要贴的话：meetap 20261118_1201 -g 架构周会"* ]] \
    && pass "meetap <文件夹> -g：建议的命令里带上文件夹" || fail "指定文件夹的建议: $OUT"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["tags"] == ["周会"]' "$S/meta.json" \
    && pass "只提示，没有自动贴标签" || fail "被自动贴了标签: $(cat "$S/meta.json")"
(cd "$TMP" && "$MEETAP" 20261118_1201 -g 架构周会 </dev/null >/dev/null 2>&1)
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 -g </dev/null 2>&1)
[[ "$OUT" != *"日历标题："* ]] && pass "日历标题已经是标签了就不再提示" || fail "还在提示: $OUT"
python3 -I - "$S/meta.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); d["calendar"]["title"] = "Weekly Sync"; d["tags"] = ["周会"]
json.dump(d, open(sys.argv[1], "w"), ensure_ascii=False)
PYEOF
OUT=$(cd "$TMP" && "$MEETAP" 20261118_1201 -g </dev/null 2>&1)
[[ "$OUT" == *"要贴的话：meetap 20261118_1201 -g 'Weekly Sync'"* ]] && pass "标题带空格时，建议的命令加了引号，照抄能用" || fail "带空格的建议: $OUT"

# ── 14. setup 的日历授权一步：只有这里会请求授权；拒绝、跳过都算通过 ──
printf '#!/bin/bash\ncase "$1" in tap-supported) echo yes ;; tap-start) printf xxxx ;; *) exit 1 ;; esac\n' > "$APP/audio-tap"
mkdir -p "$TMP/fakebin" "$TMP/home"
for c in afplay osascript open; do printf '#!/bin/bash\necho "%s $*" >> "%s/sys.log"\n' "$c" "$TMP" > "$TMP/fakebin/$c"; done
chmod +x "$APP/audio-tap" "$TMP/fakebin/"*
setup_run() {   # setup_run <授权状态> <请求后的状态> <tty|notty> [TERM_PROGRAM]
    echo "$1" > "$FAKE/status"; echo "$2" > "$FAKE/status-after"; rm -f "$FAKE/calls.log"
    if [[ "$3" == tty ]]; then
        OUT=$({ sleep 1; sleep 3; } | HOME="$TMP/home" TERM_PROGRAM="${4:-}" PATH="$TMP/fakebin:$PATH" script -q /dev/null "$MEETAP" setup 2>&1); RC=$?
    else
        OUT=$(cd "$TMP" && HOME="$TMP/home" TERM_PROGRAM="${4:-}" PATH="$TMP/fakebin:$PATH" "$MEETAP" setup </dev/null 2>&1); RC=$?
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

# ── 11. 中英两份提示语 key 一致 ──
diff <(grep -oE '^MSG_[A-Z_0-9]+' "$REPO_ROOT/src/i18n/messages-zh-CN.sh" | sort) \
     <(grep -oE '^MSG_[A-Z_0-9]+' "$REPO_ROOT/src/i18n/messages-en-US.sh" | sort) >/dev/null \
    && pass "中英两份提示语的 key 一致" || fail "中英提示语 key 不一致"

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
