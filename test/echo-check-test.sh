#!/bin/bash
# 会议室回声检查和录音定稿的测试：用 ffmpeg 现做 4 分钟的双声道录音（声道 0 麦克风、声道 1 电脑的
# 声音），跑 src/meetap 的 _echo_check / _finalize_audio / _echo_undo。不碰音频设备、不触达 AWS。
# 「人声」是带通噪声，按随机长短的音节（约 4 Hz）和句子（约 0.3 Hz）开关，每个人一个随机种子。
# 麦克风那一路垫一个 6 kHz 的轻音、电脑的声音垫 7.5 kHz：都在检查用的人声频段外，不影响结论；
# 定稿的录音里还有没有它们，就知道哪一路留下了。
#
# 结论（_echo_check）：
#   A    会议室设备整场在会里：电脑的声音 = 麦克风人声晚 1.5 秒（和远端一样响）+ 远端的人 → echo，整场
#   R    同上，而且会议室音箱放的远端声音也被麦克风录进去 → echo，整场
#   J    会议室设备第 120 秒才进会 → echo，从 120 秒起，前面照常两路相加
#   B    普通线上会（戴耳机）：麦克风是自己，电脑的声音是远端 → none
#   O    普通线上会，旁边还有个小声说话的同事，和自己的话叠在一起 → none
#   W    普通线上会，远端回声消除没做干净：电脑的声音里有你自己的声音晚 0.6 秒、低 20 dB → none
#   F    开外放：麦克风里有电脑声音晚 40 毫秒的漏音 → none
#   M    开外放放音乐：电脑的声音是 2 Hz 的节拍，漏进麦克风 → none
#   C    线下会议，电脑没声音 → nosys
#   D    麦克风全零 → nomic
# 不能误判的会（5 分钟，37 秒一轮）：隔壁同事也在会里（两个种子 × 三种说话比例，同事在你麦克风里
#   低 10 / 16 / 20 dB，同事的麦克风也录到你）；会议室那一遍时有时无；远端回声低 6 / 10 / 14 dB
#   （叠着说、轮流说）。都必须两路相加
# 定稿（_finalize_audio）：只留电脑的声音 / 两路相加 / 从 120 秒起只留电脑的声音；时长不变；
# 默认会话里只剩一个单声道录音、没有多的音频文件；echo_check = off；keep_stereo_original = true 留原始录音；
# 已经是单声道不动；混不出来原录音不动；上次被强杀留下的临时文件会清掉。
# 退路（_echo_undo）：留了原始录音就重做两路相加、旧转录稿挪走；没留就照实说。
#
# 用法: test/echo-check-test.sh   （五六分钟，有一场 60 分钟的长会）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"

# 真实录音在进行时一个用例都不跑（解码、算互相关都吃 CPU）
REAL_PID_FILE=/tmp/meeting-record/ffmpeg.pid
if [[ -f "$REAL_PID_FILE" ]] && kill -0 "$(cat "$REAL_PID_FILE")" 2>/dev/null; then
    echo "SKIP: 检测到正在录音（$REAL_PID_FILE → $(cat "$REAL_PID_FILE")），不跑测试"
    exit 2
fi
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "SKIP: 没装 ffmpeg"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in _t _tn _flag _job_file_read _transcribe_cleanup _fsync _echo_check _finalize_audio _echo_undo; do
    range="/^$f() {/,/^}/p"
    eval "$(sed -n "$range" "$MEETAP")"
    declare -F "$f" >/dev/null || { echo "ABORT: src/meetap 里找不到 $f"; exit 1; }
done
source "$REPO_ROOT/src/i18n/messages-zh-CN.sh"
CFG_AUDIO_BITRATE=128k
CFG_ECHO_CHECK=on
CFG_KEEP_STEREO_ORIGINAL=""
mkdir -p "$TMP/state"
PID_FILE="$TMP/state/ffmpeg.pid"; OUTPUT_FILE_MARKER="$TMP/state/output-file"   # 正在录哪个文件
osascript() { echo "notify: $*" >> "$TMP/notify.log"; }   # 不真弹通知，记下来

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# 一个人的声音（lavfi 片段，末尾没有输出标签）：<标签> <随机种子>
voice() {
    echo "anoisesrc=r=48000:c=pink:seed=$2:a=0.5,bandpass=f=1000:width_type=o:w=2[n$1];anoisesrc=r=1000:c=white:seed=$(($2 + 100)),lowpass=f=4,lowpass=f=4[s$1];anoisesrc=r=1000:c=white:seed=$(($2 + 200)),lowpass=f=0.3,lowpass=f=0.3[p$1];[s$1][p$1]amerge=inputs=2,aeval=gt(val(0)\,0)*gt(val(1)\,0):c=mono,aresample=48000[g$1];[n$1][g$1]amultiply"
}
noise() { echo "anoisesrc=r=48000:c=white:seed=$1:a=$2"; }
# 一直在说的声音：只按音节开关，没有句子之间的停顿（长会里你那几句话，保证真的说了）
talking() {
    echo "anoisesrc=r=48000:c=pink:seed=$2:a=0.5,bandpass=f=1000:width_type=o:w=2[n$1];anoisesrc=r=1000:c=white:seed=$(($2 + 100)),lowpass=f=4,lowpass=f=4,aeval=gt(val(0)\,0):c=mono,aresample=48000[g$1];[n$1][g$1]amultiply"
}
ROOM="$(voice r 1)"      # 会议室里的人 / 自己（麦克风录到的）
REMOTE="$(voice f 2)"    # 远端的人（只在电脑的声音里）
QUIET="$(voice q 3)"     # 旁边小声说话的同事
MICBG="$(noise 11 0.003)"
SYSBG="$(noise 12 0.002)"
DUR=240

# mk <名字> <lavfi：麦克风那一路标成 [mic]，电脑的声音标成 [sys]>：4 分钟双声道 m4a，两路各垫记号音
mk() {
    ffmpeg -nostdin -v error -y -filter_complex "$2;sine=f=6000:r=48000,volume=0.1[tm];sine=f=7500:r=48000,volume=0.1[ts];[mic][tm]amix=inputs=2:normalize=0[mic2];[sys][ts]amix=inputs=2:normalize=0[sys2];[mic2][sys2]join=inputs=2:channel_layout=stereo,atrim=0:$DUR" \
        -c:a aac -b:a 128k "$TMP/$1.m4a" || { echo "ABORT: 生成 $1 失败"; exit 1; }
}
# 会议室设备在会里：电脑的声音 = 麦克风人声晚 1.5 秒 + 远端的人。会议 App 把每个人都调到差不多的
# 音量，会议室设备传来的那一遍和远端的人一样响。$1 给会议室那一遍加的滤镜
room_call() { echo "$ROOM,asplit[r1][r2];$MICBG[nm];[r1][nm]amix=inputs=2:normalize=0[mic];$REMOTE,volume=0.7[rem];[r2]adelay=1500,volume=0.7$1[echo];$SYSBG[ns];[echo][rem][ns]amix=inputs=3:normalize=0[sys]"; }
mk A "$(room_call "")"
mk R "$ROOM,asplit[r1][r2];$REMOTE,asplit[f1][f2];[f2]adelay=60,volume=0.5[spk];$(noise 11 0.006)[nm];[r1][spk][nm]amix=inputs=3:normalize=0[mic];[r2]adelay=1100,volume=1.0,highpass=f=300,lowpass=f=3000[echo];$(noise 12 0.004)[ns];[echo][f1][ns]amix=inputs=3:normalize=0[sys]"
mk J "$(room_call ",volume=0:enable='lt(t,121.5)'")"
mk B "$ROOM[r];$MICBG[nm];[r][nm]amix=inputs=2:normalize=0[mic];$REMOTE[sys]"
mk O "$ROOM[r];$QUIET,volume=0.18[q];$MICBG[nm];[r][q][nm]amix=inputs=3:normalize=0[mic];$REMOTE[sys]"
mk W "$ROOM,asplit[r1][r2];$MICBG[nm];[r1][nm]amix=inputs=2:normalize=0[mic];$REMOTE[rem];[r2]adelay=600,volume=0.1[echo];$SYSBG[ns];[echo][rem][ns]amix=inputs=3:normalize=0[sys]"
mk F "$REMOTE,asplit[s1][s2];[s2]adelay=40,volume=0.3[leak];$ROOM[r];$MICBG[nm];[r][leak][nm]amix=inputs=3:normalize=0[mic];[s1]anull[sys]"
mk M "anoisesrc=r=48000:c=pink:seed=5:a=0.5,bandpass=f=800:width_type=o:w=3[bn];aevalsrc='lt(mod(t\,0.5)\,0.12)':s=48000[bt];[bn][bt]amultiply,asplit[s1][s2];[s2]adelay=40,volume=0.3[leak];$ROOM[r];$MICBG[nm];[r][leak][nm]amix=inputs=3:normalize=0[mic];[s1]anull[sys]"
mk C "$ROOM[r];$MICBG[nm];[r][nm]amix=inputs=2:normalize=0[mic];anullsrc=r=48000:cl=mono[sys]"
mk D "anullsrc=r=48000:cl=mono[mic];$REMOTE[sys]"

echo "== _echo_check 的结论 =="
col() { cut -f"$1" <<< "$2"; }
check() {   # check <用例> <期望结论> <说明>
    local got; got=$(_echo_check "$TMP/$1.m4a")
    if [[ "$(col 1 "$got")" == "$2" ]]; then pass "$1 → $2 $3（$(tr '\t' ' ' <<< "$got")）"
    else fail "$1 应为 $2 $3，实际：$(tr '\t' ' ' <<< "$got")"; fi
}
check B none "普通线上会照常两路相加"
check O none "旁边有人小声说话、和自己叠在一起也照常两路相加"
check W none "低 20 dB 的远端回声不算会议室设备"
check F none "外放漏音不算"
check M none "外放放节奏很强的音乐也不算"
check C nosys "线下会议"
check D nomic "麦克风没声音"
# muted <结论那一行> <录音秒数>：去掉麦克风的秒数合计；first：最早的起点
muted() { local rg x t=0; rg=$(col 8 "$1"); [[ "$rg" == all ]] && { echo "$2"; return; }
    for x in ${rg//,/ }; do t=$((t + ${x#*-} - ${x%-*})); done; echo "$t"; }
first() { local rg; rg=$(col 8 "$1"); [[ "$rg" == all ]] && echo 0 || echo "${rg%%-*}"; }
got=$(_echo_check "$TMP/A.m4a")
[[ "$(col 1 "$got")" == echo ]] && (( $(muted "$got" 240) >= 180 )) \
    && awk -v l="$(col 2 "$got")" 'BEGIN { exit !(l >= 1.4 && l <= 1.6) }' \
    && pass "A → 去掉麦克风 $(muted "$got" 240) 秒（共 240），延迟 $(col 2 "$got") 秒（造的是 1.5 秒）（$(tr '\t' ' ' <<< "$got")）" \
    || fail "A 应为 echo、大部分时段去掉麦克风、延迟 1.5 秒，实际：$(tr '\t' ' ' <<< "$got")"
got=$(_echo_check "$TMP/R.m4a")
[[ "$(col 1 "$got")" == echo ]] && (( $(muted "$got" 240) >= 180 )) \
    && pass "R → 麦克风也录到会议室音箱，照样去掉麦克风 $(muted "$got" 240) 秒（$(tr '\t' ' ' <<< "$got")）" \
    || fail "R 应为 echo、大部分时段去掉麦克风，实际：$(tr '\t' ' ' <<< "$got")"
got=$(_echo_check "$TMP/J.m4a")
[[ "$(col 1 "$got")" == echo ]] && (( $(first "$got") >= 120 && $(muted "$got" 240) >= 90 )) \
    && pass "J → 第 $(first "$got") 秒起才去掉麦克风，没早于进会的 120 秒（$(tr '\t' ' ' <<< "$got")）" \
    || fail "J 应从 120 秒或更晚开始去掉麦克风，实际：$(tr '\t' ' ' <<< "$got")"

echo "== 不能误判的会（5 分钟，37 秒一轮说话）=="
# 误判会整场丢掉你自己的话，下面每一场都必须两路相加
DUR=300
gate() { echo "volume=0:enable='not(between(mod(t,$1),$2,$3))'"; }
fp() {   # fp <用例> <说明> <lavfi>：结论必须不是 echo
    mk "$1" "$3"
    local got; got=$(_echo_check "$TMP/$1.m4a")
    [[ "$(col 1 "$got")" != echo ]] && pass "$1 两路相加：$2（$(tr '\t' ' ' <<< "$got")）" \
        || fail "$1 不该判成会议室设备：$2（$(tr '\t' ' ' <<< "$got")）"
}
# 隔壁同事也在这个会里：你的麦克风录到同事（低 Q dB），电脑的声音里 0.9 秒后放出同事（正常音量）。
# 你自己的话只在麦克风里。teammate <种子> <你每轮说几秒> <同事每轮说几秒> <同事低几 dB> [你在同事麦克风里低几 dB]
teammate() {
    local s=$1 u=$2 tt=$3 q; q=$(awk -v d="$4" 'BEGIN { printf "%.3f", 10 ^ (-d / 20) }')
    local me tm rm back=""
    me="$(voice u$s $((s * 10 + 1)))"; tm="$(voice t$s $((s * 10 + 2)))"; rm="$(voice o$s $((s * 10 + 3)))"
    local mix_in="[tc][rr][ns]amix=inputs=3" split="[uu]"
    if [[ -n "${5:-}" ]]; then
        back="[uc]adelay=900,volume=$(awk -v d="$5" 'BEGIN { printf "%.3f", 10 ^ (-d / 20) }')[ue];"
        mix_in="[tc][ue][rr][ns]amix=inputs=4"; split=",asplit[uu][uc]"
    fi
    echo "$me,$(gate 37 0 "$u")$split;$tm,$(gate 37 $((u + 1)) $((u + 1 + tt))),asplit[t1][t2];[t1]volume=$q[tq];$MICBG[nm];[uu][tq][nm]amix=inputs=3:normalize=0[mic];$rm,$(gate 37 $((u + 2 + tt)) 37)[rr];[t2]adelay=900[tc];$back$SYSBG[ns];$mix_in:normalize=0[sys]"
}
for s in 1 7; do
    for split in "5 24" "9 20" "12 16"; do
        set -- $split
        fp "T${s}_$1" "隔壁同事在会里，种子 ${s}，你每轮说 $1 秒、同事 $2 秒，同事在你麦克风里低 16 dB" "$(teammate "$s" "$1" "$2" 16)"
    done
done
fp T1_q10 "同事在你麦克风里低 10 dB，你每轮说 5 秒" "$(teammate 1 5 24 10)"
fp T1_q20 "同事在你麦克风里低 20 dB，你每轮说 5 秒" "$(teammate 1 5 24 20)"
fp T1_back "同事的麦克风也录到你（低 20 dB）" "$(teammate 1 5 24 16 20)"
# 会议室那一遍时有时无（每 41 秒有 16 秒没有）：没副本的话不能跟着丢
fp I0 "会议室那一遍和远端一样响，每 41 秒缺 16 秒" "$(room_call ",volume=0:enable='gte(mod(t,41),25)'")"
fp I8 "会议室那一遍低 8 dB，每 41 秒缺 16 秒" "$ROOM,asplit[r1][r2];$MICBG[nm];[r1][nm]amix=inputs=2:normalize=0[mic];$REMOTE,volume=1.0[rem];[r2]adelay=1500,volume=0.4,volume=0:enable='gte(mod(t,41),25)'[echo];$SYSBG[ns];[echo][rem][ns]amix=inputs=3:normalize=0[sys]"
# 远端回声消除没做干净：电脑的声音里有你自己的声音晚 0.6 秒、低 L dB。有一直说话的两个远端（叠着说），
# 或者你和远端轮流说
for db in 6 10 14; do
    v=$(awk -v d="$db" 'BEGIN { printf "%.3f", 10 ^ (-d / 20) }')
    fp "E${db}_dt" "远端回声低 $db dB，两个远端一直在说（叠着说）" "$ROOM,asplit[r1][r2];$MICBG[nm];[r1][nm]amix=inputs=2:normalize=0[mic];$REMOTE[rem];$QUIET[rem2];[r2]adelay=600,volume=$v[echo];$SYSBG[ns];[echo][rem][rem2][ns]amix=inputs=4:normalize=0[sys]"
    fp "E${db}" "远端回声低 $db dB，你和远端轮流说" "$ROOM,$(gate 37 0 15),asplit[r1][r2];$MICBG[nm];[r1][nm]amix=inputs=2:normalize=0[mic];$REMOTE,$(gate 37 15 37)[rem];[r2]adelay=600,volume=$v[echo];$SYSBG[ns];[echo][rem][ns]amix=inputs=3:normalize=0[sys]"
done
DUR=240

echo "== _finalize_audio 定稿 =="
tone() {   # tone <文件> <频率> [起 止]：那个频率附近的平均音量（dB）
    ffmpeg -nostdin ${3:+-ss "$3" -to "$4"} -i "$1" -af "bandpass=f=$2:width_type=q:w=30,volumedetect" -f null - 2>&1 \
        | sed -n 's/.*mean_volume: \([-0-9.]*\) dB.*/\1/p'
}
has() { awk -v v="$1" 'BEGIN { exit !(v != "" && v > -50) }'; }
chans() { ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$1"; }
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
same_dur() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a != "" && d < 0.05) }'; }
# session <名字> <用例>：一个会话文件夹，里面是那份双声道录音
session() {
    local d="$TMP/s-$1"
    mkdir -p "$d/.meetap"
    cp "$TMP/$2.m4a" "$d/meeting_$1.m4a"
    printf '%s' "$d"
}
extra_audio() { find "$1" -name '*.m4a' ! -path "$1/meeting_*.m4a" | sed "s|^$1/||"; }
for c in A B J; do
    S=$(session "$c" "$c"); rm -f "$TMP/notify.log"
    out=$(_finalize_audio "$S/meeting_$c.m4a" "$S/.meetap" 2>&1); rc=$?
    eval "S_$c=\$S; OUT_$c=\$out"
    F="$S/meeting_$c.m4a"
    [[ $rc == 0 && "$(chans "$F")" == 1 && -z "$(extra_audio "$S")" ]] && same_dur "$(dur "$F")" "$(dur "$TMP/$c.m4a")" \
        && pass "$c 定稿成单声道、时长不变（$(dur "$F") 秒），会话里没有多的音频文件" \
        || fail "$c 定稿不对（rc=${rc}，声道 $(chans "$F")，时长 $(dur "$F") / $(dur "$TMP/$c.m4a")，多出：$(extra_audio "$S")）：$out"
done
# A：结论里去掉麦克风的每个时段，定稿里都没有麦克风；别的时段有
ok=1; desc=""; prev=0
for x in $(col 8 "$(_echo_check "$TMP/A.m4a")" | tr ',' ' '); do
    [[ "$x" == all ]] && x="0-240"
    a=${x%-*}; b=${x#*-}
    v=$(tone "$S_A/meeting_A.m4a" 6000 $((a + 1)) $((b - 1))); has "$v" && ok=0; desc+=" $a~$b:${v}"
    if (( a - prev >= 4 )); then v=$(tone "$S_A/meeting_A.m4a" 6000 $((prev + 1)) $((a - 1))); has "$v" || ok=0; desc+=" 留 $prev~$a:${v}"; fi
    prev=$b
done
vs=$(tone "$S_A/meeting_A.m4a" 7500)
(( ok )) && has "$vs" && [[ -s "$S_A/.meetap/echo-check.txt" && -s "$TMP/notify.log" ]] && [[ "$OUT_A" == *"去掉了麦克风"* ]] \
    && pass "A 定稿：去掉麦克风的时段里没有麦克风、别的时段有（${desc}），电脑的声音一直在，记了结论、弹了通知" \
    || fail "A 定稿不对：${desc}，电脑 ${vs} dB / $OUT_A"
vm=$(tone "$S_B/meeting_B.m4a" 6000); vs=$(tone "$S_B/meeting_B.m4a" 7500)
has "$vm" && has "$vs" && [[ ! -e "$S_B/.meetap/echo-check.txt" ]] && [[ "$OUT_B" == *"没认出会议室设备"* ]] \
    && pass "B 定稿是两路相加（麦克风 ${vm} dB、电脑 ${vs} dB），没记回声" || fail "B 定稿不对：麦克风 ${vm} dB、电脑 ${vs} dB / $OUT_B"
v1=$(tone "$S_J/meeting_J.m4a" 6000 0 118); v2=$(tone "$S_J/meeting_J.m4a" 6000 122 240)
has "$v1" && ! has "$v2" && [[ "$OUT_J" == *"2:00-4:00"* ]] \
    && pass "J 定稿进会前有麦克风（${v1} dB）、进会后没有（${v2} dB）" || fail "J 定稿不对：进会前 ${v1} dB、进会后 ${v2} dB / $OUT_J"

# 已经是单声道：什么都不动；上次被强杀留下的临时文件（那个进程已经不在了）清掉
sleep 0 & dead=$!; wait $dead
echo junk > "$S_A/.meetap/finalize.$dead.m4a"
sum0=$(md5 -q "$S_A/meeting_A.m4a")
_finalize_audio "$S_A/meeting_A.m4a" "$S_A/.meetap" >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(md5 -q "$S_A/meeting_A.m4a")" == "$sum0" && -z "$(extra_audio "$S_A")" ]] \
    && pass "定稿过的再跑一遍不动，上次留下的临时文件清掉了" || fail "定稿过的又动了，或者临时文件还在：$(extra_audio "$S_A")"

# 进程号还活着、但 20 分钟没再写过的临时文件（进程号被别的进程重用了）也清掉；刚写的留着
sleep 300 & alive=$!
echo junk > "$S_A/.meetap/finalize.$alive.m4a"; touch -t "$(date -v-20M +%Y%m%d%H%M)" "$S_A/.meetap/finalize.$alive.m4a"
_finalize_audio "$S_A/meeting_A.m4a" "$S_A/.meetap" >/dev/null 2>&1
[[ ! -e "$S_A/.meetap/finalize.$alive.m4a" ]] && pass "进程号被重用、20 分钟没写过的临时文件清掉了" || fail "进程号被重用的临时文件还在"
echo junk > "$S_A/.meetap/finalize.$alive.m4a"
_finalize_audio "$S_A/meeting_A.m4a" "$S_A/.meetap" >/dev/null 2>&1
[[ -e "$S_A/.meetap/finalize.$alive.m4a" ]] && pass "进程还在、刚写过的临时文件不动（可能正在定稿）" || fail "正在定稿的临时文件被删了"
rm -f "$S_A/.meetap/finalize.$alive.m4a"

# 还在录的文件：返回 3，一个字节都不动（again 那边先拦，这里再拦一次）
S=$(session L A); sum0=$(md5 -q "$S/meeting_L.m4a")
echo "$alive" > "$PID_FILE"; echo "$S/meeting_L.m4a" > "$OUTPUT_FILE_MARKER"
_finalize_audio "$S/meeting_L.m4a" "$S/.meetap" >/dev/null 2>&1; rc=$?
[[ $rc == 3 && "$(md5 -q "$S/meeting_L.m4a")" == "$sum0" && -z "$(extra_audio "$S")" ]] \
    && pass "还在录的文件：返回 3，不动" || fail "还在录的文件被动了（rc=${rc}）"
rm -f "$PID_FILE" "$OUTPUT_FILE_MARKER"; kill "$alive" 2>/dev/null; wait "$alive" 2>/dev/null

# 临时文件刷不到磁盘上：不改名，返回 2，原文件不动，不留临时文件
eval "real_$(declare -f _fsync)"
_fsync() { return 1; }
S=$(session Y A); sum0=$(md5 -q "$S/meeting_Y.m4a")
_finalize_audio "$S/meeting_Y.m4a" "$S/.meetap" >/dev/null 2>&1; rc=$?
[[ $rc == 2 && "$(md5 -q "$S/meeting_Y.m4a")" == "$sum0" && -z "$(extra_audio "$S")" ]] \
    && pass "刷不到磁盘：不替换，原文件不动，没留临时文件" || fail "刷不到磁盘时 rc=${rc}，留下：$(extra_audio "$S")"
eval "$(declare -f real__fsync | sed '1s/real__fsync/_fsync/')"

# 混不出来（录音坏了）：返回 2，原文件不动，不留临时文件
S=$(session X A); head -c 4096 /dev/urandom > "$S/meeting_X.m4a"; sum0=$(md5 -q "$S/meeting_X.m4a")
_finalize_audio "$S/meeting_X.m4a" "$S/.meetap" >/dev/null 2>&1; rc=$?
[[ $rc == 2 && "$(md5 -q "$S/meeting_X.m4a")" == "$sum0" && -z "$(extra_audio "$S")" ]] \
    && pass "混不出来：返回 2，原文件不动，没留临时文件" || fail "混不出来时 rc=${rc}，留下：$(extra_audio "$S")"

# echo_check = off：不查，整场两路相加
CFG_ECHO_CHECK=Off
S=$(session Aoff A)
out=$(_finalize_audio "$S/meeting_Aoff.m4a" "$S/.meetap" 2>&1)
vm=$(tone "$S/meeting_Aoff.m4a" 6000)
has "$vm" && [[ "$out" == *"echo_check = off"* && ! -e "$S/.meetap/echo-check.txt" && -z "$(extra_audio "$S")" ]] \
    && pass "echo_check = Off：不查，两路相加（麦克风 ${vm} dB）" || fail "echo_check = Off 时不对（麦克风 ${vm} dB）：$out"
CFG_ECHO_CHECK=on

# keep_stereo_original = true：判成回声时留原始双声道录音，和录下来的一模一样
CFG_KEEP_STEREO_ORIGINAL=YES
S=$(session Akeep A); sum0=$(md5 -q "$S/meeting_Akeep.m4a")
_finalize_audio "$S/meeting_Akeep.m4a" "$S/.meetap" >/dev/null 2>&1
O="$S/.meetap/meeting_Akeep.stereo-original.m4a"
[[ -f "$O" && "$(md5 -q "$O")" == "$sum0" && "$(chans "$O")" == 2 && "$(extra_audio "$S")" == ".meetap/meeting_Akeep.stereo-original.m4a" ]] \
    && pass "keep_stereo_original = YES：判成回声时留下原始双声道录音" || fail "原始录音没留对：$(extra_audio "$S")"
# 文件系统不支持硬链接：先拷到临时名字再 mv，结果一样
ln() { return 1; }
S3=$(session Ckeep A); sum0=$(md5 -q "$S3/meeting_Ckeep.m4a")
_finalize_audio "$S3/meeting_Ckeep.m4a" "$S3/.meetap" >/dev/null 2>&1
O3="$S3/.meetap/meeting_Ckeep.stereo-original.m4a"
[[ -f "$O3" && "$(md5 -q "$O3")" == "$sum0" && "$(extra_audio "$S3")" == ".meetap/meeting_Ckeep.stereo-original.m4a" ]] \
    && pass "不支持硬链接时拷贝原始录音，和录下来的一模一样" || fail "不支持硬链接时原始录音不对：$(extra_audio "$S3")"
# 拷到一半被强杀：只留下临时名字的半截文件；下次定稿把它当临时文件清掉，重新拷一份完整的
S3=$(session Dkeep A); sum0=$(md5 -q "$S3/meeting_Dkeep.m4a")
sleep 0 & dead=$!; wait $dead
head -c 1000 "$S3/meeting_Dkeep.m4a" > "$S3/.meetap/finalize.$dead.orig.m4a"
_finalize_audio "$S3/meeting_Dkeep.m4a" "$S3/.meetap" >/dev/null 2>&1
O3="$S3/.meetap/meeting_Dkeep.stereo-original.m4a"
[[ -f "$O3" && "$(md5 -q "$O3")" == "$sum0" && "$(extra_audio "$S3")" == ".meetap/meeting_Dkeep.stereo-original.m4a" ]] \
    && pass "上次拷到一半被强杀：半截的临时文件清掉了，原始录音是完整的" || fail "拷到一半被强杀以后：$(extra_audio "$S3")"
unset -f ln
S2=$(session Bkeep B)
_finalize_audio "$S2/meeting_Bkeep.m4a" "$S2/.meetap" >/dev/null 2>&1
[[ -z "$(extra_audio "$S2")" ]] && pass "keep_stereo_original = YES、没判成回声：不留原始录音" || fail "没回声也留了：$(extra_audio "$S2")"
CFG_KEEP_STEREO_ORIGINAL=""

echo "== 长会：隔壁同事说了大半场，你只说几句，每一句都要留下 =="
# 同事在你麦克风里低 Q dB、电脑的声音里 0.9 秒后正常音量放出来，还有一个远端的人。你只在几个
# 3 秒（或 2 秒）里说话。判不判成回声都行，但你说话的那几秒定稿里必须有麦克风（6 kHz 记号音）
# colleague <名字> <分钟> <同事低几 dB> <你每句几秒> <你说话的起秒…>
colleague() {
    local name=$1 mins=$2 q t; q=$(awk -v d="$3" 'BEGIN { printf "%.3f", 10 ^ (-d / 20) }'); local len=$4; shift 4
    local en=""
    for t in "$@"; do en+="${en:++}between(t,$t,$((t + len)))"; done
    DUR=$((mins * 60))
    mk "$name" "$(talking u9 91),volume=0:enable='not($en)'[uu];$(voice t9 92),asplit[t1][t2];[t1]volume=$q[tq];$MICBG[nm];[uu][tq][nm]amix=inputs=3:normalize=0[mic];[t2]adelay=900[tc];$(voice o9 93),volume=0.7[rr];$SYSBG[ns];[tc][rr][ns]amix=inputs=3:normalize=0[sys]"
    local S got out v ok=1 desc=""
    got=$(_echo_check "$TMP/$name.m4a")
    S=$(session "$name" "$name")
    out=$(_finalize_audio "$S/meeting_$name.m4a" "$S/.meetap" 2>&1)
    for t in "$@"; do
        v=$(tone "$S/meeting_$name.m4a" 6000 "$t" $((t + len))); has "$v" || ok=0; desc+=" ${t}s:${v}"
    done
    (( ok )) && pass "$name 你说的每一句都留下了（${desc}）（$(tr '\t' ' ' <<< "$got")）" \
        || fail "$name 丢了你说的话（${desc}）（$(tr '\t' ' ' <<< "$got")）"
    rm -rf "$S" "$TMP/$name.m4a"
    DUR=240
}
colleague L60 60 10 3 905 1805 2705
colleague L30 30 6 3 155 455 755 1055 1355 1655
colleague L20 20 10 2 145 445 745 1045

echo "== _echo_undo 退路 =="
# echo_check 还开着：什么都不做
mkdir -p "$S/log"; echo "旧转录" > "$S/log/transcript.txt"
out=$(_echo_undo "$S" 2>&1)
[[ -z "$out" && -f "$O" ]] && pass "echo_check 开着时不退" || fail "echo_check 开着也动了：$out"
CFG_ECHO_CHECK=0
out=$(_echo_undo "$S" 2>&1); rc=$?
vm=$(tone "$S/meeting_Akeep.m4a" 6000)
[[ $rc == 0 && ! -e "$O" && ! -e "$S/.meetap/echo-check.txt" && ! -e "$S/log/transcript.txt" && -n "$(ls "$S/archive/"*_transcript.txt 2>/dev/null)" ]] \
    && has "$vm" && [[ "$(chans "$S/meeting_Akeep.m4a")" == 1 && -z "$(extra_audio "$S")" ]] \
    && pass "echo_check = 0 + 留了原始录音：重做成两路相加（麦克风 ${vm} dB），旧转录稿挪进 archive/，原始录音删掉" \
    || fail "退回不对（rc=${rc}，麦克风 ${vm} dB）：$out"
# 没留原始录音：照实说麦克风那一路没了，录音不动
sum0=$(md5 -q "$S_A/meeting_A.m4a")
out=$(_echo_undo "$S_A" 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"麦克风那一路已经去掉"*"keep_stereo_original"* && "$(md5 -q "$S_A/meeting_A.m4a")" == "$sum0" ]] \
    && pass "没留原始录音：照实说退不回去，录音不动" || fail "没留原始录音时：rc=${rc} / $out"
out=$(_echo_undo "$S_B" 2>&1)
[[ -z "$out" ]] && pass "没判成过回声的会：什么都不说" || fail "没回声的会也说了：$out"
CFG_ECHO_CHECK=on

echo ""
(( FAIL == 0 )) && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
