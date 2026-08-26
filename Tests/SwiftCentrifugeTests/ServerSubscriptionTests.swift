import XCTest
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// Tests for server-side subscriptions (subscriptions the server attaches to the
/// connection — they come in the connect result and their events go to the client
/// delegate). Server-side subscriptions require server configuration, so the
/// behavior is exercised against the in-process `FakeCentrifugoServer`.
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter ServerSubscriptionTests
final class ServerSubscriptionTests: XCTestCase {

    private final class ClientDelegate: CentrifugeClientDelegate {
        var onSub: ((CentrifugeServerSubscribedEvent) -> Void)?
        var onUnsub: ((CentrifugeServerUnsubscribedEvent) -> Void)?
        var onPub: ((CentrifugeServerPublicationEvent) -> Void)?
        func onSubscribed(_ c: CentrifugeClient, _ e: CentrifugeServerSubscribedEvent) { onSub?(e) }
        func onUnsubscribed(_ c: CentrifugeClient, _ e: CentrifugeServerUnsubscribedEvent) { onUnsub?(e) }
        func onPublication(_ c: CentrifugeClient, _ e: CentrifugeServerPublicationEvent) { onPub?(e) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    private var server: FakeCentrifugoServer!

    override func setUpWithError() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    private func makeClient(delegate: CentrifugeClientDelegate) -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
    }

    /// Reply to every connect command with server-side subscriptions for the given
    /// channels — `channelsPerConnect[i]` is used for the i-th connect, the last
    /// entry is reused for all following connects.
    private func serveConnects(_ channelsPerConnect: [[String]]) {
        let connects = Counter()
        server.onCommand = { cmd in
            guard cmd.hasConnect else { return nil }
            let index = min(connects.next(), channelsPerConnect.count) - 1
            var result = FakeCentrifugoServer.PConnectResult()
            result.client = "fake-client"
            var subs = [String: FakeCentrifugoServer.PSubscribeResult]()
            for channel in channelsPerConnect[index] {
                subs[channel] = FakeCentrifugoServer.PSubscribeResult()
            }
            result.subs = subs
            var reply = FakeCentrifugoServer.PReply()
            reply.id = cmd.id
            reply.connect = result
            return reply
        }
    }

    func testServerSubUnsubscribedWhenMissingFromNextConnectResult() throws {
        // Regression: the cleanup of server-side subscriptions absent from a
        // connect result used to be nested in the loop over the received subs, so
        // it never ran when the connect result carried no subs at all.
        serveConnects([["news"], []])

        let delegate = ClientDelegate()
        let subscribed = expectation(description: "subscribed")
        let unsubscribed = expectation(description: "unsubscribed")
        delegate.onSub = { event in
            XCTAssertEqual(event.channel, "news")
            subscribed.fulfill()
        }
        delegate.onUnsub = { event in
            XCTAssertEqual(event.channel, "news")
            unsubscribed.fulfill()
        }

        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        wait(for: [subscribed], timeout: 5)

        // Reconnect: the server no longer sends the subscription.
        server.closeConnection()
        wait(for: [unsubscribed], timeout: 8)
    }

    func testServerSubKeptWhenPresentInNextConnectResult() throws {
        serveConnects([["news"]])

        let delegate = ClientDelegate()
        let subscribed = expectation(description: "subscribed")
        let resubscribed = expectation(description: "resubscribed")
        let unsubscribed = expectation(description: "no unsubscribed event")
        unsubscribed.isInverted = true
        var subCount = 0
        delegate.onSub = { _ in
            subCount += 1
            if subCount == 1 { subscribed.fulfill() } else if subCount == 2 { resubscribed.fulfill() }
        }
        delegate.onUnsub = { _ in unsubscribed.fulfill() }

        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        wait(for: [subscribed], timeout: 5)

        server.closeConnection()
        wait(for: [resubscribed], timeout: 8)
        wait(for: [unsubscribed], timeout: 1)
    }

    func testOnlyDroppedServerSubUnsubscribed() throws {
        serveConnects([["news", "sports"], ["news"]])

        let delegate = ClientDelegate()
        let subscribed = expectation(description: "both channels subscribed")
        subscribed.expectedFulfillmentCount = 2
        // "news" is subscribed again after the reconnect.
        subscribed.assertForOverFulfill = false
        let unsubscribed = expectation(description: "sports unsubscribed")
        delegate.onSub = { _ in subscribed.fulfill() }
        delegate.onUnsub = { event in
            XCTAssertEqual(event.channel, "sports", "only the dropped channel must be unsubscribed")
            unsubscribed.fulfill()
        }

        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        wait(for: [subscribed], timeout: 5)

        server.closeConnection()
        wait(for: [unsubscribed], timeout: 8)
    }

    func testServerSubPublicationDelivered() throws {
        serveConnects([["news"]])

        let delegate = ClientDelegate()
        let subscribed = expectation(description: "subscribed")
        let published = expectation(description: "publication")
        delegate.onSub = { _ in subscribed.fulfill() }
        delegate.onPub = { event in
            XCTAssertEqual(event.channel, "news")
            XCTAssertEqual(event.data, Data("{\"hello\":\"world\"}".utf8))
            published.fulfill()
        }

        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        wait(for: [subscribed], timeout: 5)

        server.publishChannel("news", Data("{\"hello\":\"world\"}".utf8))
        wait(for: [published], timeout: 5)
    }
}
