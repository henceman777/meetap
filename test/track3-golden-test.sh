#!/bin/bash
# 轨道3 黄金样本测试：验证 build_prompt 改造前后输出逐字节一致。
#
# 用法:
#   test/track3-golden-test.sh <输出文件>
#     构造一个含 shell 特殊字符的假 session，调用 src/meetap 的 build_prompt，
#     把 prompt 写入 <输出文件>。改造前生成 golden-before.txt，改造后生成
#     golden-after.txt，再 diff 比对。
#
# 关键点:
#   - 假 session 名用 8 位日期 20250715_1430，SESSION_DATE 结果确定（周二），
#     不受当前时间影响，可重复 diff。
#   - transcript / speaker-stats 故意塞入 $HOME、反引号、${foo}、$(whoami)、
#     引号、$100、中文、emoji，用来抓「变量注入被 shell 执行或误替换」的风险。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"
OUT_FILE="${1:?用法: track3-golden-test.sh <输出文件>}"

# --- 构造确定性的假 session ---
TMP_SESSION="$(mktemp -d)"
trap 'rm -rf "$TMP_SESSION"' EXIT
SESSION_DIR="$TMP_SESSION/20250715_1430"
mkdir -p "$SESSION_DIR/log"

# transcript：含各种 shell 元字符，务必原样保留、不被执行
cat > "$SESSION_DIR/log/transcript.txt" <<'TRANSCRIPT_EOF'
spk_0: 我的家目录是 $HOME 但不该被展开
spk_1: 反引号命令 `whoami` 也不该执行
spk_0: 花括号变量 ${foo} 和 ${bar} 要原样保留
spk_1: 命令替换 $(whoami) 和 $(rm -rf /) 绝对不能执行
spk_0: 带"双引号"和'单引号'的句子
spk_1: 报价是 $100 到 $999，涨了 $HOME 块钱（开玩笑）
spk_0: 中文正常 + emoji 🎤📝✅ + 制表符	结束
TRANSCRIPT_EOF

# speaker-stats：也塞一个 ${bar} 占位符
cat > "$SESSION_DIR/log/speaker-stats.txt" <<'STATS_EOF'
spk_0: 62% (含 ${bar} 特殊字符测试)
spk_1: 38% `date`
STATS_EOF

# --- 隔离提取 build_prompt 并调用 ---
# src/meetap 是个大脚本，底部有 case 分发会执行 main，不能直接 source。
# 用 sed 抽出 build_prompt 函数体，在子 shell 里 eval，提供必要的桩。
FUNC_SRC="$(sed -n '/^build_prompt() {/,/^}/p' "$MEETAP")"

# SCRIPT_DIR 指向 src/，让默认模板查找命中 dev 树 share/meetap/prompts/
export SCRIPT_DIR="$REPO_ROOT/src"

# _tn 桩：模仿真脚本行为——查 MSG_<KEY> 并 printf；缺失则打印占位。
# 仅错误路径会用到，happy path 不触发。
_tn() {
    local key="MSG_$1"; shift
    local template="${!key:-}"
    [[ -z "$template" ]] && template="<missing:${key#MSG_}>"
    # shellcheck disable=SC2059
    printf "$template" "$@"
}
export -f _tn 2>/dev/null || true

# 在当前 shell 定义并调用（保留 set -e 环境）
eval "$FUNC_SRC"
build_prompt "$SESSION_DIR" > "$OUT_FILE"

echo "已生成: $OUT_FILE ($(wc -c < "$OUT_FILE") 字节)"
