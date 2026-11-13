#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift-format lint --strict --recursive Package.swift Sources Tests Scripts/make-icon.swift
plutil -lint Scripts/Info.plist
for strings in Sources/WorkbenchApp/Resources/*.lproj/*.strings; do plutil -lint "$strings"; done
