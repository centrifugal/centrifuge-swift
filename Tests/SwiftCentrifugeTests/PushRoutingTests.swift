import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Pushes (publications, joins, leaves, unsubscribes) are applied to a client-side
/// subscription only while it is subscribed. Otherwise they belong to a server-side
/// subscription of the channel, if the connection has one, or are dropped.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class PushRoutingTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: (() -> Void)?
        var onPub: ((CentrifugePublicationEvent) -> Void)?
        var onUnsub: ((CentrifugeUnsubscribedEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
        func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) { onPub?(e) }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?(e) }
    }

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        var onConn: (() -> Void)?
        var onPub: ((CentrifugeServerPublicationEvent) -> Void)?
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) { onConn?() }
        func onPublication(_ c: CentrifugeClient, _ e: CentrifugeServerPublicationEvent) { onPub?(e) }
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

    private func unsubscribePush(_ channel: String, _ code: UInt32) -> FakeCentrifugoServer.PPush {
        var u = Centrifugal_Centrifuge_Protocol_Unsubscribe()
        u.code = code
        u.reason = "server unsubscribe"
        var push = FakeCentrifugoServer.PPush()
        push.channel = channel
        push.unsubscribe = u
        return push
    }

    /// A publication for a subscription whose subscribe reply has not arrived yet
    /// is not delivered: it is not part of the stream the subscribe reply starts.
    @Test func publicationWhileSubscribingNotDelivered() async throws {
        server.dropCommand = { cmd in cmd.hasSubscribe }
        let connected = Expectation("connected")
        let delegate = ClientDelegate()
        delegate.onConn = { connected.fulfill() }
        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        await fulfillment(of: connected, within: 5)

        let published = Expectation("publication while subscribing")
        published.isInverted = true
        let d = SubDelegate()
        d.onPub = { _ in published.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        #expect(await waitUntil(3) { self.server.lastSubscribe() != nil })

        server.publishChannel("ch", Data("{}".utf8))
        await fulfillment(of: published, within: 0.5)
        #expect(sub.state == .subscribing)
    }

    /// After `unsubscribe()`, publications the server sent before it processed the
    /// unsubscribe command are not delivered.
    @Test func publicationAfterUnsubscribeNotDelivered() async throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }

        let subscribed = Expectation("subscribed")
        let unsubscribed = Expectation("unsubscribed")
        let published = Expectation("publication after unsubscribe")
        published.isInverted = true
        let d = SubDelegate()
        d.onSub = { subscribed.fulfill() }
        d.onUnsub = { _ in unsubscribed.fulfill() }
        d.onPub = { _ in published.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)

        sub.unsubscribe()
        await fulfillment(of: unsubscribed, within: 5)
        server.publishChannel("ch", Data("{}".utf8))
        await fulfillment(of: published, within: 0.5)
    }

    /// An unsubscribe push that arrives while a new subscribe is in flight is for
    /// the previous subscription: it does not end the new attempt.
    @Test func unsubscribePushWhileSubscribingIgnored() async throws {
        server.dropCommand = { cmd in cmd.hasSubscribe }
        let connected = Expectation("connected")
        let delegate = ClientDelegate()
        delegate.onConn = { connected.fulfill() }
        let client = makeClient(delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        await fulfillment(of: connected, within: 5)

        let unsubscribed = Expectation("unsubscribed by a stale push")
        unsubscribed.isInverted = true
        let d = SubDelegate()
        d.onUnsub = { _ in unsubscribed.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        #expect(await waitUntil(3) { self.server.lastSubscribe() != nil })

        server.sendPush(unsubscribePush("ch", 2000))
        await fulfillment(of: unsubscribed, within: 0.5)
        #expect(sub.state == .subscribing)
    }

    /// While the client-side subscription of a channel is not subscribed, the
    /// publications of a server-side subscription to the same channel reach the
    /// client delegate instead of being swallowed by the client-side object.
    @Test func serverSubPublicationsNotTakenByUnsubscribedClientSub() async throws {
        server.onCommand = { cmd in
            guard cmd.hasConnect else { return nil }
            var result = FakeCentrifugoServer.PConnectResult()
            result.client = "fake-client"
            result.subs = ["ch": FakeCentrifugoServer.PSubscribeResult()]
            var reply = FakeCentrifugoServer.PReply()
            reply.id = cmd.id
            reply.connect = result
            return reply
        }
        let connected = Expectation("connected")
        let serverPub = Expectation("server-side publication")
        let clientPub = Expectation("publication on the unsubscribed client-side subscription")
        clientPub.isInverted = true
        let delegate = ClientDelegate()
        delegate.onConn = { connected.fulfill() }
        delegate.onPub = { _ in serverPub.fulfill() }
        let client = makeClient(delegate: delegate)
        let d = SubDelegate()
        d.onPub = { _ in clientPub.fulfill() }
        _ = try client.newSubscription(channel: "ch", delegate: d)
        client.connect()
        defer { client.disconnect() }
        await fulfillment(of: connected, within: 5)

        server.publishChannel("ch", Data("{}".utf8))
        await fulfillment(of: [serverPub, clientPub], within: 1)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
