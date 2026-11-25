# MeeTap

在 Mac 上录下会议，或者任何电脑里在放的声音；停止以后自动转成带说话人的文字，再写成一份中文纪要，可以顺手发到邮箱。音频和纪要只在你自己的 AWS 账号里流转。

> **从 1.x 升级？** 先看[从 1.x 升级到 2.0](#upgrade)：不再需要 BlackHole，要重新授权一次。

## 上手：装好 → 授权 → 录一场 → 找到纪要

前提：macOS 14.4 以上；一个 AWS 账号，在 Bedrock 里开通了 Claude Sonnet 等模型（[怎么准备](#aws)）。

```bash
# 1. 装好（自动装上 ffmpeg、python），再填 AWS 的 Access Key 和区域
brew install henceman777/tap/meetap
aws configure

# 2. 授权：系统录音（必须）、日历（可选）。在哪个终端 App 里开录，就在哪个里面跑一次
meetap setup

# 3. 开会前敲一下就开始录；会开完按 Ctrl-C，后台自动转录、写纪要，写完弹通知
meetap

# 4. 打开最新那个会话文件夹，纪要是 2026-11-19_1430_<主题>.md
open ~/Record
```

每一步会看到什么，见[录一场线上会议](#s-online)。

## 按场景找

| 我想…… | 看这张卡 |
|---|---|
| 录 Zoom、Teams、飞书、腾讯会议、Chime 上的会 | [录一场线上会议](#s-online) |
| 录会议室里的会、面对面聊 | [线下会议、面对面聊](#s-offline) |
| 录网课、直播、视频、播客，只要电脑的声音 | [只录电脑的声音](#s-mute) |
| 会议有固定时长，到点自动停 | [到点自动停](#s-duration) |
| 录音时还要用这个终端，或者在脚本里调用 | [在后台录](#s-background) |
| 纪要不满意：补资料、提要求、重写 | [重写纪要](#s-again) |
| 合盖休眠、断网、凭证过期以后，接着出纪要 | [中断以后接着出纪要](#s-resume) |
| 让纪要用上日历里的会名、人名、议程 | [用上日历](#s-calendar) |
| 标出纪要里的重点 | [标重点](#s-mark) |
| 给会贴标签，以后按标签找回来 | [贴标签、找回以前的会](#s-tag) |
| 纪要自动发到邮箱 | [自动发邮件](#s-email) |
| 老会话的文件夹和新录的不一样 | [整理老会话](#s-tidy) |
| 终端里的提示换成英文 | [英文界面](#s-english) |
| 命令、配置项一览 | [速查](#cheatsheet) |
| 出问题了 | [故障排查](#troubleshooting) |

---

## 安装和准备

### 系统要求

- **macOS 14.4 以上**：Sonoma 14.4 及之后的版本，包括 macOS 15 Sequoia、macOS 26 Tahoe。2.0 起只用系统自带的 Process Tap 录音，不再支持 macOS 13，还在 13.x 上请继续用 1.x。Homebrew 只能按大版本限制系统，所以 14.0–14.3 上也装得上，但 `meetap start`、`meetap setup` 会直接提示版本太低、不开录。
- **Xcode Command Line Tools**：首次安装会自动提示，也可以先跑 `xcode-select --install`。

### 安装（任选一种）

**Homebrew（推荐）**：

```bash
brew install henceman777/tap/meetap   # 一行：自动 tap 再安装，顺带装上 ffmpeg、python

# 或者分两步：先 tap 一次，以后用短名字安装、升级
brew tap henceman777/tap
brew install meetap
brew upgrade meetap
```

**从源码装**：

```bash
brew install ffmpeg awscli
git clone https://github.com/henceman777/meetap.git
cd meetap
make install     # 编译 audio-tap、audio-multi-output，装到 ~/bin，并嵌入权限说明、重新签名
```

开发、测试见 [docs/development.md](docs/development.md)。

<a id="aws"></a>

### 准备 AWS 账号

1. 在 [Bedrock 控制台](https://console.aws.amazon.com/bedrock/) 的 **Model access** 开通一个模型。默认用 Anthropic Claude Sonnet；也可以用 Amazon Nova Pro，或者 Meta Llama、Mistral、DeepSeek 等支持 Converse API 的模型（配置项 `model`）。
2. 配好 AWS 命令行：

   ```bash
   aws configure    # 填 Access Key、Secret 和区域（us-east-1 或别的开通了 Bedrock 的区域）
   ```

   用 `AWS_PROFILE` 指定 profile 也行。
3. 账号要有这些权限：`s3:PutObject/GetObject/DeleteObject`、`transcribe:*TranscriptionJob`、`bedrock:InvokeModelWithResponseStream`；要发邮件再加 `ses:SendRawEmail`。默认模型 `global.anthropic.claude-sonnet-5` 是跨区域的推理配置文件，Bedrock 权限要按推理配置文件、本区域的基础模型、不分区域的基础模型三段写。想收紧权限，照 [docs/iam.md](docs/iam.md) 的最小策略配。

费用按量计费，没有订阅、没有最低消费，一场会大约几毛钱（Transcribe 转录 + Bedrock 生成纪要）。

### 授权：meetap setup

```bash
meetap setup
```

它分三步，哪一步不需要就不出声：

1. **检查从 1.x 留下的音频设置**：系统输出、会议 App 的扬声器是不是还指着 BlackHole，见[从 1.x 升级到 2.0](#upgrade)。会议 App 本身不用做任何设置：Process Tap 录的是整台电脑的声音，和会议 App 选哪个扬声器无关。
2. **检查系统录音授权**（Process Tap）：实测 2 秒，会播一声提示音。录到的是静音，就打开 **系统设置 › 隐私与安全性 › 屏幕与系统录音**，引导你把终端 App（Ghostty、终端、iTerm 等）加进"仅系统录音"，再按提示复测。有的终端（比如 Ghostty）不会自动弹授权框，要手动加。这是录音唯一必须的准备。
3. **日历授权（可选）**：还没授权时，说明用途后请求一次（会弹授权框），拒绝也算通过，只是纪要里没有日历信息。详见[用上日历](#s-calendar)。

> **权限是按终端 App 给的**：系统录音和日历这两项权限，macOS 都是授给你运行 meetap 的**那个终端 App**，不是授给 meetap 本身。所以在几个终端里开录，就要**在每个终端里各跑一次 `meetap setup`**；在系统设置里改了权限，可能要**退出并重新打开那个终端 App** 才生效。

<a id="upgrade"></a>

## 从 1.x 升级到 2.0

2.0 起只用 macOS 自带的 **Process Tap** 录音，**不再使用 BlackHole**，也不用再给会议 App 配扬声器；系统要求随之提高到 **macOS 14.4+**。

```bash
brew upgrade meetap        # 源码安装的话：cd meetap && git pull && make install
meetap setup               # 升级后先跑一次；在几个终端里开录，就在每个终端里各跑一次
```

`meetap setup` 会检查这些从 1.x 留下来的东西：

- **系统输出还停在 `BlackHole 2ch` 上**（以前录音崩溃后没恢复）：知道原来用的设备、它也还连着，就自动切回并告诉你切到了哪个；不知道的话列出设备让你选，默认「保持不变」——你可能是有意给别的软件用的。`meetap start` 开录前也会做同样的检查，但不会因此不开录。
- **Zoom 的扬声器还设成了 BlackHole**：提示你在 Zoom › 设置 › 音频 › 扬声器 里改回「与系统相同」。只提示，不改 Zoom 的配置。
- **系统里还装着 BlackHole**：提醒你检查 Teams、腾讯会议的扬声器是不是还选着 BlackHole 2ch（以前的 `setup` 让你这样选过），是的话改回系统默认或你的扬声器、耳机。
- **系统录音授权**：1.5.0 以前一直走 BlackHole 的用户从没授过这项权限，这一步必须做。

另外：

- **BlackHole 可以卸载**：`brew uninstall --cask blackhole-2ch`。卸不卸由你定——别的软件还在用的话就留着。卸载后驱动文件就删了，但设备列表里可能还挂着 `BlackHole 2ch`，要重启电脑（或 `sudo killall coreaudiod`）才会消失；在那之前别把它选成输出设备，`meetap setup` 也会这样提示。
- **配置里的 `audio_capture = blackhole` 可以删掉**：2.0 起这一项不起作用，录音照样走 Process Tap，`start`、`setup` 会提示一句。
- `meetap setup-zoom`、`setup-teams`、`setup-wemeet` 只会提示"2.0 起不需要配置会议 App 的扬声器"。
- 授权没生效时没有别的录音方式可以退，会录成静音。所以 2.0 加了**静音报警**：录音期间只要有 App 在放声音、录到的却全是零，30 秒内弹通知（见[故障排查](#troubleshooting)）。
- **会话文件夹变了**：诊断文件、标签挪进隐藏的 `.meetap/`，`log/` 里是 `transcript.txt`、`meetap.log` 和 Transcribe 原始结果 `transcribe-raw.json`。老会话照样读得到；想整理成新样子，跑 [`meetap tidy`](#s-tidy)。
- **2.0.0 转录完会删掉 `transcribe-raw.json`，2.0.1 起不再删**：逐词时间和置信度只在这个文件里。用 2.0.0 录的会想找回来，见[会话文件夹里有什么](#files)。
- **日历是新功能**：想用的话在 `setup` 第 3 步授权，见[用上日历](#s-calendar)。

---

## 场景卡

<a id="s-online"></a>

### 录一场线上会议（Zoom、Teams、飞书、腾讯会议、Chime）

**什么时候用**：任何在这台 Mac 上开的线上会。meetap 录的是整台电脑的声音加上你的麦克风，不用以"机器人参会者"的身份进会，会上的人看不到它；会议 App 也不用做任何设置。

**怎么用**：

```bash
meetap              # 开会前或会上随时敲，等同 meetap start
meetap start 周会    # 想给这场起个名：名字接在文件夹名后面，比如 20261119_1430_周会
# 会开完：在这个终端按 Ctrl-C（等同 meetap stop）
```

**你会看到什么**：

```
🎙️  录制已开始
   播放: MacBook Pro Speakers (Process Tap)
   停止录制: Ctrl-C（或在其他终端运行 /Users/you/bin/meetap stop）
   自动停止: 关闭（手动 stop 结束）
```

终端底部一直显示音量电平和时长。按 Ctrl-C 以后：

```
⏳ 等待录制完成...
✅ 音频采样成功
📝 后台转录已启动（完成后会收到通知）
```

转录、写纪要在后台跑，30 秒到几分钟（看会议长度），写完右上角弹通知。纪要在 `~/Record/<YYYYMMDD_HHMM>/` 里，文件名按纪要的主题起，比如 `2026-11-19_1430_季度规划评审.md`，旁边还有一份排好版的 `.html`（[文件夹里都有什么](#files)）。

**注意**：

- 照常从原来的扬声器、耳机听声音；录音中途换输出设备也不影响。
- 开着外放会有回声：扬声器的声音又被麦克风录进去一遍。戴耳机最好。
- 只敲 `meetap` 就开录；开录选项可以直接跟在后面，比如 `meetap -m -d 60`（只认 `-t`、`-d`、`-b`、`-m` 和它们的长写法）。`meetap 周会` 会报"未知命令"、不开录，免得敲错字误开录音；起名要写 `meetap start 周会`。
- 前台录音时直接关掉终端窗口，也会像 `stop` 一样正常收尾。
- 加 `-t`（`meetap start -t`、`meetap stop -t`）会多显示文件路径、大小、时长。
- 整段录音都是静音（多半是系统录音没授权）时不上传转录，音频留在本地，并弹通知；先跑 `meetap setup`。
- 纪要始终是中文；转录稿保持会上说的语言。

<a id="s-offline"></a>

### 线下会议、面对面聊（靠麦克风）

**什么时候用**：会议室里开会、面对面聊、做访谈、电话开外放——声音只从麦克风进来。

**怎么用**：和线上会议一样敲 `meetap`，会开完按 Ctrl-C。把 Mac 放在大家中间；别加 `-m`，加了就不开麦克风了。

**你会看到什么**：和[线上会议](#s-online)一样。转录稿里按说话人分开，写成 `spk_0`、`spk_1`……，纪要里会尽量对上人名（有[日历](#s-calendar)或 `materials/` 里的资料时更准）。

**注意**：

- 菜单栏亮橙点是麦克风在用，正常。
- 用 AirPods 之类的蓝牙耳机当麦克风时，系统会把它切到通话音质，耳机里放的声音会变差；只要电脑声音的场合用 [`-m`](#s-mute)。
- 中英混着讲，把配置 `multi_language` 改成 `true`；会议常用的语言写在 `transcribe_languages`（按优先级，默认 `en-US zh-CN ja-JP`）。
- 说话人最多分 `max_speakers` 个（2–10，默认 10）。

<a id="s-mute"></a>

### 录网课、直播、视频，只要电脑的声音（-m）

**什么时候用**：网课、直播、YouTube、播客、线上分享——只要电脑里在放的声音，现场的环境声会干扰转录。

**怎么用**：

```bash
meetap -m                 # 不开麦克风
meetap start -m -d 150    # 再加个时长上限，150 分钟后自动停
```

**你会看到什么**：

```
🎙️  录制已开始
   播放: MacBook Pro Speakers (Process Tap)
   麦克风: 已静音（只录系统音）
   停止录制: Ctrl-C（或在其他终端运行 /Users/you/bin/meetap stop）
   自动停止: 150 分钟后（约 17:00）
```

**注意**：

- 麦克风全程不打开：菜单栏不亮橙点，AirPods 不会被切到通话音质。你自己说的话也录不进去。
- `-m`、`--mute-mic`、`--mute-microphone` 三种写法一样；写在会议名前后都行。
- 终端底部的电平这时只跟电脑的声音走。

<a id="s-duration"></a>

### 会议有固定时长，到点自动停（-d）

**什么时候用**：会议时间定好了，怕会后忘了停，录一晚上。

**怎么用**：

```bash
meetap -d 60              # 60 分钟后自动停
meetap start -d 90 评审    # 起名、限时一起写
```

**你会看到什么**：开录时多一行 `   自动停止: 60 分钟后（约 15:30）`；到点自动停止，接着照常转录、写纪要。`meetap status` 会显示 `自动停止: 已设时长上限`。

**注意**：

- 没写 `-d` 就一直录到你停。
- 中间安静一阵不会自动停：按静音自动停的功能已经去掉了，会议停顿不该结束录音。
- 提前开完了照样可以 Ctrl-C 或 `meetap stop`。

<a id="s-background"></a>

### 录音时还要用这个终端（-b、stop）

**什么时候用**：开着录音还想在这个终端里干别的；或者在脚本、alias、shell 函数、快捷指令里调用，要求马上返回（比如 `meetap start -b && open zoommtg://...`）。

**怎么用**：

```bash
meetap -b         # 在后台录，马上把终端还给你
meetap status     # 看看是不是在录
meetap stop       # 结束（哪个终端里都行）
```

**你会看到什么**：开录信息的"停止录制"一行变成 `   停止录制: /Users/you/bin/meetap stop`。没在录时 `meetap status` 显示：

```
⏹️  未在录制
```

**注意**：

- 从 v1.7 起 `meetap start` 默认在前台运行、占着终端；脚本里调用、希望立刻返回的，要加 `-b`。
- `-b` 时关掉终端窗口不会收尾，录音继续，要记得 `meetap stop`。

<a id="s-again"></a>

### 纪要不满意：补资料、提要求、重写（again、materials/）

**什么时候用**：纪要里人名、术语写错了；会后拿到了议程、PPT；想换个写法，比如突出决策和负责人。

**怎么用**：

```bash
cp 议程.pdf ~/Record/20261119_1430/materials/          # 资料放进这场会的 materials/
meetap again                                           # 重写最近一场
meetap again 20261119_1430                             # 指定哪一场：文件夹名，或者 2026-10/20261008_1046 这样的路径
meetap again '' '请用要点列表重写，突出决策项与负责人'      # 附带要求；第一个参数留空就是最近一场
```

**你会看到什么**（照代码写）：

```
🔁 重新执行会议任务: 20261119_1430
   本次补充要求: 请用要点列表重写，突出决策项与负责人
   已归档旧文件: 2026-11-19_1430_季度规划评审.md → archive/
   检测到转录文本，从「纪要生成」阶段重跑（吸收 materials/ 新资料与 extra-requirements.md）
```

然后照常生成新的纪要；配了邮件的话也会再发一封。

**注意**：

- 资料支持 md、txt、pdf、docx、html；pdf 要装 `pdftotext`（`brew install poppler`）。资料只是帮模型认人名、术语、补背景，会上讲了什么以录音为准。
- 补充要求存进会话文件夹里的 `extra-requirements.md`，以后不带要求再跑 `again` 也照样用；不想要了就删掉它，也可以直接编辑它。
- 旧纪要（md、html）挪进 `archive/`，文件名前加时间，不会被覆盖。
- 已经有转录稿时只重写纪要，不重新上传、不重新转录；会重新认一次日历（见[用上日历](#s-calendar)）。

<a id="s-resume"></a>

### 合盖休眠、断网、转录中断以后，接着出纪要（again、status）

**什么时候用**：录到一半合盖休眠了；转录、写纪要时网断了、AWS 凭证过期了；或者哪一步失败了。

**怎么用**：

- **凭证过期、网络断一下**：什么都不用做。刷新凭证、等网络恢复，它自己接着跑完。
- **合盖休眠**：录音会自动结束，唤醒后弹通知，照通知里写的跑 `meetap again <会话>`。
- **别的失败，或者等太久放弃了**：

```bash
meetap status                  # 休眠留下的待办会显示在这里
meetap again 20261119_1430     # 从断的地方接着跑，音频不用重录
```

**你会看到什么**：

- 休眠结束录音时，通知写 `录音已因休眠结束。运行 meetap again 20261119_1430 生成纪要`；`meetap status` 里多一行 `   上次录音因休眠结束，待生成纪要: meetap again 20261119_1430`。
- 凭证过期时弹一次通知（下面的时间是示意）：`上传录音失败：AWS 凭证可能过期了。刷新凭证以后会自动接着跑`；会话的 `log/meetap.log` 里是：

  ```
  [14:02:10] ⚠️ 上传录音失败：AWS 凭证取不到或者已经过期。刷新凭证以后会自动接着跑，这一步最多等 15 分钟
  [14:02:10]    上传录音第 1 次失败，10 秒后重试
  [14:02:20]    上传录音第 2 次失败，20 秒后重试
  [14:02:40] ✅ 上传录音恢复了，接着跑
  ```

- 15 分钟还不行就放弃，再弹一次通知：`上传录音一直没成功，已放弃。恢复以后用 meetap again 20261119_1430 重跑`。

**注意**：

- `again` 自己判断从哪一步接：已经有转录稿，只重写纪要；没有转录稿、但上一次的转录任务已经在 AWS 上转完（或者还在转），直接取结果，不重新上传、不重新转录；都没有，就从上传开始。
- 查凭证、上传、查转录进度、下载结果、认日历、生成纪要、发邮件，每一步都这样等：间隔从 10 秒起逐次拉长（最长 2 分钟），每一步各自最多等 15 分钟。通知只弹两次：断掉时第一次失败弹一次（分得出是凭证问题就直说），放弃时再弹一次。
- 不是凭证、也不是网络的报错（比如权限不够），试 3 次就停，不空等；原因看 `log/meetap.log`。
- `log/meetap.log` 接着往后写，每次开头一行 `===== 2026-11-19 14:23:05 · meetap again 20261119_1430 =====`，上一次为什么失败还看得到。
- 录音边录边落盘，每 10 秒写一次；进程被强杀或者断电，最多丢最后 10 秒，剩下的照样能 `again`。
- 只有系统休眠才结束录音；锁屏、显示器休眠不影响。休眠前不上传，免得上传被打断。

<a id="s-calendar"></a>

### 让日历帮纪要认人名和议题（日历授权）

**什么时候用**：系统日历里有这场会，想让纪要用上会名、组织者、参会人和议程，人名、议题写得更准。

**怎么用**：

1. 在 **系统设置 › 互联网账户** 里加上公司账户（比如 Microsoft Exchange），勾选「日历」。刚加的账户要等十几分钟才同步完。
2. 在你开录的那个终端里跑 `meetap setup`，第 3 步授权日历，要「完全访问」。
3. 之后照常录，什么都不用多做。

**你会看到什么**：

- 纪要写完的通知里带一句，比如 `会议纪要已生成: 2026-11-19_1430_季度规划评审.md。日历：按时间认出 季度规划评审`；录到的明显不是日历上那场会时是 `日历：同时段 1 场，内容对不上，没用`；时段里没有会就不带。
- 会话的 `log/meetap.log` 里记一行，比如 `📅 日历：这场会是「季度规划评审」（时间最接近，内容也对得上：讨论的是季度规划），已写 materials/calendar.md`。
- **纪要里不写怎么认的**：纪要会转给别人，写进去会把日历里别的会、客户名带出去。
- 会话的 `materials/calendar.md`：标题、时间、怎么认出来的、组织者、参会人、地点、会议说明。开头写明"来自系统日历，是会前的安排，实际讨论以录音为准"。
- `meetap <文件夹>` 多一行 `  日历：季度规划评审（12:00–13:00，按时间认出）`；转录还没完时是 `  日历：候选 2 场，转录完按内容认`。

**注意**：

- **怎么认的**：停止录音时，按这场录音的实际起止时间收下同时段的会——重叠不到 5 分钟的不算（录音不到 10 分钟时，重叠要超过录音的一半）；全天事件、已取消的、你已拒绝的不算；剩下的按起止时间和录音的贴近程度排（重叠时长 ÷ 录音和会合起来的总时长），最多收 5 场。转录完、写纪要之前再认：**时间优先**，起止时间最接近的那场交给模型（和写纪要同一个后端、同一个模型）核对内容。只有一场时先看标题：标题对得上就用它，不管会议说明写的是什么（自己建的日程，比如 `youtube-watching`，说明常常是从别的会复制来的）；标题和说明都明显对不上（比如标题是周会、录到的是新闻时评），才不用日历。几场起止时间完全一样时，按内容选最对得上的那场。模型 30 秒没回、出错、回的看不懂时：时间最接近的只有一场就照时间定，几场一样就不用日历；都不耽误写纪要。
- **交给模型什么**：转录稿开头约 4000 字加结尾约 1000 字、`materials/` 里的文件名、候选会议的标题、起止时间、组织者、前 20 位参会人、会议说明的前 500 字。入会链接、会议号、密码、拨入电话都去掉了，发到的是你自己账号里的 Bedrock（`ai_backend = claude-code` 时走 `claude` 命令行）。不想多这一次调用，配置写 `calendar = off`，整个不碰日历。
- **不写什么**：入会信息不进纪要和邮件；参会人超过 30 位时只列组织者和前 20 位，并写明总人数；文件里不出现邮箱。
- **只有 `meetap setup` 会请求日历授权**：开录、停止、休眠自动停止、后台录音都不弹框，只在已经授权时读。查不到——没授权、日历没同步、时段里没有会、查询超时（10 秒）——都直接跳过，只在 `log/meetap.log` 里记一行 📅。
- **重查**：`meetap again` 会重新收、重新认，覆盖 `calendar.md`——前提是这份文件是 meetap 自己写的、没被改过。你改过的、自己放进去的原样留着，日志里提示一句；想重查就先删掉它。休眠自动结束的那场，唤醒后 `again` 时补上。
- **只有「写入」权限读不到会**：`setup` 会写明去 **系统设置 › 隐私与安全性 › 日历** 把当前终端 App 改成「完全访问」，改完可能要重开终端。换了终端 App，要在新终端里再跑一次 `setup`。
- 认出来的那场的标题会当成[标签](#s-tag)建议。

<a id="s-mark"></a>

### 标出纪要里的重点（mark）

**什么时候用**：纪要写好了，想让关键数字、核心结论、案例结果更醒目。

**怎么用**：

```bash
meetap mark                  # 给最新一场的纪要加高亮
meetap mark 20261119_1430    # 指定哪一场
```

**你会看到什么**（照代码写）：

```
🖍  高亮目标：2026-11-19_1430_季度规划评审.md
   正在标注要点...
✅ 已高亮：2026-11-19_1430_季度规划评审.md
```

纪要里的重点套上 `<mark>`，在 VS Code、Typora、GitHub、浏览器里显示成黄色底色。

**注意**：

- 只加标记、不改正文：写回前逐字比对，模型动了正文就放弃，原文件不变。
- 可以反复跑：重跑先清掉上次的高亮再重标，不会层层嵌套。没找到可标的就提示"文件未改动"。
- 高亮只写进 md 文件，不影响已经发出的邮件。

<a id="s-tag"></a>

### 贴标签，找回以前的会（-g、--untag、meetap <文件夹>）

**什么时候用**：同一系列的会（周会、某个客户）想归到一起，以后按标签找出来，做跨会议的回顾；或者想看看某场会录了多久、纪要叫什么。

**怎么用**：

```bash
meetap -g 周会                         # 贴给正在录的那场；没在录就贴给最新一场
meetap -g 周会 -g 客户A                 # 一次贴多个（-g 也可以写成 --tag）
meetap 20261118_1201 -g 周会            # 贴给指定的那场（写文件夹名）
meetap 2026-10/20261008_1046 -g 周会    # 已经挪进月份文件夹的老会议，写路径
meetap 20261118_1201 --untag 客户A      # 撤掉一个标签（不写文件夹时，默认目标和 -g 一样）
meetap -g                              # 列出最新一场的标签，以及用过的全部标签和场数
meetap 20261118_1201                   # 显示这场会的时间、时长、纪要、标签、日历（不开录）
```

**你会看到什么**（临时目录里实跑，会话是编的）：

```
$ meetap 20261118_1201
20261118_1201
  开始：2026-11-18 12:01
  时长：73 分钟
  纪要：季度规划评审
  标签：周会
  日历：季度规划评审（12:00–13:00，按时间认出）
  状态：已结束

$ meetap 20261118_1201 -g 客户A
已给 11-18 12:01（73 分钟 · 纪要：季度规划评审）贴上：客户A
现有标签：周会、客户A

$ meetap -g
最新一场 11-18 12:01（73 分钟 · 纪要：季度规划评审）的标签：周会、客户A
日历标题：季度规划评审，要贴的话：meetap -g 季度规划评审
用过的全部标签（2 个，含月份文件夹里的会话）：
  客户A（2 场）
  周会（1 场）
```

**注意**：

- 录音中、停止时、会后任何时候都能贴。
- **防贴错**：没写文件夹、当前没在录、最新一场又开始于 12 小时以前时，会先问一句再写；没有终端时（脚本、菜单栏 App 调用）直接拒绝，提示你写明文件夹。
- **大小写不敏感**：`Weekly` 和 `weekly` 算同一个标签，存的时候保留你第一次的写法。新标签和已有标签相近时（一个包含另一个），提示一句"已有相近的标签：团队周会（8 场）"，照样贴上。
- **统计范围**："用过的全部标签"扫 `recording_dir` 第一层，加上名字是 `20YY-MM` 的月份文件夹里的会话，所以按月把老会议挪进月份文件夹不会丢掉标签统计。
- 日历标题只当建议，只提示、不自动贴。
- 开录选项不能和 `-g` 混用（`meetap -m -g 周会` 会报错、不开录）；`meetap start 周会` 里的名字只进文件夹名，不会自动变成标签。
- 标签存在会话的隐藏文件夹 `.meetap/meta.json` 里，不放进 `materials/`（那里的东西会交给模型）。以前的版本放在会话根目录，照样读得到；改一次标签就挪进 `.meetap/`，`meetap tidy` 也会挪。

<a id="s-email"></a>

### 纪要自动发到邮箱

**什么时候用**：每场会的纪要想自动发给自己或固定几个人。

**怎么用**：

1. 在 [SES 控制台](https://console.aws.amazon.com/ses/) 验证发件地址（AWS 防滥用的要求，绕不过去）。
2. `meetap config` 打开配置，填上：

   ```ini
   email = alice@example.com, bob@example.com
   email_sender = meetap@example.com
   ```

**你会看到什么**：每次写完纪要，`log/meetap.log` 里记一行 `✅ Email sent to: alice@example.com, bob@example.com`；邮件正文就是排好版的纪要（会话文件夹里那份 `.html`），标题是 `[MeeTap] <纪要标题>`。

**注意**：

- 邮件版去掉了纪要里的"目录"一节；表格样式写成内联，Outlook 这类会剥掉样式表的邮件客户端里也能正常显示。
- 填了 `email` 没填 `email_sender`：只生成 HTML，不发，日志里提示。两项都空着就整个跳过。
- SES 新账户默认在 sandbox 里，只能发给已验证的地址；要发给别人，先申请生产访问。权限配法见 [docs/iam.md](docs/iam.md)。
- 发信时网断了、凭证过期了，同样会等着重试（见[中断以后接着出纪要](#s-resume)）。

<a id="s-tidy"></a>

### 老会话整理成新样子（tidy）

**什么时候用**：以前录的会，`log/` 里还放着录音诊断、发言统计这些诊断文件，或者 2.0.0 转录失败时把 `transcribe-raw.json` 留在了隐藏的 `.meetap/` 里，和新录的会放得不一样。

**怎么用**：

```bash
meetap tidy        # 只列清单：每场会要挪什么；不改任何文件
meetap tidy --yes  # 看过清单、确认后执行
```

**你会看到什么**（临时目录里实跑，会话是编的）：

```
下面是 meetap tidy 会做的事（/Users/you/Record；只是清单，还没动任何文件）：

  2026-10/20261008_1046：诊断文件 1 个挪进 .meetap/
  20261105_0930：诊断文件 1 个挪进 .meetap/，meta.json 挪进 .meetap/
  20261119_1000：transcribe-raw.json 挪回 log/

挪进 .meetap/ 的诊断文件：2 个
挪回 log/ 的 transcribe-raw.json：1 个
挪进 .meetap/ 的 meta.json：1 个

确认没问题后执行：meetap tidy --yes
```

**注意**：

- **只挪不删**：`transcribe-raw.json` 是唯一带逐词时间和置信度的文件，tidy 一个都不删；留在 `.meetap/` 里的挪回 `log/`，老版本放在会话根目录的不动。
- `audio-tap.log`、`speaker-stats.txt` 和根目录的 `meta.json` 挪进隐藏的 `.meetap/`；`meetap.log` 留在 `log/`，以前被挪进 `.meetap/` 的挪回 `log/`。要挪去的位置已有同名文件的不挪，在清单里列出来。
- 2.0.0 的 `--include-no-audio`（连没有音频的会话的 `transcribe-raw.json` 也删）不再起作用：还认这个写法，只提示一句，不删任何东西。
- 音频、纪要、`materials/`、`archive/`、转录稿一概不动。扫的是 `recording_dir`（默认 `~/Record`）下的所有会话，含月份文件夹、更深的子文件夹和老版本的文件布局。
- 新录的会不用整理：转录完就是整理好的样子。

<a id="s-english"></a>

### 界面切成英文

**什么时候用**：习惯看英文提示，或者把终端输出贴给不读中文的同事。

**怎么用**：`meetap config` 打开配置，把 `language` 改成 `en-US`。

**你会看到什么**（照代码写）：

```
🎙️  Recording started
   Playback: MacBook Pro Speakers (Process Tap)
   Stop recording: Ctrl-C (or run /Users/you/bin/meetap stop in another terminal)
   Auto-stop: off (stop manually)
```

**注意**：只影响终端输出、通知和帮助。纪要始终是中文，`materials/calendar.md` 也是中文；转录稿保持会上说的语言。

---

<a id="cheatsheet"></a>

## 速查

### 命令

| 命令 | 做什么 |
|---|---|
| `meetap` 或 `meetap start [会议名]` | 开始录音（前台运行，Ctrl-C 结束） |
| `-d 分钟` | 到点自动停 |
| `-m`（`--mute-mic`、`--mute-microphone`） | 不开麦克风，只录电脑的声音 |
| `-b` | 在后台录，不占终端 |
| `-t` | 开录、停止时多显示文件路径、大小、时长 |
| `meetap stop [-t]` | 结束录音，后台转录、写纪要 |
| `meetap status` | 看是不是在录，有没有休眠留下的待办 |
| `meetap again [会话] [补充要求]` | 从断的地方接着跑，或者重写纪要 |
| `meetap mark [会话]` | 给纪要的重点加高亮 |
| `meetap [会话] -g 标签`（`--tag`） | 贴标签；不写会话就贴给正在录的，没在录就最新一场 |
| `meetap [会话] --untag 标签` | 撤掉一个标签 |
| `meetap [会话] -g` | 列这场的标签和用过的全部标签 |
| `meetap <会话>` | 显示这场的时间、时长、纪要、标签、日历 |
| `meetap tidy [--yes]` | 老会话整理成新样子，只挪不删；不加 `--yes` 只列清单 |
| `meetap setup` | 授权系统录音、日历，检查 1.x 留下的设置；每个终端 App 跑一次 |
| `meetap config` / `meetap config show` | 编辑配置 / 看当前配置值 |
| `meetap version` | 显示版本号 |
| `meetap help`（`-h`、`--help`） | 显示所有命令 |

"会话"写文件夹名（`20261119_1430`），月份文件夹里的写路径（`2026-10/20261008_1046`），也可以写完整路径。

### 配置项

配置文件是 `~/.config/meetap/config`，第一次跑任何 `meetap` 命令时自动生成。`meetap config` 用 `$VISUAL` / `$EDITOR` 打开它；想恢复默认，删掉它再跑任意 `meetap` 命令。

| 配置项 | 默认 | 说明 |
|---|---|---|
| `region` | `us-east-1` | AWS 区域，S3、Transcribe、Bedrock 都用它 |
| `ai_backend` | `bedrock` | 用什么写纪要：`bedrock`，或 `claude-code`（走 `claude` 命令行，用不了时退回 Bedrock） |
| `model` | `global.anthropic.claude-sonnet-5` | 写纪要用的 Bedrock 模型 ID |
| `transcribe_languages` | `en-US zh-CN ja-JP` | 转录候选语言，按优先级 |
| `multi_language` | `false` | 一场会里中英混着讲时改成 `true` |
| `max_speakers` | `10` | 最多分几个说话人（2–10） |
| `recording_dir` | `~/Record` | 会话文件夹放在哪 |
| `audio_bitrate` | `128k` | 录音码率：`64k` 文件小，`256k` 音质高 |
| `audio_persist` | `true` | 转录成功后留不留本地音频；`false` 就删 |
| `language` | `zh-CN` | 终端界面语言：`zh-CN` 或 `en-US`，不影响纪要 |
| `visualizer` | `dot` | 终端底部电平的样式：`dot`、`bar`、`spectrum`、`block` |
| `calendar` | `on` | 用不用日历；`off` 时完全不碰日历，也不多调一次模型 |
| `zero_alert_ignore` | `com.amazon.workspaces` | 静音报警时不算"在放声音"的 App，逗号分隔（见[故障排查](#troubleshooting)） |
| `email` | 空 | 纪要收件人，逗号分隔；空着就不发 |
| `email_sender` | 空 | SES 验证过的发件地址；填了 `email` 就要填 |

---

<a id="files"></a>

## 会话文件夹里有什么

每场会一个文件夹，默认在 `~/Record/<YYYYMMDD_HHMM>/`（起了名的话后面接 `_<会议名>`）：

```
/Users/you/Record/20261119_1430/
├── 2026-11-19_1430_<主题>.md    ← 纪要（主要看这个）
├── 2026-11-19_1430_<主题>.html  ← 排好版的 HTML，邮件正文就是它
├── meeting_20261119_143005.m4a ← 录音（边录边写，每 10 秒落一次盘；audio_persist = false 时转录成功后删掉）
├── materials/                   ← 放参考资料，写纪要时交给模型；calendar.md 是从日历认出的这场会
├── archive/                     ← （again 以后才有）旧版纪要
├── log/
│   ├── transcript.txt           ← 带说话人的转录稿
│   ├── transcribe-raw.json      ← Transcribe 原始结果：每个词的开始、结束时间和置信度
│   └── meetap.log               ← 每一步的时间和报错，排错看这个
└── .meetap/                     ← 隐藏文件夹（Finder 里按 Cmd+Shift+. 显示，或 ls -a）
    ├── meta.json                ← （贴过标签或查过日历才有）标签、日历等信息
    ├── calendar-candidates.json ← （同时段日历里有会才有）收下的候选会议，认会、重查时用
    ├── transcribe-job.json      ← （转录还没取回来时才有）AWS 上的转录任务，again 接着用
    ├── speaker-stats.txt        ← 每人发言时长占比，重写纪要时用
    └── audio-tap.log            ← 录音诊断：采样率、变零 / 恢复的时间
```

`log/transcribe-raw.json` 是 Transcribe 返回的原始结果（平均 700 多 KB），**会话里只有它带逐词时间和置信度**，转录成功、失败都留着；`audio_persist = false` 删掉音频以后也还在。

2.0.0 转录完会把它删掉。用 2.0.0 录的会想找回来，音频还在的话，删掉 `log/transcript.txt` 再跑 `meetap again`：会从音频重新转录（Transcribe 再收一次费），纪要也跟着重写，旧纪要挪进 `archive/`。音频已经删了的就找不回来了。2.0.0 转录失败时留在 `.meetap/` 里的那份，跑 [`meetap tidy`](#s-tidy) 挪回 `log/`。

---

<a id="troubleshooting"></a>

## 故障排查

| 现象 | 原因 | 怎么办 |
|---|---|---|
| 第一次 `start` 提示没有系统音频权限，或者录音全是静音 | 终端 App 没有"系统录音"授权 | 在这个终端里跑 `meetap setup`；或者在 系统设置 › 隐私与安全性 › 屏幕与系统录音 里把终端 App 加进"仅系统录音"，再重开终端 |
| 录出 0 字节的音频，或者转录报 `input file empty`（短会议偶发） | macOS Process Tap 的回调偶尔不启动，ffmpeg 收不到数据。终端底部的波形读的是麦克风，这时照样会跳，不代表在正常录 | 录音中 audio-tap 会自己盯着：有声音在放、tap 却一直没数据，就在进程内重建 tap，录音不中断。`start` 时起不来会自动重试 3 次；还不行就按提示跑 `meetap setup` 查授权，或者重新 `start`。细节见 [docs/tap-静默空录排障.md](docs/tap-静默空录排障.md) |
| 收到"录音可能漏了"通知 | 有 App 在放声音、录到的却全是零：授权失效，或者系统录音中途出了故障；也可能那个 App 只是开着音频输出、其实没出声 | 看通知里写的是哪个 App。它当时其实没出声（比如 Amazon WorkSpaces 客户端一直开着输出），就把通知里**括号里那一串**（bundle ID，比如 `com.google.Chrome.helper`；命令行程序没有括号，写程序名）加进配置 `zero_alert_ignore`，逗号分隔。确实在开会，就跑 `meetap setup` 查授权，必要时 `meetap stop` 后重新开录。变零、恢复的时间记在 `.meetap/audio-tap.log`（`TAP_ZERO_START` / `TAP_ZERO_END`；名单里的 App 记作 `ignored=`） |
| 转录失败：`AWS credentials not configured` | 没配 AWS 凭证 | 跑 `aws configure`，或者检查 `AWS_PROFILE` |
| 弹通知"AWS 凭证可能过期了"，日志里"凭证取不到或者已经过期" | 凭证过期了，或者刷新时网断了一下 | 刷新凭证就行，meetap 自己接着跑，不用 `again`；每一步最多等 15 分钟。放弃了（第二次通知），就在凭证恢复以后跑通知里写的 `meetap again <会话>`，AWS 上已经转完的结果会直接拿来用 |
| 转录或写纪要报 `AccessDenied` / `ValidationException` | 账号没开通模型，或者 IAM 权限不够 | 在 Bedrock 控制台的 Model access 里开通模型；IAM 要有 `bedrock:InvokeModelWithResponseStream`，默认模型是跨区域推理配置文件，推理配置文件、本区域的基础模型、不分区域的基础模型三段都要有，见 [docs/iam.md](docs/iam.md) |
| 纪要一直没出来，卡在 "Generating meeting notes..." | 多半是 Bedrock 报错或者流断了 | 看会话的 `log/meetap.log` 里具体的 AWS 报错；断流的排查见 [docs/bedrock-纪要断流排障.md](docs/bedrock-纪要断流排障.md)；修好后 `meetap again` |
| 通知"录音里没有识别出说话内容"，没有纪要 | 录音只有几秒，或者一直没人说话，转录出来一个词都没有 | 不用处理：不生成纪要，音频留着。`meetap <文件夹>` 的纪要一行写"没有（录音里没有说话内容）"，日历一行写"录音里没有说话内容，没认日历" |
| 录音有回声 | 外放的声音又被麦克风录进去一遍 | 戴耳机；只要电脑声音时用 `-m` |
| 系统通知没弹出来 | 通知权限没开 | 系统设置 › 通知 里允许"终端"（或你用的终端 App）和"脚本编辑器"发送通知 |
| `materials/` 里没有 `calendar.md`，纪要里没用上日历 | 日历没授权、没同步、时段里没有会，或者模型判断内容对不上 | 先看纪要完成的通知和 `log/meetap.log` 里的 📅，或者跑 `meetap <文件夹>` 看日历那一行。写着"按内容判断都不是这场"：模型认为录音和同时段的会对不上。写着"没有读取权限"：在开录的那个终端里跑 `meetap setup`（只有「写入」权限的，去 系统设置 › 隐私与安全性 › 日历 改成「完全访问」，改完可能要重开终端）。写着"没有对应的会"：检查 系统设置 › 互联网账户 里的日历是否已同步，或者这场录音和日历里的会是否重叠不到 5 分钟。配置 `calendar = off` 时不会查 |
| 从 1.x 升级后听不到声音 | 系统输出或会议 App 的扬声器还指着 BlackHole 2ch | 跑一次 `meetap setup`，或者在 系统设置 › 声音 › 输出、会议 App 的音频设置里改回扬声器 / 耳机 |

---

## 更多

- **实现原理**（Process Tap 怎么录、云上走了哪几步）：[docs/how-it-works.md](docs/how-it-works.md)
- **最小 IAM 权限**：[docs/iam.md](docs/iam.md)
- **开发、测试**：[docs/development.md](docs/development.md)

## License

MIT
