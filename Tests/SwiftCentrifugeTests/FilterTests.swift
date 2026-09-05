import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Tests for publication filtering (server-side filtering by publication tags).
/// The CentrifugeFilter builders construct a protocol FilterNode tree; the
/// subscribe request carries it in the `tf` field. The feature requires
/// Centrifugo PRO / namespace config, so wire-level behavior is exercised against
/// the in-process FakeCentrifugoServer.
///
/// Calling `setTagsFilter` from a delegate callback is covered by
/// ``ReentrancyTests`` along with the other re-entrancy regressions.
@Suite(.serialized)
final class FilterTests: @unchecked Sendable {

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: ((CentrifugeSubscribedEvent) -> Void)?
        var onUnsub: ((CentrifugeUnsubscribedEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?(e) }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?(e) }
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

    @Test func builderLeafAndLogicalNodes() {
        let eq = CentrifugeFilter.eq("ticker", "AAPL").node
        #expect(eq.key == "ticker")
        #expect(eq.cmp == "eq")
        #expect(eq.val == "AAPL")

        let inNode = CentrifugeFilter.inList("category", ["tech", "finance"]).node
        #expect(inNode.cmp == "in")
        #expect(inNode.vals == ["tech", "finance"])
        #expect(CentrifugeFilter.notInList("t", ["MSFT"]).node.cmp == "nin")

        #expect(CentrifugeFilter.exists("price").node.cmp == "ex")
        #expect(CentrifugeFilter.notExists("id").node.cmp == "nex")
        #expect(CentrifugeFilter.startsWith("t", "AA").node.cmp == "sw")
        #expect(CentrifugeFilter.endsWith("s", "Q").node.cmp == "ew")
        #expect(CentrifugeFilter.contains("c", "ec").node.cmp == "ct")
        #expect(CentrifugeFilter.gt("p", "1").node.cmp == "gt")
        #expect(CentrifugeFilter.gte("p", "1").node.cmp == "gte")
        #expect(CentrifugeFilter.lt("p", "1").node.cmp == "lt")
        #expect(CentrifugeFilter.lte("p", "1").node.cmp == "lte")

        let and = CentrifugeFilter.and([
            CentrifugeFilter.eq("ticker", "AAPL"),
            CentrifugeFilter.gte("price", "100"),
            CentrifugeFilter.inList("source", ["NASDAQ", "NYSE"]),
        ]).node
        #expect(and.op == "and")
        #expect(and.nodes.count == 3)
        #expect(and.nodes[0].key == "ticker")
        #expect(and.nodes[2].cmp == "in")

        let or = CentrifugeFilter.or([CentrifugeFilter.eq("a", "1"), CentrifugeFilter.eq("b", "2")]).node
        #expect(or.op == "or")
        #expect(or.nodes.count == 2)

        let not = CentrifugeFilter.not(CentrifugeFilter.eq("s", "NYSE")).node
        #expect(not.op == "not")
        #expect(not.nodes.count == 1)
        #expect(not.nodes[0].cmp == "eq")
    }

    @Test func subscribeRequestCarriesTagsFilter() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = Expectation("subscribed")
        d.onSub = { _ in subscribed.fulfill() }
        let cfg = CentrifugeSubscriptionConfig(tagsFilter: CentrifugeFilter.and([
            CentrifugeFilter.eq("ticker", "AAPL"),
            CentrifugeFilter.gte("price", "100"),
        ]))
        let sub = try client.newSubscription(channel: "market", delegate: d, config: cfg)
        sub.subscribe()
        wait(for: subscribed, timeout: 5)

        let tf = try #require(server.lastSubscribe()?.tf)
        #expect(tf.op == "and")
        #expect(tf.nodes.count == 2)
        #expect(tf.nodes[0].key == "ticker")
        #expect(tf.nodes[0].cmp == "eq")
        #expect(tf.nodes[0].val == "AAPL")
        #expect(tf.nodes[1].cmp == "gte")
    }

    @Test func setTagsFilterAppliesOnSubscribe() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = Expectation("subscribed")
        d.onSub = { _ in subscribed.fulfill() }
        let sub = try client.newSubscription(channel: "market", delegate: d)
        try sub.setTagsFilter(CentrifugeFilter.eq("ticker", "BTC"))
        sub.subscribe()
        wait(for: subscribed, timeout: 5)

        let tf = try #require(server.lastSubscribe()?.tf)
        #expect(tf.key == "ticker")
        #expect(tf.val == "BTC")
    }

    @Test func subscribeWithoutFilterSendsNoTf() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = Expectation("subscribed")
        d.onSub = { _ in subscribed.fulfill() }
        let sub = try client.newSubscription(channel: "market", delegate: d)
        sub.subscribe()
        wait(for: subscribed, timeout: 5)

        #expect(!(server.lastSubscribe()?.hasTf ?? true))
    }

    @Test func deltaAndTagsFilterCannotCombine() throws {
        let client = makeClient()
        let cfg = CentrifugeSubscriptionConfig(delta: .fossil, tagsFilter: CentrifugeFilter.eq("a", "1"))
        #expect(throws: (any Error).self) {
            try client.newSubscription(channel: "market", delegate: SubDelegate(), config: cfg)
        }

        let sub = try client.newSubscription(channel: "market2", delegate: SubDelegate(),
                                             config: CentrifugeSubscriptionConfig(delta: .fossil))
        #expect(throws: (any Error).self) {
            try sub.setTagsFilter(CentrifugeFilter.eq("a", "1"))
        }
    }
}
