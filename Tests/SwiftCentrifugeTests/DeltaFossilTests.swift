import XCTest
@testable import SwiftCentrifuge

final class DeltaFossilTests: XCTestCase {
    func testDeltaCreateAndApply() throws {
        let testDataPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Move up to SwiftCentrifugeTests/
            .appendingPathComponent("testdata/fossil") // Navigate to testdata/fossil/

        for i in 1...6 {
            let casePath = testDataPath.appendingPathComponent("\(i)")
            print("Running Fossil test case \(i)...") // Log test case start

            guard let origin = loadData(from: "origin", at: casePath),
                  let target = loadData(from: "target", at: casePath),
                  let goodDelta = loadData(from: "delta", at: casePath) else {
                XCTFail("Missing files in test case \(i)")
                continue
            }

            do {
                let calculatedTarget = try DeltaFossil.applyDelta(source: origin, delta: goodDelta)
                XCTAssertEqual(calculatedTarget, target, "Fossil test case \(i) failed: Calculated target does not match expected target")
                print("Fossil test case \(i) passed") // Log success
            } catch {
                XCTFail("Fossil test case \(i) failed: Error applying delta: \(error)")
            }
        }
    }

    private func loadData(from fileName: String, at path: URL) -> Data? {
        let fileURL = path.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            XCTFail("Could not find file \(fileName) at \(fileURL.path)")
            print("Missing file: \(fileURL.path)")
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }
}
