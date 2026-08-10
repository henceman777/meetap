# Process Tap 静默空录排障记录

分支：`fix/bedrock-timeout-retry`
涉及文件：`src/meetap` 的 `start_recording()`、`_tap_audio_flowing()`；`src/audio-tap.swift`
状态：已修复并验证（commit `5709f85`）

这条支线专治「短会议偶发录出 0 字节音频、开完会才发现整段丢失」的问题。本文记录根因、诊断信号和修复，供日后回溯。

---

## 背景

`meetap` 在 macOS 14.4+ 默认走 **Process Tap** 采集音频：`audio-tap`（Swift）在进程内用 `AudioHardwareCreateProcessTap` + aggregate device 采系统音、同进程混入麦克风，输出 Float32 LE mono PCM 到 stdout，经 FIFO 喂给 ffmpeg 编码成 m4a。

- 采集链路：`audio-tap`（tap 回调 + mic 回调混音）→ FIFO → ffmpeg → `.m4a`
- 电平/波形链路：`audio-tap` 的 **mic 回调独立**写 `mic-level` 文件，终端点阵波形读它

---

## 现象

短会议（约 1 分钟）测试**偶发**失败：

- 录出的 `.m4a` 是 **0 字节**
- 上传后 Transcribe 报 `An error occurred (BadRequestException) ... The input file that you provided is empty.`
- 整段会议丢失，且开完会转录时才暴露

长会议基本不复现；单独跑 `audio-tap`、完整复刻 FIFO+ffmpeg 管道也都正常——典型的间歇性失败。

---

## 诊断（systematic-debugging）

**关键证据链：**

1. **0 字节 = ffmpeg 一个 PCM 字节都没读到。** 复刻正常流程发现：录制中 m4a 会稳定停在 **32 字节**（ffmpeg 已读到数据、写了 mp4 的 ftyp 头，靠 `empty_moov` 到 stop 才 flush 完整音频）。失败那次是 **0 字节**——连 32 字节的头都没有。

2. **失败 session 的 `ffmpeg.log` 停在 `Press [q] to stop`，没有任何 `time=` 行**；成功那次 `time=` 一路推进。说明失败时 ffmpeg 建好流后阻塞在读 FIFO，从未收到数据。

3. **失败 session 的 `tap.log` 正常输出** `MIC=on / SAMPLE_RATE=48000 / FORMAT=f32le`，无任何报错——tap 进程起来了、`AudioDeviceStart` 也返回成功，但 tap 的 IO 回调静默不触发。

4. **波形会骗人。** 终端点阵波形读的是 `mic-level`，由 `audio-tap` 里**独立的 mic 回调**写。失败时 mic 回调照常跑（波形跳动、mic-level 变化），但喂 ffmpeg 的 PCM 由 **tap 回调**负责——它没跑。**波形动 ≠ 音频在落盘。**

**根因：** macOS Process Tap 的 IO 回调偶发不启动——`AudioDeviceStart(aggregateID, procID)` 返回 `noErr`、进程存活、无报错，但回调静默不喂数据（输出设备切换、USB 设备时钟源等场景偶发的系统级行为）。此时 ffmpeg 阻塞在读 FIFO、输出恒 0 字节。

**为什么短测试高发、长会议不明显：** 长会议里对方声音持续驱动 tap 时钟，即使偶发也易恢复；短测试常是纯对麦克风讲、无系统音，一旦 tap 回调初始没起来，整段全空。

**放大器：** 原健康检查只验 `kill -0 $FFMPEG_PID`（进程是否存活）。0 字节场景下 ffmpeg 正阻塞等数据、进程好好活着 → 检查通过 → **静默空录**，直到 1 分钟后转录才报 empty。

---

## 修复（`5709f85`）

核心：把「仅验进程存活」升级为「验 PCM 是否真在流动」，不流动就自愈重启，仍失败明确报错。

| 改动 | 作用 |
|---|---|
| 新增 `_tap_audio_flowing()` 探针 | 读 `ffmpeg.log` 的 `time=` 是否越过 0，作为「PCM 真在流动」的确定性信号。**不能用波形/tap-level**（mic 回调独立，静默空录时照样动） |
| tap+ffmpeg 启动包进重试循环（最多 3 次） | 启动后探测最多 ~3s；`time=` 不推进则杀掉 tap+ffmpeg、清理孤儿、重启 |
| 全部失败 → 明确报错退出（exit 1） | 报 `ERR_TAP_STALL` 引导重跑 `setup` 查授权 / 重新 start，并清理空 session 目录与状态文件，**不再留下静默空录** |
| 新增 i18n：`MSG_TAP_STALL_RETRY` / `MSG_ERR_TAP_STALL`（zh/en） | 重试与失败的用户提示 |

**探针逻辑：**

```bash
_tap_audio_flowing() {
    local logf="$1" t
    t=$(grep -oE 'time=[0-9:.]+' "$logf" 2>/dev/null | tail -1 | cut -d= -f2)
    [[ -z "$t" ]] && return 1
    local digits="${t//[:.]/}"
    [[ "$digits" =~ ^0*$ ]] && return 1   # 00:00:00.00 → 还没数据
    return 0
}
```

---

## 验证

- **探针单测：** 失败样本（无 `time=`）→ 未流动 ✓；边界（`time=00:00:00.00`）→ 未流动 ✓；成功（`time=` 推进）→ 流动 ✓
- **正常路径 ×2：** 0 误重试、正常起录、音频完整落盘（262KB/15.9s、115KB/7s）、转录启动 ✓
- **故障路径（假 tap 模拟静默）：** 检测到 stall → 重试 2 次 → 报错退出（exit 1），耗时约 6.9s；无残留 session 目录 / 状态文件 / 孤儿进程 ✓

---

## 经验教训

- **`AudioDeviceStart` 返回 `noErr` 不保证 IO 回调被调用。** Process Tap + aggregate device 存在「启动成功但回调静默」的偶发系统行为，应用层需用数据流信号兜底。
- **进程存活 ≠ 在工作。** 健康检查要验业务信号（有没有真数据），而非仅验进程 PID。
- **波形/电平有独立数据源，可能误导排障。** mic 电平和喂编码器的 PCM 是两条路径，一条正常不代表另一条正常。
- **`ffmpeg.log` 的 `time=` 是「解码器真收到数据」的可靠信号**，比输出文件字节数可靠（`empty_moov` 下录制中文件恒为 32 字节）。
