# MeeTap — 中文 (zh-CN) CLI 消息表
# 仅覆盖 CLI 显示范围：终端输出、系统通知、帮助文案
# 不包括：会议纪要（永远中文）、transcript（会议原语）、AWS SDK 错误
#
# 每条消息定义为 MSG_<KEY>，由 _t() / _tn() 通过 printf 格式化，可带 %s / %d 占位符

# ── 自动停止 ──
MSG_AUTOSTOP_NOTIFY="持续静音 %s 秒，自动停止录制"

# ── 转录流程 ──
MSG_TRANSCRIBE_STARTED="Transcription started"
MSG_ERR_AWS_CLI_MISSING="❌ AWS CLI not found, skipping transcription"
MSG_ERR_AWS_CREDS_MISSING="❌ AWS credentials not configured"
MSG_UPLOADING="Uploading audio..."
MSG_ERR_UPLOAD_FAILED="❌ Upload failed"
MSG_LOCAL_AUDIO_DELETED="🗑️ Local audio deleted (audio_persist=false)"
MSG_START_JOB="Starting transcription job: %s"
MSG_STATUS_QUERY_RETRY="⚠ Status query failed (%s/5), retrying..."
MSG_STATUS_QUERY_ABORT="❌ Status query failed 5 times consecutively, aborting"
MSG_STATUS_LINE="Status: %s"
MSG_ERR_TRANSCRIBE_FAILED="❌ Transcription failed: %s"
MSG_NOTIFY_TRANSCRIBE_FAILED="转录失败，请查看日志"
MSG_DOWNLOADING="Downloading transcript..."
MSG_TRANSCRIBE_DONE="✅ Transcription complete: %s"
MSG_NOTIFY_TRANSCRIBE_DONE="转录完成，正在整理会议纪要..."

# ── 纪要生成（元信息，纪要正文永远中文）──
MSG_ERR_TRANSCRIPT_MISSING="⚠️ transcript.txt not found in log/, skipping summarization"
MSG_GENERATING_NOTES="📝 Generating meeting notes via %s..."
MSG_ERR_VENV_MISSING="⚠️ Python venv not found: %s, skipping summarization"
MSG_NOTES_DONE="✅ Meeting notes generated: %s"
MSG_NOTIFY_NOTES_DONE="会议纪要已生成: meeting-notes.md"
MSG_NOTES_FAILED="⚠️ Meeting notes generation failed, transcript.txt is still available"
MSG_NOTIFY_NOTES_FAILED="纪要生成失败，转录文件可用"
MSG_CLAUDE_CLI_MISSING_FALLBACK="⚠️ claude CLI not found, falling back to bedrock"
MSG_CLAUDE_EMPTY_FALLBACK="⚠️ claude-code returned empty output, falling back to bedrock"

# ── 邮件 ──
MSG_ERR_EMAIL_SENDER_MISSING="⚠️ email_sender not configured, skipping email"
MSG_ERR_EMAIL_VENV_MISSING="⚠️ Python venv not found, skipping email"
MSG_EMAIL_CONVERTING="📧 Converting to PDF and sending email..."
MSG_EMAIL_SENT="✅ Email sent to: %s"
MSG_EMAIL_FAILED="⚠️ Email sending failed (notes still available locally)"

# ── 录制启动 ──
MSG_ERR_ALREADY_RECORDING="⚠️  已有录制进程在运行 (PID: %s)"
MSG_HINT_STOP_FIRST="   如需重新开始，请先执行: %s stop"
MSG_ERR_TOOL_MISSING="❌ 未找到 audio-multi-output 工具: %s"
MSG_ERR_MONITOR_MISSING="❌ 未找到 audio-monitor 工具: %s"
MSG_ERR_FFMPEG_MISSING="❌ 未找到 ffmpeg，请运行: brew install ffmpeg"
MSG_ERR_BLACKHOLE_MISSING="❌ 未找到 BlackHole 2ch"
MSG_HINT_INSTALL_BLACKHOLE="   安装: brew install blackhole-2ch"
MSG_CUR_OUTPUT_BH="📍 当前音频输出: BlackHole (实际设备: %s)"
MSG_ERR_OUTPUT_IS_BH="⚠️  当前输出是 BlackHole，请先切回正常扬声器/耳机"
MSG_CUR_OUTPUT="📍 当前音频输出: %s"
MSG_SWITCHING_TO_BH="🔧 切换系统输出到 BlackHole 2ch ..."
MSG_ERR_CANT_SWITCH_BH="❌ 无法切换到 BlackHole"
MSG_SWITCHED_TO_BH="✅ 系统输出已切换到: BlackHole 2ch"
MSG_STARTING_MONITOR="🔧 启动音频转发: BlackHole → %s ..."
MSG_ERR_MONITOR_FAIL="❌ audio-monitor 启动失败:"
MSG_MONITOR_STARTED="✅ 音频转发已启动 → %s"
MSG_MIC_DEVICE="🎤 麦克风: %s"
MSG_RECORDING_STARTED="🎙️  录制已开始"
MSG_FIELD_FILE="   文件: %s"
MSG_FIELD_PLAYBACK="   播放: %s"
MSG_FIELD_AUTOSTOP="   自动停止: 持续静音 2 分钟后"
MSG_FIELD_STOP_CMD="   停止录制: %s stop"
MSG_ERR_FFMPEG_FAIL="❌ ffmpeg 启动失败:"

# ── 录制停止 ──
MSG_WAITING_RECORDING="⏳ 等待录制完成..."
MSG_ERR_NO_ACTIVE_RECORDING="⚠️  没有正在进行的录制"
MSG_FFMPEG_FORCE_KILL="⚠️  ffmpeg 未响应 SIGINT，强制终止..."
MSG_OUTPUT_RESTORED="🔊 音频输出已恢复: %s"
MSG_ORIG_DEVICE_DISCONNECTED_FALLBACK="⚠️  原始设备 (%s) 已断开，已切换到: MacBook Pro Speakers"
MSG_ORIG_DEVICE_DISCONNECTED_MANUAL="⚠️  原始设备 (%s) 已断开，请手动选择输出设备"
MSG_RECORDING_SAVED="✅ 录制已保存"
MSG_FIELD_SIZE="   大小: %s"
MSG_FIELD_DURATION="   时长: %s分%s秒"
MSG_RECORDING_SUCCESS="✅ 会议采样成功"
MSG_EMPTY_SESSION_REMOVED="🗑️  未产生录音文件，已删除空目录: %s"
MSG_TRANSCRIBE_BACKGROUND="📝 后台转录已启动（完成后会收到通知）"

# ── 状态 ──
MSG_STATUS_RECORDING="🎙️  录制中%s"
MSG_STATUS_FILE="   文件: %s"
MSG_STATUS_PLAYBACK="   播放设备: %s"
MSG_STATUS_AUTOSTOP_ON="   自动停止: 已启用"
MSG_STATUS_MONITOR_RUN="   音频转发: 运行中"
MSG_STATUS_VISUALIZER_RUN="   波形显示: 运行中（终端底部）"
MSG_STATUS_IDLE="⏹️  未在录制"

# ── Setup: Zoom ──
MSG_SETUP_ZOOM_NO_CONFIG="⚠️  未找到 Zoom 配置文件，请先运行一次 Zoom"
MSG_SETUP_ZOOM_ALREADY_OK="✅ Zoom 扬声器已是 Same as System，无需修改"
MSG_SETUP_ZOOM_CUR_SPK="📍 Zoom 当前扬声器: %s"
MSG_SETUP_ZOOM_QUITTING="⏳ 正在退出 Zoom（修改后会自动重新打开）..."
MSG_SETUP_ZOOM_CANT_QUIT="❌ Zoom 无法正常退出，请手动关闭后重试"
MSG_SETUP_ZOOM_DONE="✅ Zoom 扬声器已设为: Same as System"
MSG_SETUP_ZOOM_REOPENING="🔄 正在重新打开 Zoom..."

# ── Setup: Teams ──
MSG_SETUP_TEAMS_OPENING="⏳ 正在打开 Teams..."
MSG_SETUP_TEAMS_OPEN_SETTINGS="🔧 正在打开 Teams 设备设置..."
MSG_SETUP_TEAMS_INSTRUCT_HEADER="📋 请在 Teams 设置页面中:"
MSG_SETUP_TEAMS_INSTRUCT_SPEAKER="   Speaker → 选择「BlackHole 2ch」"
MSG_SETUP_ONCE_NOTE="   ⚠️  只需设置一次"
MSG_SETUP_PRESS_ENTER="   设置完成后按 Enter 继续..."
MSG_SETUP_TEAMS_DONE="✅ Teams 设置完成"

# ── Setup: 腾讯会议 ──
MSG_SETUP_WEMEET_OPENING="⏳ 正在打开腾讯会议..."
MSG_SETUP_WEMEET_INSTRUCT_HEADER="📋 请在腾讯会议中手动设置:"
MSG_SETUP_WEMEET_STEP1="   1. 点击头像 → 设置 → 音频"
MSG_SETUP_WEMEET_STEP2="   2. 扬声器 → 选择「BlackHole 2ch」"
MSG_SETUP_WEMEET_DONE="✅ 腾讯会议设置完成"

# ── Setup apps ──
MSG_SETUP_HEADER="==============================="
MSG_SETUP_TITLE=" 会议 App 扬声器一键配置"
MSG_SETUP_STEP_ZOOM="【1/3】配置 Zoom"
MSG_SETUP_STEP_TEAMS="【2/3】配置 Teams"
MSG_SETUP_STEP_WEMEET="【3/3】配置腾讯会议"
MSG_SETUP_DIVIDER="---"
MSG_SETUP_ALL_DONE="✅ 配置完成！现在可以使用 %s start 录制会议了"
MSG_SETUP_ALL_DONE_HINT="   此配置只需执行一次，除非你在 App 中手动改回。"

# ── Config 命令 ──
MSG_CONFIG_BOOTSTRAPPED="📝 已生成默认配置: %s"
MSG_CONFIG_HEADER="MeeTap v%s 当前配置"
MSG_CONFIG_SEPARATOR="================================="
MSG_CONFIG_FILE_PATH="配置文件: %s"
MSG_CONFIG_FILE_NONE="配置文件: (未创建，使用内置默认值)"
MSG_CONFIG_RESET_HINT="如需重置为默认: rm %s 后再次运行 meetap 任意命令"
MSG_CONFIG_OPENING_EDITOR="✏️  正在打开编辑器: %s"
MSG_CONFIG_NO_TEMPLATE="❌ 未找到默认配置模板，无法初始化"

# ── 用法 ──
MSG_USAGE_HEADER="MeeTap v%s - macOS 会议录制 + 自动转录"
MSG_USAGE_LINE="用法: meetap {start|stop|status|setup|config|version}"
MSG_USAGE_START="  start [-t]   开始录制（-t 显示详细设备信息）"
MSG_USAGE_STOP="  stop [-t]    停止录制，恢复音频设备，自动转录（-t 显示详细文件信息）"
MSG_USAGE_STATUS="  status       查看当前录制状态"
MSG_USAGE_SETUP="  setup        一键配置 Zoom + Teams + 腾讯会议（只需一次）"
MSG_USAGE_CONFIG="  config       打开编辑器修改配置（\$EDITOR）"
MSG_USAGE_CONFIG_SHOW="  config show  显示当前配置"
MSG_USAGE_VERSION="  version      显示版本号"
MSG_USAGE_HINT="首次使用请先运行: meetap setup"

# ── 版本 ──
MSG_VERSION_LINE="MeeTap v%s"
