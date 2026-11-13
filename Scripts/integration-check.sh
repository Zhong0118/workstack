#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 64 ;; esac
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ww-integration.XXXXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/state"
Scripts/package.sh "$configuration" --qa "$scratch"
bin="$(swift build -c "$configuration" --scratch-path "$scratch/build" --show-bin-path)"
for name in Fixture Peer; do
    app="$scratch/$name.app"
    mkdir -p "$app/Contents/MacOS"
    install -m 755 "$bin/window-probe" "$app/Contents/MacOS/window-probe"
    cp Scripts/Info.plist "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set CFBundleExecutable window-probe' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier local.windowworkbench.qa.$name" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleName workstack-$name" "$app/Contents/Info.plist"
    codesign --force --sign - "$app"
done
export WW_TEST_DIRECTORY="$scratch/state"
export WW_INTEGRATION_CHECK="$scratch/Fixture.app/Contents/MacOS/window-probe"
"$scratch/Product.app/Contents/MacOS/workstack" --integration-check
"$bin/window-probe" --recovery-smoke "$scratch/Fixture.app"
