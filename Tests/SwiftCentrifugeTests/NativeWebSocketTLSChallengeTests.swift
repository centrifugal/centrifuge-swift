import Foundation
import Testing
@testable import SwiftCentrifuge

/// Unit tests for the native WebSocket transport's TLS/auth challenge handling
/// (`CentrifugeClientConfig.tlsChallengeHandler` and `tlsSkipVerify`, see issue #136).
///
/// `tlsChallengeHandler` is an unfiltered forward of every challenge this session-level
/// delegate method receives (server-trust, client-certificate, NTLM, Negotiate — same shape
/// as Kingfisher's `AuthenticationChallengeResponsible.downloader(_:didReceive:)`).
/// `tlsSkipVerify`, in contrast, only ever applies to server-trust, matching what it has
/// always meant on the Starscream transport.
///
/// These exercise `NativeWebSocket`'s delegate method directly with a synthetic
/// challenge, so they're fast and deterministic. `URLProtectionSpace` has no public
/// initializer that attaches a real `SecTrust`, so the synthetic challenge here always
/// has `serverTrust == nil` — good enough to test the handler/precedence/scoping logic,
/// but not the "does `tlsSkipVerify` actually trust a real certificate" happy path. That,
/// and the equivalent for `tlsChallengeHandler`, were verified manually end-to-end against
/// a real self-signed-cert local WSS server (rejected with neither set, accepted with either).
/// Note on availability: `NativeWebSocket` requires macOS 10.15 / iOS 13, but
/// swift-testing rejects `@available` on `@Test` and `@Suite`, so the requirement
/// cannot live on the suite the way it did under XCTest. Each test guards at
/// runtime instead and no-ops on older systems, which is what XCTest did with an
/// `@available` test class anyway. The package deliberately declares no
/// `platforms:`, so the guard is not redundant.
@Suite
struct NativeWebSocketTLSChallengeTests {

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

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
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

    @Test func defaultHandlingWhenNeitherOptionConfigured() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let (ws, queue) = makeSocket(tlsChallengeHandler: nil)
        let completed = Expectation("completion called")

        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: makeChallenge()) { disposition, credential in
                #expect(disposition == .performDefaultHandling)
                #expect(credential == nil)
                completed.fulfill()
            }
        }

        wait(for: completed, timeout: 1)
    }

    @Test func configuredHandlerIsInvokedAndItsDecisionIsForwarded() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let challenge = makeChallenge()
        let credential = URLCredential(user: "u", password: "p", persistence: .none)
        var receivedChallenge: URLAuthenticationChallenge?

        let (ws, queue) = makeSocket(tlsChallengeHandler: { ch, completion in
            receivedChallenge = ch
            completion(.useCredential, credential)
        })

        let completed = Expectation("completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { disposition, receivedCredential in
                #expect(disposition == .useCredential)
                #expect(receivedCredential == credential)
                completed.fulfill()
            }
        }

        wait(for: completed, timeout: 1)
        #expect(receivedChallenge === challenge)
    }

    @Test func handlerTakesPrecedenceOverTlsSkipVerify() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        // tlsSkipVerify is true, but a handler is also configured; the handler's
        // decision must win, not tlsSkipVerify's trust-everything fallback.
        let (ws, queue) = makeSocket(tlsSkipVerify: true, tlsChallengeHandler: { _, completion in
            completion(.cancelAuthenticationChallenge, nil)
        })

        let completed = Expectation("completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: makeChallenge()) { disposition, credential in
                #expect(disposition == .cancelAuthenticationChallenge)
                #expect(credential == nil)
                completed.fulfill()
            }
        }

        wait(for: completed, timeout: 1)
    }

    @Test func tlsSkipVerifyFallsBackToDefaultHandlingWithoutServerTrust() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        // No handler, tlsSkipVerify is true, but the challenge carries no serverTrust
        // (as is always the case for a synthetic challenge) — must not crash or
        // force-unwrap, just fall back to default handling.
        let (ws, queue) = makeSocket(tlsSkipVerify: true, tlsChallengeHandler: nil)
        let completed = Expectation("completion called")

        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: makeChallenge()) { disposition, credential in
                #expect(disposition == .performDefaultHandling)
                #expect(credential == nil)
                completed.fulfill()
            }
        }

        wait(for: completed, timeout: 1)
    }

    @Test func ntlmChallengeIsForwardedToHandler() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        // NTLM is, per Apple's routing rules, a session-level challenge that reaches this
        // exact delegate method (same as server-trust) - e.g. for an authenticating proxy.
        // tlsChallengeHandler is an unfiltered forward, so it must receive this too, exactly
        // like Kingfisher's equivalent AuthenticationChallengeResponsible.downloader(_:didReceive:).
        var receivedAuthMethod: String?
        let credential = URLCredential(user: "u", password: "p", persistence: .none)
        let (ws, queue) = makeSocket(tlsChallengeHandler: { ch, completion in
            receivedAuthMethod = ch.protectionSpace.authenticationMethod
            completion(.useCredential, credential)
        })

        let challenge = makeChallenge(authMethod: NSURLAuthenticationMethodNTLM)
        let completed = Expectation("completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { disposition, receivedCredential in
                #expect(disposition == .useCredential)
                #expect(receivedCredential == credential)
                completed.fulfill()
            }
        }

        wait(for: completed, timeout: 1)
        #expect(receivedAuthMethod == NSURLAuthenticationMethodNTLM)
    }

    @Test func tlsSkipVerifyDoesNotApplyToNTLM() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        // Unlike tlsChallengeHandler, tlsSkipVerify only ever means "don't verify the
        // server's certificate" - it must not affect an NTLM challenge just because
        // it's also a session-level one; that must still fall through to default handling.
        let (ws, queue) = makeSocket(tlsSkipVerify: true, tlsChallengeHandler: nil)

        let challenge = makeChallenge(authMethod: NSURLAuthenticationMethodNTLM)
        let completed = Expectation("completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
                #expect(disposition == .performDefaultHandling)
                #expect(credential == nil)
                completed.fulfill()
            }
        }

        wait(for: completed, timeout: 1)
    }

    @Test func clientCertificateChallengeIsForwardedToHandler() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        // mTLS: a client-certificate challenge is also a TLS-handshake-level challenge,
        // and must reach tlsChallengeHandler just like server-trust does.
        var receivedAuthMethod: String?
        let (ws, queue) = makeSocket(tlsChallengeHandler: { ch, completion in
            receivedAuthMethod = ch.protectionSpace.authenticationMethod
            completion(.performDefaultHandling, nil)
        })

        let challenge = makeChallenge(authMethod: NSURLAuthenticationMethodClientCertificate)
        let completed = Expectation("completion called")
        queue.sync {
            ws.urlSession(URLSession.shared, didReceive: challenge) { _, _ in
                completed.fulfill()
            }
        }

        wait(for: completed, timeout: 1)
        #expect(receivedAuthMethod == NSURLAuthenticationMethodClientCertificate)
    }
}
