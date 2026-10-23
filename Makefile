SHELL := /bin/bash
APP := build/Tailscale GPU Tracker.app
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ARCH := $(shell uname -m)
ARCHIVE := build/Tailscale-GPU-Tracker-v$(VERSION)-macos-$(ARCH).zip

.PHONY: build test run package

build:
	swift build -c release
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp .build/release/TailscaleGPUTracker "$(APP)/Contents/MacOS/TailscaleGPUTracker"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp LICENSE "$(APP)/Contents/Resources/LICENSE"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	strip -S "$(APP)/Contents/MacOS/TailscaleGPUTracker"
	codesign --force --sign - "$(APP)"

test:
	swift test

run: build
	open "$(APP)"

package: build
	ditto -c -k --norsrc --keepParent "$(APP)" "$(ARCHIVE)"
	python3 scripts/verify_release.py --arch "$(ARCH)"
