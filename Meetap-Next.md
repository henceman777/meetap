# MeeTap Next — 架构演进讨论记录

日期: 2026-04-25

---

## 1. 打包分发方式

讨论是否可以做成 Mac 安装包，评估了三种方案：

- **Homebrew Tap（推荐）** — 最适合 CLI 工具，能自动处理依赖（ffmpeg、switchaudio-osx、blackhole-2ch 都在 Homebrew 里），用户 `brew install lijyang/tap/meetap` 一条命令搞定
- **.pkg 安装包** — 传统 macOS 安装器，双击安装，但依赖管理需要自己写脚本检测和提示
- **Shell 一键安装脚本（curl | bash）** — 最简单，但不优雅，依赖也要手动处理

### Homebrew Tap 需要准备的东西

**1) 源代码发布包（GitHub Release）：**

把 meetap 项目打一个 release tarball 推到 GitHub Releases，包含 src/meetap、Swift 源码、Makefile 等。Homebrew 会从 tarball 下载源码，在用户机器上编译 Swift 二进制。

**2) Formula 文件（Ruby 脚本）：**

创建独立 repo `homebrew-tap`，放一个 `Formula/meetap.rb`，描述依赖和安装步骤。

**用户体验：**
```bash
brew tap lijyang/tap
brew install meetap
# 自动安装 ffmpeg、switchaudio-osx，编译 Swift 工具
```

**前置条件：** Swift 源码（audio-multi-output.swift、audio-monitor.swift）需要纳入项目仓库。

---

## 2. 全 Python 重写评估

### 可行性分析

主脚本（Bash → Python）完全没问题，逻辑更清晰，boto3 也能直接 import，不用 heredoc 嵌 Python。

关键难点是两个 Swift 组件：

- **audio-multi-output（设备查询/管理）** — 大部分可以用 Python 实现，通过 `pyobjc-framework-CoreAudio` 调 CoreAudio API
- **audio-monitor（实时音频转发）** — 有风险。`sounddevice` 库（底层 PortAudio/C 回调）理论上可以做，但稳定性和延迟需要实测验证

audio-monitor 是核心风险点。当前 Swift 实现直接用 AUHAL 回调跑在音频线程上，延迟极低。Python 方案用 sounddevice 的话，回调实际跑在 C 层，理论上也能低延迟，但多了一层 PortAudio 抽象，在设备切换、异常恢复等边界场景下是否可靠需要验证。

### 建议

先用混合方案——主脚本改 Python，audio-monitor 保留 Swift 二进制。这样 Homebrew 打包也更容易（Python package + 预编译 Swift 二进制）。等稳定后再评估是否用 sounddevice 替掉 Swift。

---

## 3. 会议纪要生成方式：Bedrock vs Claude Code

### 当前方案（Bedrock API）

通过 boto3 调用 Bedrock converse_stream，自动在转录完成后生成。

### 替代方案（Claude Code CLI）

用 `claude -p` 非交互模式，meetap 里直接调用：

```bash
cat transcript.txt | claude -p "根据以下转录生成会议纪要..." > meeting-notes.md
```

### 对比

- **输出质量**：几乎没区别，都是单次生成
- **自动化**：Bedrock 全自动，meetap stop 后无人值守完成；Claude Code 也可以自动化（`claude -p`）
- **成本**：Bedrock 按 token 计费走 AWS 账单；Claude Code 走 Claude 订阅额度
- **依赖**：Bedrock 需要 boto3 + Python venv + AWS 凭证；Claude Code 只需 `claude` CLI 已安装且已登录
- **稳定性**：Bedrock 曾因 model ID 变更导致失败（2026-04-24 事件）；Claude Code 模型自动跟随订阅，不用管 model ID
- **迭代**：Claude Code 可以对纪要进行多轮修改；Bedrock 是一锤子买卖

### 建议

两者可以互补：Bedrock 自动生成作为默认路径，失败或不满意时用 Claude Code 补救。或者直接切到 Claude Code（`claude -p`）简化依赖链。

---

## 4. 当前软件依赖与可变参数

### 软件依赖

**必需（运行时）：**
- ffmpeg — 音频采集、录制、静音检测
- BlackHole 2ch — 虚拟音频回环设备
- SwitchAudioSource — 切换 macOS 系统音频输出设备
- audio-monitor — Swift 编译的 AUHAL 实时音频转发（项目自带）
- audio-multi-output — Swift 编译的 CoreAudio 设备查询（项目自带）

**转录阶段：**
- AWS CLI (aws) — 调 S3 和 Transcribe
- python3 — 解析 Transcribe JSON 结果

**会议纪要阶段：**
- meetap-venv/bin/python3 — 独立 Python venv
- boto3 — 调 Bedrock converse_stream API

**编译阶段（开发时）：**
- swiftc (Xcode CLT) — 编译两个 Swift 二进制

### 可变参数

**录制：**
- 录音格式：AAC（`-c:a aac`）
- 码率：128kbps（`-b:a 128k`）
- 声道：单声道（`-ac 1`）
- 录音目录：`~/Record`
- 采样率：跟随 BlackHole 设备（48kHz，不可配置）

**静音检测 / 自动停止：**
- 采样时长：5 秒（`SAMPLE_DURATION=5`）
- 静音阈值：-50dB（`SILENCE_THRESHOLD=-50`）
- 检查间隔：30 秒（`CHECK_INTERVAL=30`）
- 静音容忍时长：120 秒（`SILENCE_GRACE=120`）

**转录（AWS Transcribe）：**
- AWS Region：us-east-1
- 语言：自动检测，候选 en-US, zh-CN, ja-JP（`--language-options`）
- 说话人分离：开启，最多 10 人（`MaxSpeakerLabels: 10`）
- S3 桶名：`meetap-transcribe-{account-id}`

**会议纪要（Bedrock）：**
- 模型：`global.anthropic.claude-opus-4-7`
- maxTokens：16000
- AWS Region：us-east-1（写了两处，分别在 transcribe 和 summarize 中）

### 备注

这些参数目前全部硬编码在脚本里。如果要做 Homebrew 分发，建议提取到配置文件（如 `~/.config/meetap/config`）中，方便用户自定义。
