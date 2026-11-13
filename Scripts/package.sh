#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) exit 64 ;; esac
build=(swift build -c "$configuration")
bundle_id=local.windowworkbench.app
app="$PWD/dist/workstack.app"
if [[ "${2:-}" == --qa && $# == 3 ]]; then
    scratch="$(cd "$3" && pwd -P)"
    temp="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
    [[ "$(dirname "$scratch")" == "$temp" && "$(basename "$scratch")" == ww-integration.* ]]
    app="$scratch/Product.app"
    [[ ! -e "$app" && ! -L "$app" && ! -e "$scratch/build" && ! -L "$scratch/build" ]]
    bundle_id=local.windowworkbench.qa
    build+=(--scratch-path "$scratch/build")
elif [[ "${2:-}" == --output && $# == 3 ]]; then
    app="$3/workstack.app"
    if [[ -e "$app" || -L "$app" ]]; then
        echo "目标目录中已存在 workstack.app，请选择新目录。" >&2
        exit 1
    fi
elif [[ $# -gt 1 ]]; then
    exit 64
fi
if [[ "$bundle_id" == local.windowworkbench.qa ]]; then
    "${build[@]}"
else
    "${build[@]}" --product workstack
fi
bin="$("${build[@]}" --show-bin-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin/workstack" "$app/Contents/MacOS/workstack"
ditto "$bin/workstack_WorkbenchApp.bundle" "$app/Contents/Resources/workstack_WorkbenchApp.bundle"
cp Scripts/Info.plist "$app/Contents/Info.plist"
if [[ -f Scripts/Workbench.icns ]]; then cp Scripts/Workbench.icns "$app/Contents/Resources/Workbench.icns"; fi
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
codesign --force --sign - --identifier "$bundle_id" "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
