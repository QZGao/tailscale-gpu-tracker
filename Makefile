SHELL := /bin/bash
APP := build/Tailscale GPU Tracker.app

.PHONY: build test run package

build:
	swift build -c release
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp .build/release/TailscaleGPUTracker "$(APP)/Contents/MacOS/TailscaleGPUTracker"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"

test:
	swift test

run: build
	open "$(APP)"

package: build
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" build/Tailscale-GPU-Tracker.zip
