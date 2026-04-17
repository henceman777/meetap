PREFIX ?= $(HOME)/bin

.PHONY: build install clean

build: bin/audio-multi-output bin/audio-monitor

bin/audio-multi-output: bin/audio-multi-output.swift
	swiftc -O -framework CoreAudio -framework AudioToolbox $< -o $@

bin/audio-monitor: bin/audio-monitor.swift
	swiftc -O -framework CoreAudio -framework AudioToolbox $< -o $@

install: build
	mkdir -p $(PREFIX)
	cp bin/meetap $(PREFIX)/meetap
	cp bin/audio-multi-output $(PREFIX)/audio-multi-output
	cp bin/audio-monitor $(PREFIX)/audio-monitor
	chmod +x $(PREFIX)/meetap

clean:
	rm -f bin/audio-multi-output bin/audio-monitor
