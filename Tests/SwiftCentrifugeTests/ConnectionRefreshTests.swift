import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Tests for the periodic connection-token refresh loop the client starts when
/// the connect result says the token expires. Behavior is asserted over the wire
/// against the in-process `FakeCentrifugoServer` (the refresh timer and task are
/// private), plus through the client delegate.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class ConnectionRefreshTests: @unchecked Sendable {

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        var onConn: (() -> Void)?
        var onErr: ((CentrifugeErrorEvent) -> Void)?
        var onDisc: ((CentrifugeDisconnectedEvent) -> Void)?
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) { onConn?() }
        func onError(_ c: CentrifugeClient, _ e: CentrifugeErrorEvent) { onErr?(e) }
        func onDisconnected(_ c: CentrifugeClient, _ e: CentrifugeDisconnectedEvent) { onDisc?(e) }
    }

    private struct TestError: Error {}

    /// Carries the token getter's completion across a queue hop. The completion is
    /// a plain non-Sendable closure, and the point of the test is precisely that
    /// the app may call it from another thread.
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        // Token expires quickly, so the client starts refreshing right after connect.
        var res = FakeCentrifugoServer.PConnectResult()
        res.client = "fake-client"; res.version = "0.0.0"; res.ping = 25
        res.expires = true; res.ttl = 1
        server.connectResult = res
        try server.start()
    }

    deinit {
        server.stop()
    }

    private func makeClient(
        delegate: CentrifugeClientDelegate,
        tokenGetter: @escaping CentrifugeConnectionTokenGetter
    ) -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.token = "initial"
        cfg.tokenGetter = tokenGetter
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
    }

    /// A token getter that fails once must not stop the refresh loop: the client
    /// has to retry with backoff, otherwise the token silently goes stale for the
    /// entire lifetime of the connection and the server eventually drops it.
    @Test func refreshRetriedAfterTokenGetterFailure() async throws {
        let connected = Expectation("connected")
        let errored = Expectation("token error reported")
        let refreshed = Expectation("refresh command reached the server")

        let calls = NSLock()
        var callCount = 0

        let delegate = ClientDelegate()
        delegate.onConn = { connected.fulfill() }
        delegate.onErr = { e in
            if case CentrifugeError.tokenError = e.error { errored.fulfill() }
        }
        let client = makeClient(delegate: delegate) { _, completion in
            calls.lock(); callCount += 1; let n = callCount; calls.unlock()
            // Fail the first refresh, hand out a token on every later attempt.
            if n == 1 {
                completion(.failure(TestError()))
            } else {
                completion(.success("refreshed-token"))
            }
        }
        server.onCommand = { cmd in
            if cmd.hasRefresh { refreshed.fulfill() }
            return nil
        }

        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: connected, within: 5)
        await fulfillment(of: errored, within: 5)
        // The retry is scheduled with backoff(step: 0, min: 5, max: 10) seconds.
        await fulfillment(of: refreshed, within: 15)
        #expect(server.received().last(where: { $0.hasRefresh })?.refresh.token == "refreshed-token")
    }

    /// The token getter's completion is called by the app on whatever thread it
    /// likes. The client must resume its own processing on syncQueue: an
    /// `unauthorized` failure disconnects, and processDisconnect asserts it runs
    /// there (`assertIsOnQueue`, a dispatchPrecondition in debug builds).
    @Test func unauthorizedFromBackgroundThreadDisconnects() async throws {
        let connected = Expectation("connected")
        let disconnected = Expectation("disconnected as unauthorized")

        let background = DispatchQueue(label: "test.token.getter")
        let delegate = ClientDelegate()
        delegate.onConn = { connected.fulfill() }
        delegate.onDisc = { e in
            if e.code == disconnectedCodeUnauthorized { disconnected.fulfill() }
        }
        let client = makeClient(delegate: delegate) { _, completion in
            let boxed = Box(completion)
            background.async { boxed.value(.failure(CentrifugeError.unauthorized)) }
        }

        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: connected, within: 5)
        await fulfillment(of: disconnected, within: 5)
    }
}
