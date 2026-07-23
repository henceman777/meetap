PREFIX ?= $(HOME)/bin
BUILD  ?= build

.PHONY: all install clean

all: $(BUILD)/audio-multi-output $(BUILD)/audio-monitor $(BUILD)/audio-tap

$(BUILD)/audio-multi-output: src/audio-multi-output.swift
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox $< -o $@

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
	cp $(BUILD)/audio-multi-output $(PREFIX)/audio-multi-output
	cp $(BUILD)/audio-monitor $(PREFIX)/audio-monitor
	cp $(BUILD)/audio-tap $(PREFIX)/audio-tap
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
