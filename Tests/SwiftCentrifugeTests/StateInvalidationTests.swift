import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Tests for "state invalidated" handling: unsubscribe code 2502 (per-subscription)
/// and disconnect code 3014 (connection-wide). On these the client drops cached
/// tokens (and recovery position / delta base) so a fresh token is obtained and
/// the subscription re-syncs. Private subscription fields aren't readable, so
/// behavior is asserted over the wire against the in-process FakeCentrifugoServer.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class StateInvalidationTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: (() -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
    }

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        var onConn: (() -> Void)?
        var onServerSub: ((CentrifugeServerSubscribedEvent) -> Void)?
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) { onConn?() }
        func onSubscribed(_ c: CentrifugeClient, _ e: CentrifugeServerSubscribedEvent) { onServerSub?(e) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    deinit {
        server.stop()
    }

    private func lastSubscribeToken() -> String? {
        server.received().last(where: { $0.hasSubscribe })?.subscribe.token
    }

    private func lastConnectToken() -> String? {
        server.received().last(where: { $0.hasConnect })?.connect.token
    }

    private func lastSubscribe() -> Centrifugal_Centrifuge_Protocol_SubscribeRequest? {
        server.received().last(where: { $0.hasSubscribe })?.subscribe
    }

    private func lastConnect() -> Centrifugal_Centrifuge_Protocol_ConnectRequest? {
        server.received().last(where: { $0.hasConnect })?.connect
    }

    @Test func unsubscribe2502ClearsTokenAndResubscribes() async throws {
        let client = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        client.connect()
        defer { client.disconnect() }

        let counter = Counter()
        let firstSubscribed = Expectation("first subscribed")
        let resubscribed = Expectation("resubscribed")
        var subCount = 0
        let d = SubDelegate()
        d.onSub = {
            subCount += 1
            if subCount == 1 { firstSubscribed.fulfill() } else { resubscribed.fulfill() }
        }
        var cfg = CentrifugeSubscriptionConfig()
        cfg.tokenGetter = { _, completion in completion(.success("t\(counter.next())")) }
        let sub = try client.newSubscription(channel: "ch", delegate: d, config: cfg)
        sub.subscribe()
        await fulfillment(of: firstSubscribed, within: 5)
        #expect(lastSubscribeToken() == "t1")

        server.unsubscribe("ch", unsubscribedStateInvalidated, "state invalidated")
        await fulfillment(of: resubscribed, within: 5)
        #expect(lastSubscribeToken() == "t2", "2502 must clear token so resubscribe fetches a fresh one")
        #expect(counter.count() == 2)
    }

    @Test func unsubscribe2502RecoverableResubscribesUnrecovered() async throws {
        // A recoverable subscription must resubscribe REQUESTING recovery from the
        // sentinel epoch "_" the server can't match → wasRecovering=true,
        // recovered=false (so the app reloads via its recovery-failure path).
        server.onSubscribe = { _, _ in
            var r = FakeCentrifugoServer.PSubscribeResult()
            r.recoverable = true
            r.epoch = "server-epoch"
            r.offset = 5
            return r
        }
        let client = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        client.connect()
        defer { client.disconnect() }

        let firstSubscribed = Expectation("first subscribed")
        let resubscribed = Expectation("resubscribed")
        var subCount = 0
        let d = SubDelegate()
        d.onSub = {
            subCount += 1
            if subCount == 1 { firstSubscribed.fulfill() } else { resubscribed.fulfill() }
        }
        let sub = try client.newSubscription(channel: "ch", delegate: d, config: CentrifugeSubscriptionConfig())
        sub.subscribe()
        await fulfillment(of: firstSubscribed, within: 5)
        #expect(lastSubscribe()?.recover == false, "initial subscribe does not request recovery")

        server.unsubscribe("ch", unsubscribedStateInvalidated, "state invalidated")
        await fulfillment(of: resubscribed, within: 5)

        let req = try #require(lastSubscribe())
        #expect(req.recover, "resubscribe requests recovery (recover left true)")
        #expect(req.epoch == "_", "resubscribe carries the unrecoverable sentinel epoch")
        #expect(req.offset == 0, "resubscribe offset reset to 0")
    }

    @Test func disconnect3014ClearsConnTokenRefreshesAndInvalidatesSubs() async throws {
        let counter = Counter()
        var cfg = CentrifugeClientConfig()
        cfg.token = "c0"
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        cfg.tokenGetter = { _, completion in _ = counter.next(); completion(.success("c1")) }

        let firstConnected = Expectation("first connected")
        let reconnected = Expectation("reconnected")
        var connCount = 0
        let cd = ClientDelegate()
        cd.onConn = {
            connCount += 1
            if connCount == 1 { firstConnected.fulfill() } else { reconnected.fulfill() }
        }
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: cd)
        client.connect()
        defer { client.disconnect() }

        let firstSubscribed = Expectation("first subscribed")
        let resubscribed = Expectation("resubscribed")
        var subCount = 0
        let sd = SubDelegate()
        sd.onSub = {
            subCount += 1
            if subCount == 1 { firstSubscribed.fulfill() } else { resubscribed.fulfill() }
        }
        var subCfg = CentrifugeSubscriptionConfig()
        subCfg.token = "sub-token-0"
        let sub = try client.newSubscription(channel: "ch", delegate: sd, config: subCfg)
        sub.subscribe()
        await fulfillment(of: [firstConnected, firstSubscribed], within: 5)
        #expect(lastConnectToken() == "c0")

        server.disconnect(disconnectedStateInvalidated, "state invalidated")
        await fulfillment(of: [reconnected, resubscribed], within: 8)
        #expect(counter.count() >= 1, "3014 must trigger a fresh connection token fetch")
        #expect(lastConnectToken() == "c1", "reconnect must use the freshly fetched token")
        #expect(lastSubscribeToken() == "", "3014 must invalidate subscription token")
    }

    @Test func disconnect3014ResetsServerSubRecoveryPosition() async throws {
        // Regression: server-side subscriptions cache their own recovery position
        // separately from client-side subscriptions. 3014 must reset it too, or the
        // next connect keeps requesting recovery from the pre-invalidation offset/epoch.
        server.onCommand = { cmd in
            guard cmd.hasConnect else { return nil }
            var result = FakeCentrifugoServer.PConnectResult()
            result.client = "fake-client"
            var subResult = FakeCentrifugoServer.PSubscribeResult()
            subResult.recoverable = true
            subResult.epoch = "server-epoch"
            subResult.offset = 5
            result.subs = ["news": subResult]
            var reply = FakeCentrifugoServer.PReply()
            reply.id = cmd.id
            reply.connect = result
            return reply
        }

        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        let cd = ClientDelegate()
        let firstServerSub = Expectation("first server sub")
        let resubscribed = Expectation("resubscribed after reconnect")
        var subCount = 0
        cd.onServerSub = { _ in
            subCount += 1
            if subCount == 1 { firstServerSub.fulfill() } else { resubscribed.fulfill() }
        }
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: cd)
        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: firstServerSub, within: 5)
        #expect(lastConnect()?.subs["news"] == nil, "initial connect carries no server subs to recover")

        server.disconnect(disconnectedStateInvalidated, "state invalidated")
        await fulfillment(of: resubscribed, within: 8)

        let req = try #require(lastConnect()?.subs["news"], "reconnect must request recovery for the server-side sub")
        #expect(req.recover, "recover flag left true")
        #expect(req.epoch == "_", "reconnect must not carry the pre-invalidation epoch")
        #expect(req.offset == 0, "reconnect must not carry the pre-invalidation offset")
    }
}
