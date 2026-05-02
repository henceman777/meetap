# MeeTap — English (en-US) CLI messages
# Covers CLI display only: terminal output, notifications, help text
# Does NOT cover: meeting notes (always Chinese), transcript (meeting-native),
#                 AWS SDK errors (passed through verbatim)

# ── Auto-stop ──
MSG_AUTOSTOP_NOTIFY="Silent for %s seconds, stopping recording automatically"

# ── Transcription pipeline ──
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
MSG_NOTIFY_TRANSCRIBE_FAILED="Transcription failed, check the log"
MSG_DOWNLOADING="Downloading transcript..."
MSG_TRANSCRIBE_DONE="✅ Transcription complete: %s"
MSG_NOTIFY_TRANSCRIBE_DONE="Transcription done, generating meeting notes..."

# ── Notes generation (meta messages only; note body stays Chinese) ──
MSG_ERR_TRANSCRIPT_MISSING="⚠️ transcript.txt not found in log/, skipping summarization"
MSG_GENERATING_NOTES="📝 Generating meeting notes via %s..."
MSG_ERR_VENV_MISSING="⚠️ Python venv not found: %s, skipping summarization"
MSG_NOTES_DONE="✅ Meeting notes generated: %s"
MSG_NOTIFY_NOTES_DONE="Meeting notes ready: meeting-notes.md"
MSG_NOTES_FAILED="⚠️ Meeting notes generation failed, transcript.txt is still available"
MSG_NOTIFY_NOTES_FAILED="Notes generation failed, transcript available"
MSG_CLAUDE_CLI_MISSING_FALLBACK="⚠️ claude CLI not found, falling back to bedrock"
MSG_CLAUDE_EMPTY_FALLBACK="⚠️ claude-code returned empty output, falling back to bedrock"

# ── Email ──
MSG_ERR_EMAIL_SENDER_MISSING="⚠️ email_sender not configured, skipping email"
MSG_ERR_EMAIL_VENV_MISSING="⚠️ Python venv not found, skipping email"
MSG_EMAIL_CONVERTING="📧 Converting to PDF and sending email..."
MSG_EMAIL_SENT="✅ Email sent to: %s"
MSG_EMAIL_FAILED="⚠️ Email sending failed (notes still available locally)"

# ── Recording start ──
MSG_ERR_ALREADY_RECORDING="⚠️  A recording is already running (PID: %s)"
MSG_HINT_STOP_FIRST="   To start again, first run: %s stop"
MSG_ERR_TOOL_MISSING="❌ audio-multi-output tool not found: %s"
MSG_ERR_MONITOR_MISSING="❌ audio-monitor tool not found: %s"
MSG_ERR_FFMPEG_MISSING="❌ ffmpeg not found, please run: brew install ffmpeg"
MSG_ERR_BLACKHOLE_MISSING="❌ BlackHole 2ch not found"
MSG_HINT_INSTALL_BLACKHOLE="   Install: brew install blackhole-2ch"
MSG_CUR_OUTPUT_BH="📍 Current audio output: BlackHole (real device: %s)"
MSG_ERR_OUTPUT_IS_BH="⚠️  Current output is BlackHole, please switch back to a normal speaker/headphone first"
MSG_CUR_OUTPUT="📍 Current audio output: %s"
MSG_SWITCHING_TO_BH="🔧 Switching system output to BlackHole 2ch..."
MSG_ERR_CANT_SWITCH_BH="❌ Failed to switch to BlackHole"
MSG_SWITCHED_TO_BH="✅ System output switched to: BlackHole 2ch"
MSG_STARTING_MONITOR="🔧 Starting audio forward: BlackHole → %s..."
MSG_ERR_MONITOR_FAIL="❌ Failed to start audio-monitor:"
MSG_MONITOR_STARTED="✅ Audio forward started → %s"
MSG_MIC_DEVICE="🎤 Microphone: %s"
MSG_RECORDING_STARTED="🎙️  Recording started"
MSG_FIELD_FILE="   File: %s"
MSG_FIELD_PLAYBACK="   Playback: %s"
MSG_FIELD_AUTOSTOP="   Auto-stop: after 2 minutes of silence"
MSG_FIELD_STOP_CMD="   Stop recording: %s stop"
MSG_ERR_FFMPEG_FAIL="❌ Failed to start ffmpeg:"

# ── Recording stop ──
MSG_WAITING_RECORDING="⏳ Waiting for recording to finish..."
MSG_ERR_NO_ACTIVE_RECORDING="⚠️  No active recording"
MSG_FFMPEG_FORCE_KILL="⚠️  ffmpeg did not respond to SIGINT, forcing shutdown..."
MSG_OUTPUT_RESTORED="🔊 Audio output restored: %s"
MSG_ORIG_DEVICE_DISCONNECTED_FALLBACK="⚠️  Original device (%s) disconnected, switched to: MacBook Pro Speakers"
MSG_ORIG_DEVICE_DISCONNECTED_MANUAL="⚠️  Original device (%s) disconnected, please pick an output device manually"
MSG_RECORDING_SAVED="✅ Recording saved"
MSG_FIELD_SIZE="   Size: %s"
MSG_FIELD_DURATION="   Duration: %sm%ss"
MSG_RECORDING_SUCCESS="✅ Meeting captured successfully"
MSG_EMPTY_SESSION_REMOVED="🗑️  No audio captured, removed empty directory: %s"
MSG_TRANSCRIBE_BACKGROUND="📝 Background transcription started (you'll be notified when done)"

# ── Status ──
MSG_STATUS_RECORDING="🎙️  Recording%s"
MSG_STATUS_FILE="   File: %s"
MSG_STATUS_PLAYBACK="   Playback device: %s"
MSG_STATUS_AUTOSTOP_ON="   Auto-stop: enabled"
MSG_STATUS_MONITOR_RUN="   Audio forward: running"
MSG_STATUS_VISUALIZER_RUN="   Waveform: running (bottom of terminal)"
MSG_STATUS_IDLE="⏹️  Not recording"

# ── Setup: Zoom ──
MSG_SETUP_ZOOM_NO_CONFIG="⚠️  Zoom config not found, please launch Zoom once first"
MSG_SETUP_ZOOM_ALREADY_OK="✅ Zoom speaker is already Same as System, no change needed"
MSG_SETUP_ZOOM_CUR_SPK="📍 Zoom current speaker: %s"
MSG_SETUP_ZOOM_QUITTING="⏳ Quitting Zoom (will reopen after change)..."
MSG_SETUP_ZOOM_CANT_QUIT="❌ Could not quit Zoom, please close it manually and retry"
MSG_SETUP_ZOOM_DONE="✅ Zoom speaker set to: Same as System"
MSG_SETUP_ZOOM_REOPENING="🔄 Reopening Zoom..."

# ── Setup: Teams ──
MSG_SETUP_TEAMS_OPENING="⏳ Opening Teams..."
MSG_SETUP_TEAMS_OPEN_SETTINGS="🔧 Opening Teams device settings..."
MSG_SETUP_TEAMS_INSTRUCT_HEADER="📋 In the Teams Settings page:"
MSG_SETUP_TEAMS_INSTRUCT_SPEAKER="   Speaker → select \"BlackHole 2ch\""
MSG_SETUP_ONCE_NOTE="   ⚠️  Only needed once"
MSG_SETUP_PRESS_ENTER="   Press Enter after configuring..."
MSG_SETUP_TEAMS_DONE="✅ Teams setup complete"

# ── Setup: Tencent Meeting ──
MSG_SETUP_WEMEET_OPENING="⏳ Opening Tencent Meeting..."
MSG_SETUP_WEMEET_INSTRUCT_HEADER="📋 Configure manually in Tencent Meeting:"
MSG_SETUP_WEMEET_STEP1="   1. Avatar → Settings → Audio"
MSG_SETUP_WEMEET_STEP2="   2. Speaker → select \"BlackHole 2ch\""
MSG_SETUP_WEMEET_DONE="✅ Tencent Meeting setup complete"

# ── Setup apps ──
MSG_SETUP_HEADER="==============================="
MSG_SETUP_TITLE=" Meeting App Speaker One-Click Setup"
MSG_SETUP_STEP_ZOOM="[1/3] Configure Zoom"
MSG_SETUP_STEP_TEAMS="[2/3] Configure Teams"
MSG_SETUP_STEP_WEMEET="[3/3] Configure Tencent Meeting"
MSG_SETUP_DIVIDER="---"
MSG_SETUP_ALL_DONE="✅ Setup complete! You can now run %s start to record a meeting"
MSG_SETUP_ALL_DONE_HINT="   You only need to do this once, unless you change it back in an app."

# ── Config command ──
MSG_CONFIG_EXISTS="⚠️  Config file already exists: %s"
MSG_CONFIG_EXISTS_HINT="   Delete it first and re-run 'meetap config init' to reset"
MSG_CONFIG_CREATED="✅ Config file created: %s"
MSG_CONFIG_CREATED_HINT="   Edit to customize: %s"
MSG_CONFIG_HEADER="MeeTap v%s Configuration"
MSG_CONFIG_SEPARATOR="================================="
MSG_CONFIG_FILE_PATH="Config file: %s"
MSG_CONFIG_FILE_NONE="Config file: (not created, using defaults)"
MSG_CONFIG_HINT_INIT="Run 'meetap config init' to generate config file"

# ── Usage ──
MSG_USAGE_HEADER="MeeTap v%s - macOS meeting recorder + auto-transcription"
MSG_USAGE_LINE="Usage: meetap {start|stop|status|setup|config|version}"
MSG_USAGE_START="  start [-t]   Start recording (-t shows verbose device info)"
MSG_USAGE_STOP="  stop [-t]    Stop recording, restore audio device, auto-transcribe (-t shows verbose file info)"
MSG_USAGE_STATUS="  status       Show current recording status"
MSG_USAGE_SETUP="  setup        One-click setup for Zoom + Teams + Tencent Meeting (only once)"
MSG_USAGE_CONFIG="  config       Show current configuration"
MSG_USAGE_CONFIG_INIT="  config init  Generate default config file"
MSG_USAGE_VERSION="  version      Show version"
MSG_USAGE_HINT="First-time users please run: meetap setup"

# ── Version ──
MSG_VERSION_LINE="MeeTap v%s"
