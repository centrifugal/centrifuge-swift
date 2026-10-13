import CryptoKit
import Foundation
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// A WebSocket server written over raw TCP, for tests that need control over the
/// bytes on the wire: how frames are split across writes, several frames in one
/// write. It answers the upgrade, decodes the client's (masked) frames into
/// commands, and leaves the replies to the test, which writes raw bytes.
final class RawWebSocketServer: @unchecked Sendable {
    typealias PCommand = Centrifugal_Centrifuge_Protocol_Command
    typealias PReply = Centrifugal_Centrifuge_Protocol_Reply

    private var listener: NWListener!
    private let queue = DispatchQueue(label: "raw.ws.server")
    private let lock = NSLock()
    private var current: NWConnection?

    /// Called on the server queue for every command the client sends.
    var onCommand: ((PCommand) -> Void)?

    var port: UInt16 { listener.port!.rawValue }
    var url: String { "ws://127.0.0.1:\(port)/connection/websocket" }

    func start() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            self.lock.lock(); self.current = conn; self.lock.unlock()
            conn.start(queue: self.queue)
            self.readUpgrade(conn, Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
        lock.lock(); current?.cancel(); lock.unlock()
    }

    /// Write raw bytes to the current connection, exactly as given.
    func write(_ data: Data) {
        lock.lock(); let conn = current; lock.unlock()
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// An unmasked binary frame with the given payload.
    static func frame(_ payload: Data) -> Data {
        var out = Data([0x82])
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            out.append(126)
            out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xff))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xff)) }
        }
        out.append(payload)
        return out
    }

    /// The payload carrying these replies (length-delimited protobuf).
    static func payload(_ replies: [PReply]) -> Data {
        let out = OutputStream.toMemory()
        out.open()
        for reply in replies { try? BinaryDelimited.serialize(message: reply, to: out) }
        out.close()
        return out.property(forKey: .dataWrittenToMemoryStreamKey) as! Data
    }

    private func readUpgrade(_ conn: NWConnection, _ buffered: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, error == nil, !isComplete || data != nil else { return }
            var buffer = buffered
            if let data = data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.readUpgrade(conn, buffer)
                return
            }
            let request = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let key = request.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: centrifuge-protobuf\r\n\r\n"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            self.readFrames(conn, Data(buffer[end.upperBound...]))
        }
    }

    private func readFrames(_ conn: NWConnection, _ buffered: Data) {
        var buffer = buffered
        // Decode every complete client frame in the buffer.
        while let (payload, size) = Self.decodeClientFrame(buffer) {
            buffer.removeFirst(size)
            let stream = InputStream(data: payload)
            stream.open()
            while let cmd = try? BinaryDelimited.parse(messageType: PCommand.self, from: stream) {
                onCommand?(cmd)
            }
            stream.close()
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, error == nil else { return }
            var next = buffer
            if let data = data { next.append(data) }
            if isComplete && data == nil { return }
            self.readFrames(conn, next)
        }
    }

    private static func decodeClientFrame(_ data: Data) -> (Data, Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7f)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3]); offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }; offset = 10
        }
        let masked = bytes[1] & 0x80 != 0
        let maskOffset = offset
        if masked { offset += 4 }
        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= bytes[maskOffset + i % 4] }
        }
        // Only binary frames carry commands; control frames (e.g. close) are skipped.
        return (bytes[0] & 0x0f == 0x2 ? Data(payload) : Data(), offset + length)
    }
}
