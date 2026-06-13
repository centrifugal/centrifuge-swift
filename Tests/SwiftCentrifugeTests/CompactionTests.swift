import XCTest
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// Integration tests for channel compaction. The feature is Centrifugo PRO only,
/// so it can't be exercised against the docker-compose OSS server — these tests
/// use the in-process `FakeCentrifugoServer`: the subscribe reply negotiates a
/// numeric channel ID and subsequent pushes carry the ID instead of the channel
/// name, exactly like the real server does when compaction is enabled.
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter CompactionTests
final class CompactionTests: XCTestCase {

    private final class SubDelegate: CentrifugeSubscriptionDelegate {
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

    private var server: FakeCentrifugoServer!
    // Numeric channel id assigned on the next subscribe; a test can change it
    // before a resubscribe to exercise id refresh. Guarded by stateLock because
    // it's read on the server queue and written from the test thread.
    private let stateLock = NSLock()
    private var nextChannelId: Int64 = 42
    private func setNextChannelId(_ v: Int64) { stateLock.lock(); nextChannelId = v; stateLock.unlock() }

    override func setUpWithError() throws {
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

    override func tearDown() {
        server.stop()
    }

    private func makeClient() -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: server.url, config: cfg)
    }

    func testFlagOfferedAndPushesRoutedByID() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let pub = expectation(description: "pub")
        let join = expectation(description: "join")
        let leave = expectation(description: "leave")
        var pubData = Data()
        d.onSub = { _ in subscribed.fulfill() }
        d.onPub = { e in pubData = e.data; pub.fulfill() }
        d.onJoinH = { _ in join.fulfill() }
        d.onLeaveH = { _ in leave.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        XCTAssertEqual((server.lastSubscribe()?.flag ?? 0) & 1, 1, "subscribe must offer the compaction flag")
        server.publishId(42, Data("{\"a\":1}".utf8))
        wait(for: [pub], timeout: 5)
        XCTAssertEqual(String(data: pubData, encoding: .utf8), "{\"a\":1}")
        server.joinId(42, "joiner")
        server.leaveId(42, "leaver")
        wait(for: [join, leave], timeout: 5)
    }

    func testUnknownIDDropped() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let pub = expectation(description: "pub")
        var lastData = Data()
        var pubCount = 0
        d.onSub = { _ in subscribed.fulfill() }
        d.onPub = { e in lastData = e.data; pubCount += 1; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        server.publishId(99, Data("{\"stray\":true}".utf8)) // unknown id, dropped
        server.publishId(42, Data("{\"ok\":true}".utf8))     // known id
        wait(for: [pub], timeout: 5)
        // Give a stray delivery a chance to (wrongly) arrive.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(pubCount, 1, "unknown id push must be dropped")
        XCTAssertEqual(String(data: lastData, encoding: .utf8), "{\"ok\":true}")
    }

    func testIDDroppedOnUnsubscribeRefreshedOnResubscribe() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let unsub = expectation(description: "unsubscribed")
        let resubscribed = expectation(description: "resubscribed")
        let pub = expectation(description: "pub")
        var subCount = 0
        var lastData = Data()
        var pubCount = 0
        d.onSub = { _ in subCount += 1; if subCount == 1 { subscribed.fulfill() } else { resubscribed.fulfill() } }
        d.onUnsub = { _ in unsub.fulfill() }
        d.onPub = { e in lastData = e.data; pubCount += 1; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        sub.unsubscribe()
        wait(for: [unsub], timeout: 5)
        server.publishId(42, Data("{\"stale\":true}".utf8)) // old id, dropped
        setNextChannelId(43)
        sub.subscribe()
        wait(for: [resubscribed], timeout: 5)
        server.publishId(43, Data("{\"fresh\":true}".utf8))
        wait(for: [pub], timeout: 5)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(pubCount, 1, "stale push for old id must be dropped")
        XCTAssertEqual(String(data: lastData, encoding: .utf8), "{\"fresh\":true}")
    }

    func testSameIDReRegisteredAfterReconnect() throws {
        // Regression guard (found in the dart port): the client drops the ID
        // registry on teardown (IDs are server-session-scoped), and on reconnect
        // the server commonly assigns the SAME ID again. The subscription must
        // re-register it even though its own remembered ID is unchanged.
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let resubscribed = expectation(description: "resubscribed")
        let pub = expectation(description: "pub")
        var subCount = 0
        var lastData = Data()
        d.onSub = { _ in subCount += 1; if subCount == 1 { subscribed.fulfill() } else { resubscribed.fulfill() } }
        d.onPub = { e in lastData = e.data; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        client.disconnect()
        client.connect()
        wait(for: [resubscribed], timeout: 8)
        server.publishId(42, Data("{\"after\":true}".utf8)) // same id 42
        wait(for: [pub], timeout: 5)
        XCTAssertEqual(String(data: lastData, encoding: .utf8), "{\"after\":true}")
    }
}
