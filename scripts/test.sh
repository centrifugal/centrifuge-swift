#!/usr/bin/env bash
#
# Run the test suite, with or without Xcode installed.
#
#   ./scripts/test.sh                 # whole suite
#   ./scripts/test.sh --filter Filter # extra args are forwarded to `swift test`
#
# The suite uses swift-testing, which ships with the Command Line Tools, so it
# runs without Xcode — it just needs its framework search paths wired up by hand.
# With Xcode present, `swift test` already knows where to look and only the
# deployment target below has to be set.
#
# Note that GetStateTests needs the docker-compose Centrifugo running:
#   docker compose up -d
set -euo pipefail

cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
TESTING_FW="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"

# The tests are async, and Swift concurrency needs macOS 10.15+ while the package
# deliberately declares no `platforms:` (its default is 10.13, and raising it
# would raise the deployment target for every consumer). swift-testing rejects
# `@available` on `@Test`, so the requirement cannot be expressed in the tests
# either - raise the target for the test build only. The library is still
# type-checked at the package default by the separate `swift build` in CI.
BUILD_TARGET="$(uname -m)-apple-macos14.0"

if [ -d "$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform" ]; then
    echo "==> Xcode toolchain detected"
    exec xcrun swift test -Xswiftc -target -Xswiftc "$BUILD_TARGET" "$@"
fi

if [ ! -d "$TESTING_FW/Testing.framework" ]; then
    echo "error: swift-testing not found under ${DEVELOPER_DIR_PATH:-<unset>}" >&2
    echo "       install Xcode, or refresh the Command Line Tools:" >&2
    echo "       sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install" >&2
    exit 1
fi

echo "==> Command Line Tools only - wiring up swift-testing by hand"

# --disable-xctest: nothing imports XCTest any more, and SwiftPM would otherwise
#   look for a framework that only exists inside Xcode.app.
# -disable-cross-import-overlays: the CLT ships _Testing_Foundation.framework
#   without its .swiftmodule, so `import Testing` beside `import Foundation`
#   cannot resolve the overlay. Turning overlays off sidesteps that packaging
#   gap; they only add Foundation conveniences the suite does not use.
exec swift test \
    --disable-xctest \
    --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$TESTING_FW" \
    -Xlinker -F -Xlinker "$TESTING_FW" \
    -Xlinker -rpath -Xlinker "$TESTING_FW" \
    -Xswiftc -target -Xswiftc "$BUILD_TARGET" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    "$@"
