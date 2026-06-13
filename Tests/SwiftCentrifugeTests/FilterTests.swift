import XCTest
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// Tests for publication filtering (server-side filtering by publication tags).
/// The CentrifugeFilter builders construct a protocol FilterNode tree; the
/// subscribe request carries it in the `tf` field. The feature requires
/// Centrifugo PRO / namespace config, so wire-level behavior is exercised against
/// the in-process FakeCentrifugoServer.
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter FilterTests
final class FilterTests: XCTestCase {

    private final class SubDelegate: CentrifugeSubscriptionDelegate {
        var onSub: ((CentrifugeSubscribedEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?(e) }
    }

    private var server: FakeCentrifugoServer!

    override func setUpWithError() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    private func makeClient() -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: server.url, config: cfg)
    }

    func testBuilderLeafAndLogicalNodes() {
        let eq = CentrifugeFilter.eq("ticker", "AAPL").node
        XCTAssertEqual(eq.key, "ticker")
        XCTAssertEqual(eq.cmp, "eq")
        XCTAssertEqual(eq.val, "AAPL")

        let inNode = CentrifugeFilter.inList("category", ["tech", "finance"]).node
        XCTAssertEqual(inNode.cmp, "in")
        XCTAssertEqual(inNode.vals, ["tech", "finance"])
        XCTAssertEqual(CentrifugeFilter.notInList("t", ["MSFT"]).node.cmp, "nin")

        XCTAssertEqual(CentrifugeFilter.exists("price").node.cmp, "ex")
        XCTAssertEqual(CentrifugeFilter.notExists("id").node.cmp, "nex")
        XCTAssertEqual(CentrifugeFilter.startsWith("t", "AA").node.cmp, "sw")
        XCTAssertEqual(CentrifugeFilter.endsWith("s", "Q").node.cmp, "ew")
        XCTAssertEqual(CentrifugeFilter.contains("c", "ec").node.cmp, "ct")
        XCTAssertEqual(CentrifugeFilter.gt("p", "1").node.cmp, "gt")
        XCTAssertEqual(CentrifugeFilter.gte("p", "1").node.cmp, "gte")
        XCTAssertEqual(CentrifugeFilter.lt("p", "1").node.cmp, "lt")
        XCTAssertEqual(CentrifugeFilter.lte("p", "1").node.cmp, "lte")

        let and = CentrifugeFilter.and([
            CentrifugeFilter.eq("ticker", "AAPL"),
            CentrifugeFilter.gte("price", "100"),
            CentrifugeFilter.inList("source", ["NASDAQ", "NYSE"]),
        ]).node
        XCTAssertEqual(and.op, "and")
        XCTAssertEqual(and.nodes.count, 3)
        XCTAssertEqual(and.nodes[0].key, "ticker")
        XCTAssertEqual(and.nodes[2].cmp, "in")

        let or = CentrifugeFilter.or([CentrifugeFilter.eq("a", "1"), CentrifugeFilter.eq("b", "2")]).node
        XCTAssertEqual(or.op, "or")
        XCTAssertEqual(or.nodes.count, 2)

        let not = CentrifugeFilter.not(CentrifugeFilter.eq("s", "NYSE")).node
        XCTAssertEqual(not.op, "not")
        XCTAssertEqual(not.nodes.count, 1)
        XCTAssertEqual(not.nodes[0].cmp, "eq")
    }

    func testSubscribeRequestCarriesTagsFilter() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        d.onSub = { _ in subscribed.fulfill() }
        let cfg = CentrifugeSubscriptionConfig(tagsFilter: CentrifugeFilter.and([
            CentrifugeFilter.eq("ticker", "AAPL"),
            CentrifugeFilter.gte("price", "100"),
        ]))
        let sub = try client.newSubscription(channel: "market", delegate: d, config: cfg)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)

        let tf = try XCTUnwrap(server.lastSubscribe()?.tf)
        XCTAssertEqual(tf.op, "and")
        XCTAssertEqual(tf.nodes.count, 2)
        XCTAssertEqual(tf.nodes[0].key, "ticker")
        XCTAssertEqual(tf.nodes[0].cmp, "eq")
        XCTAssertEqual(tf.nodes[0].val, "AAPL")
        XCTAssertEqual(tf.nodes[1].cmp, "gte")
    }

    func testSetTagsFilterAppliesOnSubscribe() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        d.onSub = { _ in subscribed.fulfill() }
        let sub = try client.newSubscription(channel: "market", delegate: d)
        try sub.setTagsFilter(CentrifugeFilter.eq("ticker", "BTC"))
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)

        let tf = try XCTUnwrap(server.lastSubscribe()?.tf)
        XCTAssertEqual(tf.key, "ticker")
        XCTAssertEqual(tf.val, "BTC")
    }

    func testSubscribeWithoutFilterSendsNoTf() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        d.onSub = { _ in subscribed.fulfill() }
        let sub = try client.newSubscription(channel: "market", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)

        XCTAssertFalse(server.lastSubscribe()?.hasTf ?? true)
    }

    func testDeltaAndTagsFilterCannotCombine() throws {
        let client = makeClient()
        let cfg = CentrifugeSubscriptionConfig(delta: .fossil, tagsFilter: CentrifugeFilter.eq("a", "1"))
        XCTAssertThrowsError(try client.newSubscription(channel: "market", delegate: SubDelegate(), config: cfg))

        let sub = try client.newSubscription(channel: "market2", delegate: SubDelegate(),
                                             config: CentrifugeSubscriptionConfig(delta: .fossil))
        XCTAssertThrowsError(try sub.setTagsFilter(CentrifugeFilter.eq("a", "1")))
    }
}
