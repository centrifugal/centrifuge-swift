import Foundation
import Testing
@testable import SwiftCentrifuge

@Suite struct DeltaFossilTests {

    @Test func deltaCreateAndApply() throws {
        let testDataPath = Bundle.module.resourceURL!
            .appendingPathComponent("testdata/fossil")

        for i in 1...6 {
            let casePath = testDataPath.appendingPathComponent("\(i)")

            guard let origin = loadData(from: "origin", at: casePath),
                  let target = loadData(from: "target", at: casePath),
                  let goodDelta = loadData(from: "delta", at: casePath) else {
                Issue.record("Missing files in test case \(i)")
                continue
            }

            do {
                let calculatedTarget = try DeltaFossil.applyDelta(source: origin, delta: goodDelta)
                #expect(calculatedTarget == target, "Fossil test case \(i) failed: Calculated target does not match expected target")
            } catch {
                Issue.record("Fossil test case \(i) failed: Error applying delta: \(error)")
            }
        }
    }

    private func loadData(from fileName: String, at path: URL) -> Data? {
        let fileURL = path.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Issue.record("Could not find file \(fileName) at \(fileURL.path)")
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    // Malformed deltas below are hand-crafted (not from the fossil test corpus) so each
    // exercises exactly one of DeltaFossil's validation guards. `applyDelta` is expected
    // to throw a typed error rather than trap, since a malformed delta is untrusted input
    // coming from the server.
    private let malformedOrigin = Data("hello world, this is the fossil delta test origin string, long enough for offsets".utf8)

    private func assertThrows(
        _ delta: String,
        _ expected: DeltaFossil.DeltaError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try DeltaFossil.applyDelta(source: malformedOrigin, delta: Data(delta.utf8))
            Issue.record("expected \(expected) to be thrown, but the delta applied cleanly", sourceLocation: sourceLocation)
        } catch let error as DeltaFossil.DeltaError {
            #expect(String(describing: error) == String(describing: expected), sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected a DeltaFossil.DeltaError, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func malformedDeltaCopyExtendsPastEnd() throws {
        // Copy command requests offset 70, count 20 from an 81-byte source (90 > 81).
        assertThrows("K\nK@16,wI_jJ;", .copyExtendsPastEnd)
    }

    @Test func malformedDeltaBadChecksum() throws {
        // Well-formed copy+insert producing "helloXXXXX", but the trailing checksum
        // digits don't match the actual checksum of that output.
        assertThrows("A\n5@0,5:XXXXXl5VJy;", .badChecksum)
    }

    @Test func malformedDeltaSizeMismatch() throws {
        // Declares an output size of 999 bytes up front, but the only command copies 5.
        assertThrows("Fc\n5@0,3NPMmh;", .sizeMismatch)
    }

    @Test func malformedDeltaUnknownOperator() throws {
        // '#' is not a valid delta command character (valid ones are @, :, ;).
        assertThrows("5\n5#0,3NPMmh;", .unknownDeltaOperator)
    }

    @Test func malformedDeltaUnterminated() throws {
        // Ends after a valid copy command without the closing ";checksum" command.
        assertThrows("5\n5@0,", .unterminatedDelta)
    }
}
