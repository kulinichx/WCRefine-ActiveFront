#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'iOS build requires macOS, full Xcode, and an installed iPhoneOS SDK.' >&2
    exit 2
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="$ROOT/build"
mkdir -p "$OUT"
# Stage every attempt separately. A failed build cannot truncate a previous result.
STAGE="$(mktemp -d "$OUT/.attempt.XXXXXX")"
bash "$ROOT/test_core.sh" "$STAGE/tests"
TARGET="$STAGE/WCRefineGroup.dylib"
xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK" \
    -fobjc-arc -fobjc-arc-exceptions -fblocks -O2 -fvisibility=hidden -Wall -Wextra \
    -Werror=implicit-function-declaration -Werror=objc-method-access -Werror=return-type \
    -DWCRAF_DIAGNOSTICS=0 -DWCRAF_VERBOSE_CELL_LOGS=0 \
    -dynamiclib -framework Foundation -framework UIKit -lobjc \
    -Wl,-install_name,@rpath/WCRefineGroup.dylib \
    -Wl,-current_version,1.9.9 -Wl,-compatibility_version,1.0 -Wl,-dead_strip \
    "$ROOT/ActiveFront.m" "$ROOT/WCRAFStateStore.m" -o "$TARGET"
codesign --force --sign - "$TARGET"
codesign --verify --strict --verbose=2 "$TARGET"
xcrun otool -hv "$TARGET"
xcrun otool -L "$TARGET"
SYMBOLS="$(xcrun nm -u "$TARGET")"
if /usr/bin/grep -E 'OBJC_(CLASS|METACLASS)_\$_(WCRefine|NewMainFrame|WCRGrouping)' <<< "$SYMBOLS"; then
    printf '%s\n' 'Unexpected hard dependency on private host classes.' >&2
    exit 1
fi
python3 "$ROOT/verify_build.py" validate --binary "$TARGET" \
    --tests "$STAGE/tests/native-tests.json" --inputs "$STAGE/tests/test-inputs.json" \
    --output "$STAGE/build_manifest.json"
FINAL="$OUT/WCRefineGroup.dylib"
cp "$STAGE/build_manifest.json" "$OUT/build_manifest.json"
cp "$STAGE/tests/native-tests.json" "$OUT/native-tests.json"
cp "$STAGE/tests/native-tests.log" "$OUT/native-tests.log"
cp "$STAGE/tests/test-inputs.json" "$OUT/test-inputs.json"
mv -f "$TARGET" "$FINAL"
(cd "$OUT" && /usr/bin/shasum -a 256 WCRefineGroup.dylib) | tee "$OUT/WCRefineGroup.dylib.sha256"
printf '%s\n' \
    "Built: $FINAL" \
    'This is ad-hoc signed only. Device trust/injection compatibility is NOT verified.' \
    'The workspace root hotfix is unchanged. Do not load both Group dylibs together.'
