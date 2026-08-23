import XCTest
import SwiftProtobuf
@testable import SwiftCentrifuge

/// Unit tests for the length-delimited Protobuf framing used on the wire
/// (`CentrifugeSerializer` and its varint helper). Malformed frames are covered
/// too: this data comes from the network, so decoding must report an error and
/// never trap.
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter SerializerTests
final class SerializerTests: XCTestCase {

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

    func testReadVarintDecodesValues() throws {
        XCTAssertEqual(try readVarint(from: Data([0x00])).value, 0)
        XCTAssertEqual(try readVarint(from: Data([0x01])).value, 1)
        XCTAssertEqual(try readVarint(from: Data([0x7F])).value, 127)

        let twoBytes = try readVarint(from: Data([0xAC, 0x02]))
        XCTAssertEqual(twoBytes.value, 300)
        XCTAssertEqual(twoBytes.length, 2)

        // Bytes following the varint are not consumed.
        let prefixed = try readVarint(from: Data([0x80, 0x01, 0xFF, 0xFF]))
        XCTAssertEqual(prefixed.value, 128)
        XCTAssertEqual(prefixed.length, 2)
    }

    func testReadVarintThrowsOnMalformedInput() {
        // Empty input.
        XCTAssertThrowsError(try readVarint(from: Data()))
        // Unterminated varint — every byte has the continuation bit set.
        XCTAssertThrowsError(try readVarint(from: Data([0x80, 0x80])))
        // Longer than a length prefix can possibly be: must be rejected instead of
        // wrapping around into a bogus (possibly negative) length.
        XCTAssertThrowsError(try readVarint(from: Data(repeating: 0x80, count: 10) + Data([0x01])))
    }

    func testSerializeCommandsWritesLengthDelimitedFrames() throws {
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
        XCTAssertEqual(first.id, 1)
        XCTAssertTrue(first.hasConnect)
        XCTAssertEqual(second.id, 2)
        XCTAssertEqual(second.subscribe.channel, "test")
    }

    func testDeserializeCommandsParsesEveryReplyInFrame() throws {
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

        XCTAssertEqual(replies.count, 3)
        XCTAssertEqual(replies[0].id, 1)
        XCTAssertEqual(replies[1].id, 2)
        XCTAssertTrue(replies[2].hasPush)
        XCTAssertEqual(replies[2].push.channel, "test")
        XCTAssertEqual(replies[2].push.pub.data, Data("{\"a\":1}".utf8))
    }

    func testDeserializeCommandsOnEmptyData() throws {
        XCTAssertTrue(try CentrifugeSerializer.deserializeCommands(data: Data()).isEmpty)
    }

    func testDeserializeCommandsThrowsOnTruncatedMessage() throws {
        var reply = PReply()
        reply.id = 1
        let data = try encode([reply])
        XCTAssertThrowsError(try CentrifugeSerializer.deserializeCommands(data: data.dropLast()))
    }

    func testDeserializeCommandsThrowsOnOversizedLengthPrefix() {
        // A 9 byte varint with all value bits set: the announced message length is
        // way beyond the data available. Must throw rather than overflow.
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertThrowsError(try CentrifugeSerializer.deserializeCommands(data: data))
    }

    func testDeserializeCommandsThrowsOnUnterminatedLengthPrefix() {
        XCTAssertThrowsError(try CentrifugeSerializer.deserializeCommands(data: Data([0x80, 0x80, 0x80])))
    }
}
