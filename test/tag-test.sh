#!/bin/bash
# 会议标签（meta.json）测试：读写可靠、默认目标、12 小时护栏、回显。
# 不需要音频设备、不触达 AWS，全部在临时目录里做，碰不到真实的 ~/Record。
#
# 用法: test/tag-test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"

# 真实录音在进行时一个用例都不跑：start 里的 pkill 作用到整台机器
REAL_PID_FILE=/tmp/meeting-record/ffmpeg.pid
if [[ -f "$REAL_PID_FILE" ]] && kill -0 "$(cat "$REAL_PID_FILE")" 2>/dev/null; then
    echo "SKIP: 检测到正在录音（$REAL_PID_FILE → $(cat "$REAL_PID_FILE")），不跑测试"
    exit 2
fi

PY="$(command -v python3)"
TMP="$(mktemp -d)"
trap '{ kill $(jobs -p); wait; } 2>/dev/null; rm -rf "$TMP"' EXIT

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
REC="$TMP/rec"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap" "$REC"
use_rec() { printf 'recording_dir = %s\nlanguage = %s\n' "$1" "${2:-zh-CN}" > "$XDG_CONFIG_HOME/meetap/config"; }
use_rec "$REC"

# 假录音进程一直活着：万一哪个调用误进了 start，也会停在「已在录制」，碰不到 pkill。
# 「正在录」靠 state/session-dir 是否存在来切换（meetap 要两者都在才算正在录）。
sleep 600 & FAKE_FFMPEG=$!
echo "$FAKE_FFMPEG" > "$MEETAP_STATE_DIR/ffmpeg.pid"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
run() { OUT=$(cd "$TMP" && "$MEETAP" "$@" </dev/null 2>&1); RC=$?; }
# 读出 meta.json 里的标签，一行一个
# meta.json 在哪：新位置 .meetap/ 优先，没有再看根目录的老文件
mp() { if [[ -f "$1/.meetap/meta.json" || ! -f "$1/meta.json" ]]; then echo "$1/.meetap/meta.json"; else echo "$1/meta.json"; fi; }
has_meta() { [[ -e "$1/.meetap/meta.json" || -e "$1/meta.json" ]]; }
tags_of() { "$PY" -I -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1], encoding="utf-8"))["tags"]))' "$(mp "$1")"; }
NOW="$(date +%Y%m%d_%H%M)"
TODAY="$(date +%Y-%m-%d)"

# ── 1. 标签读写一字不差 ──
S1="$REC/20260301_0900"
mkdir -p "$S1"
TRICKY=('周会 A' '客户"B"' "it's" 'C:\path\x' '$HOME' '50%' '🎉复盘' 'Weekly')
args=()
for t in "${TRICKY[@]}"; do args+=(-g "$t"); done
run 20260301_0900 "${args[@]}" -g '  前后空格  '
expected="$(printf '%s\n' "${TRICKY[@]}" '前后空格')"
[[ $RC -eq 0 && "$(tags_of "$S1")" == "$expected" ]] \
    && pass "中文、空格、引号、反斜杠、\$、%、emoji 的标签读出来一字不差（首尾空白去掉）" \
    || fail "标签读写不一致 (rc=$RC): $(tags_of "$S1" 2>&1) / $OUT"
"$PY" -m json.tool "$S1/.meetap/meta.json" >/dev/null && pass "meta.json 通过 python3 -m json.tool" || fail "meta.json 不是合法 JSON"
[[ "$OUT" == *"已给 03-01 09:00"*"贴上："*'客户"B"'* ]] || [[ "$OUT" == *"已给 2026-03-01 09:00"* ]] \
    && pass "回显里看得出是哪一场" || fail "回显不对: $OUT"

# 大小写不敏感去重，保留原写法；撤标签也不分大小写
run 20260301_0900 -g weekly
[[ "$(tags_of "$S1" | grep -ci '^weekly$')" == 1 && "$(tags_of "$S1")" == *Weekly* && "$OUT" == *"本来就有"* ]] \
    && pass "大小写不同的同一个标签不重复贴，保留原写法" || fail "大小写去重不对: $(tags_of "$S1") / $OUT"
run 20260301_0900 --untag WEEKLY
[[ $RC -eq 0 && "$(tags_of "$S1")" != *Weekly* && "$OUT" == *"撤掉：Weekly"* ]] \
    && pass "--untag 不分大小写" || fail "--untag 大小写不对: $(tags_of "$S1") / $OUT"
run 20260301_0900 --untag 不存在的标签
[[ $RC -eq 0 && "$OUT" == *"这场本来就没有：不存在的标签"* ]] \
    && pass "撤一个本来没有的标签：提示一句，退出码 0" || fail "撤不存在的标签 (rc=$RC): $OUT"

# 原子写：目录里不留临时文件
[[ -f "$S1/.meetap/meta.json" && ! -e "$S1/meta.json" ]] && pass "meta.json 写在 .meetap/ 里，根目录没有" || fail "meta.json 位置不对: $(ls -A "$S1")"
[[ -z "$(find "$S1" -name '.meta.*')" ]] && pass "写完不留临时文件" || fail "有残留临时文件: $(ls -a "$S1")"

# ── 2. 不认识的字段原样保留 ──
S2="$REC/20260302_0900"
mkdir -p "$S2"
cat > "$S2/meta.json" <<'EOF'
{
  "schema": 1,
  "session": "20260302_0900",
  "calendar": {"title": "团队周会", "attendees": ["甲", "乙"], "start": "2026-03-02T09:00:00+08:00"},
  "tags": [],
  "future_field": 42
}
EOF
cal_of() { "$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(json.dumps([d.get("calendar"), d.get("future_field")], ensure_ascii=False, sort_keys=True))' "$(mp "$S2")"; }
before="$(cal_of)"
run 20260302_0900 -g 周会
run 20260302_0900 --untag 周会
run 20260302_0900 -g 客户A
[[ "$(cal_of)" == "$before" && "$(tags_of "$S2")" == "客户A" ]] \
    && pass "贴、撤标签之后 calendar 等不认识的字段还在、值不变" || fail "不认识的字段变了: $(cat "$(mp "$S2")")"
[[ -f "$S2/.meetap/meta.json" && ! -e "$S2/meta.json" ]] && pass "根目录的老 meta.json：写一次就挪进 .meetap/，不留两份" || fail "老文件没挪: $(ls -A "$S2")"

# ── 3. meta.json 坏了：不覆盖 ──
S3="$REC/20260303_0900"
mkdir -p "$S3"
printf '{"tags": ["周会",' > "$S3/meta.json"
cp "$S3/meta.json" "$TMP/broken.orig"
run 20260303_0900 -g 客户A
[[ $RC -ne 0 && "$OUT" == *"不是合法的 JSON"* ]] && cmp -s "$S3/meta.json" "$TMP/broken.orig" \
    && pass "meta.json 坏了时报错，原文件不动" || fail "坏 meta.json 处理不对 (rc=$RC): $OUT"
run 20260303_0900
[[ $RC -eq 0 && "$OUT" == *"meta.json 读不了"* ]] && pass "显示信息时 meta.json 坏了不报错退出" || fail "显示信息 (rc=$RC): $OUT"
rm -f "$S3/meta.json"

# ── 4. 相近标签提示、全部标签统计（含月份文件夹） ──
mkdir -p "$REC/2026-10/20261008_1046" "$REC/2026-10/20261009_1000" "$REC/其他/20261010_1000" "$REC/2026-10/深一层/20261011_1000"
run 2026-10/20261008_1046 -g 团队周会
[[ $RC -eq 0 && -f "$REC/2026-10/20261008_1046/.meetap/meta.json" ]] && pass "月份文件夹里的老会议写路径能贴" || fail "月份文件夹路径 (rc=$RC): $OUT"
run 2026-10/20261009_1000 -g 团队周会
for d in "$REC/其他/20261010_1000" "$REC/2026-10/深一层/20261011_1000"; do
    printf '{"schema": 1, "tags": ["不该计入"]}\n' > "$d/meta.json"
done
run 20260302_0900 -g 周会
[[ "$OUT" == *"已有相近的标签：团队周会（2 场）"* && "$(tags_of "$S2")" == *"周会"* ]] \
    && pass "新标签和已有标签相近时提示（场数含月份文件夹），照样贴上" || fail "相近提示不对: $OUT"
run 20260301_0900 -g 周会
[[ "$OUT" != *"相近"* ]] && pass "贴一个已经用过的标签不提示相近" || fail "不该提示相近: $OUT"
run -g
[[ "$OUT" == *"团队周会（2 场）"* && "$OUT" == *"周会（2 场）"* && "$OUT" != *"不该计入"* ]] \
    && pass "用过的全部标签：第一层 + 月份文件夹，别的子目录和更深层不计" || fail "全部标签统计不对: $OUT"

# ── 5. 默认目标 ──
# 没在录：贴给第一层最新一场（月份文件夹里的不算）
SNEW="$REC/$NOW"
mkdir -p "$SNEW/materials"
rm -f "$MEETAP_STATE_DIR/session-dir"
run -g 默认目标
[[ $RC -eq 0 && "$(tags_of "$SNEW")" == "默认目标" ]] && pass "没在录时贴给最新一场" || fail "没在录的默认目标 (rc=$RC): $OUT"
[[ "$OUT" == *"$(date +%m-%d) "*"还没有纪要"* ]] && pass "回显带日期时间，没有纪要时写「还没有纪要」" || fail "回显: $OUT"
# 正在录：即使有更新的文件夹、正在录的这场早于 12 小时，也贴给正在录的这场，且不问
echo "$S1" > "$MEETAP_STATE_DIR/session-dir"
run -g 录音中
[[ $RC -eq 0 && "$(tags_of "$S1")" == *"录音中"* && "$(tags_of "$SNEW")" != *"录音中"* && "$OUT" == *"正在录"* ]] \
    && pass "正在录时贴给正在录的这场，回显写明正在录" || fail "正在录的默认目标 (rc=$RC): $OUT"
run --untag 录音中
[[ $RC -eq 0 && "$(tags_of "$S1")" != *"录音中"* ]] && pass "--untag 不写文件夹时也取正在录的这场" || fail "--untag 默认目标 (rc=$RC): $OUT"
run -g
[[ "$OUT" == "正在录的这场 "* ]] && pass "列标签时写明是正在录的这场" || fail "列标签前缀: $OUT"
rm -f "$MEETAP_STATE_DIR/session-dir"
run -g
[[ "$OUT" == "最新一场 "* ]] && pass "没在录时列标签写明是最新一场" || fail "列标签前缀: $OUT"

# ── 6. 12 小时护栏（另一个 recording_dir：最新一场是很久以前） ──
OLD="$TMP/rec-old"
mkdir -p "$OLD/20250101_0900"
use_rec "$OLD"
run -g '周会 A'
[[ $RC -ne 0 ]] && ! has_meta "$OLD/20250101_0900" && [[ "$OUT" == *"meetap 20250101_0900 -g '周会 A'"* ]] \
    && pass "没终端：拒绝、不写文件、提示写明文件夹（带空格的标签加引号）" || fail "没终端的护栏 (rc=$RC): $OUT"
run --untag 周会
[[ $RC -ne 0 ]] && ! has_meta "$OLD/20250101_0900" && pass "--untag 不写文件夹时也过护栏" || fail "--untag 护栏 (rc=$RC): $OUT"
run -g
[[ $RC -eq 0 ]] && pass "只列标签（只读）不过护栏" || fail "列标签被护栏拦了 (rc=$RC): $OUT"

# 有终端：用 script 起伪终端；PATH 里挡掉 gum，走 read 确认
BIN="$TMP/bin"
mkdir -p "$BIN"
for tool in python3 ffprobe; do p=$(command -v "$tool") && ln -s "$p" "$BIN/$tool"; done
# 等程序开始等输入再喂答案，再等它读完才关 stdin：script 在 stdin 结束时会往伪终端发 ^D，
# 来早了会抢在答案前面被 read 读到
pty_run() {
    OUT=$({ sleep 1; printf '%s\n' "$1"; sleep 2; } | PATH="$BIN:/usr/bin:/bin" script -q /dev/null "$MEETAP" -g 周会 2>&1)
    RC=$?
}
pty_run n
! has_meta "$OLD/20250101_0900" && [[ "$OUT" == *"确定改它的标签吗"*"[y/N]: n"* && "$OUT" == *"已取消"* ]] \
    && pass "有终端：先问，答 n 不写文件" || fail "有终端答 n (rc=$RC): $OUT"
pty_run y
[[ "$OUT" == *"[y/N]: y"* && "$(tags_of "$OLD/20250101_0900" 2>/dev/null)" == "周会" ]] \
    && pass "有终端：答 y 才写" || fail "有终端答 y (rc=$RC): $OUT"
rm -f "$OLD/20250101_0900/meta.json" "$OLD/20250101_0900/.meetap/meta.json"
run 20250101_0900 -g 周会
[[ $RC -eq 0 && "$(tags_of "$OLD/20250101_0900")" == "周会" ]] && pass "写明文件夹时不问，直接写" || fail "写明文件夹 (rc=$RC): $OUT"
use_rec "$REC"

# ── 7. 参数写反、非法标签：拒绝，不写文件 ──
before="$(tags_of "$SNEW")"
run -g "$NOW"
[[ $RC -ne 0 && "$OUT" == *"参数可能写反"*"meetap $NOW -g"* ]] && pass "-g 后面跟会话名：判定为写反并提示正确写法" || fail "写反 (rc=$RC): $OUT"
run -g "2026-10/20261008_1046"
[[ $RC -ne 0 ]] && pass "-g 后面跟会话路径也拒绝" || fail "-g 会话路径 (rc=$RC): $OUT"
run -g "$(printf 'a\tb')"
[[ $RC -ne 0 && "$OUT" == *"控制字符"* ]] && pass "含制表符的标签拒绝" || fail "控制字符 (rc=$RC): $OUT"
run -g -x
[[ $RC -ne 0 ]] && pass "标签不能以 - 开头" || fail "- 开头 (rc=$RC): $OUT"
[[ "$(tags_of "$SNEW")" == "$before" ]] && pass "以上拒绝的命令都没有改动标签" || fail "被拒绝的命令改了标签: $(tags_of "$SNEW")"

# ── 8. 回显：纪要标题、时长 ──
printf '# 纪要\n' > "$SNEW/${TODAY}_$(date +%H%M)_季度规划评审.md"
printf 'x\n' > "$SNEW/prompt.md"
run "$NOW"
[[ "$OUT" == *"纪要：季度规划评审"* && "$OUT" == *"时长：未知"* && "$OUT" == *"状态：已结束"* ]] \
    && pass "显示信息：纪要标题；没音频时时长写「未知」不报错" || fail "显示信息: $OUT"
if command -v ffmpeg >/dev/null; then
    ffmpeg -v quiet -f lavfi -i anullsrc=r=48000:cl=mono -t 95 -c:a aac "$SNEW/meeting_${NOW}00.m4a" </dev/null
    run -g 有音频
    [[ "$OUT" == *"（2 分钟 · 纪要：季度规划评审）贴上：有音频"* ]] \
        && pass "有音频：回显里时长按音频算（95 秒 → 2 分钟）" || fail "有音频的回显: $OUT"
else
    echo "SKIP: 没装 ffmpeg，跳过有音频的时长用例"
fi

# ── 9. 没终端调用：不阻塞，不留后台进程（输出接到管道上也能等到结束） ──
start=$(date +%s)
OUT=$(cd "$TMP" && "$MEETAP" -g 管道 </dev/null 2>&1 | cat); took=$(( $(date +%s) - start ))
leftover=$(pgrep -f "$MEETAP" || true)
[[ $took -lt 10 && -z "$leftover" && "$OUT" == *"贴上：管道"* ]] \
    && pass "接管道调用 ${took}s 返回，没有残留进程" || fail "管道调用 took=${took}s leftover=$leftover: $OUT"

# ── 10. 英文界面 ──
use_rec "$REC" en-US
run "$NOW" -g english
[[ $RC -eq 0 && "$OUT" == "Tagged "*"with: english"* ]] && pass "英文界面的回显" || fail "英文回显: $OUT"
use_rec "$REC"

# ── 11. 中英两份提示语 key 一致 ──
diff <(grep -oE '^MSG_[A-Z_]+' "$REPO_ROOT/src/i18n/messages-zh-CN.sh" | sort) \
     <(grep -oE '^MSG_[A-Z_]+' "$REPO_ROOT/src/i18n/messages-en-US.sh" | sort) >/dev/null \
    && pass "中英两份提示语的 key 一致" || fail "中英提示语 key 不一致"

kill -0 "$FAKE_FFMPEG" 2>/dev/null && pass "假录音进程未受影响" || fail "假录音进程被停了"

echo
[[ $FAIL -eq 0 ]] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
