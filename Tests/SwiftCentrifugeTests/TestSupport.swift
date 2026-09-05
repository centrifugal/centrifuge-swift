import Foundation
import Testing

/// swift-testing has no `XCTestExpectation`, and nothing in the framework fills
/// the gap: `confirmation(...)` counts callbacks inside a scope but does not wait
/// for them (it checks the count when its body returns), and `.timeLimit()` is a
/// per-test backstop restricted to whole minutes. The upstream proposal to give
/// `confirmation` a timeout — swiftlang/swift-testing#789 — is still unmerged,
/// and the related issue #978 was closed as not planned. So the waiting
/// primitive has to live here.
///
/// The documented way to bridge a callback API to a test is a continuation, and
/// that is what this uses. The important part is that it **suspends** rather than
/// blocks: swift-testing runs even synchronous `@Test` bodies inside a Task on
/// the cooperative thread pool, whose width is the core count, so blocking there
/// (as an NSCondition-based version did) starves the pool on a small CI machine.
///
/// `fulfillment(of:within:)` mirrors the name XCTest itself adopted for its async
/// replacement, so call sites read the way the framework's own do.
final class Expectation: @unchecked Sendable {
    let description: String

    /// Number of `fulfill()` calls that count as satisfied. Set before awaiting.
    var expectedFulfillmentCount: Int = 1

    /// When true the expectation must NOT be fulfilled: the wait runs for the
    /// full timeout and reports an issue if it fired. Mirrors
    /// `XCTestExpectation.isInverted`.
    var isInverted: Bool = false

    private let lock = NSLock()
    private var count = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Fires timeouts. A queue, not a Task, so a timeout cannot itself be delayed
    /// by a saturated cooperative pool.
    private static let timers = DispatchQueue(label: "com.centrifugal.tests.expectation-timers")

    init(_ description: String) {
        self.description = description
    }

    /// Safe to call from any thread, any number of times.
    func fulfill() {
        var toResume: [CheckedContinuation<Bool, Never>] = []
        lock.lock()
        count += 1
        if count >= expectedFulfillmentCount {
            toResume = Array(waiters.values)
            waiters.removeAll()
        }
        lock.unlock()
        for continuation in toResume { continuation.resume(returning: true) }
    }

    var fulfillmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    fileprivate var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count >= expectedFulfillmentCount
    }

    /// Suspends until satisfied or `timeout` elapses; returns whether it was
    /// satisfied. Removing the waiter under the lock is what guarantees the
    /// continuation is resumed exactly once, whichever of fulfil/timeout wins —
    /// a checked continuation traps on a second resume, and these delegates do
    /// fire again (`onSubscribed` repeats on every resubscribe).
    fileprivate func awaitSatisfied(within timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let id = UUID()
            lock.lock()
            if count >= expectedFulfillmentCount {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            waiters[id] = continuation
            lock.unlock()

            Expectation.timers.asyncAfter(deadline: .now() + max(timeout, 0)) { [weak self] in
                self?.resumeTimedOut(id)
            }
        }
    }

    private func resumeTimedOut(_ id: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(returning: false)
    }
}

/// Suspends until every expectation is satisfied, or `timeout` elapses.
///
/// The deadline is shared across all of them, as in XCTest — awaiting three
/// expectations with `within: 5` takes at most five seconds in total, not
/// fifteen. A timeout records an issue and returns rather than trapping, so a
/// deadlocked client surfaces as a failed test with a description of what never
/// arrived.
func fulfillment(
    of expectations: [Expectation],
    within timeout: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = Date().addingTimeInterval(timeout)

    for expectation in expectations where !expectation.isInverted {
        // Check satisfaction before the clock: expectations share one deadline, so
        // an earlier one can consume the whole budget, and an expectation that is
        // already fulfilled must not then be reported as timed out.
        var satisfied = expectation.isSatisfied
        let remaining = deadline.timeIntervalSinceNow
        if !satisfied && remaining > 0 {
            satisfied = await expectation.awaitSatisfied(within: remaining)
        }
        if !satisfied {
            Issue.record(
                """
                timed out after \(timeout)s waiting for "\(expectation.description)" \
                (fulfilled \(expectation.fulfillmentCount)/\(expectation.expectedFulfillmentCount) times)
                """,
                sourceLocation: sourceLocation
            )
        }
    }

    // Inverted expectations assert absence, so they have to burn the whole
    // timeout before the result means anything.
    let inverted = expectations.filter(\.isInverted)
    guard !inverted.isEmpty else { return }
    let remaining = deadline.timeIntervalSinceNow
    if remaining > 0 {
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }
    for expectation in inverted where expectation.fulfillmentCount > 0 {
        Issue.record(
            "\"\(expectation.description)\" was fulfilled \(expectation.fulfillmentCount) time(s) but should not have been",
            sourceLocation: sourceLocation
        )
    }
}

func fulfillment(
    of expectation: Expectation,
    within timeout: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    await fulfillment(of: [expectation], within: timeout, sourceLocation: sourceLocation)
}
