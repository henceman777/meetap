# MeeTap

macOS 会议录制 + 自动转录工具。通过 BlackHole 虚拟声卡无感录制 Zoom / Teams / 飞书 / 腾讯会议音频，录制结束后自动通过 AWS Transcribe 转录为文字。

## Quick Start

```bash
# 安装依赖
brew install blackhole-2ch ffmpeg switchaudio-osx awscli

# 编译 & 安装到 ~/bin
make install

# 配置会议 App（仅首次）
meetap setup

# 录制
meetap start    # 开会前
meetap stop     # 开完后（自动转录）
```

## How It Works

```
App audio → BlackHole 2ch (system output)
              ├── ffmpeg → meeting.m4a → AWS Transcribe → transcript.txt
              └── audio-monitor (AUHAL) → Speaker/Headphone (you hear it)
```

- 系统输出切到 BlackHole，ffmpeg 从中录制
- audio-monitor 通过底层 AUHAL AudioUnit 实时转发到扬声器/耳机
- 停止后自动上传到 S3，调用 AWS Transcribe 转录，生成带说话人标签的文本

## Files

```
bin/
├── meetap                     # 主控脚本
├── audio-multi-output.swift   # CoreAudio 设备管理
└── audio-monitor.swift        # AUHAL 音频实时转发

doc/
├── 用户指南.md                 # 使用说明
├── 开发说明.md                 # 技术细节
└── ...
```

## Requirements

- macOS 13+ (Ventura)
- BlackHole 2ch, ffmpeg, SwitchAudioSource
- AWS CLI (configured, for auto-transcription)
- Xcode Command Line Tools (for Swift compilation)

## Known Limitations

- AirPods 等蓝牙耳机不支持（24kHz vs 48kHz 采样率不兼容）
- 仅录制系统音频输出，不含麦克风输入
- 转录目前固定为 en-US

## License

MIT
