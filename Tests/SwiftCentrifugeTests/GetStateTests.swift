import XCTest
@testable import SwiftCentrifuge

/// Integration tests for CentrifugeSubscriptionConfig.stateGetter (getState).
/// These mirror the getState tests in other Centrifugal SDKs and require the
/// docker-compose Centrifugo (>= 6.8.0) running on localhost:8000:
///
///     docker compose up -d
///     swift test --filter GetStateTests
final class GetStateTests: XCTestCase {

    private static let endpoint = "ws://localhost:8000/connection/websocket"

    private final class TestSubDelegate: CentrifugeSubscriptionDelegate {
        var onSubscribedHandler: ((CentrifugeSubscribedEvent) -> Void)?
        var onPublicationHandler: ((CentrifugePublicationEvent) -> Void)?
        var onErrorHandler: ((CentrifugeSubscriptionErrorEvent) -> Void)?

        func onSubscribed(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribedEvent) {
            onSubscribedHandler?(event)
        }
        func onPublication(_ sub: CentrifugeSubscription, _ event: CentrifugePublicationEvent) {
            onPublicationHandler?(event)
        }
        func onError(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionErrorEvent) {
            onErrorHandler?(event)
        }
    }

    /// Thread-safe counter — getState/delegate callbacks fire on SDK queues.
    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return count
        }
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    private func newClient() -> CentrifugeClient {
        CentrifugeClient(endpoint: GetStateTests.endpoint, config: CentrifugeClientConfig())
    }

    private func uniqueChannel(_ namespace: String = "") -> String {
        let name = "get_state_" + UUID().uuidString.prefix(8)
        return namespace.isEmpty ? name : namespace + ":" + name
    }

    private func payload(_ i: Int) -> Data {
        return "{\"i\":\(i)}".data(using: .utf8)!
    }

    private func publish(_ client: CentrifugeClient, _ channel: String, _ data: Data) {
        let exp = expectation(description: "publish")
        client.publish(channel: channel, data: data) { result in
            if case .failure(let err) = result {
                XCTFail("publish failed: \(err)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    func testGetStateCalledOnInitialSubscribeAndRecovers() throws {
        let channel = uniqueChannel()

        // Publish 3 messages BEFORE subscribing.
        let publisher = newClient()
        publisher.connect()
        defer { publisher.disconnect() }
        for i in 1...3 {
            publish(publisher, channel, payload(i))
        }

        let client = newClient()
        client.connect()
        defer { client.disconnect() }

        let getStateCalls = Counter()
        // The state getter returns zero position — recovery delivers all 3 publications.
        let config = CentrifugeSubscriptionConfig(stateGetter: { _, completion in
            _ = getStateCalls.increment()
            completion(.success(CentrifugeStreamPosition(offset: 0, epoch: "")))
        })

        let subscribed = expectation(description: "subscribed")
        let pubs = expectation(description: "3 recovered publications")
        pubs.expectedFulfillmentCount = 3

        let delegate = TestSubDelegate()
        delegate.onSubscribedHandler = { _ in subscribed.fulfill() }
        delegate.onPublicationHandler = { _ in pubs.fulfill() }

        let sub = try client.newSubscription(channel: channel, delegate: delegate, config: config)
        sub.subscribe()

        wait(for: [subscribed, pubs], timeout: 5)
        XCTAssertEqual(getStateCalls.value, 1)
    }

    func testGetStateNotCalledWhenRecoverySucceeds() throws {
        let channel = uniqueChannel()

        let publisher = newClient()
        publisher.connect()
        defer { publisher.disconnect() }

        let client = newClient()
        client.connect()
        defer { client.disconnect() }

        let getStateCalls = Counter()
        let config = CentrifugeSubscriptionConfig(stateGetter: { _, completion in
            _ = getStateCalls.increment()
            completion(.success(CentrifugeStreamPosition(offset: 0, epoch: "")))
        })

        let subscribed = expectation(description: "subscribed")
        let delegate = TestSubDelegate()
        delegate.onSubscribedHandler = { _ in subscribed.fulfill() }

        let sub = try client.newSubscription(channel: channel, delegate: delegate, config: config)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        XCTAssertEqual(getStateCalls.value, 1)

        // Disconnect, publish while away, reconnect — SDK has a saved position
        // and recovery succeeds, so the state getter must NOT be called again.
        client.disconnect()

        publish(publisher, channel, payload(1))
        publish(publisher, channel, payload(2))

        let resubscribed = expectation(description: "resubscribed with recovery")
        let recoveredPubs = expectation(description: "2 recovered publications")
        recoveredPubs.expectedFulfillmentCount = 2
        delegate.onSubscribedHandler = { event in
            XCTAssertTrue(event.recovered, "expected successful recovery on reconnect")
            resubscribed.fulfill()
        }
        delegate.onPublicationHandler = { _ in recoveredPubs.fulfill() }

        client.connect()
        wait(for: [resubscribed, recoveredPubs], timeout: 5)
        XCTAssertEqual(getStateCalls.value, 1, "state getter must not be called when recovery succeeds")
    }

    func testGetStateErrorRetried() throws {
        let channel = uniqueChannel()

        let client = newClient()
        client.connect()
        defer { client.disconnect() }

        struct SimulatedError: Error {}

        let getStateCalls = Counter()
        // First state getter call fails, second succeeds.
        var config = CentrifugeSubscriptionConfig(stateGetter: { _, completion in
            if getStateCalls.increment() == 1 {
                completion(.failure(SimulatedError()))
                return
            }
            completion(.success(CentrifugeStreamPosition(offset: 0, epoch: "")))
        })
        config.minResubscribeDelay = 0.05
        config.maxResubscribeDelay = 0.05

        let subscribed = expectation(description: "subscribed after retry")
        let gotGetStateError = expectation(description: "subscriptionGetStateError event")

        let delegate = TestSubDelegate()
        delegate.onSubscribedHandler = { _ in subscribed.fulfill() }
        delegate.onErrorHandler = { event in
            if case CentrifugeError.subscriptionGetStateError(let err) = event.error {
                XCTAssertTrue(err is SimulatedError)
                gotGetStateError.fulfill()
            }
        }

        let sub = try client.newSubscription(channel: channel, delegate: delegate, config: config)
        sub.subscribe()

        // First getter call fails → error emitted → resubscribe scheduled with
        // backoff. Second call succeeds → subscribe completes.
        wait(for: [gotGetStateError, subscribed], timeout: 5)
        XCTAssertGreaterThanOrEqual(getStateCalls.value, 2)
    }

    func testGetStatePersistentFailureKeepsRetrying() throws {
        let channel = uniqueChannel()

        let client = newClient()
        client.connect()
        defer { client.disconnect() }

        struct AlwaysFails: Error {}

        let getStateCalls = Counter()
        var config = CentrifugeSubscriptionConfig(stateGetter: { _, completion in
            _ = getStateCalls.increment()
            completion(.failure(AlwaysFails()))
        })
        config.minResubscribeDelay = 0.05
        config.maxResubscribeDelay = 0.05

        let sub = try client.newSubscription(channel: channel, delegate: TestSubDelegate(), config: config)
        sub.subscribe()

        // Wait for several retry cycles.
        let waited = expectation(description: "retry cycles")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { waited.fulfill() }
        wait(for: [waited], timeout: 5)

        // Should have retried multiple times while staying in subscribing state.
        XCTAssertGreaterThan(getStateCalls.value, 2)
        XCTAssertEqual(sub.state, .subscribing)

        sub.unsubscribe()
    }

    func testGetStateCalledAgainOnUnrecoverablePosition() throws {
        // Uses "smallhistory" namespace with history_size=2. After publishing
        // enough to evict old entries, reconnecting from an old position triggers
        // error 112 (unrecoverable position) because the subscribe request carries
        // the reject_unrecovered flag. The SDK must then call the state getter
        // again to reload app state instead of delivering recovered=false on an
        // active subscription.
        let channel = uniqueChannel("smallhistory")

        // Publisher client: used both to publish and to read the current stream
        // top position via history (as the app's backend would).
        let publisher = newClient()
        publisher.connect()
        defer { publisher.disconnect() }

        let client = newClient()
        client.connect()
        defer { client.disconnect() }

        let getStateCalls = Counter()
        var config = CentrifugeSubscriptionConfig(stateGetter: { event, completion in
            _ = getStateCalls.increment()
            publisher.history(channel: event.channel, limit: 0) { result in
                switch result {
                case .success(let history):
                    completion(.success(CentrifugeStreamPosition(offset: history.offset, epoch: history.epoch)))
                case .failure(let err):
                    completion(.failure(err))
                }
            }
        })
        config.minResubscribeDelay = 0.05
        config.maxResubscribeDelay = 0.05

        let subscribed = expectation(description: "subscribed")
        let delegate = TestSubDelegate()
        delegate.onSubscribedHandler = { _ in subscribed.fulfill() }

        let sub = try client.newSubscription(channel: channel, delegate: delegate, config: config)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        XCTAssertEqual(getStateCalls.value, 1)

        // Disconnect, then publish enough messages to push the stream beyond
        // recovery (history_size=2, so 5 messages evict old entries).
        client.disconnect()
        for i in 1...5 {
            publish(publisher, channel, payload(i))
        }

        // Reconnect — SDK tries to recover from the old position, server returns
        // error 112, SDK resets position and calls the state getter again.
        let resubscribed = expectation(description: "resubscribed after unrecoverable position")
        delegate.onSubscribedHandler = { _ in resubscribed.fulfill() }

        client.connect()
        wait(for: [resubscribed], timeout: 5)
        XCTAssertEqual(getStateCalls.value, 2, "state getter must be called again after unrecoverable position")

        // Verify live delivery works after the re-sync.
        let livePub = expectation(description: "live publication after re-sync")
        delegate.onPublicationHandler = { event in
            if event.data == "{\"live\":true}".data(using: .utf8)! {
                livePub.fulfill()
            }
        }
        publish(publisher, channel, "{\"live\":true}".data(using: .utf8)!)
        wait(for: [livePub], timeout: 5)
    }
}
