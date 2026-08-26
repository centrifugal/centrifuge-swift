import XCTest
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// End-to-end tests for fossil delta compression on a subscription: the subscribe
/// result negotiates `delta`, and publications marked as deltas are applied to the
/// previously received value. Delta compression requires server configuration, so
/// the in-process `FakeCentrifugoServer` is used; the delta payloads come from the
/// same testdata as `DeltaFossilTests`.
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter DeltaPublicationTests
final class DeltaPublicationTests: XCTestCase {

    private final class SubDelegate: CentrifugeSubscriptionDelegate {
        var onSub: (() -> Void)?
        var onPub: ((CentrifugePublicationEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
        func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) { onPub?(e) }
    }

    private var server: FakeCentrifugoServer!

    override func setUpWithError() throws {
        server = FakeCentrifugoServer()
        // Negotiate delta compression for every subscription.
        server.onSubscribe = { _, _ in
            var res = FakeCentrifugoServer.PSubscribeResult()
            res.delta = true
            return res
        }
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    /// Subscribe to "ch" with fossil delta enabled and return the subscription.
    private func subscribe(_ client: CentrifugeClient, _ delegate: SubDelegate) throws -> CentrifugeSubscription {
        let subscribed = expectation(description: "subscribed")
        delegate.onSub = { subscribed.fulfill() }
        let sub = try client.newSubscription(
            channel: "ch",
            delegate: delegate,
            config: CentrifugeSubscriptionConfig(delta: .fossil)
        )
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        return sub
    }

    private func fossilCase(_ number: Int, _ fileName: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.resourceURL)
            .appendingPathComponent("testdata/fossil/\(number)/\(fileName)")
        return try Data(contentsOf: url)
    }

    func testDeltaPublicationApplied() throws {
        let origin = try fossilCase(1, "origin")
        let deltaPayload = try fossilCase(1, "delta")
        let target = try fossilCase(1, "target")

        let client = CentrifugeClient(endpoint: server.url, config: CentrifugeClientConfig())
        client.connect()
        defer { client.disconnect() }

        let delegate = SubDelegate()
        _ = try subscribe(client, delegate)
        XCTAssertEqual(server.lastSubscribe()?.delta, "fossil")

        let received = expectation(description: "two publications")
        received.expectedFulfillmentCount = 2
        var payloads = [Data]()
        delegate.onPub = { event in
            payloads.append(event.data)
            received.fulfill()
        }

        // Full value first, then a delta from it.
        server.publishChannel("ch", origin)
        server.publishChannel("ch", deltaPayload, delta: true)
        wait(for: [received], timeout: 5)

        XCTAssertEqual(payloads, [origin, target], "delta publication must be applied to the previous value")
    }
}
