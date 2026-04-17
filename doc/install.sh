#!/bin/bash
# 会议录制工具 - 一键安装脚本
# 在新 Mac 上从零开始安装所有依赖和工具
#
# 用法: bash install.sh
#
# 自动完成:
#   1. 安装 Homebrew（如未安装）
#   2. 安装 BlackHole 2ch、ffmpeg、SwitchAudioSource
#   3. 编译 audio-multi-output 和 audio-monitor
#   4. 配置 Zoom 扬声器为 Same as System
#   5. 引导配置 Teams / 腾讯会议（需少量手动操作）
#
# 系统要求: macOS 13+ (Ventura)，需要管理员权限

set -e

# ============================================================
# 颜色输出
# ============================================================
green()  { printf "\033[32m%s\033[0m\n" "$1"; }
red()    { printf "\033[31m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }
blue()   { printf "\033[34m%s\033[0m\n" "$1"; }

INSTALL_DIR="$HOME/bin"
RECORDING_DIR="$HOME/Record"
DOC_DIR="$RECORDING_DIR/doc"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

STEP=0
total_steps() { STEP=$((STEP + 1)); blue "【$STEP/$TOTAL_STEPS】$1"; }
TOTAL_STEPS=7

echo ""
echo "============================================"
echo " 会议录制工具 - 一键安装"
echo "============================================"
echo ""

# ============================================================
# 1. 检查系统环境
# ============================================================
total_steps "检查系统环境"

# macOS 版本
SW_VER=$(sw_vers -productVersion)
MAJOR=$(echo "$SW_VER" | cut -d. -f1)
if [[ "$MAJOR" -lt 13 ]]; then
    red "❌ 需要 macOS 13 (Ventura) 或更高版本，当前: $SW_VER"
    exit 1
fi
green "  ✅ macOS $SW_VER"

# Xcode Command Line Tools（编译 Swift 需要）
if ! xcode-select -p &>/dev/null; then
    yellow "  ⏳ 安装 Xcode Command Line Tools（可能需要几分钟）..."
    xcode-select --install 2>/dev/null || true
    echo "  请在弹出的窗口中点击「安装」，安装完成后重新运行此脚本。"
    exit 1
fi
green "  ✅ Xcode Command Line Tools"

# Swift
if ! command -v swiftc &>/dev/null; then
    red "❌ 未找到 swiftc 编译器，请安装 Xcode Command Line Tools"
    exit 1
fi
SWIFT_VER=$(swiftc --version 2>&1 | head -1)
green "  ✅ $SWIFT_VER"

echo ""

# ============================================================
# 2. 安装 Homebrew 和依赖
# ============================================================
total_steps "安装依赖"

# Homebrew
if ! command -v brew &>/dev/null; then
    yellow "  ⏳ 安装 Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Apple Silicon 需要手动添加到 PATH
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # 写入 shell 配置
        SHELL_RC="$HOME/.zshrc"
        if ! grep -q 'homebrew' "$SHELL_RC" 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_RC"
        fi
    fi
fi
green "  ✅ Homebrew"

# BlackHole 2ch
if brew list blackhole-2ch &>/dev/null; then
    green "  ✅ BlackHole 2ch 已安装"
else
    yellow "  ⏳ 安装 BlackHole 2ch..."
    brew install blackhole-2ch
    green "  ✅ BlackHole 2ch 安装完成"
fi

# ffmpeg
if command -v ffmpeg &>/dev/null; then
    green "  ✅ ffmpeg 已安装"
else
    yellow "  ⏳ 安装 ffmpeg（可能需要几分钟）..."
    brew install ffmpeg
    green "  ✅ ffmpeg 安装完成"
fi

# SwitchAudioSource
if command -v SwitchAudioSource &>/dev/null; then
    green "  ✅ SwitchAudioSource 已安装"
else
    yellow "  ⏳ 安装 SwitchAudioSource..."
    brew install switchaudio-osx
    green "  ✅ SwitchAudioSource 安装完成"
fi

echo ""

# ============================================================
# 3. 创建目录
# ============================================================
total_steps "创建目录"

mkdir -p "$INSTALL_DIR" "$RECORDING_DIR" "$DOC_DIR"
green "  ✅ $INSTALL_DIR"
green "  ✅ $RECORDING_DIR"

echo ""

# ============================================================
# 4. 安装工具文件
# ============================================================
total_steps "安装工具"

# 判断源文件位置（支持从 doc 目录或项目根目录运行）
find_source() {
    local name="$1"
    # 优先从 install.sh 同级的 src/ 目录找
    if [[ -f "$SCRIPT_DIR/src/$name" ]]; then
        echo "$SCRIPT_DIR/src/$name"
    # 然后从 ~/bin 找（已安装的情况）
    elif [[ -f "$HOME/bin/$name" ]]; then
        echo "$HOME/bin/$name"
    # 从 SCRIPT_DIR 的上两级（假设在 Record/doc/ 下）
    elif [[ -f "$SCRIPT_DIR/../../bin/$name" ]]; then
        echo "$SCRIPT_DIR/../../bin/$name"
    else
        echo ""
    fi
}

# 复制并编译 Swift 工具
for tool in audio-multi-output audio-monitor; do
    SRC=$(find_source "${tool}.swift")
    if [[ -z "$SRC" ]]; then
        red "  ❌ 未找到 ${tool}.swift 源文件"
        echo "    请将 ${tool}.swift 放到以下任一位置:"
        echo "      $SCRIPT_DIR/src/${tool}.swift"
        echo "      $HOME/bin/${tool}.swift"
        exit 1
    fi

    # 复制源文件
    cp "$SRC" "$INSTALL_DIR/${tool}.swift"

    # 编译
    yellow "  ⏳ 编译 ${tool}..."
    swiftc -O -framework CoreAudio -framework AudioToolbox \
        "$INSTALL_DIR/${tool}.swift" -o "$INSTALL_DIR/${tool}" 2>/dev/null
    chmod +x "$INSTALL_DIR/${tool}"
    green "  ✅ ${tool} 编译完成"
done

# 复制主脚本
for script in meeting-record.sh meeting-record-test.sh; do
    SRC=$(find_source "$script")
    if [[ -z "$SRC" ]]; then
        red "  ❌ 未找到 $script"
        exit 1
    fi
    cp "$SRC" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
    green "  ✅ $script"
done

echo ""

# ============================================================
# 5. 配置 PATH
# ============================================================
total_steps "配置环境变量"

SHELL_RC="$HOME/.zshrc"
if echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    green "  ✅ $INSTALL_DIR 已在 PATH 中"
else
    if grep -q "export PATH=.*\$HOME/bin" "$SHELL_RC" 2>/dev/null; then
        green "  ✅ PATH 配置已存在于 $SHELL_RC"
    else
        echo "" >> "$SHELL_RC"
        echo "# 会议录制工具" >> "$SHELL_RC"
        echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
        green "  ✅ 已添加 $INSTALL_DIR 到 PATH（重开终端生效）"
    fi
fi

echo ""

# ============================================================
# 6. 验证安装
# ============================================================
total_steps "验证安装"

PASS=0
FAIL=0

check() {
    if [[ $1 -eq 0 ]]; then
        green "  ✅ $2"
        ((PASS++))
    else
        red "  ❌ $2"
        ((FAIL++))
    fi
}

[[ -x "$INSTALL_DIR/audio-multi-output" ]];  check $? "audio-multi-output 可执行"
[[ -x "$INSTALL_DIR/audio-monitor" ]];       check $? "audio-monitor 可执行"
[[ -x "$INSTALL_DIR/meeting-record.sh" ]];   check $? "meeting-record.sh 可执行"
command -v ffmpeg &>/dev/null;               check $? "ffmpeg 可用"
command -v SwitchAudioSource &>/dev/null;    check $? "SwitchAudioSource 可用"

# 检查 BlackHole
"$INSTALL_DIR/audio-multi-output" blackhole-uid &>/dev/null; check $? "BlackHole 2ch 已识别"

echo ""

# ============================================================
# 7. 配置会议 App
# ============================================================
total_steps "配置会议 App 扬声器"

echo ""

# --- Zoom ---
VIPER_INI="$HOME/Library/Application Support/zoom.us/data/viper.ini"
SYSTEM_HEX="53616d652061732053797374656d"  # "Same as System"

if [[ -f "$VIPER_INI" ]]; then
    CURRENT_SPK=$(grep "^AECSPK=" "$VIPER_INI" | cut -d= -f2)
    if [[ "$CURRENT_SPK" == "$SYSTEM_HEX" ]]; then
        green "  ✅ Zoom: 扬声器已是 Same as System"
    else
        # 检查 Zoom 是否在运行
        if pgrep -x "zoom.us" >/dev/null; then
            yellow "  ⚠️  Zoom 正在运行，需要退出后修改配置"
            echo "    正在退出 Zoom..."
            osascript -e 'tell application "zoom.us" to quit' 2>/dev/null
            for i in {1..10}; do
                pgrep -x "zoom.us" >/dev/null || break
                sleep 1
            done
            REOPEN_ZOOM=1
        fi

        if ! pgrep -x "zoom.us" >/dev/null; then
            sed -i '' "s/^AECSPK=.*/AECSPK=$SYSTEM_HEX/" "$VIPER_INI"
            if grep -q "^AECBSSPK=" "$VIPER_INI"; then
                sed -i '' "s/^AECBSSPK=.*/AECBSSPK=$SYSTEM_HEX/" "$VIPER_INI"
            fi
            green "  ✅ Zoom: 扬声器已设为 Same as System"

            if [[ "${REOPEN_ZOOM:-0}" == "1" ]]; then
                open -a "zoom.us" 2>/dev/null
                echo "    已重新打开 Zoom"
            fi
        else
            yellow "  ⚠️  Zoom 无法退出，请手动关闭后运行: meeting-record.sh setup-zoom"
        fi
    fi
else
    yellow "  ⏭️  Zoom: 未安装或未运行过，跳过（安装后运行 meeting-record.sh setup-zoom）"
fi

# --- Teams ---
if ls /Applications/Microsoft\ Teams* &>/dev/null; then
    echo ""
    yellow "  📋 Teams 需要手动配置扬声器（只需一次）:"
    echo "    1. 打开 Teams → 设置 → Devices"
    echo "    2. Speaker → 选择「BlackHole 2ch」"
    echo ""

    read -p "    现在配置 Teams？(y/N) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if ! pgrep -f "Microsoft Teams" >/dev/null; then
            open -a "Microsoft Teams"
            sleep 3
        fi
        open "msteams://settings/devices" 2>/dev/null
        echo ""
        echo "    请在 Teams 设置中选择 Speaker → BlackHole 2ch"
        read -p "    设置完成后按 Enter 继续..."
        green "  ✅ Teams 配置完成"
    else
        yellow "  ⏭️  跳过，稍后运行: meeting-record.sh setup-teams"
    fi
else
    yellow "  ⏭️  Teams: 未安装，跳过"
fi

# --- 腾讯会议 ---
if [[ -d "/Applications/TencentMeeting.app" ]]; then
    echo ""
    yellow "  📋 腾讯会议需要手动配置扬声器（只需一次）:"
    echo "    1. 打开腾讯会议 → 头像 → 设置 → 音频"
    echo "    2. 扬声器 → 选择「BlackHole 2ch」"
    echo ""

    read -p "    现在配置腾讯会议？(y/N) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if ! pgrep -f "TencentMeeting" >/dev/null; then
            open -a "TencentMeeting"
            sleep 3
        fi
        echo ""
        echo "    请在腾讯会议中选择 扬声器 → BlackHole 2ch"
        read -p "    设置完成后按 Enter 继续..."
        green "  ✅ 腾讯会议配置完成"
    else
        yellow "  ⏭️  跳过，稍后运行: meeting-record.sh setup-wemeet"
    fi
else
    yellow "  ⏭️  腾讯会议: 未安装，跳过"
fi

# --- 飞书 ---
if ls /Applications/Lark* &>/dev/null || ls /Applications/飞书* &>/dev/null || ls /Applications/Feishu* &>/dev/null; then
    green "  ✅ 飞书: 默认跟随系统，无需配置"
else
    yellow "  ⏭️  飞书: 未安装，跳过"
fi

echo ""

# ============================================================
# 安装完成
# ============================================================
echo "============================================"
if [[ $FAIL -eq 0 ]]; then
    green " 安装完成！验证: $PASS/$PASS 全部通过"
else
    yellow " 安装完成（$FAIL 项需要注意）"
fi
echo "============================================"
echo ""
echo " 使用方式:"
echo "   meeting-record.sh start    开始录制"
echo "   meeting-record.sh stop     停止录制"
echo "   meeting-record.sh status   查看状态"
echo ""
echo " 录音文件: $RECORDING_DIR/"
echo ""
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    yellow " ⚠️  请重新打开终端或执行: source ~/.zshrc"
fi
echo ""
