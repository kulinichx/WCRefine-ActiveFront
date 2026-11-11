#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/build/ui"
APP="$OUT/SwipeTests.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
xcrun --sdk iphonesimulator clang -target "$ARCH-apple-ios15.0-simulator" -isysroot "$SDK" \
    -fobjc-arc -fblocks -O1 -Wall -Wextra -Werror=objc-method-access -Werror=return-type \
    -framework UIKit -framework Foundation -framework QuartzCore \
    "$ROOT/WCRAFGroupSwipe.m" "$ROOT/tests/GroupSwipeUITests.m" -o "$APP/SwipeTests"
cp "$ROOT/tests/SwipeTests-Info.plist" "$APP/Info.plist"
codesign --force --sign - "$APP"
python3 "$ROOT/tests/run_ui_tests.py" "$OUT"
