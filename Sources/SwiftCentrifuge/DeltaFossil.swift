//
//  DeltaFossil.swift
//  iOSApp
//
// Fossil SCM delta compression algorithm, this is only the applyDelta part required by the client.
// Author of the original algorithm: D. Richard Hipp
//

import Foundation

public enum DeltaFossil {
    private struct ZValue {
        static let values: [Int8] = [
            -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
            -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
            -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, -1, -1,
            -1, -1, -1, -1, -1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
            24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, -1, -1, -1, -1, 36, -1, 37,
            38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56,
            57, 58, 59, 60, 61, 62, -1, -1, -1, 63, -1,
        ]
    }

    enum DeltaError: Error {
        case outOfBounds
        case sizeIntegerNotTerminated
        case copyCommandNotTerminated
        case copyExceedsOutputSize
        case copyExtendsPastEnd
        case insertExceedsOutputSize
        case insertCountExceedsDelta
        case unknownDeltaOperator
        case unterminatedDelta
        case badChecksum
        case sizeMismatch
    }

    // Apply delta fossil algorithm
    public static func applyDelta(source: Data, delta: Data) throws -> Data {
        var total: UInt32 = 0
        var deltaReader = Reader(array: [UInt8](delta)) // Convert Data to ByteArray for Reader
        var outputWriter = Writer()

        let sourceLength = source.count
        let deltaLength = delta.count

        let limit = try deltaReader.getInt()

        guard try deltaReader.getChar() == "\n" else {
            throw DeltaError.sizeIntegerNotTerminated
        }

        while deltaReader.haveBytes() {
            let count = try deltaReader.getInt()
            let command = try deltaReader.getChar()

            switch command {
            case "@":
                let offset = try deltaReader.getInt()
                guard try deltaReader.getChar() == "," else {
                    throw DeltaError.copyCommandNotTerminated
                }
                total += count
                guard total <= limit else { throw DeltaError.copyExceedsOutputSize }
                guard offset + count <= sourceLength else { throw DeltaError.copyExtendsPastEnd }
                outputWriter.putArray([UInt8](source), start: Int(offset), end: Int(offset + count))

            case ":":
                total += count
                guard total <= limit else { throw DeltaError.insertExceedsOutputSize }
                guard count <= deltaLength else { throw DeltaError.insertCountExceedsDelta }
                outputWriter.putArray(deltaReader.array, start: deltaReader.position, end: deltaReader.position + Int(count))
                deltaReader.position += Int(count)

            case ";":
                let output = outputWriter.toByteArray()
                guard count == checksum(array: output) else { throw DeltaError.badChecksum }
                guard total == limit else { throw DeltaError.sizeMismatch }
                return Data(output) // Convert ByteArray back to Data

            default:
                throw DeltaError.unknownDeltaOperator
            }
        }

        throw DeltaError.unterminatedDelta
    }

    // Reader
    private struct Reader {
        let array: [UInt8]
        var position: Int = 0

        init(array: [UInt8]) {
            self.array = array
        }

        func haveBytes() -> Bool {
            return position < array.count
        }

        mutating func getByte() throws -> UInt8 {
            guard position < array.count else { throw DeltaError.outOfBounds }
            let byte = array[position]
            position += 1
            return byte
        }

        mutating func getChar() throws -> Character {
            return Character(UnicodeScalar(try getByte()))
        }

        mutating func getInt() throws -> UInt32 {
            var value: UInt32 = 0
            while haveBytes() {
                let byte = try getByte()
                let c = ZValue.values[Int(0x7f & byte)]
                if c < 0 {
                    position -= 1 // Adjust for invalid character
                    return value
                }
                value = (value << 6) + UInt32(c)
            }
            return value
        }
    }

    // Writer
    private struct Writer {
        private var array: [UInt8] = []

        func toByteArray() -> [UInt8] {
            return array
        }

        mutating func putArray(_ array: [UInt8], start: Int, end: Int) {
            self.array.append(contentsOf: array[start..<end])
        }
    }

    // Checksum
    private static func checksum(array: [UInt8]) -> UInt32 {
            var sum0: UInt32 = 0
            var sum1: UInt32 = 0
            var sum2: UInt32 = 0
            var sum3: UInt32 = 0
            var z: Int = 0
            var N = array.count

            while N >= 16 {
                sum0 = sum0 &+ UInt32(array[z + 0])
                sum1 = sum1 &+ UInt32(array[z + 1])
                sum2 = sum2 &+ UInt32(array[z + 2])
                sum3 = sum3 &+ UInt32(array[z + 3])

                sum0 = sum0 &+ UInt32(array[z + 4])
                sum1 = sum1 &+ UInt32(array[z + 5])
                sum2 = sum2 &+ UInt32(array[z + 6])
                sum3 = sum3 &+ UInt32(array[z + 7])

                sum0 = sum0 &+ UInt32(array[z + 8])
                sum1 = sum1 &+ UInt32(array[z + 9])
                sum2 = sum2 &+ UInt32(array[z + 10])
                sum3 = sum3 &+ UInt32(array[z + 11])

                sum0 = sum0 &+ UInt32(array[z + 12])
                sum1 = sum1 &+ UInt32(array[z + 13])
                sum2 = sum2 &+ UInt32(array[z + 14])
                sum3 = sum3 &+ UInt32(array[z + 15])

                z += 16
                N -= 16
            }

            while N >= 4 {
                sum0 = sum0 &+ UInt32(array[z + 0])
                sum1 = sum1 &+ UInt32(array[z + 1])
                sum2 = sum2 &+ UInt32(array[z + 2])
                sum3 = sum3 &+ UInt32(array[z + 3])
                z += 4
                N -= 4
            }

            sum3 = (((sum3 &+ (sum2 << 8)) &+ (sum1 << 16)) &+ (sum0 << 24))

            switch N {
            case 3:
                sum3 = sum3 &+ (UInt32(array[z + 2]) << 8)
                fallthrough // Allow fallthrough for the next case
            case 2:
                sum3 = sum3 &+ (UInt32(array[z + 1]) << 16)
                fallthrough // Allow fallthrough for the next case
            case 1:
                sum3 = sum3 &+ (UInt32(array[z + 0]) << 24)
            default:
                break
            }

            return sum3
        }
}
