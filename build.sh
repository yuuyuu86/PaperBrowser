#!/bin/sh
# Builds PaperBrowser.app (optimized for size) with App Sandbox + Hardened Runtime.
set -e
cd "$(dirname "$0")"
APP=build/PaperBrowser.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -Osize -wmo -target arm64-apple-macos14 Sources/main.swift -o "$APP/Contents/MacOS/PaperBrowser"
strip -x "$APP/Contents/MacOS/PaperBrowser"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign "${SIGN_ID:--}" --options runtime --entitlements Resources/PaperBrowser.entitlements "$APP"
du -sh "$APP"
