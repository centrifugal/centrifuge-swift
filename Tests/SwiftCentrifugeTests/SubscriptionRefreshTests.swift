import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Tests for the periodic subscription-token refresh loop a subscription starts
/// when its subscribe result says the token expires. Driven over the wire against
/// the in-process `FakeCentrifugoServer`, and asserted through the subscription
/// delegate.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class SubscriptionRefreshTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: (() -> Void)?
        var onUnsub: (() -> Void)?
        var onErr: ((CentrifugeSubscriptionErrorEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?() }
        func onError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscriptionErrorEvent) { onErr?(e) }
    }

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        // Subscription token expires quickly, so the subscription starts
        // refreshing right after it is subscribed.
        server.onSubscribe = { _, _ in
            var r = FakeCentrifugoServer.PSubscribeResult()
            r.expires = true
            r.ttl = 1
            return r
        }
        try server.start()
    }

    deinit {
        server.stop()
    }

    private func makeSubscription(client: CentrifugeClient, delegate: SubDelegate) throws -> CentrifugeSubscription {
        var cfg = CentrifugeSubscriptionConfig()
        cfg.token = "initial"
        cfg.tokenGetter = { _, completion in completion(.success("refreshed-token")) }
        return try client.newSubscription(channel: "ch", delegate: delegate, config: cfg)
    }

    /// A temporary sub_refresh error is retried with backoff, and reported through
    /// onError as `subscriptionRefreshError` - the same way the connection-level
    /// refresh reports `refreshError`, and centrifuge-js emits a `refresh` error.
    @Test func temporaryRefreshErrorReportedAndRetried() async throws {
        let subscribed = Expectation("subscribed")
        let errored = Expectation("refresh error reported")
        let retried = Expectation("sub_refresh retried")
        retried.expectedFulfillmentCount = 2
        let unsubscribed = Expectation("unsubscribed")
        unsubscribed.isInverted = true

        let delegate = SubDelegate()
        delegate.onSub = { subscribed.fulfill() }
        delegate.onUnsub = { unsubscribed.fulfill() }
        delegate.onErr = { e in
            if case CentrifugeError.subscriptionRefreshError(let err) = e.error,
               case CentrifugeError.replyError(let code, _, true) = err, code == 100 {
                errored.fulfill()
            }
        }

        let calls = NSLock()
        var refreshCount = 0
        server.onCommand = { cmd in
            guard cmd.hasSubRefresh else { return nil }
            calls.lock(); refreshCount += 1; let n = refreshCount; calls.unlock()
            retried.fulfill()
            // Fail the first refresh with a temporary error, accept later ones.
            guard n == 1 else { return nil }
            var r = FakeCentrifugoServer.PReply()
            r.id = cmd.id
            r.error.code = 100
            r.error.message = "internal server error"
            r.error.temporary = true
            return r
        }

        let client = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        client.connect()
        defer { client.disconnect() }
        let sub = try makeSubscription(client: client, delegate: delegate)
        sub.subscribe()

        await fulfillment(of: subscribed, within: 5)
        await fulfillment(of: errored, within: 5)
        // The retry is scheduled with backoff(step: 0, min: 5, max: 10) seconds.
        await fulfillment(of: retried, within: 15)
        await fulfillment(of: unsubscribed, within: 0.5)
        #expect(sub.state == .subscribed)
    }

    /// A disconnect fails the pending sub_refresh with `clientDisconnected` while
    /// the subscription is still subscribed (processDisconnect resolves pending
    /// replies before moving subscriptions to subscribing). That is teardown, not
    /// a refresh failure, and must not surface as an error event.
    @Test func disconnectWithPendingRefreshIsNotReportedAsError() async throws {
        let subscribed = Expectation("subscribed")
        let refreshSent = Expectation("sub_refresh reached the server")
        let errored = Expectation("refresh error reported")
        errored.isInverted = true

        let delegate = SubDelegate()
        delegate.onSub = { subscribed.fulfill() }
        delegate.onErr = { e in
            if case CentrifugeError.subscriptionRefreshError = e.error { errored.fulfill() }
        }
        server.dropCommand = { cmd in
            guard cmd.hasSubRefresh else { return false }
            refreshSent.fulfill()
            return true
        }

        let client = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        client.connect()
        let sub = try makeSubscription(client: client, delegate: delegate)
        sub.subscribe()

        await fulfillment(of: subscribed, within: 5)
        await fulfillment(of: refreshSent, within: 5)
        client.disconnect()
        await fulfillment(of: errored, within: 1)
    }
}
