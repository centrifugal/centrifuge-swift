//
//  Helpers.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 05/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation
import SwiftProtobuf

struct CentrifugeDisconnectOptionsV1: Decodable {
    var reason: String
    var reconnect: Bool
}

struct CentrifugeDisconnectOptions {
    var code: UInt32
    var reason: String
    var reconnect: Bool
}

struct CentrifugeResolveData {
    var error: Error?
    var reply: Centrifugal_Centrifuge_Protocol_Reply?
}

public struct StreamPosition {
    public init(offset: UInt64 = 0, epoch: String = "") {
        self.offset = offset
        self.epoch = epoch
    }
    
    var offset: UInt64 = 0
    var epoch: String = ""
}

// Helper function to decode a varint.
func readVarint(from data: Data) throws -> (value: Int, length: Int) {
    var value = 0
    var length = 0
    for byte in data {
        value |= Int(byte & 0x7F) << (7 * length)
        length += 1
        if (byte & 0x80) == 0 {
            return (value, length)
        }
    }
    throw ProtobufDecodeError.failedToReadVarintLengthPrefix
}

private enum ProtobufDecodeError: Error {
    case failedToReadVarintLengthPrefix
    case notEnoughDataForMessage
    case failedToParseMessage(Error)
}

internal enum CentrifugeSerializer {
    static func serializeCommands(commands: [Centrifugal_Centrifuge_Protocol_Command]) throws -> Data {
        let stream = OutputStream.toMemory()
        stream.open()
        for command in commands {
            try BinaryDelimited.serialize(message: command, to: stream)
        }
        stream.close()
        return stream.property(forKey: .dataWrittenToMemoryStreamKey) as! Data
    }
    
    // Note, not using BinaryDelimited.parse to work with all Protobuf versions - SwiftProtobuf 1.27.0
    // introduced noBytesAvailable error which was not available before.
    static func deserializeCommands(data: Data) throws -> [Centrifugal_Centrifuge_Protocol_Reply] {
        var replies = [Centrifugal_Centrifuge_Protocol_Reply]()
        var currentIndex = data.startIndex

        while currentIndex < data.endIndex {
            // Read the varint length prefix.
            let remainingData = data[currentIndex...]
            let (messageLength, lengthBytes) = try readVarint(from: remainingData)
            // Calculate the total length of the message (varint length prefix + message data).
            let totalLength = lengthBytes + messageLength
            // Ensure there is enough data left.
            guard currentIndex + totalLength <= data.endIndex else {
                throw ProtobufDecodeError.notEnoughDataForMessage
            }
            // Extract the message data.
            let messageData = data[(currentIndex + lengthBytes)..<(currentIndex + totalLength)]
            // Parse the Protobuf message payload to Centrifuge Reply.
            do {
                let reply = try Centrifugal_Centrifuge_Protocol_Reply(serializedData: messageData)
                replies.append(reply)
            } catch {
                throw ProtobufDecodeError.failedToParseMessage(error)
            }
            // Move to the next message.
            currentIndex += totalLength
        }
        return replies
    }
}

func assertIsOnQueue(_ queue: DispatchQueue) {
#if DEBUG
    if #available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *) {
        dispatchPrecondition(condition: .onQueue(queue))
    }
#endif
}
