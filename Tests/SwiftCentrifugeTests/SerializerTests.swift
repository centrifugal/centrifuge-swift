import Foundation
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Unit tests for the length-delimited Protobuf framing used on the wire
/// (`CentrifugeSerializer` and its varint helper). Malformed frames are covered
/// too: this data comes from the network, so decoding must report an error and
/// never trap.
@Suite struct SerializerTests {

    private typealias PCommand = Centrifugal_Centrifuge_Protocol_Command
    private typealias PReply = Centrifugal_Centrifuge_Protocol_Reply

    /// Encode replies the way a server does — the input `deserializeCommands` expects.
    private func encode(_ replies: [PReply]) throws -> Data {
        let stream = OutputStream.toMemory()
        stream.open()
        for reply in replies {
            try BinaryDelimited.serialize(message: reply, to: stream)
        }
        stream.close()
        return stream.property(forKey: .dataWrittenToMemoryStreamKey) as! Data
    }

    @Test func readVarintDecodesValues() throws {
        #expect(try readVarint(from: Data([0x00])).value == 0)
        #expect(try readVarint(from: Data([0x01])).value == 1)
        #expect(try readVarint(from: Data([0x7F])).value == 127)

        let twoBytes = try readVarint(from: Data([0xAC, 0x02]))
        #expect(twoBytes.value == 300)
        #expect(twoBytes.length == 2)

        // Bytes following the varint are not consumed.
        let prefixed = try readVarint(from: Data([0x80, 0x01, 0xFF, 0xFF]))
        #expect(prefixed.value == 128)
        #expect(prefixed.length == 2)
    }

    @Test func readVarintThrowsOnMalformedInput() {
        // Empty input.
        #expect(throws: (any Error).self) { try readVarint(from: Data()) }
        // Unterminated varint — every byte has the continuation bit set.
        #expect(throws: (any Error).self) { try readVarint(from: Data([0x80, 0x80])) }
        // Longer than a length prefix can possibly be: must be rejected instead of
        // wrapping around into a bogus (possibly negative) length.
        #expect(throws: (any Error).self) {
            try readVarint(from: Data(repeating: 0x80, count: 10) + Data([0x01]))
        }
    }

    @Test func serializeCommandsWritesLengthDelimitedFrames() throws {
        var connect = PCommand()
        connect.id = 1
        connect.connect = Centrifugal_Centrifuge_Protocol_ConnectRequest()
        var subscribe = PCommand()
        subscribe.id = 2
        var subscribeRequest = Centrifugal_Centrifuge_Protocol_SubscribeRequest()
        subscribeRequest.channel = "test"
        subscribe.subscribe = subscribeRequest

        let data = try CentrifugeSerializer.serializeCommands(commands: [connect, subscribe])

        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }
        let first = try BinaryDelimited.parse(messageType: PCommand.self, from: stream)
        let second = try BinaryDelimited.parse(messageType: PCommand.self, from: stream)
        #expect(first.id == 1)
        #expect(first.hasConnect)
        #expect(second.id == 2)
        #expect(second.subscribe.channel == "test")
    }

    @Test func deserializeCommandsParsesEveryReplyInFrame() throws {
        var first = PReply()
        first.id = 1
        var second = PReply()
        second.id = 2
        var publication = Centrifugal_Centrifuge_Protocol_Publication()
        publication.data = Data("{\"a\":1}".utf8)
        var push = Centrifugal_Centrifuge_Protocol_Push()
        push.channel = "test"
        push.pub = publication
        var third = PReply()
        third.push = push

        let replies = try CentrifugeSerializer.deserializeCommands(data: encode([first, second, third]))

        #expect(replies.count == 3)
        #expect(replies[0].id == 1)
        #expect(replies[1].id == 2)
        #expect(replies[2].hasPush)
        #expect(replies[2].push.channel == "test")
        #expect(replies[2].push.pub.data == Data("{\"a\":1}".utf8))
    }

    @Test func deserializeCommandsOnEmptyData() throws {
        #expect(try CentrifugeSerializer.deserializeCommands(data: Data()).isEmpty)
    }

    @Test func deserializeCommandsThrowsOnTruncatedMessage() throws {
        var reply = PReply()
        reply.id = 1
        let data = try encode([reply])
        #expect(throws: (any Error).self) {
            try CentrifugeSerializer.deserializeCommands(data: data.dropLast())
        }
    }

    @Test func deserializeCommandsThrowsOnOversizedLengthPrefix() {
        // A 9 byte varint with all value bits set: the announced message length is
        // way beyond the data available. Must throw rather than overflow.
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: (any Error).self) {
            try CentrifugeSerializer.deserializeCommands(data: data)
        }
    }

    @Test func deserializeCommandsThrowsOnUnterminatedLengthPrefix() {
        #expect(throws: (any Error).self) {
            try CentrifugeSerializer.deserializeCommands(data: Data([0x80, 0x80, 0x80]))
        }
    }
}
