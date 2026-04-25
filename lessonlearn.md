# MeeTap - 经验教训总结

记录 MeeTap 项目从技术探索到日常使用过程中积累的所有经验教训，供后续开发和排障参考。

---

## 一、音频架构探索

### 1.1 macOS 多输出聚合设备不可靠

**问题**：尝试用 `AudioHardwareCreateAggregateDevice` 创建 stacked aggregate 设备（`"stck": 1`），让音频同时输出到耳机和 BlackHole。

**测试结果**：

| 配置 | 耳机/扬声器 | BlackHole 录音 |
|------|:-----------:|:--------------:|
| AirPods(24kHz) 做 master, BlackHole secondary | ✅ | ❌ -91dB |
| BlackHole(48kHz) 做 master, AirPods secondary | ❌ | ✅ -24dB |
| Speaker(48kHz) 做 master, BlackHole secondary | ✅ | ❌ -91dB |
| BlackHole 做 master, Speaker(48kHz) secondary | ❌ | ✅ -20.9dB |
| 无 master 无 drift, Speaker 在前 | ✅ | ❌ -91dB |
| 系统自带 Multi-Output Device | ❌ | 未测 |

**教训**：无论采样率是否一致、无论是否使用 drift correction、无论哪方做 master，stacked aggregate 设备中始终只有一个子设备能正常输出。不要依赖聚合设备做关键音频路由。

### 1.2 AVAudioEngine 不适合自定义设备场景

**问题**：尝试用 AVAudioEngine 从 BlackHole 读取音频实时转发到扬声器/耳机。

**结果**：无论输出设备是 AirPods(24kHz) 还是 MacBook Speaker(48kHz)，均报错：

```
Error Code=-10875 IsFormatSampleRateAndChannelCountValid(outputHWFormat)
```

**教训**：AVAudioEngine 在使用非系统默认输出设备时，获取 hardware format 的方式有问题。它的设备管理过于高层抽象，不适合在非标准设备组合下使用。

### 1.3 底层 AUHAL AudioUnit 是正确方案

**方案**：使用 `kAudioUnitSubType_HALOutput` 创建两个独立 AudioUnit，通过环形缓冲区连接。

**关键实现要点**：
- 输入 AU 和输出 AU 完全独立，各自运行在自己的音频线程上
- 环形缓冲区（65536 帧）解耦两个线程的异步读写
- Bus 编号：Bus 0 = 输出端，Bus 1 = 输入端（容易搞混）
- 输入 AU 需要显式 `enable IO` on Bus 1, `disable IO` on Bus 0

**为什么 AUHAL 能成功**：聚合设备在内核态尝试同时驱动两个硬件设备，受限于内核态的时钟同步。AUHAL 在用户态独立读写，完全绕开了内核态的设备同步问题。

### 1.4 蓝牙设备采样率不可改

**现象**：`set-sample-rate` API 调用返回成功，但实际查询仍是 24kHz。

**原因**：蓝牙设备的采样率由蓝牙编解码器（如 AirPods 的 AAC）决定，macOS API 无法覆盖。

**教训**：不要相信 API 返回的"成功"状态，始终验证实际效果。

---

## 二、2026-04-24 事故复盘

### 2.1 事故概要

**影响**：Zoom 会议前 ~40 分钟听不到对方声音，meetap 录制文件无有效音频，错过重要会议内容。

### 2.2 根因

**Zoom 扬声器设置为 "External Headphones" 而非 "Same as system"。**

正常链路：
```
Zoom (speaker: Same as system) → BlackHole → ffmpeg 录制 + audio-monitor → 耳机
```

故障链路：
```
Zoom (speaker: External Headphones) → 直接输出到耳机（绕过 BlackHole）
BlackHole → ffmpeg 只录到麦克风环境音 → 转录为空
```

### 2.3 连锁故障

1. `meetap start` 将系统输出切到 BlackHole
2. Zoom 扬声器固定 "External Headphones"，不跟随系统切换
3. Zoom 声音绕过 BlackHole，直接到耳机硬件
4. audio-monitor 从 BlackHole 转发的是静音
5. Zoom 直接输出 + audio-monitor 静音输出同时写入耳机，CoreAudio 混音干扰导致用户听不到声音
6. ffmpeg 从 BlackHole 录到的只有麦克风拾取的微弱环境音
7. 静音 watchdog 检测到持续低音量，反复自动停止

### 2.4 为什么之前不是问题

不使用 meetap 时，系统输出就是 External Headphones，Zoom 选 "External Headphones" 和 "Same as system" 效果相同。只有 meetap 将系统输出切到 BlackHole 后，两者差异才暴露。

### 2.5 排障过程中的误判

| 操作 | 是否有效 | 说明 |
|------|:--------:|------|
| `SwitchAudioSource -s "External Headphones"` | ❌ | 把系统输出从 BlackHole 切回，破坏了 meetap 录制链路 |
| 修改 `MuteVoipWhenJoin=1→0` | ❌ | 这是"加入时静音麦克风"，与"听不到声音"无关 |
| 系统音量 75→100 | ❌ | 不是根因 |
| Zoom 扬声器改为 "Same as system" | ✅ | 真正的修复 |

**教训**：
- `MuteVoipWhenJoin` 控制的是麦克风（别人听不到你），不是扬声器（你听不到别人）
- 排障时不要急于修改配置，先理清音频链路的每个环节
- 切换系统音频设备是高风险操作，可能破坏已建立的录制链路

### 2.6 预防措施

1. **所有会议 App 的扬声器必须设为 "Same as system"**（或 BlackHole 2ch）
2. `meetap start` 后，检查 BlackHole 是否有有效音频信号
3. 考虑在 `meetap start` 时自动检测 Zoom 进程并提醒确认扬声器设置

---

## 三、静音 Watchdog Bug

### 3.1 问题

自动停止功能（持续静音 2 分钟后自动 `meetap stop`）在实际使用中未能正确触发。会议对方已经静音很久，但 watchdog 没有自动停止。

### 3.2 根因

Watchdog 从**混合录制文件**（BlackHole + 麦克风）采样音量。麦克风采集的环境音/键盘声等在 -40~-43dB 范围内，始终超过 -50dB 的静音阈值，导致静音计时器不断被重置。

### 3.3 修复

改为直接从 **BlackHole 通道**采样（只检测会议对方的声音），不混入麦克风信号：

```bash
# 修复前：从混合录制文件采样（包含麦克风噪音）
ffmpeg -i "$recording_file" -t 5 -af volumedetect ...

# 修复后：直接从 BlackHole 采样（只有会议声音）
ffmpeg -f avfoundation -i ":BlackHole 2ch" -t 5 -af volumedetect ...
```

### 3.4 教训

- 音频检测的信号源必须精确，混入无关信号会导致误判
- -50dB 阈值对于会议静音检测是合理的（会议人声通常在 -30~-50dB，环境音在 -40~-43dB，完全静音在 -91dB），但前提是信号源纯净
- 自动停止功能必须经过端到端测试，不能只看代码逻辑

### 3.5 正则提取 Bug

`is_audio_silent()` 函数中的正则表达式也曾出现 bug（commit 54ad68b），从 ffmpeg 输出中提取 `mean_volume` 值时匹配失败，导致 autostop 完全不工作。

**教训**：正则提取外部命令输出时，先在实际环境中验证 ffmpeg 的输出格式，不要假设格式固定不变。

---

## 四、会议纪要功能丢失事件

### 4.1 事件经过

2026-04-24：直接在 `~/bin/meetap` 上添加 Bedrock 会议纪要生成功能 → 未同步到 `projects/meetap/src/meetap` → 未 `git commit` → 后来执行 `make install` 将 src 覆盖到 bin → 新功能代码丢失。

### 4.2 教训

**永远只修改 `projects/meetap/src/meetap`，不要直接改 `~/bin/meetap`。**

正确的开发流程：
1. `git pull` 拉取最新代码
2. 修改 `projects/meetap/src/meetap`
3. `make install` 同步到 `~/bin/`
4. 测试验证
5. 立即 `git commit` + `git push`

**修改后第一件事就是 commit。** 不要等功能完善再提交，先保存代码再说。

---

## 五、Git 操作经验

### 5.1 合并冲突处理

**场景**：本地直接修改了 `~/bin/meetap`，想同步回 src 并 push，但 remote 有更新的 v0.2 版本。

**错误做法**：`git pull --rebase` → 大量冲突，因为本地和 remote 是完全不同的代码版本。

**正确做法**：
1. 识别出 remote 版本更完整
2. `git rebase --abort` 放弃 rebase
3. `git stash` 暂存本地更改
4. `git pull` 获取 remote 最新版本
5. 只应用需要的增量修改（如 model ID 变更）
6. 新建 commit

**教训**：当本地和 remote 出现大幅偏离时，不要强行 rebase。先判断哪边的代码更完整，以更完整的版本为基准，只 cherry-pick 或手动应用需要的差异。

### 5.2 代码源管理

- `~/bin/meetap` 是**部署产物**，不是源代码
- `projects/meetap/src/meetap` 是**唯一的源代码**
- `make install` 是单向同步：src → bin
- 永远不要从 bin 反向同步到 src（除非是紧急恢复）

---

## 六、各会议 App 音频配置

### 6.1 配置能力对比

| App | 配置格式 | 自动修改 | 支持 System Default |
|-----|---------|:--------:|:-------------------:|
| Zoom | INI (hex 编码) | ✅ 需退出 App | ✅ |
| Teams | WebView LevelDB | ❌ | ❌ |
| 腾讯会议 | GLS 二进制 (.tk/.tv) | ❌ | 未知 |
| 飞书 | - | 不需要 | ✅ 默认跟随 |

### 6.2 Zoom 配置修改

- 路径：`~/Library/Application Support/zoom.us/data/viper.ini`
- 设备名用 UTF-8 hex 编码：`echo -n "Meeting Multi-Output" | xxd -p | tr -d '\n'`
- **必须在 Zoom 未运行时修改**，Zoom 退出时会写回 UI 状态覆盖文件
- `meetap setup-zoom` 会自动处理 Zoom 的退出和重启

### 6.3 正确的扬声器设置

meetap 运行时，所有会议 App 的扬声器应设为：
- **Zoom**：Same as system
- **Teams**：BlackHole 2ch（因为 Teams 不支持 System Default）
- **腾讯会议**：BlackHole 2ch
- **飞书**：默认即可（自动跟随系统）

---

## 七、macOS CoreAudio 踩坑

### 7.1 `setDefaultOutput` 对聚合设备无效

`AudioObjectSetPropertyData` 设置 `kAudioHardwarePropertyDefaultOutputDevice` 对 stacked aggregate 设备不生效。必须使用 `SwitchAudioSource`（基于旧版 `AudioDeviceSetPropertyData` API）。

### 7.2 ffmpeg avfoundation 不支持采样率参数

```bash
# 以下写法都无效
ffmpeg -f avfoundation -ar 48000 -i ":BlackHole 2ch" ...
ffmpeg -f avfoundation -sample_rate 48000 -i ":BlackHole 2ch" ...
```

avfoundation 输入格式使用设备的原生采样率，不接受外部指定。

### 7.3 聚合设备跨重启不持久

通过 `AudioHardwareCreateAggregateDevice` 创建的设备在系统重启后消失。需要在每次 `meetap start` 时检查并重建。

### 7.4 audio-monitor 进程需优雅退出

`audio-monitor` 使用 AUHAL 回调机制，直接 `kill -9` 可能导致音频设备状态异常。应使用 `kill` (SIGTERM) 让进程自行清理。

---

## 八、AWS 服务使用经验

### 8.1 Transcribe 语言检测

初始版本固定 `en-US`，后改为自动语言检测（`--language-options en-US,zh-CN,ja-JP`）。

**注意**：`--language-options` 参数格式在不同 AWS CLI 版本中可能不同，曾因格式问题导致转录失败（commit 73ab40a）。

### 8.2 Bedrock 模型调用

使用 boto3 `converse_stream` 流式调用，避免同步调用超时：

```python
response = client.converse_stream(
    modelId="us.anthropic.claude-opus-4-7-v1",
    messages=[{"role": "user", "content": [{"text": prompt}]}],
    inferenceConfig={"maxTokens": 4096, "temperature": 0.3}
)
```

- 使用独立 Python venv (`meetap-venv`)，不污染系统 Python
- 流式接收避免长会议转录时 API 超时
- Temperature 0.3 在准确性和自然度之间取得平衡

### 8.3 S3 桶复用

桶名 `meetap-transcribe-{account-id}` 含 AWS Account ID 避免命名冲突，跨会话复用同一个桶。转录完成后自动清理 S3 临时文件和 Transcribe 作业记录。

---

## 九、排障标准流程

遇到 meetap 录制/音频问题时，按以下顺序排查：

### 第 1 步：确认系统音频输出

```bash
SwitchAudioSource -c -t output
```
- meetap 运行中 → 应该是 `BlackHole 2ch`
- meetap 未运行 → 应该是 `External Headphones` 或其他物理设备

### 第 2 步：确认会议 App 扬声器设置

Zoom: 点音频旁的 `^` 箭头，Speaker 必须是 "Same as system"

### 第 3 步：确认 meetap 进程

```bash
ps aux | grep -E "ffmpeg|audio-monitor" | grep -v grep
```
应看到 ffmpeg（`-i :BlackHole 2ch`）和 audio-monitor 两个进程。

### 第 4 步：确认 BlackHole 有声音

```bash
ffmpeg -f avfoundation -i ":BlackHole 2ch" -t 2 -f wav -y /tmp/test.wav 2>/dev/null
ffmpeg -i /tmp/test.wav -af volumedetect -f null /dev/null 2>&1 | grep mean_volume
```
- mean_volume > -60dB → 正常
- mean_volume < -80dB → BlackHole 没收到音频，回到第 2 步

### 第 5 步：确认耳机能出声

```bash
afplay /System/Library/Sounds/Ping.aiff
```

### 第 6 步：重启音频链路（最后手段）

```bash
meetap stop && sleep 2 && meetap start
```
然后回到第 2 步确认 Zoom 扬声器。

---

## 十、开发与维护建议

### 10.1 代码修改规范

1. 始终修改 `projects/meetap/src/meetap`，永不直接改 `~/bin/meetap`
2. 修改后立即 `make install` 测试
3. 测试通过后立即 `git commit` + `git push`
4. 不要积攒多个功能再一起提交

### 10.2 测试要点

- 音频功能必须端到端测试，单看代码不够
- 静音检测要用真实的音频环境验证
- 正则提取外部命令输出时，先手动运行确认输出格式
- `make install` 后要验证 `~/bin/meetap` 的行为与 src 一致

### 10.3 文档维护

- `doc/开发说明.md` — 架构和 API 参考
- `doc/用户指南.md` — 面向用户的使用说明
- `doc/技术探索记录.md` — 技术方案探索的完整记录
- `lessonlearn.md` — 本文档，经验教训汇总

文档应随代码更新同步维护，特别是新增功能或修复 bug 后。

---

## 附录：项目里程碑

| 日期 | 事件 |
|------|------|
| 2026-04 初 | 项目启动，探索聚合设备方案 |
| 2026-04 初 | 聚合设备方案失败，尝试 AVAudioEngine 也失败 |
| 2026-04 初 | AUHAL 底层方案成功，audio-monitor 完成 |
| 2026-04-17 | 初始 commit，meetap v0.1 |
| 2026-04-17 | 添加麦克风混录、自动语言检测 |
| 2026-04-18 | 代码从 bin/ 迁移到 src/，建立 Makefile 构建系统 |
| 2026-04-20 | 添加 Bedrock 会议纪要 + 静音自动停止功能 |
| 2026-04-21 | 会议纪要升级到 v0.2（结构化格式） |
| 2026-04-22 | 修复 is_audio_silent() 正则 bug |
| 2026-04-24 | Zoom 扬声器配置事故，发现静音 watchdog 信号源 bug |
| 2026-04-24 | 会议纪要功能丢失事件，建立开发流程规范 |
| 2026-04-24 | Bedrock 模型升级到 Claude Opus 4.7 |
