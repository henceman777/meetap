# MeeTap Ctrl-C 停止 & 休眠自动结束 设计

> 状态：待确认
> 日期：2026-10-20

## 背景与目标

当前 `meetap start` 把 ffmpeg / audio-tap / 波形全部 `disown` 到后台后立即退出，带来两个问题：

1. 终端里按 Ctrl-C 对录音毫无作用，只能另敲 `meetap stop`；关闭终端窗口后录音无人收尾。
2. Mac 休眠（合盖、`pmset sleepnow`）时录音进程被冻结，唤醒后状态不可预期，文件可能未正常收尾。

目标：

- **Ctrl-C ≡ `meetap stop`**（关闭终端窗口同理）。
- **休眠 ⇒ 结束本场录音**，只收尾文件、不启动转录；唤醒后提示用户执行 `meetap again <session>` 完成转录 + 纪要。

## 范围与边界

**做：**
- `start` 在有 TTY 时改为前台运行，捕获 INT/TERM/HUP 后执行 stop。
- 新增休眠监听，休眠前以「仅收尾」模式结束录音，唤醒后发系统通知。
- 修复「音频上传后即删除本地文件」导致转录中断后 `again` 无法重跑的问题。

**不做（YAGNI）：**
- 不做休眠暂停 / 唤醒续录（多段拼接）。
- 唤醒后不自动执行 `again`（刚唤醒网络常未就绪，交给用户手动触发）。
- 不改 `again` 的逻辑——它已支持「无 `transcript.txt` 时从 m4a 重跑全链路」（`src/meetap` `again_session`）。

## 一、Ctrl-C 等效 stop

### 运行模式

| 场景 | 行为 |
|---|---|
| 有 TTY（终端直接执行） | **前台模式（新默认）**：`start` 不退出，自己跑波形循环，Ctrl-C 结束 |
| 无 TTY（MCP、脚本、`autostop_daemon` 内部的 `$0 stop` 等） | 保持现状：后台运行后立即返回 |
| 有 TTY + `-b/--background` | 保持现状（给需要继续使用该终端的用户） |

### 实现要点

1. **录音子进程脱离前台进程组**：脚本内对拉起 tap / ffmpeg / monitor / autostop / sleep-watch 的区段开启 `set -m`，使每个后台任务拥有独立进程组。否则终端 SIGINT 会同时打到 ffmpeg、audio-tap，与 stop 的有序收尾抢跑。
   - 副作用：开启作业控制后，bash 不再把后台任务的 stdin 自动重定向到 `/dev/null`，后台进程组读终端会收到 SIGTTIN 被挂起。因此**所有后台子进程一律显式 `< /dev/null`**（ffmpeg 已有；audio-tap、audio-monitor、autostop、sleep-watch 需补上）。
2. **前台循环**：现有 `start_visualizer` 由后台改为前台调用（不再写 `VISUALIZER_PID_FILE`）。循环条件仍是 ffmpeg 存活，因此 `-d` 自停或休眠触发的 stop 杀掉 ffmpeg 后，前台循环自然退出，`start` 正常结束。
3. **trap 必须在拉起任何子进程之前安装**：有了 `set -m`，子进程收不到 Ctrl-C。如果 trap 装晚了，在启动阶段（tap 健康探测最多重试 3 轮，约 9 秒）按下 Ctrl-C，只会杀掉 `start` 本身，ffmpeg / tap 变成无人管理的孤儿进程继续录音。

   ```bash
   trap '_on_interrupt' INT TERM HUP
   _on_interrupt() {
       trap '' INT TERM HUP      # 防止 stop 过程中再次 Ctrl-C 重入
       stop_recording
       exit 0
   }
   ```

4. **退出时恢复终端**：前台循环结束（无论 trap 还是自然退出）都执行 `teardown_statusbar`，恢复滚动区域。
5. **后台转录抗 HUP**：`transcribe_recording` 是 shell 函数，无法用 `nohup` 包裹。改为在子 shell 里忽略 HUP，并放进独立进程组（`set -m` 生效）：`( trap '' HUP; transcribe_recording "$OUTPUT_FILE" "$SESSION_DIR" ) < /dev/null &`。这样关闭终端窗口触发的 stop 之后，转录不会被连带杀死。
   - 终端关闭后，stop 往 tty 的输出会以 EIO 失败。脚本没有 `set -e`，不影响收尾流程。
6. **启动早期中断**：ffmpeg 尚未起来时按 Ctrl-C，`stop_recording` 已能容忍 PID 文件缺失（打印「无进行中的录音」后退出），但需确认 BlackHole 模式下输出设备能恢复（`ORIGINAL_NAME_FILE` 在切换前已写入）。

## 二、休眠时结束录音

### 组件：`audio-multi-output sleep-watch`

放在 `audio-multi-output`（`$TOOL`）而非 `audio-tap`：前者 Tap / BlackHole 两种模式都会用到，且不涉及 TCC 的 Info.plist 与签名问题。Makefile 为它追加 `-framework IOKit`。

```
audio-multi-output sleep-watch <meetap 路径>
```

行为：

1. `IORegisterForSystemPower` 注册电源回调，`CFRunLoopRun()` 常驻。
2. `kIOMessageCanSystemSleep`（空闲休眠询问）：直接 `IOAllowPowerChange`，不阻止休眠。
3. `kIOMessageSystemWillSleep`：同步执行 `meetap stop --sleep`，**最长等 25 秒**（系统上限约 30 秒），随后 `IOAllowPowerChange` 放行。
4. `kIOMessageSystemHasPoweredOn`（唤醒）：若本轮执行过 stop，调用 `meetap _wake-notify` 发通知，然后退出。
5. **尚未处理过休眠时**，若发现 ffmpeg PID 文件消失（录音已被手动 stop / 自停），自行退出。处理过休眠后**不再做此检查**，因为 `stop --sleep` 本身就会删掉 PID 文件，检查会让 watcher 在唤醒前退出、漏发通知。

由 `start` 在录音成功启动后拉起，**所有运行模式（前台、`-b`、无 TTY）都拉起**，PID 写入 `$STATE_DIR/sleepwatch.pid`。

只响应系统休眠；锁屏和显示器休眠不会触发。

### `meetap stop --sleep`

参数解析：现有分发只把 `$2` 传给 `stop_recording`，需改为 `"${@:2}"`，并循环解析 `-t` 与 `--sleep`。

`stop_recording` 拆成两段：

- **收尾段**：停 ffmpeg / tap / monitor、恢复输出设备、清理 PID 与电平文件（即现有逻辑去掉最后的转录）。
- **转录段**：启动后台 `transcribe_recording`。

`--sleep` 时：
- 只执行收尾段，**不启动转录**。
- **不杀 sleep-watch**（它是调用方，需活到唤醒发通知）；普通 stop 则 kill `sleepwatch.pid`。
- 把会话目录名写入 `$STATE_DIR/pending-again`。

### `meetap _wake-notify`（内部子命令，不出现在 usage）

- 读 `pending-again`，发 macOS 通知（文案走 i18n）：
  「录音已因休眠结束，运行 `meetap again <session>` 生成纪要」。
- 通知中带**具体 session 名**：`again` 无参数时取最新会话，若用户唤醒后先开了新会议会选错。
- `meetap status` 在空闲时若存在 `pending-again`，追加一行同样的提示；`again` 处理该 session 成功后删除 `pending-again`。

## 三、本地音频删除时机修复

现状（`transcribe_recording`）：`audio_persist=false` 时，**上传 S3 成功后立即**删本地 m4a。若随后休眠/断网导致转录未完成，`transcript.txt` 不存在且本地音频已删，`again` 报 `ERR_AGAIN_NO_AUDIO`，录音永久丢失。

修复：删除动作移到 `transcript.txt` 成功落盘之后。默认配置（`audio_persist=true`）不受影响。

## 测试

自动化（`test/` 下新增脚本）：
- `meetap stop --sleep`：断言不产生转录进程、`pending-again` 内容正确、sleep-watch 未被 kill。
- Ctrl-C：用 `script` 提供伪终端运行 `meetap start`，**向 pty 写入 `\x03`**（不要直接 `kill -INT <pid>`，那测不到「终端信号发给前台进程组」这条路径）。断言 ffmpeg 有序退出、m4a 可被 ffprobe 正常读取、转录进程已拉起。
- 启动阶段 Ctrl-C：在健康探测期间发送 `\x03`，断言没有残留 ffmpeg / audio-tap 进程，BlackHole 模式下输出设备已恢复。
- 无 TTY 运行 `start`：断言立即返回（回归现有行为）。

手动：
- `pmset sleepnow` 休眠 → 唤醒，确认通知出现、m4a 完整、`meetap again <session>` 生成纪要。
- 合盖休眠同上。
- 录音中关闭终端窗口，确认录音收尾且转录完成。
- Tap 与 BlackHole 两种模式各验证一次。
