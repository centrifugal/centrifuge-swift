import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Tests for server-side subscriptions (subscriptions the server attaches to the
/// connection — they come in the connect result and their events go to the client
/// delegate). Server-side subscriptions require server configuration, so the
/// behavior is exercised against the in-process `FakeCentrifugoServer`.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class ServerSubscriptionTests: @unchecked Sendable {

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
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

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    deinit {
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

    @Test func serverSubUnsubscribedWhenMissingFromNextConnectResult() async throws {
        // Regression: the cleanup of server-side subscriptions absent from a
        // connect result used to be nested in the loop over the received subs, so
        // it never ran when the connect result carried no subs at all.
        serveConnects([["news"], []])

        let delegate = ClientDelegate()
        let subscribed = Expectation("subscribed")
        let unsubscribed = Expectation("unsubscribed")
        delegate.onSub = { event in
            #expect(event.channel == "news")
            subscribed.fulfill()
        }
        delegate.onUnsub = { event in
            #expect(event.channel == "news")
            unsubscribed.fulfill()
        }

        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        await fulfillment(of: subscribed, within: 5)

        // Reconnect: the server no longer sends the subscription.
        server.closeConnection()
        await fulfillment(of: unsubscribed, within: 8)
    }

    @Test func serverSubKeptWhenPresentInNextConnectResult() async throws {
        serveConnects([["news"]])

        let delegate = ClientDelegate()
        let subscribed = Expectation("subscribed")
        let resubscribed = Expectation("resubscribed")
        let unsubscribed = Expectation("no unsubscribed event")
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
        await fulfillment(of: subscribed, within: 5)

        server.closeConnection()
        await fulfillment(of: resubscribed, within: 8)
        await fulfillment(of: unsubscribed, within: 1)
    }

    @Test func onlyDroppedServerSubUnsubscribed() async throws {
        serveConnects([["news", "sports"], ["news"]])

        let delegate = ClientDelegate()
        // "news" is subscribed again after the reconnect, so this fires a third
        // time; Expectation deliberately does not treat that as over-fulfilment.
        let subscribed = Expectation("both channels subscribed")
        subscribed.expectedFulfillmentCount = 2
        let unsubscribed = Expectation("sports unsubscribed")
        delegate.onSub = { _ in subscribed.fulfill() }
        delegate.onUnsub = { event in
            #expect(event.channel == "sports", "only the dropped channel must be unsubscribed")
            unsubscribed.fulfill()
        }

        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        await fulfillment(of: subscribed, within: 5)

        server.closeConnection()
        await fulfillment(of: unsubscribed, within: 8)
    }

    @Test func serverSubPublicationDelivered() async throws {
        serveConnects([["news"]])

        let delegate = ClientDelegate()
        let subscribed = Expectation("subscribed")
        let published = Expectation("publication")
        delegate.onSub = { _ in subscribed.fulfill() }
        delegate.onPub = { event in
            #expect(event.channel == "news")
            #expect(event.data == Data("{\"hello\":\"world\"}".utf8))
            published.fulfill()
        }

        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        await fulfillment(of: subscribed, within: 5)

        server.publishChannel("news", Data("{\"hello\":\"world\"}".utf8))
        await fulfillment(of: published, within: 5)
    }
}
