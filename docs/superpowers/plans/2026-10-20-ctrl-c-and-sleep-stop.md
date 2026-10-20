# Ctrl-C 停止 & 休眠自动结束 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 终端里 Ctrl-C（或关窗口）等效 `meetap stop`；Mac 休眠前自动结束录音（只收尾不转录），唤醒后通知用户 `meetap again <session>`。

**Architecture:** `start` 在有 TTY 时留在前台跑波形，`trap INT TERM HUP` 调 `stop_recording`；录音子进程用 `set -m` 放进独立进程组，避开终端信号。休眠监听是 `audio-multi-output sleep-watch` 子命令（IOKit `IORegisterForSystemPower`），WillSleep 时同步跑 `meetap stop --sleep`，唤醒时跑 `meetap _wake-notify`。

**Tech Stack:** bash（`src/meetap`）、Swift + IOKit（`src/audio-multi-output.swift`）、bash 测试脚本 + python3 `pty`。

**Spec:** `docs/superpowers/specs/2026-10-20-ctrl-c-and-sleep-stop-design.md`

## Global Constraints

- 分支：`feature/ctrl-c-sleep-stop`（已创建）。
- commit message 用中文 conventional 风格（`feat:` / `fix:` / `test:` / `docs:`），**不加 Co-Authored-By 行**。
- 所有用户可见文案走 i18n：`src/i18n/messages-zh-CN.sh` 与 `src/i18n/messages-en-US.sh` **同时**加。
- 通知文案里不得出现双引号和反引号（会打断 `osascript -e "display notification \"...\""`）。
- 状态目录可通过环境变量 `MEETAP_STATE_DIR` 覆盖（默认 `/tmp/meeting-record`），测试一律用临时目录。
- 测试不得触达 AWS：PATH 前置假的 `aws`（让 `sts get-caller-identity` 返回空，转录在 `ERR_AWS_CREDS_MISSING` 处返回）和假的 `osascript`（记录参数，不弹通知）。
- 后台子进程一律 `< /dev/null`（`set -m` 下后台进程组读终端会被 SIGTTIN 挂起）。
- `set -m` 只包住 `cmd &` 那一行（实测：常开会让前台的 `sleep` 等也成组，抢走终端信号）。
- 实测结论（已验证）：`set -m; cmd & ; set +m` 后台进程 PGID 独立，pty 里 Ctrl-C 只触发脚本 trap、不影响该进程；pty 测试驱动必须持续读取 master fd，否则 bash 卡在退出（STAT=E）。

## File Structure

| 文件 | 改动 |
|---|---|
| `src/meetap` | `STATE_DIR` 可覆盖；新状态文件变量；`stop_recording` 参数解析 / `--sleep` / 早期中断收尾 / 抗 HUP 转录；`wake_notify`；`show_status` 待办提示；`again_session` 清待办；`transcribe_recording` 删音频时机；`start_recording` 前台模式 / `-b` / 进程组 / sleep-watch 启动；分发表 |
| `src/i18n/messages-zh-CN.sh`、`messages-en-US.sh` | 新文案 + usage 更新 |
| `src/audio-multi-output.swift` | `sleep-watch` 子命令 |
| `Makefile` | `audio-multi-output` 追加 `-framework IOKit` |
| `test/sleep-stop-test.sh` | 新增：stop --sleep / 早期中断收尾 / wake-notify / status（无音频设备依赖） |
| `test/sleep-watch-test.sh` | 新增：sleep-watch 模拟休眠与 PID 文件退出 |
| `test/ctrl-c-test.sh` | 新增：真实录音下 pty Ctrl-C、启动阶段 Ctrl-C、无 TTY 回归（需 Tap 授权） |
| `README.md` | 日常使用章节更新 |

---

### Task 1: stop 支持 `--sleep`、早期中断收尾、抗 HUP 转录

**Files:**
- Modify: `src/meetap`（`STATE_DIR` 定义约 197 行；状态文件变量约 202-211 行；`stop_recording` 约 1834-1949 行；分发表 `stop)` 约 2226 行）
- Create: `test/sleep-stop-test.sh`

**Interfaces:**
- Produces:
  - 环境变量 `MEETAP_STATE_DIR` 覆盖状态目录。
  - 全局变量 `SLEEPWATCH_PID_FILE="$STATE_DIR/sleepwatch.pid"`、`PENDING_AGAIN_FILE="$STATE_DIR/pending-again"`。
  - `meetap stop [-t] [--sleep]`：`--sleep` 只收尾、不转录、不杀 sleep-watch，把会话目录 basename 写入 `$PENDING_AGAIN_FILE`；普通 stop 会 kill `$SLEEPWATCH_PID_FILE` 记录的进程。
  - 无 ffmpeg PID 但有 tap / monitor PID 或原输出设备记录时，stop 照常收尾（exit 0）。四者都没有才报 `ERR_NO_ACTIVE_RECORDING` 并 exit 1。

- [ ] **Step 1: 写失败测试 `test/sleep-stop-test.sh`**

```bash
#!/bin/bash
# stop --sleep / 早期中断收尾 回归测试（不需要音频设备、不触达 AWS）
#
# 用法: test/sleep-stop-test.sh
#
# 注意：stop 会执行 pkill -f "audio-tap tap-start"，请勿在录音过程中运行本测试。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEETAP="$REPO_ROOT/src/meetap"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap" "$TMP/rec" "$TMP/fakebin"
cat > "$XDG_CONFIG_HOME/meetap/config" <<EOF
recording_dir = $TMP/rec
language = zh-CN
EOF

# 假 aws：sts 返回空 → 转录在凭证检查处返回，不上传
cat > "$TMP/fakebin/aws" <<'EOF'
#!/bin/bash
exit 0
EOF
# 假 osascript：只记录参数
cat > "$TMP/fakebin/osascript" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/osascript.log"
EOF
chmod +x "$TMP/fakebin/"*
export PATH="$TMP/fakebin:$PATH"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# 造一场「正在录音」的假状态：假 ffmpeg / 假 sleep-watch 都是 sleep 进程
setup_recording() {
    local name="$1"
    SESSION="$TMP/rec/$name"
    mkdir -p "$SESSION/materials"
    AUDIO="$SESSION/meeting_test.m4a"
    ffmpeg -nostdin -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a aac -y "$AUDIO"
    sleep 300 & FAKE_FFMPEG=$!
    sleep 300 & FAKE_WATCH=$!
    echo "$FAKE_FFMPEG" > "$MEETAP_STATE_DIR/ffmpeg.pid"
    echo "$FAKE_WATCH"  > "$MEETAP_STATE_DIR/sleepwatch.pid"
    echo "$SESSION" > "$MEETAP_STATE_DIR/session-dir"
    echo "$AUDIO"   > "$MEETAP_STATE_DIR/output-file"
}

alive() { kill -0 "$1" 2>/dev/null; }

echo "== 用例 1: stop --sleep 只收尾、不转录、不杀 sleep-watch =="
setup_recording "20261020_1000_sleep"
"$MEETAP" stop --sleep > "$TMP/out1.txt" 2>&1
sleep 2
alive "$FAKE_FFMPEG" && fail "ffmpeg 未被停止" || pass "ffmpeg 已停止"
alive "$FAKE_WATCH" && pass "sleep-watch 仍存活" || fail "sleep-watch 被误杀"
[[ "$(cat "$MEETAP_STATE_DIR/pending-again" 2>/dev/null)" == "20261020_1000_sleep" ]] \
    && pass "pending-again 记录了会话名" || fail "pending-again 内容不对: $(cat "$MEETAP_STATE_DIR/pending-again" 2>/dev/null)"
[[ ! -e "$SESSION/log/meetap.log" ]] && pass "未启动转录" || fail "启动了转录"
[[ -f "$AUDIO" ]] && pass "音频保留" || fail "音频丢失"
kill "$FAKE_WATCH" 2>/dev/null

echo "== 用例 2: 普通 stop 杀 sleep-watch 并启动转录 =="
rm -f "$MEETAP_STATE_DIR/pending-again"
setup_recording "20261020_1100_normal"
"$MEETAP" stop > "$TMP/out2.txt" 2>&1
sleep 3
alive "$FAKE_WATCH" && fail "sleep-watch 未被停止" || pass "sleep-watch 已停止"
[[ -s "$SESSION/log/meetap.log" ]] && pass "已启动后台转录" || fail "未启动转录"
[[ ! -e "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && pass "sleepwatch.pid 已清理" || fail "sleepwatch.pid 残留"

echo "== 用例 3: 无 ffmpeg PID、但 monitor 已起（启动阶段被打断）→ 照常收尾 =="
sleep 300 & FAKE_MON=$!
echo "$FAKE_MON" > "$MEETAP_STATE_DIR/monitor.pid"
"$MEETAP" stop > "$TMP/out3.txt" 2>&1; rc=$?
sleep 1
alive "$FAKE_MON" && fail "monitor 未被停止" || pass "monitor 已停止"
[[ $rc -eq 0 ]] && pass "exit 0" || fail "exit $rc"

echo "== 用例 4: 什么都没有 → 报无录音、exit 1（回归） =="
"$MEETAP" stop > "$TMP/out4.txt" 2>&1; rc=$?
[[ $rc -eq 1 ]] && grep -q "没有正在进行的录制" "$TMP/out4.txt" \
    && pass "无录音提示" || fail "rc=$rc out=$(cat "$TMP/out4.txt")"

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
```

- [ ] **Step 2: 运行，确认失败**

Run: `chmod +x test/sleep-stop-test.sh && test/sleep-stop-test.sh`
Expected: 用例 1 FAIL（`--sleep` 不识别，仍启动转录、无 pending-again），用例 2 「sleep-watch 未被停止」FAIL，用例 3 FAIL（rc=1，monitor 未停）。注意：此时 `MEETAP_STATE_DIR` 尚未生效，若用例写入的是临时目录而 meetap 读的是 `/tmp/meeting-record`，现象同样是 FAIL。

- [ ] **Step 3: `STATE_DIR` 可覆盖 + 新状态变量**

`src/meetap` 中替换：

```bash
STATE_DIR="/tmp/meeting-record"
```

为：

```bash
STATE_DIR="${MEETAP_STATE_DIR:-/tmp/meeting-record}"   # 测试可用 MEETAP_STATE_DIR 隔离
```

在 `VISUALIZER_PID_FILE="$STATE_DIR/visualizer.pid"` 下一行追加：

```bash
SLEEPWATCH_PID_FILE="$STATE_DIR/sleepwatch.pid"
PENDING_AGAIN_FILE="$STATE_DIR/pending-again"   # 因休眠结束、待 meetap again 补跑的会话名
```

- [ ] **Step 4: 改 `stop_recording` 开头（参数解析、sleep-watch、早期中断判定）**

替换 `stop_recording` 从函数头到 `rm -f "$PID_FILE"`（ffmpeg 停止段结束）的整段：

```bash
stop_recording() {
    local VERBOSE=false
    [[ "${1:-}" == "-t" || "${1:-}" == "--test" ]] && VERBOSE=true
    stop_visualizer

    # 停止自动停止守护进程
    if [[ -f "$AUTOSTOP_PID_FILE" ]]; then
        kill "$(cat "$AUTOSTOP_PID_FILE")" 2>/dev/null
        rm -f "$AUTOSTOP_PID_FILE" "$MEETING_APPS_FILE"
    fi
    rm -f "$MAX_DURATION_FILE"

    if [[ ! -f "$PID_FILE" ]]; then
        _t ERR_NO_ACTIVE_RECORDING
        exit 1
    fi

    FFMPEG_PID=$(cat "$PID_FILE")

    # 停止 ffmpeg
    if kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill -INT "$FFMPEG_PID"
        _t WAITING_RECORDING
        for i in $(seq 1 15); do
            kill -0 "$FFMPEG_PID" 2>/dev/null || break
            sleep 1
        done
        # 如果 15 秒后仍未退出，强制终止
        if kill -0 "$FFMPEG_PID" 2>/dev/null; then
            _t FFMPEG_FORCE_KILL
            kill -9 "$FFMPEG_PID" 2>/dev/null
            sleep 1
        fi
    fi
    rm -f "$PID_FILE"
```

为：

```bash
stop_recording() {
    local VERBOSE=false
    local SLEEP_MODE=false   # 休眠触发：只收尾录音，不转录，留待唤醒后 meetap again
    local arg
    for arg in "$@"; do
        case "$arg" in
            -t|--test) VERBOSE=true ;;
            --sleep)   SLEEP_MODE=true ;;
        esac
    done
    stop_visualizer

    # 停止自动停止守护进程
    if [[ -f "$AUTOSTOP_PID_FILE" ]]; then
        kill "$(cat "$AUTOSTOP_PID_FILE")" 2>/dev/null
        rm -f "$AUTOSTOP_PID_FILE" "$MEETING_APPS_FILE"
    fi
    rm -f "$MAX_DURATION_FILE"

    # 休眠监听：普通 stop 一并结束；--sleep 是 sleep-watch 自己调的，它要活到唤醒发通知
    if ! $SLEEP_MODE && [[ -f "$SLEEPWATCH_PID_FILE" ]]; then
        kill "$(cat "$SLEEPWATCH_PID_FILE")" 2>/dev/null
        rm -f "$SLEEPWATCH_PID_FILE"
    fi

    # 没有 ffmpeg PID 也可能有残留要收拾：start 启动阶段被 Ctrl-C 打断时，
    # tap / monitor 已起、输出设备已切到 BlackHole，但 ffmpeg 还没写 PID
    if [[ ! -f "$PID_FILE" && ! -f "$TAP_PID_FILE" && ! -f "$MONITOR_PID_FILE" \
          && ! -f "$ORIGINAL_NAME_FILE" ]]; then
        _t ERR_NO_ACTIVE_RECORDING
        exit 1
    fi

    # 停止 ffmpeg
    if [[ -f "$PID_FILE" ]]; then
        FFMPEG_PID=$(cat "$PID_FILE")
        if kill -0 "$FFMPEG_PID" 2>/dev/null; then
            kill -INT "$FFMPEG_PID"
            _t WAITING_RECORDING
            for i in $(seq 1 15); do
                kill -0 "$FFMPEG_PID" 2>/dev/null || break
                sleep 1
            done
            # 如果 15 秒后仍未退出，强制终止
            if kill -0 "$FFMPEG_PID" 2>/dev/null; then
                _t FFMPEG_FORCE_KILL
                kill -9 "$FFMPEG_PID" 2>/dev/null
                sleep 1
            fi
        fi
        rm -f "$PID_FILE"
    fi
```

- [ ] **Step 5: 改 `stop_recording` 结尾（--sleep 不转录、抗 HUP 转录）**

替换：

```bash
        elif [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
            _t TRANSCRIBE_BACKGROUND
            transcribe_recording "$OUTPUT_FILE" "$SESSION_DIR" &
            disown
        fi
```

为：

```bash
        elif [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
            if $SLEEP_MODE; then
                # 马上要休眠，上传会被打断：只记下会话，唤醒后提示 meetap again
                basename "$SESSION_DIR" > "$PENDING_AGAIN_FILE"
            else
                _t TRANSCRIBE_BACKGROUND
                # 忽略 HUP：关闭终端窗口触发的 stop 之后，转录不能被连带杀死
                # （transcribe_recording 是函数，nohup 包不了，只能在子 shell 里 trap）
                ( trap '' HUP; transcribe_recording "$OUTPUT_FILE" "$SESSION_DIR" ) < /dev/null &
                disown
            fi
        fi
```

- [ ] **Step 6: 分发表透传全部参数**

替换：

```bash
    stop)
        stop_recording "${2:-}"
        ;;
```

为：

```bash
    stop)
        stop_recording "${@:2}"
        ;;
```

- [ ] **Step 7: 运行测试，确认通过**

Run: `test/sleep-stop-test.sh`
Expected: 用例 1-4 全部 PASS，最后一行 `✅ 全部通过`。

- [ ] **Step 8: Commit**

```bash
git add src/meetap test/sleep-stop-test.sh
git commit -m "feat: stop 支持 --sleep 只收尾不转录；启动阶段中断也能收尾；转录抗 HUP"
```

---

### Task 2: 唤醒通知、status 待办提示、again 清待办

**Files:**
- Modify: `src/meetap`（`show_status` 约 1951 行；`again_session` 约 1255 行；分发表；新增 `wake_notify` 函数放在 `show_status` 之前）
- Modify: `src/i18n/messages-zh-CN.sh`、`src/i18n/messages-en-US.sh`
- Modify: `test/sleep-stop-test.sh`

**Interfaces:**
- Consumes: `PENDING_AGAIN_FILE`（Task 1）。
- Produces:
  - `meetap _wake-notify`：存在 `$PENDING_AGAIN_FILE` 时发通知（文案 `NOTIFY_SLEEP_STOPPED`，参数：会话名），否则静默 exit 0。不出现在 usage。
  - `meetap status` 空闲时，若有待办，追加 `STATUS_PENDING_AGAIN`（参数：`$0`、会话名）。
  - `again_session` 结束时，若该会话已有 `transcript.txt` 且等于待办会话名，删除 `$PENDING_AGAIN_FILE`。
  - i18n 键：`NOTIFY_SLEEP_STOPPED`、`STATUS_PENDING_AGAIN`。

- [ ] **Step 1: 给 `test/sleep-stop-test.sh` 追加失败用例**

在 `echo ""` / 结果汇总那段**之前**插入：

```bash
echo "== 用例 5: _wake-notify 发通知，带会话名 =="
echo "20261020_1000_sleep" > "$MEETAP_STATE_DIR/pending-again"
rm -f "$TMP/osascript.log"
"$MEETAP" _wake-notify; rc=$?
[[ $rc -eq 0 ]] && grep -q "20261020_1000_sleep" "$TMP/osascript.log" 2>/dev/null \
    && pass "通知含会话名" || fail "rc=$rc osascript=$(cat "$TMP/osascript.log" 2>/dev/null)"

echo "== 用例 6: 无待办时 _wake-notify 静默 =="
rm -f "$MEETAP_STATE_DIR/pending-again" "$TMP/osascript.log"
"$MEETAP" _wake-notify; rc=$?
[[ $rc -eq 0 && ! -e "$TMP/osascript.log" ]] && pass "静默" || fail "rc=$rc 或误发通知"

echo "== 用例 7: status 空闲时提示待办 =="
echo "20261020_1000_sleep" > "$MEETAP_STATE_DIR/pending-again"
"$MEETAP" status > "$TMP/out7.txt" 2>&1
grep -q "again 20261020_1000_sleep" "$TMP/out7.txt" \
    && pass "status 显示待办" || fail "status 输出: $(cat "$TMP/out7.txt")"

echo "== 用例 8: again 已有转录的待办会话 → 清除待办 =="
# 用 claude-code 后端 + 假 claude，避免调用 Bedrock
SESSION="$TMP/rec/20261020_1000_sleep"
mkdir -p "$SESSION/log"
echo "spk_0: 测试" > "$SESSION/log/transcript.txt"
cat > "$TMP/fakebin/claude" <<'EOF'
#!/bin/bash
echo "# 测试纪要"
EOF
chmod +x "$TMP/fakebin/claude"
printf 'recording_dir = %s\nlanguage = zh-CN\nai_backend = claude-code\n' "$TMP/rec" > "$XDG_CONFIG_HOME/meetap/config"
"$MEETAP" again 20261020_1000_sleep > "$TMP/out8.txt" 2>&1
[[ ! -e "$MEETAP_STATE_DIR/pending-again" ]] && pass "待办已清除" || fail "待办残留；again 输出: $(tail -5 "$TMP/out8.txt")"
```

- [ ] **Step 2: 运行，确认用例 5、7、8 失败**

Run: `test/sleep-stop-test.sh`
Expected: 用例 1-4 PASS；用例 5 FAIL（`_wake-notify` 落入 usage 分支，无通知）；用例 6 PASS（usage 不发通知，属正常）；用例 7 FAIL；用例 8 FAIL（待办残留）。

- [ ] **Step 3: 加 i18n 文案**

`src/i18n/messages-zh-CN.sh` 在 `MSG_NOTIFY_NOTES_FAILED=...` 行之后追加：

```bash
MSG_NOTIFY_SLEEP_STOPPED="录音已因休眠结束。运行 meetap again %s 生成纪要"
```

在 `MSG_STATUS_IDLE=...` 行之后追加：

```bash
MSG_STATUS_PENDING_AGAIN="   上次录音因休眠结束，待生成纪要: %s again %s"
```

`src/i18n/messages-en-US.sh` 对应位置追加：

```bash
MSG_NOTIFY_SLEEP_STOPPED="Recording ended because the Mac went to sleep. Run meetap again %s to generate notes"
```

```bash
MSG_STATUS_PENDING_AGAIN="   Last recording ended on sleep, notes pending: %s again %s"
```

- [ ] **Step 4: 加 `wake_notify`，改 `show_status`**

在 `show_status() {` 之前插入：

```bash
# 唤醒通知（内部子命令，由 sleep-watch 在唤醒后调用）：提示用 again 补跑转录与纪要。
# 通知里写具体会话名——again 不带参数取最新会话，唤醒后若先开了新会议会选错。
wake_notify() {
    [[ -f "$PENDING_AGAIN_FILE" ]] || return 0
    local session
    session=$(cat "$PENDING_AGAIN_FILE")
    osascript -e "display notification \"$(_tn NOTIFY_SLEEP_STOPPED "$session")\" with title \"MeeTap\"" 2>/dev/null
    return 0
}

```

在 `show_status` 中替换：

```bash
    else
        ui_card "$(_tn STATUS_IDLE)"
        rm -f "$PID_FILE"
    fi
```

为：

```bash
    else
        local idle_lines=("$(_tn STATUS_IDLE)")
        [[ -f "$PENDING_AGAIN_FILE" ]] && \
            idle_lines+=("$(_tn STATUS_PENDING_AGAIN "$0" "$(cat "$PENDING_AGAIN_FILE")")")
        ui_card "${idle_lines[@]}"
        rm -f "$PID_FILE"
    fi
```

- [ ] **Step 5: `again_session` 末尾清待办**

在 `again_session` 中，替换（函数最后的 if/else 结尾）：

```bash
        _t AGAIN_FROM_TRANSCRIBE "$(basename "$AUDIO_FILE")"
        transcribe_recording "$AUDIO_FILE" "$SESSION_DIR"
    fi
}
```

为：

```bash
        _t AGAIN_FROM_TRANSCRIBE "$(basename "$AUDIO_FILE")"
        transcribe_recording "$AUDIO_FILE" "$SESSION_DIR"
    fi

    # 因休眠结束的会话补跑出转录后，清除待办提示
    if [[ -f "$PENDING_AGAIN_FILE" && -f "$TRANSCRIPT" ]] \
        && [[ "$(cat "$PENDING_AGAIN_FILE")" == "$(basename "$SESSION_DIR")" ]]; then
        rm -f "$PENDING_AGAIN_FILE"
    fi
}
```

- [ ] **Step 6: 分发表加内部子命令**

在 `    mark)` 分支之前插入：

```bash
    _wake-notify)
        wake_notify
        ;;
```

- [ ] **Step 7: 运行测试，确认全部通过**

Run: `test/sleep-stop-test.sh`
Expected: 用例 1-8 全部 PASS。若用例 8 失败，查看 `$TMP/out8.txt` 尾部（测试已打印），确认假 `claude` 被调用；`summarize_via_claude_code` 用 `claude -p ...` 并把 stdout 写入纪要文件。

- [ ] **Step 8: Commit**

```bash
git add src/meetap src/i18n/messages-zh-CN.sh src/i18n/messages-en-US.sh test/sleep-stop-test.sh
git commit -m "feat: 休眠结束后唤醒通知 + status 待办提示，again 补跑后自动清除"
```

---

### Task 3: 本地音频删除改到转录成功之后

**Files:**
- Modify: `src/meetap`（`transcribe_recording` 约 443-446 行与转录 Python 段之后约 555 行）

**Interfaces:**
- Consumes: 无。
- Produces: `audio_persist=false` 时，本地 m4a 仅在 `$LOG_DIR/transcript.txt` 非空落盘后删除。

- [ ] **Step 1: 删除上传后立即删音频的段落**

删除这段（紧跟在 `aws s3 cp ... ERR_UPLOAD_FAILED ... fi` 之后）：

```bash
    if [[ "$CFG_AUDIO_PERSIST" != "true" && ! -f "$STATE_DIR/test-mode" ]]; then
        rm -f "$AUDIO_FILE"
        echo "[$(date '+%H:%M:%S')] $(_tn LOCAL_AUDIO_DELETED)"
    fi
```

- [ ] **Step 2: 在转录文本落盘后删除**

替换（唯一一处带注释的清理）：

```bash
    # Cleanup S3 bucket and Transcribe job
    aws s3 rm "s3://${BUCKET}" --recursive --region "$AWS_REGION" 2>/dev/null
```

为：

```bash
    # 本地音频要等转录文本落盘后再删：上传后立刻删的话，转录中途休眠/断网，
    # transcript 没出来、音频也没了，meetap again 无从重跑
    if [[ "$CFG_AUDIO_PERSIST" != "true" && ! -f "$STATE_DIR/test-mode" && -s "$LOG_DIR/transcript.txt" ]]; then
        rm -f "$AUDIO_FILE"
        echo "[$(date '+%H:%M:%S')] $(_tn LOCAL_AUDIO_DELETED)"
    fi

    # Cleanup S3 bucket and Transcribe job
    aws s3 rm "s3://${BUCKET}" --recursive --region "$AWS_REGION" 2>/dev/null
```

- [ ] **Step 3: 静态检查 + 回归**

Run: `bash -n src/meetap && grep -n 'LOCAL_AUDIO_DELETED' src/meetap && test/sleep-stop-test.sh`
Expected: `bash -n` 无输出；`LOCAL_AUDIO_DELETED` 只出现 1 次，且行号在 `Transcript saved` 的 Python 段之后；测试全部 PASS。

（该路径依赖真实 AWS 转录，自动化测试覆盖不到，在 Task 6 手动验证。）

- [ ] **Step 4: Commit**

```bash
git add src/meetap
git commit -m "fix: audio_persist=false 时本地音频改为转录成功后再删，避免中断后无法 again"
```

---

### Task 4: `audio-multi-output sleep-watch`

**Files:**
- Modify: `src/audio-multi-output.swift`（顶部 import；`// MARK: - Main` 之前插入函数；usage 文本；`switch cmd` 加 case）
- Modify: `Makefile`（`audio-multi-output` 规则）
- Create: `test/sleep-watch-test.sh`

**Interfaces:**
- Produces: `audio-multi-output sleep-watch <meetap-path> <ffmpeg-pid-file> [--simulate-sleep]`
  - WillSleep：同步执行 `<meetap-path> stop --sleep`（最多 25s），再 `IOAllowPowerChange`。
  - CanSystemSleep：直接放行。
  - HasPoweredOn：若处理过休眠，执行 `<meetap-path> _wake-notify`（最多 10s）后 exit 0。
  - 未处理过休眠时，每 2s 检查 `<ffmpeg-pid-file>`，不存在即 exit 0。
  - `--simulate-sleep`：不注册 IOKit，直接依次走 WillSleep → HasPoweredOn（测试用）。

- [ ] **Step 1: 写失败测试 `test/sleep-watch-test.sh`**

```bash
#!/bin/bash
# sleep-watch 回归测试：模拟休眠调用顺序 + PID 文件消失即退出
# 用法: test/sleep-watch-test.sh   （真实休眠/唤醒见计划 Task 6 手动验证）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
BIN="$TMP/audio-multi-output"

echo "== 编译 audio-multi-output =="
swiftc -O -framework CoreAudio -framework AudioToolbox -framework IOKit \
    "$REPO_ROOT/src/audio-multi-output.swift" -o "$BIN" || exit 1

cat > "$TMP/fake-meetap" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/calls.log"
EOF
chmod +x "$TMP/fake-meetap"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

echo "== 用例 1: 模拟休眠 → 先 stop --sleep 再 _wake-notify =="
"$BIN" sleep-watch "$TMP/fake-meetap" "$TMP/none.pid" --simulate-sleep; rc=$?
expected=$'stop --sleep\n_wake-notify'
[[ $rc -eq 0 && "$(cat "$TMP/calls.log" 2>/dev/null)" == "$expected" ]] \
    && pass "调用顺序正确" || fail "rc=$rc calls=$(cat "$TMP/calls.log" 2>/dev/null)"

echo "== 用例 2: PID 文件存在时常驻，删除后 2s 内退出 =="
rm -f "$TMP/calls.log"
touch "$TMP/ffmpeg.pid"
"$BIN" sleep-watch "$TMP/fake-meetap" "$TMP/ffmpeg.pid" & W=$!
sleep 3
kill -0 $W 2>/dev/null && pass "常驻" || fail "提前退出"
rm -f "$TMP/ffmpeg.pid"
sleep 3
kill -0 $W 2>/dev/null && fail "PID 文件删除后未退出" || pass "已退出"
[[ ! -e "$TMP/calls.log" ]] && pass "未调用 meetap" || fail "误调用: $(cat "$TMP/calls.log")"

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
```

- [ ] **Step 2: 运行，确认失败**

Run: `chmod +x test/sleep-watch-test.sh && test/sleep-watch-test.sh`
Expected: 编译通过；用例 1 FAIL（`Unknown command: sleep-watch`）；用例 2「提前退出」FAIL。

- [ ] **Step 3: 实现 sleep-watch**

`src/audio-multi-output.swift` 顶部 `import Foundation` 之后追加：

```swift
import IOKit.pwr_mgt
```

在 `// MARK: - Main` 之前插入：

```swift
// MARK: - sleep-watch：系统休眠前结束录音，唤醒后发通知

// IOKit 的消息常量是函数式宏（iokit_common_msg），Swift 导入不了，按定义手算：
// sys_iokit(0xE0000000) | sub_iokit_common(0) | message
let kMsgCanSystemSleep: UInt32 = 0xE000_0270
let kMsgSystemWillSleep: UInt32 = 0xE000_0280
let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

// IOKit 回调是 C 函数指针，不能捕获上下文，状态放全局
var swRootPort: io_connect_t = 0
var swMeetap = ""
var swSleepHandled = false

/// 同步执行 meetap 子命令，最多等 timeout 秒（休眠回调里不能无限阻塞，系统上限约 30s）
func swRunMeetap(_ arguments: [String], timeout: TimeInterval) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: swMeetap)
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
        fputs("sleep-watch: failed to run \(swMeetap): \(error)\n", stderr); return }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(100_000) }
}

func swHandleWillSleep() {
    guard !swSleepHandled else { return }
    swRunMeetap(["stop", "--sleep"], timeout: 25)
    swSleepHandled = true
}

func swHandlePoweredOn() {
    guard swSleepHandled else { return }
    swRunMeetap(["_wake-notify"], timeout: 10)
    exit(0)
}

func runSleepWatch(meetap: String, pidFile: String, simulate: Bool) {
    swMeetap = meetap
    if simulate {   // 测试用：不注册 IOKit，直接走一遍休眠→唤醒
        swHandleWillSleep()
        swHandlePoweredOn()
        exit(0)
    }
    var notifyPort: IONotificationPortRef?
    var notifier: io_object_t = 0
    swRootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, messageType, messageArgument in
        switch messageType {
        case kMsgCanSystemSleep:
            IOAllowPowerChange(swRootPort, Int(bitPattern: messageArgument))
        case kMsgSystemWillSleep:
            swHandleWillSleep()
            IOAllowPowerChange(swRootPort, Int(bitPattern: messageArgument))
        case kMsgSystemHasPoweredOn:
            swHandlePoweredOn()
        default:
            break
        }
    }, &notifier)
    guard swRootPort != 0, let port = notifyPort else {
        fputs("sleep-watch: IORegisterForSystemPower failed\n", stderr); exit(1) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                       .defaultMode)
    // 录音被手动 stop / 自停后 PID 文件消失 → 退出。处理过休眠后不再检查：
    // stop --sleep 本身会删 PID 文件，watcher 要活到唤醒发通知
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        if !swSleepHandled && !FileManager.default.fileExists(atPath: pidFile) { exit(0) }
    }
    CFRunLoopRun()
}

```

usage 文本中，在 `      cleanup              清理遗留的 Meeting Multi-Output 设备` 之后加一行：

```
      sleep-watch <meetap> <pid-file>  休眠前执行 meetap stop --sleep，唤醒后 _wake-notify
```

`switch cmd` 中，在 `case "cleanup":` 之前插入：

```swift
case "sleep-watch":
    guard args.count >= 3 else {
        fputs("Usage: sleep-watch <meetap-path> <ffmpeg-pid-file> [--simulate-sleep]\n", stderr); exit(1) }
    runSleepWatch(meetap: args[1], pidFile: args[2], simulate: args.contains("--simulate-sleep"))
```

- [ ] **Step 4: Makefile 链接 IOKit**

替换：

```make
$(BUILD)/audio-multi-output: src/audio-multi-output.swift
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox $< -o $@
```

为（缩进必须是 Tab）：

```make
$(BUILD)/audio-multi-output: src/audio-multi-output.swift
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox -framework IOKit $< -o $@
```

- [ ] **Step 5: 运行测试 + make**

Run: `test/sleep-watch-test.sh && make all`
Expected: 用例 1、2 全部 PASS；`make all` 成功，生成 `build/audio-multi-output`。

- [ ] **Step 6: Commit**

```bash
git add src/audio-multi-output.swift Makefile test/sleep-watch-test.sh
git commit -m "feat: audio-multi-output 新增 sleep-watch，休眠前结束录音、唤醒后通知"
```

---

### Task 5: start 前台模式 + Ctrl-C ≡ stop + 启动 sleep-watch

**Files:**
- Modify: `src/meetap`（全局变量区；`start_recording` 约 1462-1832 行；新增 `_jobctl_on` / `_jobctl_off` / `_on_start_interrupt` / `start_sleepwatch` / `foreground_wait`，放在 `start_recording` 之前）
- Modify: `src/i18n/messages-zh-CN.sh`、`src/i18n/messages-en-US.sh`
- Create: `test/ctrl-c-test.sh`

**Interfaces:**
- Consumes: `SLEEPWATCH_PID_FILE`、`PENDING_AGAIN_FILE`、`stop_recording`（Task 1）；`$TOOL sleep-watch`（Task 4）。
- Produces:
  - `meetap start [-t] [-d N] [-m] [-b] [name]`：有 TTY 且无 `-b` → 前台，Ctrl-C / 关窗口 / SIGTERM ≡ `meetap stop`；否则维持旧的后台行为。
  - 所有模式下录音成功后启动 sleep-watch，PID 写入 `$SLEEPWATCH_PID_FILE`。
  - 全局 `FOREGROUND`（默认 `false`）、`START_TTY`。
  - i18n 键：`FIELD_STOP_CTRL_C`（参数 `$0`）、`SLEEP_STOPPED_HINT`（参数 `$0`、会话名）；`USAGE_START` 更新。

- [ ] **Step 1: 写测试 `test/ctrl-c-test.sh`**

```bash
#!/bin/bash
# Ctrl-C ≡ stop 回归测试（真实录音，pty 驱动）
#
# 用法: test/ctrl-c-test.sh
# 前提: macOS 14.4+、已 make all、终端已授予「系统音频录制」权限。
#       测试期间请勿播放音频；不录麦克风（-m），不触达 AWS（假 aws）。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PREFIX="$TMP/bin"
cleanup() {
    pkill -f "$PREFIX/" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "== 组装临时安装目录 =="
[[ -x "$REPO_ROOT/build/audio-tap" ]] || { echo "请先 make all"; exit 1; }
mkdir -p "$PREFIX/i18n" "$PREFIX/lib"
cp "$REPO_ROOT/src/meetap" "$PREFIX/"
cp "$REPO_ROOT/src/i18n/"*.sh "$PREFIX/i18n/"
cp "$REPO_ROOT/src/lib/ui.sh" "$PREFIX/lib/"
cp "$REPO_ROOT/build/audio-tap" "$REPO_ROOT/build/audio-multi-output" "$REPO_ROOT/build/audio-monitor" "$PREFIX/"
codesign --force --sign - "$PREFIX/audio-tap"   # cp 会破坏 ad-hoc 签名

if ! "$PREFIX/audio-tap" tap-supported >/dev/null 2>&1; then
    echo "SKIP: 本机不支持 Process Tap"; exit 0
fi

export MEETAP_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$MEETAP_STATE_DIR" "$XDG_CONFIG_HOME/meetap" "$TMP/rec" "$TMP/fakebin"
printf 'recording_dir = %s\nlanguage = zh-CN\naudio_capture = tap\n' "$TMP/rec" > "$XDG_CONFIG_HOME/meetap/config"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fakebin/aws"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fakebin/osascript"
chmod +x "$TMP/fakebin/"*
export PATH="$TMP/fakebin:$PATH"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# pty 驱动：启动 meetap start -m，delay 秒后写入 ^C，返回退出所用秒数（超时 40 输出 TIMEOUT）。
# 必须持续读 master fd，否则 bash 退出时卡在 tty 输出（实测 STAT=E）。
run_pty_ctrl_c() {
    local delay="$1" name="$2"
    python3 - "$PREFIX/meetap" "$delay" "$name" <<'PYEOF'
import os, pty, sys, threading, time
meetap, delay, name = sys.argv[1], float(sys.argv[2]), sys.argv[3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(meetap, [meetap, "start", "-m", name])
def drain():
    try:
        while os.read(fd, 4096): pass
    except OSError: pass
threading.Thread(target=drain, daemon=True).start()
time.sleep(delay)
os.write(fd, b"\x03")
t0 = time.time()
while time.time() - t0 < 40:
    if os.waitpid(pid, os.WNOHANG)[0]:
        print(f"{time.time() - t0:.1f}"); sys.exit(0)
    time.sleep(0.2)
print("TIMEOUT")
PYEOF
}

no_leftovers() {
    ! pgrep -f "$PREFIX/audio-tap tap-start" >/dev/null && ! pgrep -f "ffmpeg.*$TMP/rec" >/dev/null
}

echo "== 用例 1: 录音中 Ctrl-C → 有序 stop =="
r=$(run_pty_ctrl_c 6 ctrlc)
[[ "$r" != "TIMEOUT" ]] && pass "start 已退出（${r}s）" || fail "Ctrl-C 后 start 未退出"
sleep 2
no_leftovers && pass "无残留 tap/ffmpeg" || fail "残留进程: $(pgrep -fl "$PREFIX/|$TMP/rec")"
M4A=$(find "$TMP/rec" -name '*.m4a' -path '*ctrlc*' | head -1)
DUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$M4A" 2>/dev/null)
[[ -n "$DUR" ]] && pass "m4a 可读（${DUR}s）" || fail "m4a 不可读: $M4A"
[[ -s "$(dirname "$M4A")/log/meetap.log" ]] && pass "已启动转录" || fail "未启动转录"
[[ ! -e "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && ! pgrep -f "$PREFIX/audio-multi-output sleep-watch" >/dev/null \
    && pass "sleep-watch 已结束" || fail "sleep-watch 残留"

echo "== 用例 2: 启动阶段 Ctrl-C → 无残留 =="
r=$(run_pty_ctrl_c 0.8 early)
[[ "$r" != "TIMEOUT" ]] && pass "start 已退出（${r}s）" || fail "start 未退出"
sleep 2
no_leftovers && pass "无残留 tap/ffmpeg" || fail "残留进程: $(pgrep -fl "$PREFIX/|$TMP/rec")"

echo "== 用例 3: 无 TTY → 立即返回（回归），stop 正常 =="
t0=$(date +%s)
"$PREFIX/meetap" start -m notty < /dev/null > "$TMP/notty.txt" 2>&1
el=$(( $(date +%s) - t0 ))
(( el < 20 )) && pass "无 TTY 立即返回（${el}s）" || fail "无 TTY 阻塞 ${el}s"
[[ -f "$MEETAP_STATE_DIR/sleepwatch.pid" ]] && kill -0 "$(cat "$MEETAP_STATE_DIR/sleepwatch.pid")" 2>/dev/null \
    && pass "sleep-watch 已启动" || fail "sleep-watch 未启动"
sleep 2
"$PREFIX/meetap" stop < /dev/null > "$TMP/notty-stop.txt" 2>&1
sleep 2
no_leftovers && pass "stop 后无残留" || fail "stop 后残留"

echo ""
if (( FAIL )); then echo "❌ 有用例失败"; exit 1; else echo "✅ 全部通过"; fi
```

- [ ] **Step 2: 运行，确认失败**

Run: `make all && chmod +x test/ctrl-c-test.sh && test/ctrl-c-test.sh`
Expected: 用例 1「Ctrl-C 后 start 未退出」不一定出现（旧 start 本来就立即退出），但「已启动转录」与「m4a 可读」FAIL（录音没被 stop，仍在跑），「sleep-watch」相关 FAIL；用例 3「sleep-watch 未启动」FAIL。测试 cleanup 会 pkill 残留进程。

- [ ] **Step 3: i18n 文案**

`src/i18n/messages-zh-CN.sh` 在 `MSG_FIELD_STOP_CMD=...` 之后追加：

```bash
MSG_FIELD_STOP_CTRL_C="   停止录制: Ctrl-C（或在其他终端运行 %s stop）"
MSG_SLEEP_STOPPED_HINT="💤 录音已因休眠结束。运行 %s again %s 生成纪要"
```

替换 `MSG_USAGE_START=...` 整行为：

```bash
MSG_USAGE_START="  start [-t] [-d 分钟] [-m] [-b] [会议名] 开始录制（默认前台运行，Ctrl-C 结束；-b 后台运行，不占用终端；-t 详细信息；-d 指定时长上限，到点自动结束；-m/--mute-mic 不开麦克风，只录电脑声音）"
```

`src/i18n/messages-en-US.sh` 对应：

```bash
MSG_FIELD_STOP_CTRL_C="   Stop recording: Ctrl-C (or run %s stop in another terminal)"
MSG_SLEEP_STOPPED_HINT="💤 Recording ended because the Mac went to sleep. Run %s again %s to generate notes"
```

```bash
MSG_USAGE_START="  start [-t] [-d MIN] [-m] [-b] [name] Start recording (runs in the foreground, Ctrl-C to stop; -b runs in the background and frees the terminal; -t verbose; -d sets a time limit, auto-stops when reached; -m/--mute-mic leaves the mic off and records computer audio only)"
```

- [ ] **Step 4: 全局变量与辅助函数**

在 `SLEEPWATCH_PID_FILE=...` 那组变量之后追加：

```bash
FOREGROUND=false   # start 前台模式（有 TTY 且未加 -b），由 start_recording 设置
START_TTY=""
```

在 `start_recording() {` 之前插入：

```bash
# 前台模式下，后台子进程放进独立进程组（set -m），终端 Ctrl-C 只打到 start 本身、
# 由 trap 走有序 stop；否则 SIGINT 会同时打到 ffmpeg / tap，与收尾抢跑。
# 只包住 `cmd &` 那一行：-m 常开会让前台的 sleep 等命令也各自成组、抢走终端信号。
_jobctl_on()  { $FOREGROUND && set -m; }
_jobctl_off() { set +m; }

# start 前台模式下 Ctrl-C / 关窗口 / kill：等效 meetap stop
_on_start_interrupt() {
    trap '' INT TERM HUP      # 防止 stop 过程中再次 Ctrl-C 重入
    teardown_statusbar "$START_TTY" 2>/dev/null
    stop_recording
    exit 0
}

# 休眠监听：系统休眠前以 stop --sleep 结束录音，唤醒后发通知（所有运行模式都启动）
start_sleepwatch() {
    [[ -f "$SLEEPWATCH_PID_FILE" ]] && kill "$(cat "$SLEEPWATCH_PID_FILE")" 2>/dev/null
    _jobctl_on
    "$TOOL" sleep-watch "$SCRIPT_DIR/meetap" "$PID_FILE" \
        < /dev/null > "$STATE_DIR/sleepwatch.log" 2>&1 &
    local pid=$!
    _jobctl_off
    echo "$pid" > "$SLEEPWATCH_PID_FILE"
    disown "$pid"
}

# 前台等待：在当前终端跑波形直到录音结束。Ctrl-C 走 trap；-d 自停或休眠触发的
# stop 杀掉 ffmpeg 后循环自然退出
foreground_wait() {
    sleep 0.1
    setup_statusbar "$START_TTY"
    start_visualizer "$START_TTY"
    # 波形写终端失败会提前跳出循环；录音仍在就继续守着，保证 Ctrl-C 依然有效
    while kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; do sleep 1; done
    teardown_statusbar "$START_TTY" 2>/dev/null
    local session
    session=$(basename "$SESSION_DIR")
    if [[ -f "$PENDING_AGAIN_FILE" && "$(cat "$PENDING_AGAIN_FILE")" == "$session" ]]; then
        _t SLEEP_STOPPED_HINT "$0" "$session"
    fi
}

```

- [ ] **Step 5: `start_recording` 选项解析加 `-b`，安装 trap**

在 `local MUTE_MIC=false ...` 一行之后加：

```bash
    local BACKGROUND=false      # -b：维持旧的后台行为，不占用终端
```

在选项 `case` 中 `-m|--mute-mic|--mute-microphone)` 分支之前插入：

```bash
            -b|--background)
                BACKGROUND=true
                shift
                ;;
```

替换：

```bash
    # 清理残留状态。关键：上次异常停止可能留下孤儿 audio-tap（stop 只杀
```

为（即在「已在录制」检查之后、清理残留之前插入一段，原注释行保留）：

```bash
    # 前台模式：有 TTY 且未加 -b。start 不退出、跑波形，Ctrl-C / 关窗口 ≡ meetap stop。
    # trap 必须在拉起任何子进程之前装：子进程在独立进程组里收不到 Ctrl-C，装晚了，
    # 启动阶段的 Ctrl-C 只会杀掉 start 自己，留下孤儿录音。
    # 也必须在「已在录制」检查之后装，否则那时的 Ctrl-C 会误停正在进行的录音。
    START_TTY=$(tty 2>/dev/null)
    [[ "$START_TTY" == "not a tty" ]] && START_TTY=""
    if ! $BACKGROUND && [[ -n "$START_TTY" ]]; then
        FOREGROUND=true
        trap '_on_start_interrupt' INT TERM HUP
    fi

    # 清理残留状态。关键：上次异常停止可能留下孤儿 audio-tap（stop 只杀
```

- [ ] **Step 6: Tap 分支后台启动处包进程组 + `< /dev/null`**

替换：

```bash
            "$TAP_TOOL" tap-start "${mic_args[@]}" \
                --level-file "$STATE_DIR/tap-level" \
                > "$TAP_FIFO" 2>"$STATE_DIR/tap.log" &
            TAP_PID=$!
```

为：

```bash
            _jobctl_on
            "$TAP_TOOL" tap-start "${mic_args[@]}" \
                --level-file "$STATE_DIR/tap-level" \
                < /dev/null > "$TAP_FIFO" 2>"$STATE_DIR/tap.log" &
            TAP_PID=$!
            _jobctl_off
```

替换（Tap 分支的 ffmpeg，以 `-i "$TAP_FIFO"` 区分）：

```bash
            ffmpeg -y -f f32le -ar "$TAP_RATE" -ac 1 -i "$TAP_FIFO" \
                -c:a aac -b:a "$CFG_AUDIO_BITRATE" -ac 1 \
                -movflags frag_keyframe+empty_moov \
                "$OUTPUT_FILE" \
                < /dev/null > "$STATE_DIR/ffmpeg.log" 2>&1 &

            FFMPEG_PID=$!
```

为：

```bash
            _jobctl_on
            ffmpeg -y -f f32le -ar "$TAP_RATE" -ac 1 -i "$TAP_FIFO" \
                -c:a aac -b:a "$CFG_AUDIO_BITRATE" -ac 1 \
                -movflags frag_keyframe+empty_moov \
                "$OUTPUT_FILE" \
                < /dev/null > "$STATE_DIR/ffmpeg.log" 2>&1 &

            FFMPEG_PID=$!
            _jobctl_off
```

- [ ] **Step 7: BlackHole 分支 monitor / ffmpeg 包进程组**

替换：

```bash
    "$MONITOR" "$BH_UID" "$ORIG_UID" > "$STATE_DIR/monitor.log" 2>&1 &
    MONITOR_PID=$!
```

为：

```bash
    _jobctl_on
    "$MONITOR" "$BH_UID" "$ORIG_UID" < /dev/null > "$STATE_DIR/monitor.log" 2>&1 &
    MONITOR_PID=$!
    _jobctl_off
```

替换（BlackHole 分支的 ffmpeg，以 `-i ":BlackHole 2ch"` + `mic_args` 区分）：

```bash
        "$OUTPUT_FILE" \
        < /dev/null > "$STATE_DIR/ffmpeg.log" 2>&1 &

    FFMPEG_PID=$!
```

为：

```bash
        "$OUTPUT_FILE" \
        < /dev/null > "$STATE_DIR/ffmpeg.log" 2>&1 &

    FFMPEG_PID=$!
    _jobctl_off
```

并在该 ffmpeg 命令的首行 `    ffmpeg -y -f avfoundation -i ":BlackHole 2ch" \` 之前加一行：

```bash
    _jobctl_on
```

- [ ] **Step 8: 两个分支的 autostop 包进程组；停止提示按模式切换**

两个分支中都有（缩进不同，Tap 分支 16 空格，BlackHole 分支 12 空格）：

```bash
autostop_daemon &
```

两处都改为（保持原缩进）：

```bash
_jobctl_on; autostop_daemon < /dev/null &
```

并在紧随其后的 `AUTOSTOP_PID=$!` 行之后加 `_jobctl_off`（同缩进）。

两个分支中的：

```bash
_t FIELD_STOP_CMD "$0"
```

两处都改为（保持原缩进）：

```bash
if $FOREGROUND; then _t FIELD_STOP_CTRL_C "$0"; else _t FIELD_STOP_CMD "$0"; fi
```

- [ ] **Step 9: 删除两个分支里的波形启动块，统一到函数末尾**

两个分支中各有一段（Tap 分支带注释 `# 点阵波形 + 状态栏...`，BlackHole 分支无注释）：

```bash
        local TTY_DEV
        TTY_DEV=$(tty 2>/dev/null)
        if [[ -n "$TTY_DEV" && "$TTY_DEV" != "not a tty" ]]; then
            sleep 0.1
            setup_statusbar "$TTY_DEV"
            start_visualizer "$TTY_DEV" &
            echo $! > "$VISUALIZER_PID_FILE"
            disown $!
        fi
```

两处整段删除（Tap 分支连同上方注释行 `# 点阵波形 + 状态栏（与 BlackHole 分支一致；电平来自 tap-level 文件）` 一起删）。

替换 `start_recording` 结尾：

```bash
    fi  # 闭合 if use_tap / else (BlackHole 分支结束)
}
```

为：

```bash
    fi  # 闭合 if use_tap / else (BlackHole 分支结束)

    # 走到这里说明录音已成功启动（两个分支失败时都已 exit）
    start_sleepwatch
    if $FOREGROUND; then
        foreground_wait
    elif [[ -n "$START_TTY" ]]; then
        # -b 后台模式：保持旧行为，波形在后台画到终端底部
        sleep 0.1
        setup_statusbar "$START_TTY"
        start_visualizer "$START_TTY" &
        echo $! > "$VISUALIZER_PID_FILE"
        disown $!
    fi
}
```

- [ ] **Step 10: 静态检查**

Run: `bash -n src/meetap && grep -c '_jobctl_on' src/meetap && grep -c '_jobctl_off' src/meetap; grep -n 'TTY_DEV' src/meetap`
Expected: `bash -n` 无输出；`_jobctl_on` 计数 = 8（定义 1 + tap 1 + ffmpeg 2 + monitor 1 + autostop 2 + sleepwatch 1），`_jobctl_off` 计数同为 8；最后的 `grep TTY_DEV` 无输出（两个分支里的旧波形块已删干净；`start_visualizer` 内部用的是小写 `tty_dev`）。

- [ ] **Step 11: 运行全部测试**

Run: `make all && test/ctrl-c-test.sh && test/sleep-stop-test.sh && test/sleep-watch-test.sh`
Expected: 三个脚本均 `✅ 全部通过`。

- [ ] **Step 12: Commit**

```bash
git add src/meetap src/i18n/messages-zh-CN.sh src/i18n/messages-en-US.sh test/ctrl-c-test.sh
git commit -m "feat: start 默认前台运行，Ctrl-C/关窗口等效 stop；-b 保留后台模式；录音期间启动休眠监听"
```

---

### Task 6: README + 手动验证

**Files:**
- Modify: `README.md`（「四、日常使用」章节，约 183-245 行）

- [ ] **Step 1: 更新 README**

替换：

```markdown
```bash
meetap start   # 开会前或开会过程中随时可以敲
meetap stop    # 会议结束后敲；自动转录 + 生成纪要
```
```

为：

```markdown
```bash
meetap start   # 开会前或开会过程中随时可以敲；终端底部显示波形
               # 会议结束按 Ctrl-C（等同 meetap stop）：自动转录 + 生成纪要
```

`meetap start` 默认在前台运行、占用当前终端。想继续用这个终端，加 `-b` 在后台运行，结束时再敲 `meetap stop`。录音期间关闭终端窗口，也会像 `stop` 一样正常收尾。
```

三个示例输出块里的 `   停止录制: /Users/you/bin/meetap stop` 都改为：

```
   停止录制: Ctrl-C（或在其他终端运行 /Users/you/bin/meetap stop）
```

在「音频采集期间」列表末尾追加一条：

```markdown
- **Mac 休眠（合盖等）时自动结束本场录音**：只把音频文件收尾，不在休眠前上传转录；唤醒后会弹通知，按提示运行 `meetap again <会话名>` 生成纪要（`meetap status` 也会显示这条待办）。锁屏、显示器休眠不受影响
```

- [ ] **Step 2: 手动验证清单（逐项执行并记录结果）**

1. Tap 模式：`make install` 后 `meetap start 手测`，放一段音频 30s，按 Ctrl-C → 终端恢复正常滚动、提示后台转录，几分钟后收到纪要通知。
2. 休眠：`meetap start 休眠测`，20s 后运行 `pmset sleepnow` → 唤醒 → 收到「录音已因休眠结束」通知；终端里出现 `💤` 提示；`meetap status` 显示待办；`meetap again <会话名>` 生成纪要；再 `meetap status` 待办消失。
3. 合盖休眠：同 2，用合盖代替 `pmset sleepnow`。
4. 关窗口：`meetap start 关窗测`，直接关闭终端窗口 → 另开终端 `meetap status` 显示未在录制；几分钟后收到纪要通知（转录未被 HUP 杀死）。
5. `-b`：`meetap start -b`，终端立即可用、底部有波形；`meetap stop` 正常结束；`ps aux | grep sleep-watch` 无残留。
6. `-d 1`：前台 `meetap start -d 1`，1 分钟后自动结束，`start` 自行退出、终端恢复。
7. BlackHole 模式：配置 `audio_capture = blackhole`，重复 1，并在启动后 1 秒内 Ctrl-C，确认系统输出设备已恢复为原设备。
8. `audio_persist = false`：录一段，转录完成后本地 m4a 被删除、纪要正常；`log/meetap.log` 中 `LOCAL_AUDIO_DELETED` 出现在转录完成之后。
9. 锁屏（Ctrl-Cmd-Q）30s 后解锁 → 录音未中断。

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README 补充 Ctrl-C 结束、-b 后台模式与休眠自动结束"
```
