// XCTest ships only inside Xcode.app. Guard the file so the test target still
// compiles with just the Command Line Tools, where the swift-testing suites in
// this target can still run (see CLAUDE.md, "Running tests locally").
// Removed once this suite is migrated to swift-testing.
#if canImport(XCTest)
import XCTest
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// Tests for "state invalidated" handling: unsubscribe code 2502 (per-subscription)
/// and disconnect code 3014 (connection-wide). On these the client drops cached
/// tokens (and recovery position / delta base) so a fresh token is obtained and
/// the subscription re-syncs. Private subscription fields aren't readable, so
/// behavior is asserted over the wire against the in-process FakeCentrifugoServer.
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter StateInvalidationTests
final class StateInvalidationTests: XCTestCase {

    private final class SubDelegate: CentrifugeSubscriptionDelegate {
        var onSub: (() -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
    }

    private final class ClientDelegate: CentrifugeClientDelegate {
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

    private var server: FakeCentrifugoServer!

    override func setUpWithError() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    override func tearDown() {
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

    func testUnsubscribe2502ClearsTokenAndResubscribes() throws {
        let client = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        client.connect()
        defer { client.disconnect() }

        let counter = Counter()
        let firstSubscribed = expectation(description: "first subscribed")
        let resubscribed = expectation(description: "resubscribed")
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
        wait(for: [firstSubscribed], timeout: 5)
        XCTAssertEqual(lastSubscribeToken(), "t1")

        server.unsubscribe("ch", unsubscribedStateInvalidated, "state invalidated")
        wait(for: [resubscribed], timeout: 5)
        XCTAssertEqual(lastSubscribeToken(), "t2", "2502 must clear token so resubscribe fetches a fresh one")
        XCTAssertEqual(counter.count(), 2)
    }

    func testUnsubscribe2502RecoverableResubscribesUnrecovered() throws {
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

        let firstSubscribed = expectation(description: "first subscribed")
        let resubscribed = expectation(description: "resubscribed")
        var subCount = 0
        let d = SubDelegate()
        d.onSub = {
            subCount += 1
            if subCount == 1 { firstSubscribed.fulfill() } else { resubscribed.fulfill() }
        }
        let sub = try client.newSubscription(channel: "ch", delegate: d, config: CentrifugeSubscriptionConfig())
        sub.subscribe()
        wait(for: [firstSubscribed], timeout: 5)
        XCTAssertEqual(lastSubscribe()?.recover, false, "initial subscribe does not request recovery")

        server.unsubscribe("ch", unsubscribedStateInvalidated, "state invalidated")
        wait(for: [resubscribed], timeout: 5)

        let req = try XCTUnwrap(lastSubscribe())
        XCTAssertTrue(req.recover, "resubscribe requests recovery (recover left true)")
        XCTAssertEqual(req.epoch, "_", "resubscribe carries the unrecoverable sentinel epoch")
        XCTAssertEqual(req.offset, 0, "resubscribe offset reset to 0")
    }

    func testDisconnect3014ClearsConnTokenRefreshesAndInvalidatesSubs() throws {
        let counter = Counter()
        var cfg = CentrifugeClientConfig()
        cfg.token = "c0"
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        cfg.tokenGetter = { _, completion in _ = counter.next(); completion(.success("c1")) }

        let firstConnected = expectation(description: "first connected")
        let reconnected = expectation(description: "reconnected")
        var connCount = 0
        let cd = ClientDelegate()
        cd.onConn = {
            connCount += 1
            if connCount == 1 { firstConnected.fulfill() } else { reconnected.fulfill() }
        }
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: cd)
        client.connect()
        defer { client.disconnect() }

        let firstSubscribed = expectation(description: "first subscribed")
        let resubscribed = expectation(description: "resubscribed")
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
        wait(for: [firstConnected, firstSubscribed], timeout: 5)
        XCTAssertEqual(lastConnectToken(), "c0")

        server.disconnect(disconnectedStateInvalidated, "state invalidated")
        wait(for: [reconnected, resubscribed], timeout: 8)
        XCTAssertGreaterThanOrEqual(counter.count(), 1, "3014 must trigger a fresh connection token fetch")
        XCTAssertEqual(lastConnectToken(), "c1", "reconnect must use the freshly fetched token")
        XCTAssertEqual(lastSubscribeToken(), "", "3014 must invalidate subscription token")
    }

    func testDisconnect3014ResetsServerSubRecoveryPosition() throws {
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
        let firstServerSub = expectation(description: "first server sub")
        let resubscribed = expectation(description: "resubscribed after reconnect")
        var subCount = 0
        cd.onServerSub = { _ in
            subCount += 1
            if subCount == 1 { firstServerSub.fulfill() } else { resubscribed.fulfill() }
        }
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: cd)
        client.connect()
        defer { client.disconnect() }

        wait(for: [firstServerSub], timeout: 5)
        XCTAssertNil(lastConnect()?.subs["news"], "initial connect carries no server subs to recover")

        server.disconnect(disconnectedStateInvalidated, "state invalidated")
        wait(for: [resubscribed], timeout: 8)

        let req = try XCTUnwrap(lastConnect()?.subs["news"], "reconnect must request recovery for the server-side sub")
        XCTAssertTrue(req.recover, "recover flag left true")
        XCTAssertEqual(req.epoch, "_", "reconnect must not carry the pre-invalidation epoch")
        XCTAssertEqual(req.offset, 0, "reconnect must not carry the pre-invalidation offset")
    }
}
#endif // canImport(XCTest)
