import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// End-to-end tests for fossil delta compression on a subscription: the subscribe
/// result negotiates `delta`, and publications marked as deltas are applied to the
/// previously received value. Delta compression requires server configuration, so
/// the in-process `FakeCentrifugoServer` is used; the delta payloads come from the
/// same testdata as `DeltaFossilTests`.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class DeltaPublicationTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: (() -> Void)?
        var onPub: ((CentrifugePublicationEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
        func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) { onPub?(e) }
    }

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        // Negotiate delta compression for every subscription.
        server.onSubscribe = { _, _ in
            var res = FakeCentrifugoServer.PSubscribeResult()
            res.delta = true
            return res
        }
        try server.start()
    }

    deinit {
        server.stop()
    }

    /// Subscribe to "ch" with fossil delta enabled and return the subscription.
    private func subscribe(_ client: CentrifugeClient, _ delegate: SubDelegate) async throws -> CentrifugeSubscription {
        let subscribed = Expectation("subscribed")
        delegate.onSub = { subscribed.fulfill() }
        let sub = try client.newSubscription(
            channel: "ch",
            delegate: delegate,
            config: CentrifugeSubscriptionConfig(delta: .fossil)
        )
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)
        return sub
    }

    private func fossilCase(_ number: Int, _ fileName: String) throws -> Data {
        let url = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("testdata/fossil/\(number)/\(fileName)")
        return try Data(contentsOf: url)
    }

    @Test func deltaPublicationApplied() async throws {
        let origin = try fossilCase(1, "origin")
        let deltaPayload = try fossilCase(1, "delta")
        let target = try fossilCase(1, "target")

        let client = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        client.connect()
        defer { client.disconnect() }

        let delegate = SubDelegate()
        _ = try await subscribe(client, delegate)
        #expect(server.lastSubscribe()?.delta == "fossil")

        let received = Expectation("two publications")
        received.expectedFulfillmentCount = 2
        // Written on the client's queue, read here after `wait` — the wait's lock
        // provides the necessary happens-before.
        var payloads = [Data]()
        delegate.onPub = { event in
            payloads.append(event.data)
            received.fulfill()
        }

        // Full value first, then a delta from it.
        server.publishChannel("ch", origin)
        server.publishChannel("ch", deltaPayload, delta: true)
        await fulfillment(of: received, within: 5)

        #expect(payloads == [origin, target], "delta publication must be applied to the previous value")
    }
}
