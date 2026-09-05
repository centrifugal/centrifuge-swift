// XCTest ships only inside Xcode.app. Guard the file so the test target still
// compiles with just the Command Line Tools, where the swift-testing suites in
// this target can still run (see CLAUDE.md, "Running tests locally").
// Removed once this suite is migrated to swift-testing.
#if canImport(XCTest)
import XCTest
@testable import SwiftCentrifuge

final class SwiftCentrifugeTests: XCTestCase {
    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(1+1, 2)
    }
}
#endif // canImport(XCTest)
