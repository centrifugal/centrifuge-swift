#!/usr/bin/env bash
#
# Run the test suite, with or without Xcode installed.
#
#   ./scripts/test.sh                 # everything available in this environment
#   ./scripts/test.sh --filter Filter # extra args are forwarded to `swift test`
#
# XCTest ships only inside Xcode.app. With the Command Line Tools alone it does
# not exist, so the XCTest suites are compiled out (`#if canImport(XCTest)`) and
# only the swift-testing suites run. swift-testing itself does ship with the CLT,
# it just needs its framework search path wired up by hand.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || true)"
XCTEST_FW="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework"

if [ -d "$XCTEST_FW" ]; then
    echo "==> Xcode toolchain detected - running the full suite (XCTest + swift-testing)"
    exec xcrun swift test "$@"
fi

TESTING_FW="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
if [ ! -d "$TESTING_FW/Testing.framework" ]; then
    echo "error: neither XCTest nor swift-testing found under ${DEVELOPER_DIR_PATH:-<unset>}" >&2
    echo "       install Xcode, or refresh the Command Line Tools:" >&2
    echo "       sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install" >&2
    exit 1
fi

# Testing.framework is built for macOS 14.0. The package deliberately declares no
# `platforms:` (that would raise the deployment target for every consumer of the
# library), so raise it here, for this build only.
BUILD_TARGET="$(uname -m)-apple-macos14.0"

SKIPPED="$(grep -l 'canImport(XCTest)' Tests/SwiftCentrifugeTests/*.swift 2>/dev/null | wc -l | tr -d ' ')"
cat >&2 <<EOF

  +----------------------------------------------------------------------+
  |  Xcode not installed - PARTIAL TEST RUN                              |
  |                                                                      |
  |  XCTest is unavailable with the Command Line Tools, so ${SKIPPED} XCTest      |
  |  file(s) are compiled out; only swift-testing suites run below.      |
  |  Green here does NOT mean the whole suite is green - CI runs both.   |
  +----------------------------------------------------------------------+

EOF

# The CLT ships Testing.framework but not the _Testing_Foundation cross-import
# overlay's .swiftmodule, so `import Testing` next to `import Foundation` fails
# to resolve it. Turn overlays off - they only add Foundation conveniences we do
# not use.
exec swift test \
    --disable-xctest \
    --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$TESTING_FW" \
    -Xlinker -F -Xlinker "$TESTING_FW" \
    -Xlinker -rpath -Xlinker "$TESTING_FW" \
    -Xswiftc -target -Xswiftc "$BUILD_TARGET" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    "$@"
