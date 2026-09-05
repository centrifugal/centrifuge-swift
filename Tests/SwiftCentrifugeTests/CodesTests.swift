import Testing
@testable import SwiftCentrifuge

/// Unit tests for `interpretCloseCode` — the mapping of WebSocket close codes to
/// Centrifuge disconnect codes and the reconnect decision. See
/// https://centrifugal.dev/docs/transports/client_api#disconnect-codes
@Suite struct CodesTests {

    @Test func transportCodesHiddenBehindTransportClosed() {
        // Codes below 3000 are transport-specific, the SDK does not expose them.
        for code: UInt32 in [1000, 1001, 1006, 1011, 2999] {
            let result = interpretCloseCode(code)
            #expect(result.code == connectingCodeTransportClosed, "code \(code)")
            #expect(result.reconnect, "code \(code) must reconnect")
        }
    }

    @Test func messageSizeLimitIsTerminal() {
        let result = interpretCloseCode(1009)
        #expect(result.code == disconnectCodeMessageSizeLimit)
        #expect(!result.reconnect, "message size limit must not reconnect")
    }

    @Test func applicationCodesKeptAsIs() {
        // 3000-3499: temporary problems on the server side, reconnect.
        for code: UInt32 in [3000, 3499] {
            let result = interpretCloseCode(code)
            #expect(result.code == code)
            #expect(result.reconnect, "code \(code) must reconnect")
        }
        // 3500-3999 and 4500-4999: terminal, no reconnect.
        for code: UInt32 in [3500, 3999, 4500, 4999] {
            let result = interpretCloseCode(code)
            #expect(result.code == code)
            #expect(!result.reconnect, "code \(code) must not reconnect")
        }
        // 4000-4499 (custom, reconnect) and >= 5000 (reserved, reconnect).
        for code: UInt32 in [4000, 4499, 5000] {
            let result = interpretCloseCode(code)
            #expect(result.code == code)
            #expect(result.reconnect, "code \(code) must reconnect")
        }
    }

    @Test func stateInvalidatedReconnects() {
        // 3014 arrives when the server invalidated the client state: the client
        // drops cached state (see StateInvalidationTests) and reconnects.
        let result = interpretCloseCode(disconnectedStateInvalidated)
        #expect(result.code == disconnectedStateInvalidated)
        #expect(result.reconnect)
    }
}
