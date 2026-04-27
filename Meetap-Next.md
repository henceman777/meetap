# MeeTap Next — 产品演进路线图

> 按功能领域分类，每个条目遵循统一格式。新增内容请参考文末 [条目模板](#条目模板)。

---

## 目录

| 分类 | 条目数 | 最近更新 |
|------|--------|----------|
| [A. 架构与技术栈](#a-架构与技术栈) | 2 | 2026-04-25 |
| [B. 分发与安装](#b-分发与安装) | 1 | 2026-04-25 |
| [C. 录制与音频](#c-录制与音频) | 0 | — |
| [D. 转录与语音识别](#d-转录与语音识别) | 1 | 2026-04-27 |
| [E. 纪要生成（AI 后端）](#e-纪要生成ai-后端) | 2 | 2026-04-26 |
| [F. 纪要质量（模板与 Prompt）](#f-纪要质量模板与-prompt) | 12 | 2026-04-26 |
| [G. 用户体验与交互](#g-用户体验与交互) | 0 | — |
| [H. 集成与生态](#h-集成与生态) | 1 | 2026-04-27 |

---

## A. 架构与技术栈

涉及整体技术选型、语言迁移、依赖管理、配置体系等基础架构话题。

### A-1. 全 Python 重写评估

- **日期**：2026-04-25
- **状态**：🔍 评估中
- **优先级**：P1

#### 可行性分析

主脚本（Bash → Python）完全没问题，逻辑更清晰，boto3 也能直接 import，不用 heredoc 嵌 Python。

关键难点是两个 Swift 组件：

- **audio-multi-output（设备查询/管理）** — 大部分可以用 Python 实现，通过 `pyobjc-framework-CoreAudio` 调 CoreAudio API
- **audio-monitor（实时音频转发）** — 有风险。`sounddevice` 库（底层 PortAudio/C 回调）理论上可以做，但稳定性和延迟需要实测验证

audio-monitor 是核心风险点。当前 Swift 实现直接用 AUHAL 回调跑在音频线程上，延迟极低。Python 方案用 sounddevice 的话，回调实际跑在 C 层，理论上也能低延迟，但多了一层 PortAudio 抽象，在设备切换、异常恢复等边界场景下是否可靠需要验证。

#### 建议

先用混合方案——主脚本改 Python，audio-monitor 保留 Swift 二进制。这样 Homebrew 打包也更容易（Python package + 预编译 Swift 二进制）。等稳定后再评估是否用 sounddevice 替掉 Swift。

---

### A-2. 当前软件依赖与可变参数

- **日期**：2026-04-25
- **状态**：📋 参考文档
- **优先级**：—

#### 软件依赖

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

#### 可变参数

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
- 模型：`us.anthropic.claude-sonnet-4-6`（Sonnet 性价比最优，Opus 质量相近但成本 5 倍）
- maxTokens：16000
- AWS Region：us-east-1（写了两处，分别在 transcribe 和 summarize 中）

#### 备注

这些参数目前全部硬编码在脚本里。如果要做 Homebrew 分发，建议提取到配置文件（如 `~/.config/meetap/config`）中，方便用户自定义。

---

## B. 分发与安装

涉及打包方式、安装流程、依赖自动化、版本发布等分发相关话题。

### B-1. 打包分发方式

- **日期**：2026-04-25
- **状态**：🔍 评估中
- **优先级**：P2

讨论是否可以做成 Mac 安装包，评估了三种方案：

- **Homebrew Tap（推荐）** — 最适合 CLI 工具，能自动处理依赖（ffmpeg、switchaudio-osx、blackhole-2ch 都在 Homebrew 里），用户 `brew install lijyang/tap/meetap` 一条命令搞定
- **.pkg 安装包** — 传统 macOS 安装器，双击安装，但依赖管理需要自己写脚本检测和提示
- **Shell 一键安装脚本（curl | bash）** — 最简单，但不优雅，依赖也要手动处理

#### Homebrew Tap 需要准备的东西

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

## C. 录制与音频

涉及音频采集、虚拟声卡、静音检测、多设备支持、音质优化等录制阶段话题。

> 暂无条目。新增时从 C-1 开始编号。

---

## D. 转录与语音识别

涉及 ASR 引擎选型、说话人分离、多语言支持、转录精度优化等话题。

### D-1. 音频不落盘转写

- **日期**：2026-04-27
- **状态**：🔍 评估中
- **优先级**：P2
- **实施方式**：需要代码改动

**问题**：当前流程 `ffmpeg 录音 → 本地 .m4a → 上传 S3 → Transcribe → 下载结果`，会议音频始终保留在本地磁盘。部分用户（合规敏感、磁盘空间有限、隐私偏好）希望音频"过手即弃"——转写完成后本地不残留音频文件。

#### 方案 A：流式转写（Transcribe Streaming API）

ffmpeg 的音频输出通过管道直接喂给 AWS Transcribe Streaming API，完全不产生本地文件。

```
ffmpeg → pipe:1 (PCM) → boto3 TranscribeStreamingClient → 实时返回文本
```

**优点**：
- 真正的零落盘，音频数据只在内存中流过
- 转写延迟更低（边录边转，不用等录完再上传）

**缺点**：
- Streaming API 的说话人分离（speaker diarization）能力弱于批量 API
- 不支持 `--identify-language`（自动语言检测），需预设语言
- ffmpeg 输出格式需改为 PCM（Streaming API 不支持 m4a/mp4）
- 网络中断 = 丢失已录部分，无法重试

**技术要点**：
- ffmpeg 输出 `-f s16le -ar 16000 -ac 1 pipe:1`，通过 Python subprocess 读取 stdin
- boto3 `transcribe-streaming` 的 `start_stream_transcription()` 接收 audio chunks
- 需处理 WebSocket 断连重连

#### 方案 B：内存文件系统中转（推荐）

录音写入 macOS 的 tmpfs（`/dev/shm` 或 RAM disk），转写完成后自动清除。严格说不是"完全不落盘"（数据经过内存文件系统），但对用户来说等效——录音结束后本地无文件残留。

```
ffmpeg → /tmp/meetap-ram/meeting.m4a → 上传 S3 → Transcribe → 删除 RAM 文件
```

**优点**：
- 对现有代码改动最小（只改录音路径）
- 保留批量 Transcribe API 的全部能力（speaker diarization、auto language detection）
- 可靠性与现有流程一致

**缺点**：
- macOS 没有原生 `/dev/shm`，需要 `hdiutil` 或 `diskutil` 创建 RAM disk
- 长时间会议的音频可能占用较多内存（1 小时 ≈ 60MB @ 128kbps）
- 异常退出（crash/断电）时音频不可恢复

**技术要点**：
- 创建 RAM disk：`hdiutil attach -nomount ram://$(( SIZE_MB * 2048 ))`
- 或使用 `/tmp`（macOS 的 `/tmp` 是 tmpfs，重启即清除），配合录制结束后主动删除
- config 新增 `audio_persist = true | false`，默认 `true`（保持现有行为）

#### 方案 C：混合方案——先落盘，转写后删除

最简单：现有流程不变，转写成功后自动删除本地音频文件。

```
ffmpeg → 本地 .m4a → 上传 S3 → Transcribe 成功 → rm 本地 .m4a
```

**优点**：零代码风险，只在 `transcribe_recording()` 末尾加一行 `rm`

**缺点**：音频曾短暂存在于磁盘（严格合规场景不满足）

#### 收敛建议

**第一步落地方案 C**（转写后删除）——一行代码，立即可用，覆盖 80% 需求。config 加 `audio_persist = true | false`。

**后续如有严格零落盘需求**，再评估方案 B（RAM disk）。方案 A（Streaming API）因 speaker diarization 能力折损，暂不推荐。

---

## E. 纪要生成（AI 后端）

涉及 LLM 选型、API 调用方式、成本优化、生成链路等 AI 后端话题。

### E-1. 会议纪要生成方式：Bedrock vs Claude Code

- **日期**：2026-04-25
- **状态**：🔍 评估中
- **优先级**：P1

#### 当前方案（Bedrock API）

通过 boto3 调用 Bedrock converse_stream，自动在转录完成后生成。

#### 替代方案（Claude Code CLI）

用 `claude -p` 非交互模式，meetap 里直接调用：

```bash
cat transcript.txt | claude -p "根据以下转录生成会议纪要..." > meeting-notes.md
```

#### 对比

- **输出质量**：几乎没区别，都是单次生成
- **自动化**：Bedrock 全自动，meetap stop 后无人值守完成；Claude Code 也可以自动化（`claude -p`）
- **成本**：Bedrock 按 token 计费走 AWS 账单；Claude Code 走 Claude 订阅额度
- **依赖**：Bedrock 需要 boto3 + Python venv + AWS 凭证；Claude Code 只需 `claude` CLI 已安装且已登录
- **稳定性**：Bedrock 曾因 model ID 变更导致失败（2026-04-24 事件）；Claude Code 模型自动跟随订阅，不用管 model ID
- **迭代**：Claude Code 可以对纪要进行多轮修改；Bedrock 是一锤子买卖

#### 建议

两者可以互补：Bedrock 自动生成作为默认路径，失败或不满意时用 Claude Code 补救。或者直接切到 Claude Code（`claude -p`）简化依赖链。

---

### E-2. 纪要生成后端可插拔——配置化选择 AI 引擎

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P1
- **实施方式**：需要代码改动

**问题**：纪要生成后端硬编码为 Bedrock，用户无法自主选择其他 AI 引擎。不同用户环境差异大——有人有 AWS 凭证用 Bedrock，有人有 Claude 订阅用 Claude Code，有人用 OpenAI API，有人在离线环境只能用本地模型。

#### 配置方案

在 `~/.config/meetap/config` 中新增 `ai_backend` 段：

```ini
[ai]
# 可选值: bedrock | claude-code | openai | ollama | custom
backend = bedrock

[ai.bedrock]
region = us-east-1
model = us.anthropic.claude-sonnet-4-6
max_tokens = 16000

[ai.claude-code]
# 使用 claude -p 非交互模式，无需额外配置
# 可选：指定模型偏好
model = opus

[ai.openai]
# 需要用户自行设置 OPENAI_API_KEY 环境变量
model = gpt-4o
base_url =
# 兼容 OpenAI API 格式的服务（Azure OpenAI、DeepSeek 等）也通过此配置

[ai.ollama]
# 本地模型，离线可用
model = llama3:70b
base_url = http://localhost:11434

[ai.custom]
# 自定义命令，meetap 将 transcript 通过 stdin 传入，期望 stdout 输出 markdown
command = my-summarizer --format markdown
```

#### 支持的后端

| 后端 | 依赖 | 成本 | 离线 | 质量 | 适用场景 |
|------|------|------|:---:|------|----------|
| **bedrock** | boto3 + AWS 凭证 | 按 token 计费 | — | 高 | AWS 用户，企业环境 |
| **claude-code** | `claude` CLI 已登录 | 走订阅额度 | — | 高 | Claude 订阅用户 |
| **openai** | openai SDK + API key | 按 token 计费 | — | 高 | OpenAI / Azure / 兼容 API 用户 |
| **ollama** | ollama 本地运行 | 免费 | ✅ | 中 | 隐私敏感、离线、免费场景 |
| **custom** | 用户自定义 | — | — | — | 高级用户自定义管道 |

#### 代码架构

```
summarize_transcript()
    ├── 读取 config → 确定 backend
    ├── 构造 prompt（与后端无关，F-1~F-12 的模板逻辑在此层）
    └── 调用对应后端
         ├── backend_bedrock()    → boto3 converse_stream
         ├── backend_claude_code() → claude -p < transcript
         ├── backend_openai()     → openai chat completions
         ├── backend_ollama()     → ollama API
         └── backend_custom()     → 执行用户命令
```

关键设计：**prompt 构造与后端调用分离**。F-1~F-12 的所有模板优化在 prompt 层实现，与选择哪个后端无关。后端只负责"接收 prompt，返回文本"。

#### CLI 交互

```bash
# 初始化配置（首次使用）
meetap config init          # 交互式选择后端

# 修改后端
meetap config set ai.backend claude-code

# 临时覆盖（不改配置文件）
meetap stop --backend openai

# 查看当前配置
meetap config show
```

#### 实现思路

1. **第一步**：将当前 `summarize_transcript()` 中的 Bedrock 调用抽成 `backend_bedrock()` 函数，prompt 构造逻辑独立出来
2. **第二步**：加入 `backend_claude_code()`——最简单，`echo "$prompt" | claude -p > output`
3. **第三步**：加入配置文件读取，支持 `ai.backend` 字段切换
4. **第四步**：按需增加 openai / ollama / custom 后端

前两步工作量很小，可以快速落地。后面的后端按用户需求逐步添加。

#### 与其他条目的关系

- **E-1**（Bedrock vs Claude Code 评估）→ E-2 将其结论落地为可配置方案
- **A-2**（可变参数）→ E-2 是参数配置化（A-2 备注）的具体实例
- **F-1~F-12**（模板优化）→ prompt 层改动，与 E-2 的后端选择独立，互不影响

#### 风险分析

**风险一：Prompt ≠ 后端无关（最大风险）**

E-2 的前提假设是"prompt 构造与后端调用分离"，但 prompt 工程实际是模型相关的：

- F-1~F-12 的复杂结构化输出指令（嵌套表格、三段式、情绪分析）在 Claude Sonnet 上效果好，换到 Llama 3 70B 可能直接崩格式
- 不同模型 context window 差异巨大——一场 30 分钟会议的 transcript 约 8k-15k tokens，加上 F-12 完整多类型模板 prompt 可能 5k+，本地小模型可能放不下
- 同一个 prompt 在 Claude 上输出中文质量高，在某些模型上会中英混杂

结果：用户换了后端，纪要质量断崖下降，会觉得是 meetap 的问题。

**风险二：维护成本指数增长**

| 后端 | 需要处理的差异点 |
|------|-----------------|
| bedrock | boto3 认证、region、model ID 变更、流式输出 |
| claude-code | CLI 版本兼容性、登录态过期、订阅额度耗尽 |
| openai | API key 管理、rate limit、Azure 兼容层差异 |
| ollama | 模型下载、GPU 内存不足、服务未启动 |
| custom | 任意命令——安全风险、stdout 格式不可控 |

5 个后端 = 5 套错误处理、5 套认证逻辑、5 套需要维护和测试的代码。

**风险三：过早抽象**

当前 meetap 的用户只有自己。E-1 里已评估过 Bedrock vs Claude Code，结论是 Bedrock 默认 + Claude Code 补救就够了。加 5 个后端解决的是假想用户的需求，而不是当前真实的痛点。

#### 代价分析

**开发代价**

| 方案 | 代码量 | 耗时估算 | 复杂度增加 |
|------|--------|----------|-----------|
| 只做 Bedrock（现状） | 0 | 0 | 0 |
| Bedrock + Claude Code | ~50 行 | 半天 | 低——加个 if/else + `claude -p` 管道 |
| + OpenAI | +80 行 | 再半天 | 中——多一套 SDK 依赖 + API key 管理 |
| + Ollama | +60 行 | 再半天 | 中——多一套 HTTP 调用 + 模型检测 |
| + Custom | +30 行 | 2 小时 | 低——subprocess 管道 |
| 完整 5 后端 + 配置体系 | ~300 行 | 2-3 天 | 高——配置解析、校验、错误处理、文档 |

**持续维护代价**

每多一个后端，每次改 prompt（F-1~F-12 落地时）都要多测一遍。当前改一次 prompt，跑一次 Bedrock 验证就行。5 个后端意味着改一次 prompt 要验证 5 次——或者只验证 Bedrock，其他后端"大概能用"，用户踩坑了再说。

**注意力代价**

meetap 当前核心价值链是：**录音 → 转录 → 纪要**。F-1~F-12 的 prompt 优化直接提升纪要质量，用户感知强。E-2 是基础设施工作，用户感知弱——花 2-3 天做 5 后端可插拔，这 2-3 天本来可以把 F-12（类型感知）落地，直接让每场会议的纪要变好。

#### 收敛结论

**当前阶段只做 Bedrock + Claude Code 两后端，配置文件里 `backend = bedrock | claude-code`。**

- Bedrock + Claude Code 的代价很低（~50 行，半天），且覆盖了实际使用场景
- OpenAI / Ollama / Custom 保留在架构设计中（上面的代码分层不变），等有真实用户需求时再加
- 如果未来加更多后端，需为不同能力等级的模型准备"简化版 prompt"（去掉 F-3 情绪分析、F-11 立场图谱等高难度模块），避免弱模型输出乱码

---

## F. 纪要质量（模板与 Prompt）

涉及纪要输出格式、Prompt 优化、信息结构、阅读体验等话题。对标 Otter.ai、Fireflies.ai、Microsoft Copilot、Zoom AI Companion、Notion AI、Read.ai、Fellow.app、Grain.co、Avoma、Chorus.ai 等产品的智能会议总结最佳实践。

**当前做得好的（保持）：**
- 30 秒速览——对标 Otter/Fireflies 的 "Meeting Overview"，信息密度高
- Action Items 带原文溯源（📎）——超越多数工具（Copilot 只列 action 不带出处）
- 决策 vs 待讨论分离——对标 Notion AI 的 "Decisions" vs "Open Questions" 双轨模式
- 术语速查表——对跨团队分发有价值，多数工具不做这一步

### F-1. Action Items 增加截止时间和优先级标签

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P0
- **实施方式**：纯 prompt 改动
- **对标**：Fireflies.ai Action Items 面板 `Due: Today` / `Due: Next Week`；Asana AI urgency 排序

**问题**：Action items 平铺列出，读者无法区分"今天就要做"和"长期建设"。

**方案**：给每条 action 补上截止时间（从原文提取线索）和优先级标签：

```markdown
- [ ] 🔴 **发言人E** — 今天向 SE ops 确认 PARC 上线原因（⏰ 2026-04-25）
- [ ] 🟡 **Sean** — 转发 3 个阻塞服务给 Greg（⏰ 下周内）
- [ ] 🟢 **团队** — 建立 ELB 竞品监控机制（⏰ 持续）
```

**实现思路**：在 prompt 中要求模型识别原文中的时间线索（"today"、"Monday"、"next week"），自动推断截止日期；无明确时间的标注"待定"。优先级按发言人语气强度（强烈不满=🔴、要求=🟡、建议=🟢）判断。

---

### F-2. 增加"上次 Action Items 回顾"章节

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P0
- **实施方式**：需要代码改动（读取历史纪要传入 prompt）
- **对标**：Fellow.app "Previous Action Items Review"

**问题**：会议间缺乏闭环。会上讨论了上次遗留问题但纪要没有结构化呈现。

**方案**：在 30 秒速览前增加：

```markdown
## 🔄 上次 Action Items 回顾

| # | 事项 | 负责人 | 状态 |
|---|------|--------|------|
| 1 | [上次事项] | [负责人] | ✅ 已完成 / 🔄 进行中 / ❌ 未启动 |
```

**实现思路**：meetap stop 生成纪要时，自动读取同目录下或上一个录制目录的 `meeting-notes.md`，提取其中的 Action Items 列表，作为上下文传入 prompt。如果找不到上次纪要，留空并标注"无历史数据"。

---

### F-3. 增加"会议情绪/张力地图"

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P0
- **实施方式**：纯 prompt 改动
- **对标**：Otter.ai Pro "Sentiment Analysis"；Read.ai "Meeting Energy" 热力图

**问题**：会议有明显情绪张力（领导强烈反驳、用词激烈），中性叙述丢失了 urgency 信号。

**方案**：在 30 秒速览后增加：

```markdown
## 🌡️ 会议温度

| 议题 | 温度 | 说明 |
|------|------|------|
| PARC "SE 政策"说法 | 🔴 高 | 直接否定，用词强烈 |
| Lattice 跨区域归因 | 🟠 中高 | 明确不买账，要求数据 |
| Elemental Inference | 🟢 低 | 正向反馈 |
```

**实现思路**：在 prompt 中要求模型根据发言人用词强度、打断频率、语气词判断每个议题的情绪温度。分三档：🔴 高张力（强烈反驳/不满）、🟠 中（质疑/挑战）、🟢 低（共识/正向）。

---

### F-4. 增加"议题间依赖关系"

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P2
- **实施方式**：纯 prompt 改动
- **对标**：Notion AI Meeting Notes topic linking；Loom AI "this connects to..."

**问题**：多个议题高度关联（PARC 费率 → 上线时间 → GCR → 支持计划），但呈现为独立章节。

**方案**：在正文前增加简易依赖图：

```markdown
## 🔗 议题关系

PARC 费率调整 → PARC 上线时间 → GCR 定价（已解决，等上线）
      └→ 支持计划定价

DX Flat Rate → HA Bundle / 端口转换 / 区域覆盖（三个子议题）

Ingress 弃用 → 竞品监控 → Phoenix 发布准备
```

**实现思路**：在 prompt 中增加指令，要求模型在分析完所有议题后，输出议题间的因果/依赖关系。用简单箭头 ASCII 图表示，不需要复杂可视化。

---

### F-5. Action Items 按负责人分组

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P0
- **实施方式**：纯 prompt 改动
- **对标**：Zoom AI Companion "My Action Items"；Fellow.app 按 assignee 分组

**问题**：Action items 按议题顺序排列，分发给不同负责人时需通读全部。

**方案**：在按议题排列的列表之后，增加按人分组的速查：

```markdown
### 按负责人速查

**Sean**: #1 转发阻塞服务, #2 与SE安排会议, #9 对齐支持团队
**CJ 团队**: #7 Phoenix准备, #8 Lattice数据, #10 HA Bundle定价
**Neil**: #3 跟踪PARC进度, #13 会议文档格式
```

**实现思路**：在 prompt 末尾要求模型输出完整 action items 后，再按负责人聚合输出一份索引。编号引用原列表序号。

---

### F-6. 标记"论点被挑战/推翻"的讨论结构

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P1
- **实施方式**：纯 prompt 改动
- **对标**：Read.ai "Key Moments" Challenge/Redirect；Grain.co 高亮转折点

**问题**：多个议题存在"团队提出 X → 领导否定 → 新方向 Y"模式，正文叙述中结构不够突出。

**方案**：在争议性议题中使用三段式：

```markdown
## VPC Lattice 采用率

**团队立场** 🗣️：跨区域缺失导致客户离开 Lattice
**领导挑战** ⚡：绝大多数客户单区域部署，单区域采用率已经很低
**最终方向** ✅：提供单区域客户不采用的数据分析
```

**实现思路**：在 prompt 中增加指令——当检测到某个议题中存在"提出观点→被反驳→新方向"的模式时，用三段式（立场→挑战→方向）结构化呈现，而非线性叙述。

---

### F-7. 增加"风险与升级路径"章节

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P1
- **实施方式**：纯 prompt 改动
- **对标**：Avoma / Chorus.ai "Risks" + "Next Steps if Blocked"

**问题**：会议中有多个潜在 escalation（邮件 Elizabeth、端口问题升级到 Rob），散落在不同议题中。

**方案**：

```markdown
## ⚠️ 风险与升级路径

| 风险 | 触发条件 | 升级路径 | 时间窗口 |
|------|----------|----------|----------|
| PARC 上线延迟 | 今天无合理解释 | Rob → Elizabeth | 周一 |
| DX 端口转换阻塞 | 服务团队不配合 | CJ → Doug Lane → Rob | 即刻 |
```

**实现思路**：在 prompt 中增加指令，要求模型识别原文中的 escalation 信号（"I'm gonna email..."、"if they have a problem, start a new thread with me"）并汇总为风险表。

---

### F-8. 量化"会议效率"元数据

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P2
- **实施方式**：纯 prompt 改动 + 后处理统计
- **对标**：Read.ai "Meeting Score"

**方案**：在会议元数据区补充：

```markdown
**议题覆盖**：8 个议题 / 30 分钟 ≈ 3.75 分钟/议题
**决策率**：6 项决策 / 8 个议题 = 75%
**Action 产出**：13 项（🔴 紧急 2 / 🟡 短期 7 / 🟢 持续 4）
**发言集中度**：最高发言人占比 40%
```

**实现思路**：模型生成完所有章节后，自动统计议题数、决策数、action items 数，计算比率。发言集中度从 speaker-stats.txt 获取。

---

### F-9. 为"30 秒速览"增加分层阅读设计

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P1
- **实施方式**：纯 prompt 改动
- **对标**：Fireflies "Smart Summary" 三层；Notion AI "TL;DR" + "Detailed Summary"

**问题**：速览约 150 字，对繁忙高管仍偏长。

**方案**：

```markdown
## ⚡ 速览

**一句话**：Rob 推动 PARC 逐服务落地，否决 DX mix-and-match，要求 Lattice 拿数据说话。

**三句核心**：
1. PARC 已批准但上线延迟，Rob 要求下周可用，否则 escalate
2. DX Flat Rate 按 HA Bundle 定价（1.2-1.4x），现有端口必须直接转换
3. Lattice 和 DX 团队被要求提供客户数据支撑阻塞说法

> [完整速览...]
```

**实现思路**：在 prompt 的输出格式中将速览拆分为三层。一句话限 30 字以内，三句核心每句限 40 字。

---

### F-10. 增加"会议系列上下文"

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P2
- **实施方式**：需要代码改动（读取历史纪要传入 prompt）
- **对标**：Otter.ai Meeting History 自动关联；Copilot "Catch me up"

**问题**：多个议题引用前次会议进展，但缺少上下文链接。

**方案**：

```markdown
## 📅 会议系列上下文

本次为 **合作伙伴定价月度评审** 系列会议。
- **前次**：完成 CloudFront 与 SE 费率评审（Elizabeth 已批准）
- **本次**：扩展到其他服务，解决上线时间和 DX 定价
- **下次预期**：回顾本次 action items 完成情况
```

**实现思路**：与 F-2 类似，读取上一次 meeting-notes.md 的标题和速览部分作为上下文传入 prompt。模型据此输出系列关系。如无历史数据则省略此节。

---

### F-11. 将"发言人贡献摘要"改为"立场图谱"

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P2
- **实施方式**：纯 prompt 改动
- **对标**：Grain.co / Chorus.ai "Stakeholder Map"

**问题**：叙述性的发言人摘要信息密度不如结构化呈现。

**方案**：

```markdown
## 👤 立场图谱

| 人物 | PARC 费率 | DX 定价 | Lattice | 角色定位 |
|------|-----------|---------|---------|----------|
| Rob | 推动+决策 | 否决 mix-match | 挑战归因 | 最终裁决者 |
| Sean | 提出阻塞 | — | — | 一线执行反馈 |
| CJ | — | 客户反馈 | 辩护跨区域 | 服务团队代言 |
```

**实现思路**：在 prompt 中要求模型为每个主要发言人在每个议题上标注立场标签（推动/支持/反对/挑战/中立/未参与），输出为表格。

---

### F-12. 会议类型感知——按类型自适应纪要模板

- **日期**：2026-04-26
- **状态**：💡 待实施
- **优先级**：P0
- **实施方式**：纯 prompt 改动（核心）+ 代码改动（可选，支持用户手动指定类型）
- **对标**：Otter.ai 按会议类型切模板；Fireflies.ai Smart Summary 根据内容自适应；Read.ai 按 meeting type 出不同 report

**问题**：F-1 到 F-11 的优化模块源自"领导评审会"场景，并非所有模块适用于所有会议类型。强行套用会导致纪要臃肿或内容生硬。

#### 会议类型定义

| 类型 | 识别特征 | 核心叙事 |
|------|----------|----------|
| **决策评审会** | 多议题、有明确决策者、存在拍板/否决 | 谁拍了什么板、什么被否决了 |
| **头脑风暴** | 发散性讨论、大量"如果..."/"我们可以..."、无明确结论 | 产生了哪些想法、哪些值得深挖 |
| **日常站会** | 短时间、固定节奏、逐人汇报进展/blockers | 谁卡住了、整体进度如何 |
| **1-on-1** | 2 人、个人发展/反馈/职业话题 | 共识是什么、下次前要做什么 |
| **技术讨论** | 方案对比、架构设计、代码评审、故障分析 | 方案对比结论、技术决策依据 |
| **客户会议** | 有外部参会者、需求收集、方案演示、合同谈判 | 客户要什么、我们承诺了什么 |
| **培训/Workshop** | 有讲师角色、知识传授、演示操作、Q&A 环节 | 教了什么、关键知识点、学员疑问 |

#### 各类型启用模块矩阵

| 模块 | 决策评审 | 头脑风暴 | 站会 | 1-on-1 | 技术讨论 | 客户会议 | 培训 |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| F-1 截止时间+优先级 | ✅ | — | ✅ | ⚠️ | — | ✅ | — |
| F-2 上次 AI 回顾 | ✅ | — | ✅ | ✅ | — | ✅ | ✅* |
| F-3 情绪张力地图 | ✅ | — | — | — | ⚠️ | ⚠️ | — |
| F-4 议题依赖关系 | ✅ | — | — | — | ✅ | ⚠️ | — |
| F-5 按人分组 | ✅ | — | ⚠️ | — | ⚠️ | ✅ | — |
| F-6 论点挑战结构 | ✅ | — | — | — | ✅ | — | — |
| F-7 风险与升级路径 | ✅ | — | — | — | ⚠️ | ✅ | — |
| F-8 会议效率元数据 | ✅ | ⚠️ | — | — | ⚠️ | ⚠️ | ⚠️ |
| F-9 速览分层 | ✅ | ✅ | ⚠️ | — | ✅ | ✅ | ✅ |
| F-10 会议系列上下文 | ✅ | — | ✅ | ✅ | — | ✅ | ✅* |
| F-11 立场图谱 | ✅ | — | — | — | ⚠️ | ⚠️ | — |

✅ 启用　⚠️ 视内容自动判断　— 不启用
\* 培训系列课程时启用

#### 各类型专属模块

除了通用模块（F-1~F-11）的选择性启用，每种类型还有**专属输出模块**：

**决策评审会**——使用当前完整模板，F-1~F-11 全量启用。

**头脑风暴**：
```markdown
## 💡 创意清单
- [创意 1]——[一句话描述] | 👍 支持度: [高/中/低]
- [创意 2]——...

## 🔬 待验证假设
- [假设 1]——验证方式: [...]
- [假设 2]——...

## 🚫 已排除方向
- [方向]——排除原因: [...]
```

**日常站会**：
```markdown
## 🚦 团队状态

| 成员 | 昨日完成 | 今日计划 | Blocker |
|------|----------|----------|---------|
| ... | ... | ... | ⚠️ [描述] 或 ✅ 无 |

## 🚧 Blockers 汇总
- [Blocker 1]——影响人: [...], 需要: [...]
```

**1-on-1**：
```markdown
## 🤝 共识要点
- [达成共识 1]
- [达成共识 2]

## 💬 反馈记录
- **[给予方 → 接收方]**: [反馈内容]

## 🎯 个人 Action Items
- [ ] [具体事项]（⏰ 下次 1-on-1 前）
```

**技术讨论**：
```markdown
## ⚖️ 方案对比

| 维度 | 方案 A | 方案 B | 方案 C |
|------|--------|--------|--------|
| [维度 1] | ... | ... | ... |

## 🏗️ 技术决策
- **选定方案**: [方案名]
- **决策依据**: [...]
- **已知 trade-off**: [...]

## ❓ 待验证技术问题
- [问题 1]——验证方式: [...], 负责人: [...]
```

**客户会议**：
```markdown
## 🎯 客户需求
- [需求 1]——优先级: [高/中/低], 客户原话: "..."
- [需求 2]——...

## 🤝 我方承诺
- [承诺 1]——负责人: [...], 截止: [...]
  📎 原文: "..."

## ⚠️ 客户顾虑
- [顾虑 1]——我方回应: [...]

## 📋 后续跟进
- [ ] [跟进事项]——对内/对外, 负责人: [...]
```

**培训/Workshop**：
```markdown
## 📚 知识点大纲
1. **[主题 1]**
   - 要点: [...]
   - 关键概念: [...]
   > 📌 注解: [补充说明]
2. **[主题 2]**
   - ...

## 🔧 操作步骤记录
[如有演示/实操环节]
1. [步骤 1]——目的: [...]
2. [步骤 2]——注意: [...]

## ❓ Q&A 汇总
| 问题 | 提问人 | 回答要点 |
|------|--------|----------|
| ... | ... | ... |

## 📝 学习要点回顾
- **必须掌握**: [...]
- **推荐深入**: [...]
- **参考资料**: [链接/文档名]
```

#### 实现方案（推荐思路 A：类型感知）

**Prompt 结构改造**：

```
第一步：通读转录全文，判断会议类型。从以下类型中选择最匹配的一个：
- 决策评审会 / 头脑风暴 / 日常站会 / 1-on-1 / 技术讨论 / 客户会议 / 培训Workshop
输出: "会议类型: [类型名]"

第二步：根据会议类型，使用对应的模板结构生成纪要。
[此处按类型分支，给出各自的输出格式要求]
```

**为什么不用思路 B（全输出 + 自动裁剪）**：不同类型不只是模块取舍不同，核心叙事结构完全不同——决策会强调"谁拍了什么板"，头脑风暴强调"产生了哪些想法"，技术讨论强调"方案对比和结论"，培训强调"知识点提取和 Q&A 沉淀"。硬套一个模板再裁剪，不如从源头分流。

**可选增强——用户手动指定类型**：

```bash
meetap stop                      # 自动识别类型
meetap stop --type training      # 手动指定为培训
meetap stop --type decision      # 手动指定为决策评审
```

需要代码改动：`meetap stop` 接受 `--type` 参数，传入 prompt。如未指定则由模型自动判断。

---

## G. 用户体验与交互

涉及 CLI 交互、通知机制、状态展示、错误提示等用户体验话题。

> 暂无条目。新增时从 G-1 开始编号。

---

## H. 集成与生态

涉及与日历、Slack、邮件、项目管理工具等外部系统的集成。

### H-1. 会议纪要邮件发送

- **日期**：2026-04-27
- **状态**：💡 待实施
- **优先级**：P1
- **实施方式**：需要代码改动

**问题**：会议纪要生成后仅保存在本地文件系统，用户需要手动复制分发给参会者。

#### 配置

`~/.config/meetap/config` 新增：

```ini
email = alice@example.com, bob@example.com
email_subject_prefix = [MeeTap]
```

- `email`：收件人列表，逗号分隔，可配多个
- `email_subject_prefix`：邮件主题前缀，默认 `[MeeTap]`
- 邮件主题自动生成：`{prefix} {会议标题}`（从 meeting-notes.md 的 H1 标题提取）

#### 发送方式评估

| 方案 | 依赖 | 配置复杂度 | 适用场景 |
|------|------|-----------|----------|
| **AWS SES**（推荐） | boto3 + 已验证发件人 | 低（已有 AWS 凭证） | AWS 用户，已配置 SES |
| **msmtp / mailx** | 系统工具 + SMTP 配置 | 中 | 通用，需配 SMTP 服务器 |
| **Python smtplib** | 无额外依赖 | 中 | 通用，需配 SMTP 凭证 |
| **macOS Mail.app** | AppleScript / osascript | 低 | Mac 用户，Mail.app 已登录 |

#### 推荐实现（AWS SES）

meetap 用户已有 AWS 凭证（Transcribe 和 Bedrock 都需要），SES 是最自然的选择。

```python
import boto3

def send_meeting_notes(session_dir, recipients, region):
    notes_path = os.path.join(session_dir, "meeting-notes.md")
    with open(notes_path) as f:
        content = f.read()

    title = content.split('\n')[0].lstrip('# ').strip()
    subject = f"[MeeTap] {title}"

    ses = boto3.client('ses', region_name=region)
    ses.send_email(
        Source=sender,  # 需 SES 验证
        Destination={'ToAddresses': recipients},
        Message={
            'Subject': {'Data': subject},
            'Body': {
                'Text': {'Data': content},
                'Html': {'Data': markdown_to_html(content)}
            }
        }
    )
```

**技术要点**：
- 发件人地址需在 SES 中预先验证（或 SES 已移出沙盒模式）
- config 可选 `email_sender`，默认用 SES 已验证的地址
- Markdown → HTML 转换：用 Python `markdown` 库（已在 venv 中）或简单正则
- 发送时机：在 `summarize_transcript()` 成功后自动调用
- 失败不阻塞：发送失败只打日志和通知，不影响纪要文件生成

#### CLI 交互

```bash
meetap stop                    # 转写 + 纪要 + 自动发邮件（如已配置 email）
meetap stop --no-email         # 转写 + 纪要，不发邮件
meetap send <session-dir>      # 手动发送已有纪要
```

#### 后续增强

- 支持附件模式（将 .md 作为附件而非正文）
- 支持 Slack webhook 发送（新增 `slack_webhook` 配置项）
- 支持自定义邮件模板

---

## 实施总览

### 按优先级

| 优先级 | 条目 | 说明 |
|--------|------|------|
| P0 | F-1, F-2, F-3, F-5, F-12 | Action Items 强化 + 情绪地图 + 历史回顾 + 类型感知 |
| P1 | A-1, E-1, E-2, F-6, F-7, F-9, H-1 | 架构评估 + AI 后端可插拔 + 纪要结构增强 + 邮件发送 |
| P2 | B-1, D-1, F-4, F-8, F-10, F-11 | 分发打包 + 音频不落盘 + 低优纪要优化 |

### 按实施方式

| 方式 | 条目 |
|------|------|
| 纯 prompt 改动 | F-1, F-3, F-4, F-5, F-6, F-7, F-8, F-9, F-11, F-12 |
| 需要代码改动 | D-1, E-2, F-2, F-10, F-12(可选 --type 参数), H-1 |
| 独立工程任务 | A-1, B-1, E-1 |

---

## 条目模板

新增条目时复制以下模板，填入对应分类末尾，并更新顶部目录表的条目数和最近更新日期。

```markdown
### {分类前缀}-{序号}. {标题}

- **日期**：{YYYY-MM-DD}
- **状态**：{💡 待实施 | 🔍 评估中 | 🚧 开发中 | ✅ 已完成 | ❌ 已放弃}
- **优先级**：{P0 | P1 | P2}
- **实施方式**：{纯 prompt 改动 | 需要代码改动 | 独立工程任务}（可选）
- **对标**：{业界产品/功能参考}（可选）

**问题**：{一句话描述当前痛点}

**方案**：{具体方案描述，可附代码/格式示例}

**实现思路**：{技术实现路径}
```

**编号规则**：
- 分类前缀：A/B/C/D/E/F/G/H
- 序号：分类内递增，从 1 开始
- 删除条目后序号不回收，新条目继续递增

**状态流转**：💡 待实施 → 🔍 评估中 → 🚧 开发中 → ✅ 已完成（或 ❌ 已放弃）

**新增分类**：如需新增分类，在 H 之后添加，使用字母 I/J/K... 作为前缀，同时更新目录表。



