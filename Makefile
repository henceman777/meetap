PREFIX ?= $(HOME)/bin
BUILD  ?= build
# 源码在 git 仓库里时，install 把「分支@提交号」写进 meetap --version（有未提交改动加 -dirty）
GIT_SHA   := $(shell git rev-parse --short HEAD 2>/dev/null)
GIT_DIRTY := $(shell git diff --quiet HEAD -- 2>/dev/null || echo -dirty)
BUILD_ID  := $(if $(GIT_SHA),$(shell git rev-parse --abbrev-ref HEAD)@$(GIT_SHA)$(GIT_DIRTY))

.PHONY: all install clean

all: $(BUILD)/audio-multi-output $(BUILD)/audio-monitor $(BUILD)/audio-tap

$(BUILD)/audio-multi-output: src/audio-multi-output.swift
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox -framework IOKit $< -o $@

$(BUILD)/audio-monitor: src/audio-monitor.swift
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox $< -o $@

# audio-tap 必须嵌入 Info.plist（NSAudioCaptureUsageDescription），
# 否则 TCC 不弹授权框、静默拒绝，Process Tap 输出全零静音。
$(BUILD)/audio-tap: src/audio-tap.swift src/audio-tap-Info.plist
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
		-Xlinker src/audio-tap-Info.plist \
		$< -o $@
	codesign --force --sign - $@

install: all
	mkdir -p $(PREFIX)
	cp src/meetap $(PREFIX)/meetap
	sed -i '' 's|^BUILD_ID=""|BUILD_ID="$(BUILD_ID)"|' $(PREFIX)/meetap
	cp $(BUILD)/audio-multi-output $(PREFIX)/audio-multi-output
	cp $(BUILD)/audio-monitor $(PREFIX)/audio-monitor
	cp $(BUILD)/audio-tap $(PREFIX)/audio-tap
	# cp 会破坏 ad-hoc 签名（带 __info_plist 段尤甚），TCC 判定签名无效后
	# 内核会在创建 Process Tap 时 SIGKILL 进程（tap-format/tap-start 表现为
	# exit 137）。install 后必须重新签名，否则安装版录音全静音/被杀。
	codesign --force --sign - $(PREFIX)/audio-tap
	chmod +x $(PREFIX)/meetap
	mkdir -p $(PREFIX)/i18n
	cp src/i18n/*.sh $(PREFIX)/i18n/
	mkdir -p $(PREFIX)/lib
	cp src/lib/ui.sh $(PREFIX)/lib/
	mkdir -p $(PREFIX)/share/meetap
	cp config.default $(PREFIX)/share/meetap/config.default
	mkdir -p $(PREFIX)/share/meetap/prompts
	cp share/meetap/prompts/*.md $(PREFIX)/share/meetap/prompts/
	mkdir -p $(PREFIX)/share/meetap/templates
	cp share/meetap/templates/*.html $(PREFIX)/share/meetap/templates/
	@if [ ! -d "$(PREFIX)/meetap-venv" ]; then \
		echo "Creating Python venv for boto3..."; \
		python3 -m venv $(PREFIX)/meetap-venv; \
	fi
	@$(PREFIX)/meetap-venv/bin/pip install -q boto3==1.40.0 markdown
	@echo ""
	@echo "Installed. A default config will be created in ~/.config/meetap/"
	@echo "on first run. Use 'meetap config' to edit it."

clean:
	rm -rf $(BUILD)
