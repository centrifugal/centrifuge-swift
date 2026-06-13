import Foundation
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// In-process Centrifugo fake server for tests, speaking the protobuf protocol
/// over a WebSocket (Network.framework). It is intentionally protocol-level and
/// generic: it provides sensible defaults for the connect/subscribe/unsubscribe
/// handshake, captures received commands for assertions, and exposes hooks + raw
/// push senders so new scenarios can be added WITHOUT touching the client under
/// test or this helper.
///
/// This exists because some features (channel compaction, and in future others)
/// are Centrifugo PRO only and can't be exercised against the OSS docker-compose
/// server the other suites use; and because a fake gives deterministic control of
/// timing, errors and reconnects.
///
/// How to extend (most→least common):
///   - Customize a subscribe reply:
///       server.onSubscribe = { channel, req in
///           var r = SubscribeResult(); r.recoverable = true; return r
///       }
///   - Negotiate channel compaction (assign a numeric id when the client offers it):
///       server.onSubscribe = { channel, req in
///           var r = SubscribeResult(); if req.flag & 1 != 0 { r.id = 42 }; return r
///       }
///   - Push to a subscription:
///       server.publishId(42, data)              // by numeric id (compaction)
///       server.publishChannel("news", data)     // by channel name
///   - Fully control any command reply (return nil to fall through):
///       server.onCommand = { cmd in cmd.hasRpc ? errorReply(cmd.id) : nil }
///   - Send anything the protocol allows:
///       server.sendPush({ var p = Push(); p.disconnect = ...; return p }())
///   - Drive a reconnect:        server.closeConnection()
///   - Assert on what the client sent:  server.received() / server.lastSubscribe()
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; `listener`/
/// `queue` are set-once/immutable. The closures are invoked on the server queue.
/// Required because the instance is captured in Network.framework's @Sendable
/// connection/receive handlers, and the test target compiles under Swift 6.
final class FakeCentrifugoServer: @unchecked Sendable {
    typealias PCommand = Centrifugal_Centrifuge_Protocol_Command
    typealias PReply = Centrifugal_Centrifuge_Protocol_Reply
    typealias PPush = Centrifugal_Centrifuge_Protocol_Push
    typealias PSubscribeRequest = Centrifugal_Centrifuge_Protocol_SubscribeRequest
    typealias PSubscribeResult = Centrifugal_Centrifuge_Protocol_SubscribeResult
    typealias PConnectResult = Centrifugal_Centrifuge_Protocol_ConnectResult

    private var listener: NWListener!
    private let queue = DispatchQueue(label: "fake.centrifugo.server")
    private let lock = NSLock()
    private var current: NWConnection?
    private var _received: [PCommand] = []

    /// connect reply fields. Override to set expires/ttl/data/etc.
    var connectResult: PConnectResult = {
        var res = PConnectResult()
        res.client = "fake-client"; res.version = "0.0.0"; res.ping = 25
        return res
    }()

    /// Full override for any command — return a Reply to send, or nil to fall
    /// through to default handling.
    var onCommand: ((PCommand) -> PReply?)?

    /// Customize the subscribe result per channel (default: empty result).
    var onSubscribe: ((String, PSubscribeRequest) -> PSubscribeResult)?

    var port: UInt16 { listener.port!.rawValue }
    var url: String { "ws://127.0.0.1:\(port)/connection/websocket" }

    /// A copy of all commands received from the client, in order.
    func received() -> [PCommand] { lock.lock(); defer { lock.unlock() }; return _received }

    /// The most recent subscribe request the client sent, or nil.
    func lastSubscribe() -> PSubscribeRequest? {
        lock.lock(); defer { lock.unlock() }
        return _received.last(where: { $0.hasSubscribe })?.subscribe
    }

    func start() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            self.lock.lock(); self.current = conn; self.lock.unlock()
            conn.start(queue: self.queue)
            self.receive(conn)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel(); lock.lock(); current?.cancel(); lock.unlock() }

    /// Close the active connection from the server side, triggering the client's
    /// automatic reconnect.
    func closeConnection() { lock.lock(); let c = current; lock.unlock(); c?.cancel() }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { self.handleFrame(conn, data) }
            if error == nil { self.receive(conn) }
        }
    }

    private func handleFrame(_ conn: NWConnection, _ data: Data) {
        let stream = InputStream(data: data)
        stream.open()
        defer { stream.close() }
        while true {
            guard let cmd = try? BinaryDelimited.parse(messageType: PCommand.self, from: stream) else { break }
            dispatch(conn, cmd)
        }
    }

    private func dispatch(_ conn: NWConnection, _ cmd: PCommand) {
        lock.lock(); _received.append(cmd); lock.unlock()

        if let onCommand = onCommand, let reply = onCommand(cmd) {
            send(conn, reply)
            return
        }

        if cmd.hasConnect {
            var r = PReply(); r.id = cmd.id; r.connect = connectResult
            send(conn, r)
        } else if cmd.hasSubscribe {
            let res = onSubscribe?(cmd.subscribe.channel, cmd.subscribe) ?? PSubscribeResult()
            var r = PReply(); r.id = cmd.id; r.subscribe = res
            send(conn, r)
        } else if cmd.hasUnsubscribe {
            var r = PReply(); r.id = cmd.id; r.unsubscribe = Centrifugal_Centrifuge_Protocol_UnsubscribeResult()
            send(conn, r)
        } else if cmd.id != 0 {
            // Reply to anything else with an empty result to avoid client timeouts.
            var r = PReply(); r.id = cmd.id
            send(conn, r)
        }
    }

    // --- raw escape hatches ---------------------------------------------------

    private func send(_ conn: NWConnection, _ reply: PReply) {
        let out = OutputStream.toMemory()
        out.open()
        try? BinaryDelimited.serialize(message: reply, to: out)
        out.close()
        let data = out.property(forKey: .dataWrittenToMemoryStreamKey) as! Data
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func currentConn() -> NWConnection { lock.lock(); defer { lock.unlock() }; return current! }

    /// Send a raw reply to the active connection.
    func sendReply(_ reply: PReply) { send(currentConn(), reply) }

    /// Send a raw push (wrapped in a reply) to the active connection.
    func sendPush(_ push: PPush) { var r = PReply(); r.push = push; sendReply(r) }

    // --- typed push senders ---------------------------------------------------
    //
    // Channel compaction pushes carry a numeric id and no channel; otherwise the
    // channel name is used. The *Id variants address by numeric id, the *Channel
    // variants by channel name.

    func publishId(_ id: Int64, _ data: Data) {
        var pub = Centrifugal_Centrifuge_Protocol_Publication(); pub.data = data
        var push = PPush(); push.id = id; push.pub = pub
        sendPush(push)
    }

    func publishChannel(_ channel: String, _ data: Data) {
        var pub = Centrifugal_Centrifuge_Protocol_Publication(); pub.data = data
        var push = PPush(); push.channel = channel; push.pub = pub
        sendPush(push)
    }

    func joinId(_ id: Int64, _ client: String) {
        var info = Centrifugal_Centrifuge_Protocol_ClientInfo(); info.client = client
        var join = Centrifugal_Centrifuge_Protocol_Join(); join.info = info
        var push = PPush(); push.id = id; push.join = join
        sendPush(push)
    }

    func leaveId(_ id: Int64, _ client: String) {
        var info = Centrifugal_Centrifuge_Protocol_ClientInfo(); info.client = client
        var leave = Centrifugal_Centrifuge_Protocol_Leave(); leave.info = info
        var push = PPush(); push.id = id; push.leave = leave
        sendPush(push)
    }
}
