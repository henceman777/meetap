#!/bin/bash
# 轨道3 黄金样本测试：验证 build_prompt 变量注入的正确性与安全性。
#
# 用法:
#   test/track3-golden-test.sh <输出文件> [--with-outlook]
#     构造一个含 shell 特殊字符的假 session，调用 src/meetap 的 build_prompt，
#     把 prompt 写入 <输出文件>，并做内置断言。
#     --with-outlook：额外造假 log/outlook/meeting.md，验证 ${outlook_context}
#     注入及其中特殊字符的安全性。
#
# 关键点:
#   - 假 session 名用 8 位日期 20250715_1430，SESSION_DATE 结果确定（周二），
#     不受当前时间影响，可重复 diff。
#   - transcript / speaker-stats 故意塞入 $HOME、反引号、${foo}、$(whoami)、
#     引号、$100、中文、emoji，用来抓「变量注入被 shell 执行或误替换」的风险。
#   - 轨道4 起模板含可选占位符 ${outlook_context}：无 outlook 文件时应替换为
#     空字符串；有文件时应注入其内容且特殊字符原样保留。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"
OUT_FILE="${1:?用法: track3-golden-test.sh <输出文件> [--with-outlook]}"
WITH_OUTLOOK=false
[[ "${2:-}" == "--with-outlook" ]] && WITH_OUTLOOK=true

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

# outlook（可选）：同样塞入 shell 元字符验证注入安全性
if $WITH_OUTLOOK; then
    mkdir -p "$SESSION_DIR/log/outlook"
    cat > "$SESSION_DIR/log/outlook/meeting.md" <<'OUTLOOK_EOF'
### 季度架构评审 OUTLOOK-MARKER-7f3a
- 开始时间: 2025年7月15日 星期二 14:00:00
- 结束时间: 2025年7月15日 星期二 15:00:00
- 组织者: 张三
- 参会人: 李四, 王五

议程正文含元字符: $(whoami) 和 ${foo} 与 `date` 都不能执行
OUTLOOK_EOF
fi

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

# --- 内置断言 ---
fail=0
assert() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS: $desc"
    else
        echo "  FAIL: $desc"
        fail=1
    fi
}

# 1) 三个原有变量注入正常
assert "SESSION_DATE 已注入"      grep -qF '2025-07-15（周二）14:30' "$OUT_FILE"
assert "transcript 已注入"        grep -qF '我的家目录是 $HOME 但不该被展开' "$OUT_FILE"
assert "speaker_stats 已注入"     grep -qF 'spk_0: 62% (含 ${bar} 特殊字符测试)' "$OUT_FILE"

# 2) 特殊字符安全：原样保留、未被执行/展开
assert '$(whoami) 原样保留'       grep -qF '$(whoami)' "$OUT_FILE"
assert '$(rm -rf /) 原样保留'     grep -qF '$(rm -rf /)' "$OUT_FILE"
assert '未展开出真实用户名'        bash -c '! grep -qF "$(whoami)@" "'"$OUT_FILE"'"'
assert '反引号命令原样保留'        grep -qF '`whoami`' "$OUT_FILE"

# 3) 白名单占位符全部被消耗，不残留在输出里
assert '无 ${SESSION_DATE} 残留'    bash -c '! grep -qF "\${SESSION_DATE}" "'"$OUT_FILE"'"'
assert '无 ${transcript} 残留'      bash -c '! grep -qF "\${transcript}" "'"$OUT_FILE"'"'
assert '无 ${speaker_stats} 残留'   bash -c '! grep -qF "\${speaker_stats}" "'"$OUT_FILE"'"'
assert '无 ${outlook_context} 残留' bash -c '! grep -qF "\${outlook_context}" "'"$OUT_FILE"'"'

# 4) outlook_context 注入行为
if $WITH_OUTLOOK; then
    assert 'outlook 内容已注入'        grep -qF 'OUTLOOK-MARKER-7f3a' "$OUT_FILE"
    assert 'outlook 元字符原样保留'    grep -qF '议程正文含元字符: $(whoami) 和 ${foo} 与 `date` 都不能执行' "$OUT_FILE"
else
    # 无 outlook 文件：背景信息节标题在，但 ${outlook_context} 替换为空
    assert '背景信息节标题存在'        grep -qF '## 会议背景信息（来自日历）' "$OUT_FILE"
    assert '无 outlook 标记泄漏'       bash -c '! grep -qF "OUTLOOK-MARKER" "'"$OUT_FILE"'"'
fi

# 转录内容里的非白名单 ${foo}/${bar} 必须原样保留（perl 只替换白名单）
assert '${foo} 原样保留'          grep -qF '花括号变量 ${foo} 和 ${bar} 要原样保留' "$OUT_FILE"

if [[ $fail -eq 0 ]]; then
    echo "全部断言通过"
else
    echo "存在失败断言" >&2
    exit 1
fi
