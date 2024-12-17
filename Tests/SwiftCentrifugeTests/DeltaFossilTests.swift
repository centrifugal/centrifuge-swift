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
        guard let origin = loadData(from: "origin"),
              let target = loadData(from: "target"),
              let goodDelta = loadData(from: "delta") else {
            return
        }
        
        // Test with Data
        do {
            let delta = try DeltaFossil.applyDelta(source: origin, delta: goodDelta)
            XCTAssertEqual(delta, target)
        } catch {
            XCTFail("Error applying delta: \(error)")
        }
    }
    
    // Helper function to load data from file
    private func loadData(from fileName: String) -> Data? {
        let bundle = Bundle(for: DeltaFossilTests.self) // Get the bundle for this test class
        guard let url = bundle.url(forResource: fileName, withExtension: nil, subdirectory: nil) else {
            XCTFail("Could not find file \(fileName)")
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
