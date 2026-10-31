#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
    printf '%s\n' 'Native tests require macOS with Apple Foundation and Xcode command-line tools.' >&2
    exit 2
fi
OUT="${1:-$ROOT/build/tests}"
mkdir -p "$OUT"
python3 "$ROOT/verify_build.py" snapshot "$OUT/test-inputs.json"
xcrun --sdk macosx clang -fobjc-arc -fobjc-arc-exceptions -fblocks -Wall -Wextra \
    -Werror=implicit-function-declaration -Werror=objc-method-access -Werror=return-type \
    -framework Foundation "$ROOT/WCRAFStateStore.m" "$ROOT/tests/StateStoreTests.m" \
    -o "$OUT/StateStoreTests"
"$OUT/StateStoreTests" "$OUT/native-tests.json" 2>&1 | tee "$OUT/native-tests.log"
