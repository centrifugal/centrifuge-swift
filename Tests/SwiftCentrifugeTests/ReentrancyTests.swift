import Foundation
import Testing
@testable import SwiftCentrifuge

/// Delegate callbacks are invoked inline on the client's internal serial
/// syncQueue - that is what gives the transport its backpressure, and it is not
/// going to change. The cost is that any handler can re-enter the SDK, so every
/// public entry point must be safe to call from one: no `syncQueue.sync`, and no
/// callout made while holding `subscriptionsLock` (a non-recursive NSLock).
///
/// These tests pin that contract down. Each one hangs forever if the invariant
/// breaks, so they run with a hard deadline rather than relying on the suite
/// timing out.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReentrancyTests {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: ((CentrifugeSubscription) -> Void)?
        var onSubscribing: ((CentrifugeSubscription) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?(s) }
        func onSubscribing(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribingEvent) { onSubscribing?(s) }
    }

    private func makeClient(_ server: FakeCentrifugoServer) -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: server.url, config: cfg)
    }

    /// Regression: `processDisconnect` used to hold `subscriptionsLock` across
    /// `moveToSubscribingUponDisconnect`, which emits `onSubscribing`. A handler
    /// calling `getSubscription` then re-took that non-recursive lock on the same
    /// thread and deadlocked the client on every transport drop.
    @Test func registryAccessFromOnSubscribingSurvivesReconnect() async throws {
        let server = FakeCentrifugoServer()
        try server.start()
        defer { server.stop() }

        let client = makeClient(server)
        defer { client.disconnect() }
        let d = SubDelegate()
        let sub = try client.newSubscription(channel: "market", delegate: d)

        let firstSubscribe = Expectation("firstSubscribe")
        let sawSubscribing = Expectation("sawSubscribing")
        let resubscribed = Expectation("resubscribed")
        var lookedUpChannel: String?
        var registrySize = -1

        var subscribedCount = 0
        d.onSub = { _ in
            subscribedCount += 1
            if subscribedCount == 1 { firstSubscribe.fulfill() } else { resubscribed.fulfill() }
        }
        d.onSubscribing = { [weak client] _ in
            // The re-entrant calls under test. Both take subscriptionsLock.
            lookedUpChannel = client?.getSubscription(channel: "market")?.channel
            registrySize = client?.getSubscriptions().count ?? -1
            sawSubscribing.fulfill()
        }

        client.connect()
        sub.subscribe()
        await fulfillment(of: firstSubscribe, within: 5)  // "initial subscribe timed out"

        // Drop the transport: the client moves subscriptions back to .subscribing
        // and emits onSubscribing while it used to hold the registry lock.
        server.closeConnection()
        await fulfillment(of: sawSubscribing, within: 5)  // "onSubscribing never arrived - client deadlocked on subscriptionsLock"
        #expect(lookedUpChannel == "market")
        #expect(registrySize == 1)

        // The client must still be alive and able to complete a resubscribe.
        await fulfillment(of: resubscribed, within: 10)  // "client did not resubscribe after reconnect"
    }

    /// Regression: `setTagsFilter` hopped onto syncQueue with `sync`, so calling
    /// it from a callback already running on syncQueue deadlocked the client for
    /// good.
    @Test func setTagsFilterFromDelegateCallbackDoesNotDeadlock() async throws {
        let server = FakeCentrifugoServer()
        try server.start()
        defer { server.stop() }

        let client = makeClient(server)
        defer { client.disconnect() }
        let d = SubDelegate()
        let sub = try client.newSubscription(channel: "market", delegate: d)

        let applied = Expectation("applied")
        d.onSub = { s in
            try? s.setTagsFilter(CentrifugeFilter.eq("ticker", "BTC"))
            applied.fulfill()
        }

        client.connect()
        sub.subscribe()
        await fulfillment(of: applied, within: 5)  // "setTagsFilter deadlocked the client's syncQueue"

        // Queue still alive, and the filter reached the next subscribe.
        let resubscribed = Expectation("resubscribed")
        d.onSub = { _ in resubscribed.fulfill() }
        sub.unsubscribe()
        sub.subscribe()
        await fulfillment(of: resubscribed, within: 5)  // "client stopped processing after setTagsFilter"

        let tf = try #require(server.lastSubscribe()?.tf)
        #expect(tf.key == "ticker")
        #expect(tf.val == "BTC")
    }

    /// `syncQueue.sync` is a deadlock waiting to happen: delegate callbacks run
    /// on that queue, so any public method using it wedges the client when called
    /// from a handler. Nothing in the library may use it.
    @Test func libraryNeverUsesSyncQueueSync() throws {
        // …/Tests/SwiftCentrifugeTests/ReentrancyTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/SwiftCentrifuge")

        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "no sources found under \(sources.path)")

        for file in files {
            for (i, line) in try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                let code = line.components(separatedBy: "//")[0]
                if code.contains("syncQueue.sync") {
                    offenders.append("\(file.lastPathComponent):\(i + 1):\(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "syncQueue.sync deadlocks when called from a delegate callback; use async:\n\(offenders.joined(separator: "\n"))")
    }
}
