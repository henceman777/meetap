PREFIX ?= $(HOME)/bin
BUILD  ?= build

.PHONY: all install clean

all: $(BUILD)/audio-multi-output $(BUILD)/audio-monitor

$(BUILD)/audio-multi-output: src/audio-multi-output.swift
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox $< -o $@

$(BUILD)/audio-monitor: src/audio-monitor.swift
	mkdir -p $(BUILD)
	swiftc -O -framework CoreAudio -framework AudioToolbox $< -o $@

install: all
	mkdir -p $(PREFIX)
	cp src/meetap $(PREFIX)/meetap
	cp $(BUILD)/audio-multi-output $(PREFIX)/audio-multi-output
	cp $(BUILD)/audio-monitor $(PREFIX)/audio-monitor
	chmod +x $(PREFIX)/meetap
	mkdir -p $(PREFIX)/i18n
	cp src/i18n/*.sh $(PREFIX)/i18n/
	mkdir -p $(PREFIX)/share/meetap
	cp config.default $(PREFIX)/share/meetap/config.default
	@if [ ! -d "$(PREFIX)/meetap-venv" ]; then \
		echo "Creating Python venv for boto3..."; \
		python3 -m venv $(PREFIX)/meetap-venv; \
		$(PREFIX)/meetap-venv/bin/pip install -q boto3; \
	fi
	@echo ""
	@echo "Installed. A default config will be created in ~/.config/meetap/"
	@echo "on first run. Use 'meetap config' to edit it."

clean:
	rm -rf $(BUILD)
