# 在新 Mac 上通过 Claude Code 部署会议录制工具

将以下内容作为提示词发给 Claude Code，它会自动完成全部安装和配置。

---

## 使用方法

1. 在新 Mac 上安装 Claude Code
2. 打开终端，运行 `claude`
3. 将下面「提示词」部分的全部内容粘贴发送
4. Claude Code 会自动执行所有步骤
5. 仅 Teams 和腾讯会议需要你在 App 中手动选一下扬声器

---

## 提示词

```
我需要你帮我在这台 Mac 上从零搭建一个会议录制工具，用于录制 Zoom / Teams / 飞书 / 腾讯会议的音频。

## 原理

通过 BlackHole 虚拟声卡捕获系统音频，同时用 AUHAL AudioUnit 实时转发音频到扬声器，让用户能正常听到声音。

架构：
- 录制时，系统输出切换到 BlackHole 2ch
- audio-monitor（AUHAL 底层转发）实时将 BlackHole 音频转发到用户的扬声器/耳机
- ffmpeg 从 BlackHole 采集音频并编码为 AAC 文件
- meetap 编排整个流程

重要：不要使用 macOS 多输出聚合设备（Multi-Output / Aggregate Device）方案，那个方案已验证不可行——secondary 设备始终静音。也不要使用 AVAudioEngine，它对非默认设备会报 Code=-10875 错误。必须使用底层 AUHAL AudioUnit API。

## 步骤

请按以下顺序执行：

### 1. 安装依赖

```bash
# 如果没有 Homebrew，先安装
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 安装三个依赖
brew install blackhole-2ch ffmpeg switchaudio-osx
```

验证：
- `brew list blackhole-2ch` 成功
- `ffmpeg -version` 有输出
- `SwitchAudioSource -c` 显示当前设备名

### 2. 创建 ~/bin/audio-multi-output.swift

CoreAudio 设备管理工具，提供设备查询（list、default-output-uid/name/id、blackhole-uid、find-uid）和设备控制（set-default、get/set-sample-rate）功能。

要点：
- 使用 AudioObjectGetPropertyData / AudioObjectSetPropertyData API
- 支持 create 命令创建聚合设备（保留用于调试，主流程不使用）
- 固定 UID: `com.meeting-record.multi-output`，名称: `Meeting Multi-Output`
- 支持 cleanup 命令清理遗留聚合设备

编译命令：
```bash
swiftc -O -framework CoreAudio -framework AudioToolbox ~/bin/audio-multi-output.swift -o ~/bin/audio-multi-output
```

### 3. 创建 ~/bin/audio-monitor.swift

这是核心组件——AUHAL 音频实时转发工具。

用法: `audio-monitor <input-device-uid> <output-device-uid>`

实现要点（必须严格遵循）：
- 创建两个独立的 AUHAL AudioUnit（kAudioUnitSubType_HALOutput）
- 输入 AU：启用 input bus (element 1)，禁用 output bus (element 0)，绑定到输入设备
- 输出 AU：默认播放模式，绑定到输出设备
- 中间格式：Float32 非交错 PCM，采样率和通道数跟随输入设备
- 通过环形缓冲区（65536 帧 × 通道数）连接输入回调和输出回调
- 输入回调：AudioUnitRender 从 bus 1 读取 → 写入环形缓冲区
- 输出回调：从环形缓冲区读取 → 填入 ioData（欠载时输出静音）
- 用 AURenderCallbackStruct 设置回调
- 输入 AU 用 kAudioOutputUnitProperty_SetInputCallback
- 输出 AU 用 kAudioUnitProperty_SetRenderCallback
- 信号处理：捕获 SIGINT/SIGTERM 优雅退出
- RunLoop.current.run() 保持进程运行

编译命令：
```bash
swiftc -O -framework CoreAudio -framework AudioToolbox ~/bin/audio-monitor.swift -o ~/bin/audio-monitor
```

### 4. 创建 ~/bin/meetap

主控脚本，支持命令：start / stop / status / setup / setup-zoom / setup-teams / setup-wemeet

**start 流程**：
1. 检查依赖（audio-multi-output、audio-monitor、ffmpeg、BlackHole）
2. 记录当前默认输出设备（UID + Name）到 /tmp/meeting-record/
3. 如果当前输出已是 BlackHole，从状态文件恢复真实设备
4. SwitchAudioSource 切换系统输出到 BlackHole 2ch
5. 后台启动 audio-monitor（BlackHole → 原始设备）
6. 后台启动 ffmpeg: `ffmpeg -f avfoundation -i ":BlackHole 2ch" -c:a aac -b:a 128k -ac 1 "$OUTPUT_FILE"`
7. 验证两个进程存活，失败则回滚

**stop 流程**：
1. kill -INT ffmpeg（优雅停止）
2. kill audio-monitor
3. SwitchAudioSource 恢复原始输出设备
4. 显示录音文件信息（路径、大小、时长）

**setup-zoom**：自动修改 `~/Library/Application Support/zoom.us/data/viper.ini`，将 AECSPK 设为 `53616d652061732053797374656d`（"Same as System" 的 hex 编码）。需要 Zoom 未运行。

**setup-teams**：打开 `msteams://settings/devices`，引导用户选择 Speaker → BlackHole 2ch

**setup-wemeet**：打开腾讯会议，引导用户选择 扬声器 → BlackHole 2ch

状态文件存放在 /tmp/meeting-record/：ffmpeg.pid、monitor.pid、original-output.uid、original-output.name、output-file

录音文件存放在 ~/Record/meeting_YYYYMMDD_HHMMSS.m4a

```bash
chmod +x ~/bin/meetap
```

### 5. 配置 PATH

```bash
# 确保 ~/bin 在 PATH 中
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### 6. 验证

依次执行：
```bash
audio-multi-output blackhole-uid          # 应输出 BlackHole UID
audio-multi-output default-output-name    # 应输出当前扬声器名
SwitchAudioSource -a -t output            # 应包含 BlackHole 2ch
```

然后做一个端到端测试：
```bash
meetap start
# 等 2 秒后播放测试音
afplay /System/Library/Sounds/Glass.aiff
afplay /System/Library/Sounds/Ping.aiff
sleep 1
meetap stop
```

检查录音文件：
```bash
# 最新录音文件
LATEST=$(ls -t ~/Record/meeting_*.m4a | head -1)
# 检查音量（应大于 -80 dB，-91 dB 表示静音）
ffmpeg -i "$LATEST" -af "volumedetect" -f null /dev/null 2>&1 | grep mean_volume
```

如果 Speaker 测试音能听到 + 录音有有效音频（> -80 dB），安装成功。

### 7. 配置会议 App

```bash
meetap setup
```

这会依次配置 Zoom（全自动）、Teams（需手动选一下）、腾讯会议（需手动选一下）。

## 注意事项

- 蓝牙耳机（AirPods 等）因采样率不匹配（24kHz vs 48kHz）不支持录音，请用 MacBook 内置扬声器或有线耳机
- BlackHole 安装后可能需要重启 Mac 才能识别
- 安装 BlackHole 时如果 macOS 弹出安全性提示，需要到「系统设置 → 隐私与安全性」中允许
- 录音期间不要手动切换音频设备
- 如果脚本异常退出导致没声音，手动执行: `SwitchAudioSource -s "MacBook Pro Speakers" -t output`
```

---

## 补充说明

以上提示词包含了完整的技术规格，Claude Code 可以据此从零实现所有代码。关键约束已明确：

1. **必须用 AUHAL**，不用聚合设备，不用 AVAudioEngine
2. **环形缓冲区**连接输入和输出 AudioUnit
3. **SwitchAudioSource** 做设备切换（CoreAudio setDefaultOutput 对某些设备不可靠）
4. **Zoom 配置**可自动修改（hex 编码的 INI 文件），Teams/腾讯会议需手动选一下

如果 Claude Code 执行中遇到问题，可参考 `技术探索记录.md` 中的失败方案和原因分析。
