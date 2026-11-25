# MeeTap 开发说明

> 从 README 挪过来的。只用 meetap 不需要读这一页。

## 编译和安装

```bash
git clone https://github.com/henceman777/meetap.git
cd meetap
make            # 只编译，不安装（产物在 build/）
make install    # 装到 ~/bin（含 audio-tap、audio-multi-output 重新签名，保证系统录音、日历授权生效）
make clean      # 清理构建产物
```

源码装的 `meetap version` 后面会带「分支@提交号」（有未提交的改动再加 `-dirty`），用来区分本地试用的构建；Homebrew 装的不带。

## 代码布局

```
src/
├── meetap                    # bash 主控脚本（录音、转录、纪要、日历、标签、tidy 都在这里）
├── audio-tap.swift           # Core Audio Process Tap 采集 + 麦克风进程内采集，两路分声道输出（macOS 14.4+）
├── audio-tap-Info.plist      # 嵌入 audio-tap 的音频录制权限描述
├── audio-multi-output.swift  # CoreAudio 设备查询 / 切换默认输出（升级迁移用）+ 休眠自动结束（sleep-watch）+ 日历查询（EventKit）
├── audio-multi-output-Info.plist  # 嵌入 audio-multi-output 的日历用途说明
├── lib/ui.sh                 # 终端交互的样式：有 gum 时用 gum，没有就纯文本
└── i18n/                     # CLI 双语消息表（messages-zh-CN.sh / messages-en-US.sh，两份 key 要一致）
share/meetap/prompts/
├── meeting-notes.md          # 生成纪要的提示词
├── calendar-match.md         # 认日历（核对是哪场会）的提示词
└── highlight.md              # meetap mark 的提示词
config.default                # 首次运行时拷到 ~/.config/meetap/config 的默认配置
```

## 测试

测试都是 `test/` 下的 bash 脚本，直接跑：`test/calendar-test.sh`。全部在临时目录里做，不碰真实的 `~/Record`；开头会查 `/tmp/meeting-record/ffmpeg.pid`，正在录音时一个用例都不跑。

| 不需要音频设备、不触达 AWS | 需要真机（音频设备、真实录音） |
|---|---|
| `bare-start-test.sh`、`calendar-test.sh`、`calendar-selftest.sh`、`echo-check-test.sh`、`frag-write-test.sh`、`highlight-verify-test.sh`、`log-cleanup-test.sh`、`migrate-test.sh`、`resample-selftest.sh`、`resolve-session-test.sh`、`retry-test.sh`、`sleep-stop-test.sh`、`sleep-watch-test.sh`、`tag-test.sh`、`track3-golden-test.sh`、`zero-guard-selftest.sh` | `bt-scenarios.sh`（蓝牙耳机）、`ctrl-c-test.sh`、`mic-clock-test.sh`、`mic-rate-test.sh` |

注意：`sleep-stop-test.sh` 里有作用到整台机器的 `pkill`，正在录音时别跑。

只给测试用的环境变量（正式使用不要设）：

| 变量 | 作用 |
|---|---|
| `MEETAP_STATE_DIR` | 录音状态目录（默认 `/tmp/meeting-record`） |
| `MEETAP_HAL_PLUGIN_DIRS` | 检查 BlackHole 驱动时看的目录 |
| `MEETAP_CAL_LLM_TIMEOUT` | 认日历那次模型调用的上限（默认 30 秒） |
| `MEETAP_RETRY_LIMIT_SEC` | 凭证、网络断了时每一步最多等多久（默认 900 秒），间隔按比例跟着缩 |
| `MEETAP_TAP_FAULT_ZERO_AFTER` / `MEETAP_TAP_FAULT_ZERO_FOR` | 让 audio-tap 故意交出全零数据，测静音报警 |
