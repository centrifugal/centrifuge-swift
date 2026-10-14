import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Clients and subscriptions with a static token (no token getter) keep it when
/// the server invalidates the state, and stop as unauthorized when it expires.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class StaticTokenTests: @unchecked Sendable {

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        let lock = NSLock()
        var connected = 0
        var errors: [Error] = []
        var onConn: (() -> Void)?
        var onDisc: ((CentrifugeDisconnectedEvent) -> Void)?
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) {
            lock.lock(); connected += 1; lock.unlock()
            onConn?()
        }
        func onDisconnected(_ c: CentrifugeClient, _ e: CentrifugeDisconnectedEvent) { onDisc?(e) }
        func onError(_ c: CentrifugeClient, _ e: CentrifugeErrorEvent) { lock.lock(); errors.append(e.error); lock.unlock() }
        var connectedCount: Int { lock.lock(); defer { lock.unlock() }; return connected }
        var errorList: [Error] { lock.lock(); defer { lock.unlock() }; return errors }
    }

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        let lock = NSLock()
        var subscribed = 0
        var errors: [Error] = []
        var onUnsub: ((CentrifugeUnsubscribedEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { lock.lock(); subscribed += 1; lock.unlock() }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?(e) }
        func onError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscriptionErrorEvent) { lock.lock(); errors.append(e.error); lock.unlock() }
        var subscribedCount: Int { lock.lock(); defer { lock.unlock() }; return subscribed }
        var errorList: [Error] { lock.lock(); defer { lock.unlock() }; return errors }
    }

    private final class Locked<T>: @unchecked Sendable {
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

    private func makeClient(token: String, delegate: CentrifugeClientDelegate) -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.token = token
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
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

    /// State invalidated (3014) without a token getter: the client reconnects with
    /// the token it has, instead of without a token.
    @Test func stateInvalidationKeepsStaticConnectionToken() async throws {
        let delegate = ClientDelegate()
        let client = makeClient(token: "static", delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        #expect(await waitUntil(3) { delegate.connectedCount == 1 })

        server.disconnect(3014, "state invalidated")
        #expect(await waitUntil(3) { delegate.connectedCount == 2 })
        #expect(connectTokens() == ["static", "static"])
    }

    /// Token expired (109) without a token getter: the client stops as unauthorized
    /// with a configuration error, instead of retrying the expired token forever;
    /// setToken() + connect() then works.
    @Test func expiredStaticConnectionTokenEndsUnauthorized() async throws {
        let expired = Locked(true)
        server.onCommand = { cmd in
            guard cmd.hasConnect, expired.get else { return nil }
            var reply = FakeCentrifugoServer.PReply()
            reply.id = cmd.id
            reply.error.code = 109
            reply.error.message = "token expired"
            return reply
        }
        let delegate = ClientDelegate()
        let disconnected = Expectation("disconnected")
        let code = Locked<UInt32>(0)
        delegate.onDisc = { e in code.set(e.code); disconnected.fulfill() }
        let client = makeClient(token: "static", delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: disconnected, within: 3)
        #expect(code.get == 1)
        #expect(connectTokens() == ["static"])
        #expect(delegate.errorList.contains { if case CentrifugeError.configurationError = $0 { return true }; return false })

        expired.set(false)
        client.setToken(token: "new")
        client.connect()
        #expect(await waitUntil(3) { delegate.connectedCount == 1 })
        #expect(connectTokens() == ["static", "new"])
    }

    /// State invalidated (2502) for a subscription with a static token: it
    /// resubscribes with that token, instead of without a token.
    @Test func stateInvalidationKeepsStaticSubscriptionToken() async throws {
        let delegate = ClientDelegate()
        let client = makeClient(token: "", delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        var cfg = CentrifugeSubscriptionConfig()
        cfg.token = "sub-static"
        let d = SubDelegate()
        let sub = try client.newSubscription(channel: "ch", delegate: d, config: cfg)
        sub.subscribe()
        #expect(await waitUntil(3) { d.subscribedCount == 1 })

        server.unsubscribe("ch", 2502, "state invalidated")
        #expect(await waitUntil(3) { d.subscribedCount == 2 })
        #expect(server.received().filter(\.hasSubscribe).map(\.subscribe.token) == ["sub-static", "sub-static"])
    }

    /// Subscription token expired (109) without a token getter: the subscription
    /// ends as unauthorized with a configuration error, instead of subscribing
    /// again without a token.
    @Test func expiredStaticSubscriptionTokenEndsUnauthorized() async throws {
        server.onCommand = { cmd in
            guard cmd.hasSubscribe else { return nil }
            var reply = FakeCentrifugoServer.PReply()
            reply.id = cmd.id
            reply.error.code = 109
            reply.error.message = "token expired"
            return reply
        }
        let delegate = ClientDelegate()
        let client = makeClient(token: "", delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        var cfg = CentrifugeSubscriptionConfig()
        cfg.token = "sub-static"
        let d = SubDelegate()
        let unsubscribed = Expectation("unsubscribed")
        let code = Locked<UInt32>(0)
        d.onUnsub = { e in code.set(e.code); unsubscribed.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d, config: cfg)
        sub.subscribe()

        await fulfillment(of: unsubscribed, within: 3)
        #expect(code.get == 1)
        #expect(d.errorList.contains { if case CentrifugeError.configurationError = $0 { return true }; return false })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(server.received().filter(\.hasSubscribe).map(\.subscribe.token) == ["sub-static"])
    }
}
