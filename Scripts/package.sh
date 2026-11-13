#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 64 ;; esac
swift build -c "$configuration" --product WindowWorkbench
bin="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/dist/WindowWorkbench.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin/WindowWorkbench" "$app/Contents/MacOS/WindowWorkbench"
ditto "$bin/WindowWorkbench_WorkbenchApp.bundle" "$app/Contents/Resources/WindowWorkbench_WorkbenchApp.bundle"
cp Scripts/Info.plist "$app/Contents/Info.plist"
if [[ -f Scripts/Workbench.icns ]]; then cp Scripts/Workbench.icns "$app/Contents/Resources/Workbench.icns"; fi
codesign --force --sign - --identifier local.windowworkbench.app "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
