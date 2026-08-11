#!/bin/bash
# Highlight 校验闸门测试：验证「剥掉 <mark> 后逐字节比对」的行为。
#   通过场景：LLM 输出 = 原文 + <mark> 标记 → exit 0
#   篡改场景：LLM 改了正文一个字 → exit 2
#   多字节场景：中文/emoji 原样 + 高亮 → exit 0
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"

# 抽出 _highlight_verify_py 函数体并 eval，拿到 Python 源码
FUNC_SRC="$(sed -n '/^_highlight_verify_py() {/,/^}/p' "$MEETAP")"
eval "$FUNC_SRC"
PY="$(_highlight_verify_py)"

PYBIN="$(command -v python3)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
run_case() {
    local name="$1" orig="$2" out="$3" want="$4"
    printf '%s' "$orig" > "$TMP/orig.md"
    printf '%s' "$out"  > "$TMP/out.md"
    "$PYBIN" -c "$PY" "$TMP/orig.md" "$TMP/out.md"
    local got=$?
    if [[ "$got" == "$want" ]]; then
        echo "PASS: $name (exit $got)"
    else
        echo "FAIL: $name (want $want, got $got)"; fail=1
    fi
}

# 通过：纯加标
run_case "add-mark" \
    "Graviton 占 37%，年底达 50%。" \
    "Graviton 占 <mark>37%</mark>，年底达 <mark>50%</mark>。" 0
# 通过：多字节 + emoji 原样，只加标
run_case "multibyte" \
    "增长 5.3 倍 🎤 结论明确" \
    "增长 <mark>5.3 倍</mark> 🎤 结论明确" 0
# 篡改：改了数字
run_case "tampered-number" \
    "Graviton 占 37%。" \
    "Graviton 占 <mark>38%</mark>。" 2
# 篡改：删了字
run_case "tampered-delete" \
    "这是一句完整的话。" \
    "这是一句话。" 2
# 通过：仅首尾空白抖动（开头空行/末尾换行增减），中间正文不变 → 放行
run_case "edge-whitespace" \
    $'\n开头有空行，结尾无换行。' \
    "开头有空行，结尾无换行。"$'\n' 0
# 篡改：正文中间空白被改（不在首尾），仍须拒绝
run_case "tampered-inner-space" \
    "两个字 之间有一个空格" \
    "两个字之间有一个空格" 2
# 篡改：模型用 **加粗** 代替 <mark>（真实失败场景），剥 mark 后残留 ** → 拒绝
run_case "tampered-bold" \
    "他的观点是SSO团队了解不够。" \
    "他的观点是**SSO团队了解不够**。" 2

exit $fail
