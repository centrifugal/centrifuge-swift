import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Subscription token requests, subscribe replies and refresh steps belong to the
/// subscribe attempt (or subscribed session) they were made for, and are dropped
/// once it is over.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class SubscriptionAttemptTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        let lock = NSLock()
        var subscribed = 0
        var errors: [Error] = []
        var onSub: (() -> Void)?
        var onUnsub: ((CentrifugeUnsubscribedEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) {
            lock.lock(); subscribed += 1; lock.unlock()
            onSub?()
        }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?(e) }
        func onError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscriptionErrorEvent) {
            lock.lock(); errors.append(e.error); lock.unlock()
        }
        var subscribedCount: Int { lock.lock(); defer { lock.unlock() }; return subscribed }
        var errorList: [Error] { lock.lock(); defer { lock.unlock() }; return errors }
    }

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        let lock = NSLock()
        var connected = 0
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) { lock.lock(); connected += 1; lock.unlock() }
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

    private func makeClient(delegate: CentrifugeClientDelegate? = nil) -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
    }

    private func subscribeCommands() -> [FakeCentrifugoServer.PCommand] {
        server.received().filter(\.hasSubscribe)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// unsubscribe() + subscribe() while the first subscribe is in flight: an error
    /// reply to the first subscribe does not end the second attempt.
    @Test func replyToSupersededSubscribeIgnored() async throws {
        server.dropCommand = { cmd in cmd.hasSubscribe }
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }

        let subscribed = Expectation("subscribed")
        let unsubscribed = Expectation("unsubscribed")
        let d = SubDelegate()
        d.onSub = { subscribed.fulfill() }
        d.onUnsub = { _ in unsubscribed.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        #expect(await waitUntil(3) { self.subscribeCommands().count == 1 })
        sub.unsubscribe()
        await fulfillment(of: unsubscribed, within: 3)
        sub.subscribe()
        #expect(await waitUntil(3) { self.subscribeCommands().count == 2 })

        let commands = subscribeCommands()
        var stale = FakeCentrifugoServer.PReply()
        stale.id = commands[0].id
        stale.error.code = 103
        stale.error.message = "permission denied"
        server.sendReply(stale)
        var fresh = FakeCentrifugoServer.PReply()
        fresh.id = commands[1].id
        fresh.subscribe = FakeCentrifugoServer.PSubscribeResult()
        server.sendReply(fresh)

        await fulfillment(of: subscribed, within: 3)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sub.state == .subscribed)
    }

    /// unsubscribe() + subscribe() while the token getter is pending: the token the
    /// first getter call returns later is not used.
    @Test func tokenOfAbandonedSubscribeNotUsed() async throws {
        let delegate = ClientDelegate()
        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        #expect(await waitUntil(3) { delegate.connectedCount == 1 })

        let getter = Getter()
        var cfg = CentrifugeSubscriptionConfig()
        cfg.tokenGetter = { _, completion in getter.get(completion) }
        let subscribed = Expectation("subscribed")
        let unsubscribed = Expectation("unsubscribed")
        let d = SubDelegate()
        d.onSub = { subscribed.fulfill() }
        d.onUnsub = { _ in unsubscribed.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d, config: cfg)
        sub.subscribe()
        #expect(await waitUntil(3) { getter.calls == 1 })
        sub.unsubscribe()
        await fulfillment(of: unsubscribed, within: 3)
        sub.subscribe()
        #expect(await waitUntil(3) { getter.calls == 2 })

        getter.complete(0, .success("stale"))
        try await Task.sleep(nanoseconds: 300_000_000)
        getter.complete(1, .success("fresh"))
        await fulfillment(of: subscribed, within: 3)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(subscribeCommands().map(\.subscribe.token) == ["fresh"])
    }

    /// A refresh token request still pending when the subscription resubscribes
    /// does not refresh the new subscribed session, which runs its own refresh.
    @Test func refreshOfPreviousSessionNotUsed() async throws {
        server.onSubscribe = { _, _ in
            var r = FakeCentrifugoServer.PSubscribeResult()
            r.expires = true
            r.ttl = 1
            return r
        }
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }

        let getter = Getter()
        // Calls 0 and 2 are the tokens of the two subscribes.
        getter.autoComplete = [0, 2]
        var cfg = CentrifugeSubscriptionConfig()
        cfg.tokenGetter = { _, completion in getter.get(completion) }
        let d = SubDelegate()
        let sub = try client.newSubscription(channel: "ch", delegate: d, config: cfg)
        sub.subscribe()

        // Call 1: the refresh of the first session; keep it pending across a resubscribe.
        #expect(await waitUntil(5) { getter.calls == 2 })
        var u = Centrifugal_Centrifuge_Protocol_Unsubscribe()
        u.code = 2500
        u.reason = "resubscribe"
        var push = FakeCentrifugoServer.PPush()
        push.channel = "ch"
        push.unsubscribe = u
        server.sendPush(push)
        // Call 3: the refresh of the second session.
        #expect(await waitUntil(5) { getter.calls == 4 && d.subscribedCount == 2 })

        getter.complete(1, .success("stale"))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(server.received().filter(\.hasSubRefresh).isEmpty)

        getter.complete(3, .success("fresh"))
        #expect(await waitUntil(3) { !self.server.received().filter(\.hasSubRefresh).isEmpty })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(server.received().filter(\.hasSubRefresh).map(\.subRefresh.token) == ["fresh"])
    }

    /// A subscribe in flight when the connection is lost is not reported as a
    /// subscribe error: the subscription resubscribes after the reconnect.
    @Test func subscribeInterruptedByDisconnectNotReported() async throws {
        let first = NSLock()
        var dropped = false
        server.dropCommand = { cmd in
            guard cmd.hasSubscribe else { return false }
            first.lock(); defer { first.unlock() }
            if dropped { return false }
            dropped = true
            return true
        }
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }

        let subscribed = Expectation("subscribed after reconnect")
        let d = SubDelegate()
        d.onSub = { subscribed.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        #expect(await waitUntil(3) { self.subscribeCommands().count == 1 })

        server.closeConnection()
        await fulfillment(of: subscribed, within: 5)
        #expect(d.errorList.isEmpty, "errors: \(d.errorList)")
    }

    /// An unsubscribe still pending when the connection is lost fails with the
    /// teardown; that failure doesn't count as one more reconnect: the first retry
    /// uses the first backoff step.
    @Test func unsubscribeFailedByTeardownDoesNotReconnectAgain() async throws {
        server.dropCommand = { cmd in cmd.hasUnsubscribe }
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 5
        cfg.maxReconnectDelay = 20
        let delegate = ClientDelegate()
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        let d = SubDelegate()
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        #expect(await waitUntil(3) { d.subscribedCount == 1 })
        sub.unsubscribe()
        #expect(await waitUntil(3) { self.server.received().contains(where: \.hasUnsubscribe) })

        server.closeConnection()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.state == .connecting)
        #expect(reconnectAttempts(client) == 1)
    }

    private func reconnectAttempts(_ client: CentrifugeClient) -> Int? {
        Mirror(reflecting: client).children.first { $0.label == "reconnectAttempts" }?.value as? Int
    }
}

