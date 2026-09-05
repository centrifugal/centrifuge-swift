import Foundation
import Testing

/// swift-testing has no `XCTestExpectation`, and its `confirmation(...)` is
/// scope- and async-shaped, which does not fit this suite: the SDK delivers
/// events by invoking delegate callbacks synchronously on its own queue, and the
/// tests are written as "install a callback, trigger something, block until it
/// fires".
///
/// `Expectation` keeps exactly that shape. It is a small NSCondition wrapper with
/// the subset of XCTestExpectation semantics these tests actually use.
///
/// One deliberate omission: over-fulfillment is never an error. XCTest fails a
/// test when an expectation is fulfilled more often than `expectedFulfillmentCount`,
/// but with an event stream arriving on a background queue that check mostly
/// produces flakes, and no test here is trying to assert an upper bound. Use an
/// explicit count assertion if you need one.
final class Expectation: @unchecked Sendable {
    let description: String

    /// Number of `fulfill()` calls that count as satisfied. Set before waiting.
    var expectedFulfillmentCount: Int = 1

    /// When true the expectation must NOT be fulfilled: `wait` burns the full
    /// timeout and reports an issue if it fired. Mirrors `XCTestExpectation.isInverted`.
    var isInverted: Bool = false

    private let cond = NSCondition()
    private var count = 0

    init(_ description: String) {
        self.description = description
    }

    func fulfill() {
        cond.lock()
        count += 1
        cond.broadcast()
        cond.unlock()
    }

    var fulfillmentCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return count
    }

    /// Blocks until satisfied or `deadline` passes. Returns whether it was satisfied.
    fileprivate func waitUntilSatisfied(deadline: Date) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while count < expectedFulfillmentCount {
            if !cond.wait(until: deadline) { return false }
        }
        return true
    }
}

/// Blocks until every expectation is satisfied, or `timeout` elapses.
///
/// The deadline is shared across all of them, as in XCTest — waiting for three
/// expectations with `timeout: 5` waits five seconds in total, not fifteen.
/// A timeout records an issue and returns; it never traps, so a deadlocked client
/// surfaces as a failed test rather than a hung run.
func wait(
    for expectations: [Expectation],
    timeout: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let deadline = Date().addingTimeInterval(timeout)

    for expectation in expectations where !expectation.isInverted {
        if !expectation.waitUntilSatisfied(deadline: deadline) {
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
    if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    for expectation in inverted where expectation.fulfillmentCount > 0 {
        Issue.record(
            "\"\(expectation.description)\" was fulfilled \(expectation.fulfillmentCount) time(s) but should not have been",
            sourceLocation: sourceLocation
        )
    }
}

func wait(
    for expectation: Expectation,
    timeout: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    wait(for: [expectation], timeout: timeout, sourceLocation: sourceLocation)
}
