//
//  DeltaFossilTests.swift
//  SwiftCentrifuge
//
//  Created by Mehdi on 9/22/24.
//

import XCTest
@testable import SwiftCentrifuge

final class DeltaFossilTests: XCTestCase {
    func testDeltaCreateAndApply() throws {
        let testDataPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Move up to SwiftCentrifugeTests/
            .appendingPathComponent("testdata/fossil") // Navigate to testdata/fossil/

        for i in 1...6 {
            let casePath = testDataPath.appendingPathComponent("\(i)")
            print("Running test case \(i)...") // Log test case start

            guard let origin = loadData(from: "origin", at: casePath),
                  let target = loadData(from: "target", at: casePath),
                  let goodDelta = loadData(from: "delta", at: casePath) else {
                XCTFail("Missing files in test case \(i)")
                continue
            }

            // Test with Data
            do {
                let delta = try DeltaFossil.applyDelta(source: origin, delta: goodDelta)
                XCTAssertEqual(delta, target, "Test case \(i) failed: Delta does not match target")
                print("✅ Test case \(i) passed!") // Log success
            } catch {
                XCTFail("Test case \(i) failed: Error applying delta: \(error)")
                print("❌ Test case \(i) failed with error: \(error)")
            }
        }
    }

    private func loadData(from fileName: String, at path: URL) -> Data? {
        let fileURL = path.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            XCTFail("Could not find file \(fileName) at \(fileURL.path)")
            print("❌ Missing file: \(fileURL.path)")
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }
}
