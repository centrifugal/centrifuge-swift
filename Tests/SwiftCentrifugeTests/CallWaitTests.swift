import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Calls made while the client is connecting wait for the connection, also
/// across a reconnect; only disconnect() (or their timeout) ends the wait.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class CallWaitTests: @unchecked Sendable {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var get: T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    }

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    deinit {
        server.stop()
    }

    private func makeClient() -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: server.url, config: cfg)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test func callWaitsAcrossReconnect() async throws {
        let firstConnect = Box(true)
        server.dropCommand = { cmd in
            guard cmd.hasConnect, firstConnect.get else { return false }
            firstConnect.set(false)
            return true
        }
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        #expect(await waitUntil(3) { self.server.received().contains(where: \.hasConnect) })

        let done = Expectation("rpc completed")
        let failure = Box<Error?>(nil)
        client.rpc(method: "m", data: Data()) { res in
            if case .failure(let error) = res { failure.set(error) }
            done.fulfill()
        }
        // The first attempt fails; the client reconnects and the call goes out then.
        server.closeConnection()
        await fulfillment(of: done, within: 5)
        #expect(failure.get == nil, "rpc failed: \(String(describing: failure.get))")
        #expect(!server.received().filter(\.hasRpc).isEmpty)
    }

    @Test func disconnectEndsTheWait() async throws {
        server.dropCommand = { cmd in cmd.hasConnect }
        let client = makeClient()
        client.connect()
        #expect(await waitUntil(3) { self.server.received().contains(where: \.hasConnect) })

        let done = Expectation("rpc completed")
        let failure = Box<Error?>(nil)
        client.rpc(method: "m", data: Data()) { res in
            if case .failure(let error) = res { failure.set(error) }
            done.fulfill()
        }
        client.disconnect()
        await fulfillment(of: done, within: 3)
        if case CentrifugeError.clientDisconnected? = failure.get {} else {
            Issue.record("expected clientDisconnected, got \(String(describing: failure.get))")
        }
    }
}
