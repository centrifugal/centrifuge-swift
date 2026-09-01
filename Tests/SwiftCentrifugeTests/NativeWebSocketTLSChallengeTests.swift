import XCTest
@testable import SwiftCentrifuge

/// Unit tests for the native WebSocket transport's TLS/auth challenge handling
/// (`CentrifugeClientConfig.tlsChallengeHandler` and `tlsSkipVerify`, see issue #136).
///
/// These exercise `NativeWebSocket`'s delegate method directly with a synthetic
/// challenge, so they're fast and deterministic. `URLProtectionSpace` has no public
/// initializer that attaches a real `SecTrust`, so the synthetic challenge here always
/// has `serverTrust == nil` — good enough to test the handler/precedence/scoping logic,
/// but not the "does `tlsSkipVerify` actually trust a real certificate" happy path. That,
/// and the equivalent for `tlsChallengeHandler`, were verified manually end-to-end against
/// a real self-signed-cert local WSS server (rejected with neither set, accepted with either).
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter NativeWebSocketTLSChallengeTests
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class NativeWebSocketTLSChallengeTests: XCTestCase {

    private final class DummySender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func makeChallenge(authMethod: String = NSURLAuthenticationMethodServerTrust) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: "example.com", port: 443, protocol: "https",
            realm: nil, authenticationMethod: authMethod
        )
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: DummySender()
        )
    }

    private func makeSocket(tlsSkipVerify: Bool = false, tlsChallengeHandler: CentrifugeTLSChallengeHandler?) -> (NativeWebSocket, DispatchQueue) {
        let queue = DispatchQueue(label: "test")
        let ws = NativeWebSocket(
            request: URLRequest(url: URL(string: "wss://example.com/connection/websocket")!),
            urlSessionConfigurationProvider: nil,
            tlsSkipVerify: tlsSkipVerify,
            tlsChallengeHandler: tlsChallengeHandler,
            queue: queue,
            log: EmptyLogger.instance
        )
        return (ws, queue)
    }

    func testDefaultHandlingWhenNeitherOptionConfigured() {
        let (ws, queue) = makeSocket(tlsChallengeHandler: nil)
        let completed = expectation(description: "completion called")

        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: makeChallenge()) { disposition, credential in
                XCTAssertEqual(disposition, .performDefaultHandling)
                XCTAssertNil(credential)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
    }

    func testConfiguredHandlerIsInvokedAndItsDecisionIsForwarded() {
        let challenge = makeChallenge()
        let credential = URLCredential(user: "u", password: "p", persistence: .none)
        var receivedChallenge: URLAuthenticationChallenge?

        let (ws, queue) = makeSocket(tlsChallengeHandler: { ch, completion in
            receivedChallenge = ch
            completion(.useCredential, credential)
        })

        let completed = expectation(description: "completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { disposition, receivedCredential in
                XCTAssertEqual(disposition, .useCredential)
                XCTAssertEqual(receivedCredential, credential)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
        XCTAssertTrue(receivedChallenge === challenge)
    }

    func testHandlerTakesPrecedenceOverTlsSkipVerify() {
        // tlsSkipVerify is true, but a handler is also configured; the handler's
        // decision must win, not tlsSkipVerify's trust-everything fallback.
        let (ws, queue) = makeSocket(tlsSkipVerify: true, tlsChallengeHandler: { _, completion in
            completion(.cancelAuthenticationChallenge, nil)
        })

        let completed = expectation(description: "completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: makeChallenge()) { disposition, credential in
                XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
                XCTAssertNil(credential)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
    }

    func testTlsSkipVerifyFallsBackToDefaultHandlingWithoutServerTrust() {
        // No handler, tlsSkipVerify is true, but the challenge carries no serverTrust
        // (as is always the case for a synthetic challenge) — must not crash or
        // force-unwrap, just fall back to default handling.
        let (ws, queue) = makeSocket(tlsSkipVerify: true, tlsChallengeHandler: nil)
        let completed = expectation(description: "completion called")

        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: makeChallenge()) { disposition, credential in
                XCTAssertEqual(disposition, .performDefaultHandling)
                XCTAssertNil(credential)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
    }

    func testNTLMChallengeIsNeverForwardedToHandlerOrSkipVerify() {
        // NTLM is, per Apple's routing rules, a session-level challenge that WOULD reach
        // this exact delegate method (same as server-trust) if not explicitly excluded —
        // e.g. for an authenticating proxy. It must always get default handling and must
        // never reach tlsChallengeHandler or be affected by tlsSkipVerify, both of which
        // only apply to TLS-handshake-level challenges (server-trust, client-certificate).
        var handlerCalled = false
        let (ws, queue) = makeSocket(tlsSkipVerify: true, tlsChallengeHandler: { _, completion in
            handlerCalled = true
            completion(.useCredential, nil)
        })

        let challenge = makeChallenge(authMethod: NSURLAuthenticationMethodNTLM)
        let completed = expectation(description: "completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
                XCTAssertEqual(disposition, .performDefaultHandling)
                XCTAssertNil(credential)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
        XCTAssertFalse(handlerCalled)
    }

    func testHTTPBasicChallengeIsNeverForwardedToHandlerOrSkipVerify() {
        // HTTP Basic is task-level only per Apple's routing rules, so it would never
        // actually reach this session-level delegate method in production — but the
        // guard covers it defensively too, in case that routing behavior ever changes.
        var handlerCalled = false
        let (ws, queue) = makeSocket(tlsSkipVerify: true, tlsChallengeHandler: { _, completion in
            handlerCalled = true
            completion(.useCredential, nil)
        })

        let challenge = makeChallenge(authMethod: NSURLAuthenticationMethodHTTPBasic)
        let completed = expectation(description: "completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
                XCTAssertEqual(disposition, .performDefaultHandling)
                XCTAssertNil(credential)
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
        XCTAssertFalse(handlerCalled)
    }

    func testClientCertificateChallengeIsForwardedToHandler() {
        // mTLS: a client-certificate challenge is also a TLS-handshake-level challenge,
        // and must reach tlsChallengeHandler just like server-trust does.
        var receivedAuthMethod: String?
        let (ws, queue) = makeSocket(tlsChallengeHandler: { ch, completion in
            receivedAuthMethod = ch.protectionSpace.authenticationMethod
            completion(.performDefaultHandling, nil)
        })

        let challenge = makeChallenge(authMethod: NSURLAuthenticationMethodClientCertificate)
        let completed = expectation(description: "completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { _, _ in
                completed.fulfill()
            }
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(receivedAuthMethod, NSURLAuthenticationMethodClientCertificate)
    }
}
