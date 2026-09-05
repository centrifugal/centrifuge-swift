import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Integration tests for channel compaction. The feature is Centrifugo PRO only,
/// so it can't be exercised against the docker-compose OSS server — these tests
/// use the in-process `FakeCentrifugoServer`: the subscribe reply negotiates a
/// numeric channel ID and subsequent pushes carry the ID instead of the channel
/// name, exactly like the real server does when compaction is enabled.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class CompactionTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: ((CentrifugeSubscribedEvent) -> Void)?
        var onPub: ((CentrifugePublicationEvent) -> Void)?
        var onJoinH: ((CentrifugeJoinEvent) -> Void)?
        var onLeaveH: ((CentrifugeLeaveEvent) -> Void)?
        var onUnsub: ((CentrifugeUnsubscribedEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?(e) }
        func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) { onPub?(e) }
        func onJoin(_ s: CentrifugeSubscription, _ e: CentrifugeJoinEvent) { onJoinH?(e) }
        func onLeave(_ s: CentrifugeSubscription, _ e: CentrifugeLeaveEvent) { onLeaveH?(e) }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?(e) }
    }

    private let server: FakeCentrifugoServer
    // Numeric channel id assigned on the next subscribe; a test can change it
    // before a resubscribe to exercise id refresh. Guarded by stateLock because
    // it's read on the server queue and written from the test thread.
    private let stateLock = NSLock()
    private var nextChannelId: Int64 = 42
    private func setNextChannelId(_ v: Int64) { stateLock.lock(); nextChannelId = v; stateLock.unlock() }

    init() throws {
        server = FakeCentrifugoServer()
        // Negotiate channel compaction: assign a numeric channel id whenever the
        // client offers the channelCompaction flag (bit 1).
        server.onSubscribe = { [weak self] _, req in
            var res = FakeCentrifugoServer.PSubscribeResult()
            guard let self = self else { return res }
            self.stateLock.lock(); let nid = self.nextChannelId; self.stateLock.unlock()
            if req.flag & 1 != 0 { res.id = nid }
            return res
        }
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

    @Test func flagOfferedAndPushesRoutedByID() async throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = Expectation("subscribed")
        let pub = Expectation("pub")
        let join = Expectation("join")
        let leave = Expectation("leave")
        var pubData = Data()
        d.onSub = { _ in subscribed.fulfill() }
        d.onPub = { e in pubData = e.data; pub.fulfill() }
        d.onJoinH = { _ in join.fulfill() }
        d.onLeaveH = { _ in leave.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)
        #expect(((server.lastSubscribe()?.flag ?? 0) & 1) == 1, "subscribe must offer the compaction flag")
        server.publishId(42, Data("{\"a\":1}".utf8))
        await fulfillment(of: pub, within: 5)
        #expect(String(data: pubData, encoding: .utf8) == "{\"a\":1}")
        server.joinId(42, "joiner")
        server.leaveId(42, "leaver")
        await fulfillment(of: [join, leave], within: 5)
    }

    @Test func unknownIDDropped() async throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = Expectation("subscribed")
        let pub = Expectation("pub")
        var lastData = Data()
        var pubCount = 0
        d.onSub = { _ in subscribed.fulfill() }
        d.onPub = { e in lastData = e.data; pubCount += 1; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)
        server.publishId(99, Data("{\"stray\":true}".utf8)) // unknown id, dropped
        server.publishId(42, Data("{\"ok\":true}".utf8))     // known id
        await fulfillment(of: pub, within: 5)
        // Give a stray delivery a chance to (wrongly) arrive.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(pubCount == 1, "unknown id push must be dropped")
        #expect(String(data: lastData, encoding: .utf8) == "{\"ok\":true}")
    }

    @Test func idDroppedOnUnsubscribeRefreshedOnResubscribe() async throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = Expectation("subscribed")
        let unsub = Expectation("unsubscribed")
        let resubscribed = Expectation("resubscribed")
        let pub = Expectation("pub")
        var subCount = 0
        var lastData = Data()
        var pubCount = 0
        d.onSub = { _ in subCount += 1; if subCount == 1 { subscribed.fulfill() } else { resubscribed.fulfill() } }
        d.onUnsub = { _ in unsub.fulfill() }
        d.onPub = { e in lastData = e.data; pubCount += 1; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)
        sub.unsubscribe()
        await fulfillment(of: unsub, within: 5)
        server.publishId(42, Data("{\"stale\":true}".utf8)) // old id, dropped
        setNextChannelId(43)
        sub.subscribe()
        await fulfillment(of: resubscribed, within: 5)
        server.publishId(43, Data("{\"fresh\":true}".utf8))
        await fulfillment(of: pub, within: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(pubCount == 1, "stale push for old id must be dropped")
        #expect(String(data: lastData, encoding: .utf8) == "{\"fresh\":true}")
    }

    @Test func sameIDReRegisteredAfterReconnect() async throws {
        // Regression guard (found in the dart port): the client drops the ID
        // registry on teardown (IDs are server-session-scoped), and on reconnect
        // the server commonly assigns the SAME ID again. The subscription must
        // re-register it even though its own remembered ID is unchanged.
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = Expectation("subscribed")
        let resubscribed = Expectation("resubscribed")
        let pub = Expectation("pub")
        var subCount = 0
        var lastData = Data()
        d.onSub = { _ in subCount += 1; if subCount == 1 { subscribed.fulfill() } else { resubscribed.fulfill() } }
        d.onPub = { e in lastData = e.data; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)
        client.disconnect()
        client.connect()
        await fulfillment(of: resubscribed, within: 8)
        server.publishId(42, Data("{\"after\":true}".utf8)) // same id 42
        await fulfillment(of: pub, within: 5)
        #expect(String(data: lastData, encoding: .utf8) == "{\"after\":true}")
    }
}
