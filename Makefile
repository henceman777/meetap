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
	@if [ ! -d "$(PREFIX)/meetap-venv" ]; then \
		echo "Creating Python venv for boto3..."; \
		python3 -m venv $(PREFIX)/meetap-venv; \
		$(PREFIX)/meetap-venv/bin/pip install -q boto3; \
	fi

clean:
	rm -rf $(BUILD)
