import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// removeSubscription() removes that subscription only, and a removed
/// subscription can't subscribe again.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class RemoveSubscriptionTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        let lock = NSLock()
        var errors: [Error] = []
        var onSub: (() -> Void)?
        var onUnsub: (() -> Void)?
        var onErr: (() -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?() }
        func onError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscriptionErrorEvent) {
            lock.lock(); errors.append(e.error); lock.unlock()
            onErr?()
        }
        var errorList: [Error] { lock.lock(); defer { lock.unlock() }; return errors }
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

    /// Removing a subscription a second time, after a new subscription of the same
    /// channel was created, leaves the new one alone.
    @Test func removingStaleSubscriptionKeepsNewerOne() async throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }

        let old = try client.newSubscription(channel: "ch", delegate: SubDelegate())
        client.removeSubscription(old)

        let subscribed = Expectation("new subscription subscribed")
        let unsubscribed = Expectation("new subscription unsubscribed")
        unsubscribed.isInverted = true
        let d = SubDelegate()
        d.onSub = { subscribed.fulfill() }
        d.onUnsub = { unsubscribed.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)

        client.removeSubscription(old)
        await fulfillment(of: unsubscribed, within: 0.5)
        #expect(client.getSubscription(channel: "ch") === sub)
        #expect(sub.state == .subscribed)
    }

    /// subscribe() on a removed subscription reports an error and does nothing: the
    /// client would not route anything to it.
    @Test func removedSubscriptionCannotSubscribe() async throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }

        let errored = Expectation("configuration error")
        let d = SubDelegate()
        d.onErr = { errored.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        client.removeSubscription(sub)
        sub.subscribe()

        await fulfillment(of: errored, within: 3)
        #expect(d.errorList.contains { if case CentrifugeError.configurationError = $0 { return true }; return false })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(sub.state == .unsubscribed)
        #expect(server.received().filter(\.hasSubscribe).isEmpty)
    }
}
