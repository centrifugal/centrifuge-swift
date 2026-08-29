import XCTest
@testable import SwiftCentrifuge

final class DeltaFossilTests: XCTestCase {
    func testDeltaCreateAndApply() throws {
        let testDataPath = Bundle.module.resourceURL!
            .appendingPathComponent("testdata/fossil")

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

    // Malformed deltas below are hand-crafted (not from the fossil test corpus) so each
    // exercises exactly one of DeltaFossil's validation guards. `applyDelta` is expected
    // to throw a typed error rather than trap, since a malformed delta is untrusted input
    // coming from the server.
    private let malformedOrigin = Data("hello world, this is the fossil delta test origin string, long enough for offsets".utf8)

    private func assertThrows(_ delta: String, _ expected: DeltaFossil.DeltaError, line: UInt = #line) {
        XCTAssertThrowsError(try DeltaFossil.applyDelta(source: malformedOrigin, delta: Data(delta.utf8)), line: line) { error in
            guard let deltaError = error as? DeltaFossil.DeltaError else {
                XCTFail("expected a DeltaFossil.DeltaError, got \(error)", line: line)
                return
            }
            XCTAssertEqual(String(describing: deltaError), String(describing: expected), line: line)
        }
    }

    func testMalformedDeltaCopyExtendsPastEnd() throws {
        // Copy command requests offset 70, count 20 from an 81-byte source (90 > 81).
        assertThrows("K\nK@16,wI_jJ;", .copyExtendsPastEnd)
    }

    func testMalformedDeltaBadChecksum() throws {
        // Well-formed copy+insert producing "helloXXXXX", but the trailing checksum
        // digits don't match the actual checksum of that output.
        assertThrows("A\n5@0,5:XXXXXl5VJy;", .badChecksum)
    }

    func testMalformedDeltaSizeMismatch() throws {
        // Declares an output size of 999 bytes up front, but the only command copies 5.
        assertThrows("Fc\n5@0,3NPMmh;", .sizeMismatch)
    }

    func testMalformedDeltaUnknownOperator() throws {
        // '#' is not a valid delta command character (valid ones are @, :, ;).
        assertThrows("5\n5#0,3NPMmh;", .unknownDeltaOperator)
    }

    func testMalformedDeltaUnterminated() throws {
        // Ends after a valid copy command without the closing ";checksum" command.
        assertThrows("5\n5@0,", .unterminatedDelta)
    }
}
