# shellcheck shell=bash
# ui.sh - MeeTap UI 抽象层
#
# 有 gum (https://github.com/charmbracelet/gum) 且在交互终端时用 gum 美化；
# 否则降级为纯文本（与历史行为一致）。本文件被 src/meetap source，
# 也可单独 source 用于测试。
#
# 降级保证：
#   - gum 不在 PATH        → 纯文本
#   - 无 TTY（管道/CI 环境）→ 纯文本，绝不挂起等待 gum 的 TUI

# gum 是否可用
_ui_has_gum() { command -v gum &>/dev/null; }

# 输入类函数（choose/confirm）：需要 stdin 是终端才能起 TUI
_ui_can_prompt() { _ui_has_gum && [[ -t 0 ]]; }

# 输出类函数（card/spin/markdown）：需要 stdout 是终端才有美化意义
_ui_can_style() { _ui_has_gum && [[ -t 1 ]]; }

# ui_choose 选项1 选项2 ...  →  stdout 输出选中项（多选一）
# 降级：编号列表 + read；非法/空输入回退到第一项，不循环追问（避免非交互卡死）
ui_choose() {
    if _ui_can_prompt; then
        gum choose "$@"
    else
        local i=1 item choice
        for item in "$@"; do
            echo "  $i) $item" >&2
            ((i++))
        done
        IFS= read -rp "选择 [1-$#]: " choice || choice=""
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= $# )); then
            shift $((choice - 1))
        fi
        echo "$1"
    fi
}

# ui_confirm [提示语]  →  返回 0=是 / 1=否
# 降级：read y/n，默认否；stdin 关闭或空输入 → 否（不挂起）
ui_confirm() {
    if _ui_can_prompt; then
        gum confirm "$@"
    else
        local prompt="${1:-确认?}" yn=""
        IFS= read -rp "$prompt [y/N]: " yn || yn=""
        [[ "$yn" =~ ^[Yy] ]]
    fi
}

# ui_pause [提示语]  →  暂停等待任意确认（"按 Enter 继续"语义），永远返回 0
# gum 路径：单按钮 confirm（negative 置空只剩「继续」按钮）；Esc 取消也照样继续
# 降级：read 等 Enter；EOF/管道 不挂起
ui_pause() {
    local prompt="${1:-按 Enter 继续...}"
    if _ui_can_prompt; then
        gum confirm --affirmative="继续" --negative="" "$prompt" || true
    else
        local _discard
        IFS= read -rp "$prompt" _discard || true
    fi
    return 0
}

# ui_spin 标题 命令 [参数...]  →  执行命令，期间显示 spinner
# 降级：先打印标题（stderr），再直接执行命令；返回命令退出码
ui_spin() {
    local title="${1:-}"
    shift
    if _ui_can_style && [[ -t 2 ]]; then
        gum spin --spinner dot --title "$title" -- "$@"
    else
        [[ -n "$title" ]] && echo "$title" >&2
        "$@"
    fi
}

# ui_card 行1 行2 ...  →  带圆角边框的卡片
# 降级：逐行原样打印（与历史 echo 输出一致）
ui_card() {
    if _ui_can_style; then
        # 逐行作为参数传入（管道方式会丢首行的前导空格，导致缩进不齐）
        gum style --border rounded --padding "0 2" "$@"
    else
        printf '%s\n' "$@"
    fi
}

# ui_markdown  →  从 stdin 读 Markdown 并渲染
# 降级：cat 原样输出
ui_markdown() {
    if _ui_can_style; then
        gum format
    else
        cat
    fi
}
