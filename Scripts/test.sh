#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc "$frameworks" -Xlinker "-F$frameworks"
else
    swift test
fi
