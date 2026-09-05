// XCTest ships only inside Xcode.app. Guard the file so the test target still
// compiles with just the Command Line Tools, where the swift-testing suites in
// this target can still run (see CLAUDE.md, "Running tests locally").
// Removed once this suite is migrated to swift-testing.
#if canImport(XCTest)
import XCTest
@testable import SwiftCentrifuge

/// Unit tests for `interpretCloseCode` — the mapping of WebSocket close codes to
/// Centrifuge disconnect codes and the reconnect decision. See
/// https://centrifugal.dev/docs/transports/client_api#disconnect-codes
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter CodesTests
final class CodesTests: XCTestCase {

    func testTransportCodesHiddenBehindTransportClosed() {
        // Codes below 3000 are transport-specific, the SDK does not expose them.
        for code: UInt32 in [1000, 1001, 1006, 1011, 2999] {
            let result = interpretCloseCode(code)
            XCTAssertEqual(result.code, connectingCodeTransportClosed, "code \(code)")
            XCTAssertTrue(result.reconnect, "code \(code) must reconnect")
        }
    }

    func testMessageSizeLimitIsTerminal() {
        let result = interpretCloseCode(1009)
        XCTAssertEqual(result.code, disconnectCodeMessageSizeLimit)
        XCTAssertFalse(result.reconnect, "message size limit must not reconnect")
    }

    func testApplicationCodesKeptAsIs() {
        // 3000-3499: temporary problems on the server side, reconnect.
        for code: UInt32 in [3000, 3499] {
            let result = interpretCloseCode(code)
            XCTAssertEqual(result.code, code)
            XCTAssertTrue(result.reconnect, "code \(code) must reconnect")
        }
        // 3500-3999 and 4500-4999: terminal, no reconnect.
        for code: UInt32 in [3500, 3999, 4500, 4999] {
            let result = interpretCloseCode(code)
            XCTAssertEqual(result.code, code)
            XCTAssertFalse(result.reconnect, "code \(code) must not reconnect")
        }
        // 4000-4499 (custom, reconnect) and >= 5000 (reserved, reconnect).
        for code: UInt32 in [4000, 4499, 5000] {
            let result = interpretCloseCode(code)
            XCTAssertEqual(result.code, code)
            XCTAssertTrue(result.reconnect, "code \(code) must reconnect")
        }
    }

    func testStateInvalidatedReconnects() {
        // 3014 arrives when the server invalidated the client state: the client
        // drops cached state (see StateInvalidationTests) and reconnects.
        let result = interpretCloseCode(disconnectedStateInvalidated)
        XCTAssertEqual(result.code, disconnectedStateInvalidated)
        XCTAssertTrue(result.reconnect)
    }
}
#endif // canImport(XCTest)
