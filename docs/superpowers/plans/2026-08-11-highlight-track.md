# Highlight Track 实现计划（纪要要点高亮）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 `meetap highlight [dir]` 命令，用 LLM 给已生成的会议纪要 markdown 补一层 `<mark>` 要点高亮，且保证不改动正文一个字。

**Architecture:** 独立后处理命令，纯手动触发，不碰生成/邮件/PDF 流程。复用现有 `summarize_via_bedrock` / `summarize_via_claude_code`（二者接口均为 `<prompt文件> <输出文件>`）作为 LLM 调用层；高亮策略固化进独立模板 `share/meetap/prompts/highlight.md`；写回前用 Python 做「剥掉 `<mark>` 后逐字节比对」的校验闸门，正文被改则拒绝写入。

**Tech Stack:** Bash（主脚本 `src/meetap`）、Python 3（校验闸门，标准库即可，不需要 boto3）、现有 i18n 机制（`MSG_<KEY>` shell 变量）、golden-diff 风格的 bash 测试（见 `test/track3-golden-test.sh`）。

## Global Constraints

以下为 spec 的项目级约束，每个 Task 都隐含适用：

- **只改 `src/` 下源文件**，不直接改 `~/bin/`（改完 `make install` 同步）。
- **高亮仅落在 markdown 源文件**，不改邮件 HTML / PDF 渲染链路。
- **纯手动触发**，不介入录制后自动流程。
- **只加 `<mark>` 不改字**：写回前必须通过校验闸门（剥标后逐字节比对），不一致则拒绝写入、保留原文件、打印告警。
- **幂等**：对已高亮文件重跑，先剥旧 `<mark>` 再重标，不产生嵌套。
- **复用现有 LLM 分派**，不新写调用代码，不做超出「让 highlight 能复用」目的的重构。
- **i18n 双份**：所有面向用户的文案在 `messages-zh-CN.sh` 与 `messages-en-US.sh` 同步新增（纪要正文语言不变，仅界面文案）。
- **固定高亮策略**：只标「关键数字/指标、核心判断与结论、案例结果」；每段最多 1-2 处；不标行动计划表格、签名页脚、顶部 blockquote 元信息区。
- **禁用非包容性词汇**（master/slave/whitelist/blacklist 等），代码与注释均遵守。
- **提交信息不加 Co-Authored-By 行**。

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `share/meetap/prompts/highlight.md` | 高亮 prompt 模板（策略 + 「只加 mark 不改字」严令 + 占位符 `${notes}`） | 新建 |
| `src/meetap` | `highlight)` case 分支、`highlight_notes()` 函数、纪要文件定位、prompt 组装、校验闸门调用、帮助行 | 修改 |
| `src/i18n/messages-zh-CN.sh` | 中文文案 | 修改 |
| `src/i18n/messages-en-US.sh` | 英文文案 | 修改 |
| `test/highlight-verify-test.sh` | 校验闸门的 golden/单元测试 | 新建 |
| `README.md` | 命令文档 | 修改 |

`highlight_notes()` 内部用现成的 `summarize_via_bedrock`/`summarize_via_claude_code`（无需新建 LLM 层）与 Python 校验闸门。Makefile 的 install 已自动拷贝 `share/meetap/prompts/*.md`，无需改 Makefile。

---

## Task 1: 高亮 prompt 模板

**Files:**
- Create: `share/meetap/prompts/highlight.md`

**Interfaces:**
- Produces: 一个含单一占位符 `${notes}` 的模板文件。`highlight_notes()`（Task 3）会读它、把 `${notes}` 替换为纪要正文、写入临时 prompt 文件。

- [ ] **Step 1: 写模板文件**

创建 `share/meetap/prompts/highlight.md`，内容如下：

```markdown
你的唯一任务是给下面这份会议纪要 markdown **添加要点高亮标记**，帮助读者一眼抓住重点。

## 绝对铁律（违反即视为失败）

- **逐字保留原文**。你只能在原文中**插入** `<mark>` 和 `</mark>` 两种标签，**不得增、删、改任何其他字符**——包括标点、空格、换行、大小写、markdown 语法。
- 输出 = 原文 + 若干对 `<mark></mark>`。把你输出里所有 `<mark>` 和 `</mark>` 删掉后，必须和原文**一字不差**。
- 不要输出任何解释、前言、代码块包裹，直接输出加了高亮的 markdown 全文。
- 如果原文里已经有 `<mark>` 标签，忽略它们（当作普通文本，调用方已提前清理过）。

## 标什么（只标这三类）

1. **关键数字 / 指标**：增长倍数、百分比、金额、日期、deadline、市占率等硬数据。
2. **核心判断与结论**：会议的关键定性、决策、观点性结论。
3. **案例结果**：标杆客户、迁移成果、客户评价等的结论性表述。

## 标多密

- 每个自然段最多标 1-2 处，只标那一句里最要害的片段，不要整段包起来。
- `## 关键结论` 区：每条列表项标 1-2 处。
- 目标是突出重点，不是满页泛黄。

## 不要标的区域

- `行动计划 & 待定事项` 表格（本身已是结构化要点）。
- 末尾以 `——` 开头的 Meetap 签名落款那一段。
- 顶部引用块（`>` 开头的 会议时间/会议性质/关键词/与会人员 元信息区）。

## 待高亮的纪要正文

${notes}
```

- [ ] **Step 2: 校验模板占位符存在**

Run: `grep -F '${notes}' share/meetap/prompts/highlight.md`
Expected: 输出含 `${notes}` 的那一行（确认占位符没写错）。

- [ ] **Step 3: Commit**

```bash
git add share/meetap/prompts/highlight.md
git commit -m "feat(highlight): 新增纪要要点高亮 prompt 模板"
```

---

## Task 2: 校验闸门（Python）+ 测试

先落地最关键、最独立的一环：给定「原文」和「LLM 输出」，判断输出是否只是原文加了 `<mark>`。这段逻辑用 Python inline heredoc 实现，Task 3 会从 bash 调它。本任务先把它写成一个可独立测试的 Python 脚本片段，并用 golden 测试锁定行为。

**Files:**
- Create: `test/highlight-verify-test.sh`
- Modify: `src/meetap`（仅新增 `_highlight_verify_py()` 一个函数，输出 Python 源码字符串，供测试与 Task 3 共用；本任务不接线到命令分派）

**Interfaces:**
- Produces: `_highlight_verify_py()` —— 无参数，向 stdout 打印一段 Python 源码。该 Python 程序：
  - `argv[1]` = 原始纪要文件路径，`argv[2]` = LLM 输出文件路径。
  - 读两个文件，各自用正则 `re.sub(r'</?mark>', '', text)` 剥掉所有 `<mark>`/`</mark>`。
  - 剥标后两串**完全相等** → `sys.exit(0)`；否则 → `sys.exit(2)`。
  - 退出码契约：`0` = 通过（可写回），`2` = 正文被改（拒绝写回）。

- [ ] **Step 1: 写失败测试**

创建 `test/highlight-verify-test.sh`：

```bash
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

exit $fail
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash test/highlight-verify-test.sh`
Expected: FAIL —— `sed` 抽不到 `_highlight_verify_py`（函数尚不存在），`eval` 空串后 `$PY` 为空，python3 报参数/语法错，脚本非 0 退出。

- [ ] **Step 3: 在 `src/meetap` 新增 `_highlight_verify_py()`**

在 `src/meetap` 中 `_tn()` 函数定义之后（约第 128 行，紧跟 i18n 辅助函数之后）插入：

```bash
# 输出校验闸门的 Python 源码：判断 LLM 输出是否只是原文加了 <mark>。
# 用 Python 而非 bash 做逐字节比对——bash 处理多字节/换行/特殊字符不可靠。
# argv[1]=原始纪要, argv[2]=LLM 输出。剥掉所有 <mark>/</mark> 后：
#   相等 → exit 0（可写回）; 不等 → exit 2（正文被改，拒绝写回）。
_highlight_verify_py() {
    cat <<'PYEOF'
import re, sys

def strip_marks(s):
    return re.sub(r'</?mark>', '', s)

with open(sys.argv[1], 'r') as f:
    original = f.read()
with open(sys.argv[2], 'r') as f:
    llm_out = f.read()

if strip_marks(original) == strip_marks(llm_out):
    sys.exit(0)
sys.exit(2)
PYEOF
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `bash test/highlight-verify-test.sh`
Expected: 四条全 PASS，脚本 exit 0。

- [ ] **Step 5: Commit**

```bash
git add test/highlight-verify-test.sh src/meetap
git commit -m "feat(highlight): 校验闸门——剥 mark 后逐字节比对，正文被改则拒写"
```

---

## Task 3: `highlight_notes()` 主函数 + 命令分派 + i18n + 文档

把各环节接起来：定位纪要文件 → 组装 prompt → 调 LLM → 过校验闸门 → 写回。并接入命令分派、i18n、帮助与 README。

**Files:**
- Modify: `src/meetap`（新增 `highlight_notes()`；在 case 分发处加 `highlight)` 分支；帮助输出加一行）
- Modify: `src/i18n/messages-zh-CN.sh`
- Modify: `src/i18n/messages-en-US.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes:
  - `_highlight_verify_py()`（Task 2）——输出校验 Python 源码。
  - `summarize_via_bedrock <prompt文件> <输出文件>` 与 `summarize_via_claude_code <prompt文件> <输出文件>`（现有，约 `src/meetap:694`/`:791`）——LLM 调用层。
  - `$CFG_AI_BACKEND`（现有，`bedrock` / `claude-code`）、`$VENV_PYTHON`、`$RECORDING_DIR`、`$SCRIPT_DIR`、`_t`/`_tn`（现有）。
- Produces:
  - `highlight_notes <可选目录>` —— 对目标会话的纪要 md 原地加高亮。
  - 命令：`meetap highlight [dir]`。

**背景（实现者必读）：**
- 纪要文件名**不是固定的** `meeting-notes.md`。生成流程末尾 `smart_name_notes` 会把它 mv 成 `<YYYY-MM-DD>_<HHMM>_<主题>.md`。所以要在会话目录里**查找**实际纪要 md：取目录下最新的 `*.md`，**排除** `archive/` 子目录、`prompt.md`、`extra-requirements.md`。
- 目录解析规则与 `again_session`（`src/meetap` 约 :1150）一致：不传参 → 最新 `20*` 目录；传目录名 → `$RECORDING_DIR/<名>`；传绝对路径 → 直接用。

- [ ] **Step 1: 新增 i18n 文案（中文）**

在 `src/i18n/messages-zh-CN.sh` 的「Usage」区（`MSG_USAGE_AGAIN` 那一带）加 usage 行，并在文件合适分区加 highlight 专用文案：

```bash
MSG_USAGE_HIGHLIGHT="  highlight [dir]  给纪要要点加高亮标记（默认最新会话）"

# ── Highlight（纪要要点高亮）──
MSG_HL_TARGET="🖍  高亮目标：%s"
MSG_HL_GENERATING="   正在标注要点..."
MSG_HL_DONE="✅ 已高亮：%s"
MSG_HL_UNCHANGED="ℹ️  未发现可高亮的内容，文件未改动"
MSG_ERR_HL_NO_NOTES="❌ 会话目录下没有找到纪要 markdown 文件：%s"
MSG_ERR_HL_SESSION_NOT_FOUND="❌ 找不到会话「%s」（在 %s 下）"
MSG_ERR_HL_NO_SESSIONS="❌ %s 下没有任何会话记录"
MSG_ERR_HL_TEMPLATE_MISSING="❌ 高亮模板缺失或损坏：%s"
MSG_ERR_HL_VERIFY_FAILED="❌ 模型改动了正文（不只是加高亮），已放弃写入，原文件保持不变"
MSG_ERR_HL_LLM_FAILED="❌ 高亮生成失败（LLM 未产出内容）"
```

- [ ] **Step 2: 新增 i18n 文案（英文）**

在 `src/i18n/messages-en-US.sh` 对应位置加同名 key：

```bash
MSG_USAGE_HIGHLIGHT="  highlight [dir]  Highlight key points in the notes (default: latest session)"

# ── Highlight ──
MSG_HL_TARGET="🖍  Highlight target: %s"
MSG_HL_GENERATING="   Marking key points..."
MSG_HL_DONE="✅ Highlighted: %s"
MSG_HL_UNCHANGED="ℹ️  Nothing to highlight; file left unchanged"
MSG_ERR_HL_NO_NOTES="❌ No notes markdown file found in session dir: %s"
MSG_ERR_HL_SESSION_NOT_FOUND="❌ Session '%s' not found (under %s)"
MSG_ERR_HL_NO_SESSIONS="❌ No sessions found under %s"
MSG_ERR_HL_TEMPLATE_MISSING="❌ Highlight template missing or invalid: %s"
MSG_ERR_HL_VERIFY_FAILED="❌ Model altered the body (not just added highlights); write aborted, original file unchanged"
MSG_ERR_HL_LLM_FAILED="❌ Highlight generation failed (LLM produced no content)"
```

- [ ] **Step 3: 写 `highlight_notes()` 函数**

在 `src/meetap` 中 `again_session()` 函数之后插入：

```bash
# 纪要要点高亮：给已生成的纪要 md 原地补 <mark> 高亮。独立后处理，不碰生成流程。
# 复用 summarize_via_* 作为 LLM 层；写回前过校验闸门，正文被改则拒写。
highlight_notes() {
    local target="${1:-}"
    local SESSION_DIR

    # 目录解析（与 again_session 一致）
    if [[ -n "$target" ]]; then
        if [[ -d "$target" ]]; then
            SESSION_DIR="$(cd "$target" && pwd)"
        elif [[ -d "$RECORDING_DIR/$target" ]]; then
            SESSION_DIR="$RECORDING_DIR/$target"
        else
            _t ERR_HL_SESSION_NOT_FOUND "$target" "$RECORDING_DIR"
            exit 1
        fi
    else
        SESSION_DIR=$(find "$RECORDING_DIR" -maxdepth 1 -type d -name "20*" | sort | tail -1)
        if [[ -z "$SESSION_DIR" ]]; then
            _t ERR_HL_NO_SESSIONS "$RECORDING_DIR"
            exit 1
        fi
    fi

    # 定位实际纪要 md：目录下最新 *.md，排除 archive/、prompt.md、extra-requirements.md。
    # （纪要经 smart_name_notes 已 mv 成 <日期>_<时间>_<主题>.md，文件名不固定）
    local NOTES="" f
    for f in $(find "$SESSION_DIR" -maxdepth 1 -type f -name "*.md" | sort); do
        case "$(basename "$f")" in
            prompt.md|extra-requirements.md) continue ;;
        esac
        NOTES="$f"   # sort 升序，最后一个即最新命名
    done
    if [[ -z "$NOTES" ]]; then
        _t ERR_HL_NO_NOTES "$SESSION_DIR"
        exit 1
    fi
    _t HL_TARGET "$(basename "$NOTES")"

    # 找高亮模板（dev 树 / install 树两种前缀），需含 ${notes} 占位符
    local TPL="" cand
    for cand in \
        "$SCRIPT_DIR/../share/meetap/prompts/highlight.md" \
        "$SCRIPT_DIR/share/meetap/prompts/highlight.md"; do
        if [[ -f "$cand" ]] && grep -qF '${notes}' "$cand"; then
            TPL="$cand"; break
        fi
    done
    if [[ -z "$TPL" ]]; then
        _t ERR_HL_TEMPLATE_MISSING "share/meetap/prompts/highlight.md"
        exit 1
    fi

    # 组装 prompt：先剥掉纪要里可能已有的 <mark>（保证幂等），再替换 ${notes}。
    # 用 python 做替换：纪要正文含 & / 反斜杠等，sed/bash 替换不安全。
    local LOG_DIR="$SESSION_DIR/log"; mkdir -p "$LOG_DIR"
    local PROMPT_FILE="$LOG_DIR/.highlight-prompt.tmp"
    local LLM_OUT="$LOG_DIR/.highlight-out.tmp"
    local PYBIN="$VENV_PYTHON"; [[ -x "$PYBIN" ]] || PYBIN="$(command -v python3)"

    "$PYBIN" - "$TPL" "$NOTES" "$PROMPT_FILE" <<'PYEOF'
import re, sys
tpl_path, notes_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(tpl_path) as f: tpl = f.read()
with open(notes_path) as f: notes = f.read()
notes = re.sub(r'</?mark>', '', notes)          # 剥旧高亮，保证幂等
prompt = tpl.replace('${notes}', notes)          # 字面替换，不走 shell
with open(out_path, 'w') as f: f.write(prompt)
PYEOF

    _t HL_GENERATING
    # 复用现有 LLM 分派（接口：<prompt文件> <输出文件>）
    rm -f "$LLM_OUT"
    case "$CFG_AI_BACKEND" in
        claude-code) summarize_via_claude_code "$PROMPT_FILE" "$LLM_OUT" ;;
        bedrock|*)   summarize_via_bedrock "$PROMPT_FILE" "$LLM_OUT" ;;
    esac

    if [[ ! -s "$LLM_OUT" ]]; then
        _t ERR_HL_LLM_FAILED
        rm -f "$PROMPT_FILE" "$LLM_OUT"
        exit 1
    fi

    # 校验闸门：剥 mark 后与原文逐字节比对（原文同样剥 mark，应对重标）
    "$PYBIN" -c "$(_highlight_verify_py)" "$NOTES" "$LLM_OUT"
    local vrc=$?
    if [[ $vrc -ne 0 ]]; then
        _t ERR_HL_VERIFY_FAILED
        rm -f "$PROMPT_FILE" "$LLM_OUT"
        exit 1
    fi

    # 通过：写回原文件。若输出与原文完全相同（模型没标任何东西），提示未改动。
    if cmp -s "$NOTES" "$LLM_OUT"; then
        _t HL_UNCHANGED
    else
        mv "$LLM_OUT" "$NOTES"
        _t HL_DONE "$(basename "$NOTES")"
    fi
    rm -f "$PROMPT_FILE" "$LLM_OUT"
}
```

- [ ] **Step 4: 接入命令分派**

在 `src/meetap` 底部 case 分发中，`again)` 分支之后插入：

```bash
    highlight)
        highlight_notes "${2:-}"
        ;;
```

- [ ] **Step 5: 帮助输出加一行**

在帮助输出区 `_t USAGE_AGAIN` 之后插入一行：

```bash
        _t USAGE_HIGHLIGHT
```

- [ ] **Step 6: 语法自检 + 命令可达性**

Run: `bash -n src/meetap && echo SYNTAX_OK`
Expected: 输出 `SYNTAX_OK`（无语法错）。

Run: `bash src/meetap help 2>&1 | grep -i highlight`
Expected: 输出含 highlight 的 usage 行（确认帮助已接线；注意 `help`/无参分支会打印 usage）。

- [ ] **Step 7: 端到端 smoke（无 LLM，验证「无纪要文件」错误路径）**

用一个空的假会话目录验证错误分支不崩、走的是 i18n 文案：

Run:
```bash
TMP=$(mktemp -d); mkdir -p "$TMP/20250715_1430"; \
RECORDING_DIR_OVERRIDE="$TMP" bash -c '
  # 直接指定目录，触发「目录存在但没有 md」分支
  out=$(bash src/meetap highlight "'"$TMP"'/20250715_1430" 2>&1); echo "$out"
'; rm -rf "$TMP"
```
Expected: 输出包含「没有找到纪要 markdown 文件」（`MSG_ERR_HL_NO_NOTES`），进程以非 0 退出，不出现 `<missing:...>`（说明 i18n key 都已定义）。

- [ ] **Step 8: 更新 README**

在 README 命令列表 / `again` 附近新增一节：

```markdown
### 🖍 纪要要点高亮（可选）

纪要生成后，想让重点更醒目：

    meetap highlight            # 给最新会话的纪要加要点高亮
    meetap highlight <目录名>    # 指定某次会议

会用 LLM 给纪要里的关键数字、核心结论、案例结果套上 `<mark>` 标记（在 VS Code / Typora / GitHub / 浏览器里显示为黄色底色）。

- **只加标记、不改正文**：写回前会逐字比对，一旦发现模型改动了正文，直接放弃、原文件保持不变。
- **可反复运行**：重跑会先清掉上次的高亮再重标，不会层层嵌套。
- 高亮**只写进 markdown 源文件**，不影响邮件与 PDF。
```

- [ ] **Step 9: 校验闸门测试仍通过（回归）**

Run: `bash test/highlight-verify-test.sh`
Expected: 四条全 PASS（确认 Task 3 的改动没破坏 Task 2 的函数）。

- [ ] **Step 10: Commit**

```bash
git add src/meetap src/i18n/messages-zh-CN.sh src/i18n/messages-en-US.sh README.md
git commit -m "feat(highlight): meetap highlight 命令——定位纪要、调 LLM、校验后写回"
```

---

## Task 4: 安装联调（可选人工验证）

**Files:** 无（仅构建/安装/手测）

- [ ] **Step 1: 安装到 ~/bin**

Run: `make install > /tmp/hl-install.log 2>&1 && tail -5 /tmp/hl-install.log`
Expected: 无报错；`~/bin/share/meetap/prompts/highlight.md` 已就位（install 规则拷贝 `prompts/*.md`）。

Run: `ls ~/bin/share/meetap/prompts/highlight.md`
Expected: 文件存在。

- [ ] **Step 2: 对一份真实纪要手测（需 AWS/Bedrock 或 claude-code 后端）**

准备一份含数字/结论/表格的 `meeting-notes.md` 放进某个会话目录，运行：

Run: `meetap highlight <该会话目录>`
Expected: 提示 `✅ 已高亮：<文件名>`；打开该 md，关键数字/结论被 `<mark>` 包裹，行动计划表格与签名落款未被标注；再跑一次不产生嵌套 `<mark><mark>`。

- [ ] **Step 3:（如有改动）Commit**

若联调中发现并修了小问题：

```bash
git add -A
git commit -m "fix(highlight): 联调修正"
```

---

## Self-Review

**1. Spec coverage（逐条对照 spec）：**
- 独立后处理命令 `meetap highlight [dir]` → Task 3 ✅
- 复用现有 LLM 调用链（不新写） → Task 3 Step 3（调 `summarize_via_*`）✅
- 幂等（重跑先剥旧 mark） → Task 3 Step 3 prompt 组装处剥标 + 校验对比也剥标 ✅
- 「只加 mark 不改字」校验闸门 → Task 2（实现+测试）+ Task 3（接线）✅
- 固定高亮策略（三类/密度/不标区域） → Task 1 模板 ✅
- 仅 markdown 源文件、不碰邮件/PDF → 全程只改会话目录的 md，未触碰渲染链 ✅
- 纯手动、不自动触发 → 只加 case 分支，未改 start/again 流程 ✅
- i18n 双份 → Task 3 Step 1/2 ✅
- 改动清单（src/meetap、highlight.md、i18n、README）→ 全覆盖；Makefile 无需改（已确认 install 拷贝 prompts）✅
- 测试要点：幂等（Task 4 Step 2 手测）、校验闸门（Task 2 自动测试）、目录解析（复用 again 模式）、模板缺失（Task 3 有 `ERR_HL_TEMPLATE_MISSING`）、纪要不存在（Task 3 Step 7 smoke）✅

**2. Placeholder scan：** 无 TBD/TODO；每个代码步骤都给了完整代码；错误处理均为具体 i18n key，非「add error handling」。✅

**3. Type/命名一致性：**
- `_highlight_verify_py` 在 Task 2 定义、Task 3 Step 3 调用，名称一致 ✅
- 退出码契约（0=通过/2=被改）在 Task 2 与 Task 3 校验分支一致 ✅
- i18n key（`HL_*` / `ERR_HL_*` / `USAGE_HIGHLIGHT`）在 zh/en 两份与 `highlight_notes` 调用处逐一对应 ✅
- `summarize_via_bedrock/claude_code` 的 `<prompt文件> <输出文件>` 接口与现有定义一致 ✅

无遗留问题。
