#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 64 ;; esac
Scripts/package.sh "$configuration"
swift build -c "$configuration" --product window-probe
bin="$(swift build -c "$configuration" --show-bin-path)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ww-integration.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/state" "$scratch/Fixture.app/Contents/MacOS"
cp "$bin/window-probe" "$scratch/Fixture.app/Contents/MacOS/window-probe"
cat > "$scratch/Fixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>window-probe</string>
<key>CFBundleIdentifier</key><string>local.windowworkbench.integration-fixture</string>
<key>CFBundleName</key><string>workstack 测试应用</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cp -R "$scratch/Fixture.app" "$scratch/Peer.app"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier local.windowworkbench.integration-peer' "$scratch/Peer.app/Contents/Info.plist"
codesign --force --sign - "$scratch/Fixture.app"
codesign --force --sign - "$scratch/Peer.app"
export WW_TEST_DIRECTORY="$scratch/state"
export WW_INTEGRATION_CHECK="$scratch/Fixture.app/Contents/MacOS/window-probe"
dist/workstack.app/Contents/MacOS/workstack
"$bin/window-probe" --recovery-smoke "$scratch/Fixture.app"
