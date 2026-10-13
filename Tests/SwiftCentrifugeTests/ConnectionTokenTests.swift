import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// A connection token request belongs to the connection attempt (or, for a
/// refresh, to the connection) it was made for: a token that arrives after that
/// attempt or connection is over is not used.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class ConnectionTokenTests: @unchecked Sendable {

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        let lock = NSLock()
        var connected = 0
        var onConn: (() -> Void)?
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) {
            lock.lock(); connected += 1; lock.unlock()
            onConn?()
        }
        var connectedCount: Int { lock.lock(); defer { lock.unlock() }; return connected }
    }

    /// Token getter whose calls the test completes by hand.
    private final class Getter: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(Result<String, Error>) -> Void] = []
        /// Calls with an index in this set are completed at once with "auto-<index>".
        var autoComplete: Set<Int> = []

        var calls: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

        func get(_ completion: @escaping (Result<String, Error>) -> Void) {
            lock.lock()
            pending.append(completion)
            let index = pending.count - 1
            let auto = autoComplete.contains(index)
            lock.unlock()
            if auto { completion(.success("auto-\(index)")) }
        }

        func complete(_ index: Int, _ result: Result<String, Error>) {
            lock.lock(); let completion = pending[index]; lock.unlock()
            completion(result)
        }
    }

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    deinit {
        server.stop()
    }

    private func makeClient(_ getter: Getter, delegate: CentrifugeClientDelegate) -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        cfg.tokenGetter = { _, completion in getter.get(completion) }
        return CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
    }

    private func connectTokens() -> [String] {
        server.received().filter(\.hasConnect).map(\.connect.token)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// disconnect() + connect() while the token getter is pending: the token the
    /// first getter call returns later (e.g. for the previous user) is not used,
    /// and the client sends one connect command, with the new token.
    @Test(arguments: [false, true])
    func tokenOfAbandonedAttemptNotUsed(native: Bool) async throws {
        let getter = Getter()
        let delegate = ClientDelegate()
        let connected = Expectation("connected")
        delegate.onConn = { connected.fulfill() }
        let client = makeClient(getter, delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        #expect(await waitUntil(3) { getter.calls == 1 })

        client.disconnect()
        client.connect()
        #expect(await waitUntil(3) { getter.calls == 2 })
        // The first request completes while the second attempt is in progress.
        getter.complete(0, .success("stale"))
        try await Task.sleep(nanoseconds: 300_000_000)
        getter.complete(1, .success("fresh"))
        await fulfillment(of: connected, within: 5)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(connectTokens() == ["fresh"])
        #expect(client.state == .connected)
        #expect(delegate.connectedCount == 1)
    }

    /// A getter that calls its completion twice: only the first call counts.
    @Test func getterCompletionCalledTwice() async throws {
        let delegate = ClientDelegate()
        let connected = Expectation("connected")
        delegate.onConn = { connected.fulfill() }
        var cfg = CentrifugeClientConfig()
        cfg.tokenGetter = { _, completion in
            completion(.success("first"))
            completion(.success("second"))
        }
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        await fulfillment(of: connected, within: 5)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(connectTokens() == ["first"])
    }

    /// A refresh token request still pending when the connection is lost does not
    /// refresh the next connection, which runs its own refresh.
    @Test func refreshOfPreviousConnectionNotUsed() async throws {
        var res = FakeCentrifugoServer.PConnectResult()
        res.client = "fake-client"; res.version = "0.0.0"; res.ping = 25
        res.expires = true; res.ttl = 1
        server.connectResult = res

        let getter = Getter()
        getter.autoComplete = [0]
        let delegate = ClientDelegate()
        let client = makeClient(getter, delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        // Call 1: the refresh of the first connection; keep it pending across a reconnect.
        #expect(await waitUntil(5) { getter.calls == 2 })
        server.closeConnection()
        // Call 2: the refresh of the second connection.
        #expect(await waitUntil(5) { getter.calls == 3 && delegate.connectedCount == 2 })

        getter.complete(1, .success("stale"))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(server.received().filter(\.hasRefresh).isEmpty)

        getter.complete(2, .success("fresh"))
        #expect(await waitUntil(3) { !self.server.received().filter(\.hasRefresh).isEmpty })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(server.received().filter(\.hasRefresh).map(\.refresh.token) == ["fresh"])
    }
}
