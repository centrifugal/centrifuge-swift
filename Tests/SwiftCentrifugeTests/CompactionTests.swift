import XCTest
import Network
import SwiftProtobuf
@testable import SwiftCentrifuge

/// Integration tests for channel compaction. The feature is Centrifugo PRO only,
/// so it can't be exercised against the docker-compose OSS server — these tests
/// use an in-process Network.framework WebSocket fake server which negotiates a
/// numeric channel ID in the subscribe reply and then sends pushes carrying the
/// ID instead of the channel name, exactly like the real server does when
/// compaction is enabled.
///
/// Run with full Xcode toolchain (XCTest is unavailable under CommandLineTools):
///     swift test --filter CompactionTests
final class CompactionTests: XCTestCase {

    private typealias PCommand = Centrifugal_Centrifuge_Protocol_Command
    private typealias PReply = Centrifugal_Centrifuge_Protocol_Reply
    private typealias PPush = Centrifugal_Centrifuge_Protocol_Push

    private final class FakeServer {
        private var listener: NWListener!
        private let queue = DispatchQueue(label: "fake.compaction.server")
        private let lock = NSLock()
        private var current: NWConnection?
        private var _lastFlag: Int64 = 0
        private var _nextChannelId: Int64 = 42

        var port: UInt16 { listener.port!.rawValue }
        var lastFlag: Int64 { lock.lock(); defer { lock.unlock() }; return _lastFlag }
        func setNextChannelId(_ v: Int64) { lock.lock(); _nextChannelId = v; lock.unlock() }

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
                handleCommand(conn, cmd)
            }
        }

        private func handleCommand(_ conn: NWConnection, _ cmd: PCommand) {
            if cmd.hasConnect {
                var res = Centrifugal_Centrifuge_Protocol_ConnectResult()
                res.client = "fake"; res.version = "0.0.0"; res.ping = 25
                var r = PReply(); r.id = cmd.id; r.connect = res
                send(conn, r)
            } else if cmd.hasSubscribe {
                lock.lock(); _lastFlag = cmd.subscribe.flag; let nid = _nextChannelId; lock.unlock()
                var res = Centrifugal_Centrifuge_Protocol_SubscribeResult()
                if cmd.subscribe.flag & 1 != 0 { res.id = nid }
                var r = PReply(); r.id = cmd.id; r.subscribe = res
                send(conn, r)
            } else if cmd.hasUnsubscribe {
                var r = PReply(); r.id = cmd.id; r.unsubscribe = Centrifugal_Centrifuge_Protocol_UnsubscribeResult()
                send(conn, r)
            } else if cmd.id != 0 {
                var r = PReply(); r.id = cmd.id
                send(conn, r)
            }
        }

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

        func sendPub(_ id: Int64, _ data: Data) {
            var pub = Centrifugal_Centrifuge_Protocol_Publication(); pub.data = data
            var push = PPush(); push.id = id; push.pub = pub
            var r = PReply(); r.push = push
            send(currentConn(), r)
        }
        func sendJoin(_ id: Int64, _ client: String) {
            var info = Centrifugal_Centrifuge_Protocol_ClientInfo(); info.client = client
            var join = Centrifugal_Centrifuge_Protocol_Join(); join.info = info
            var push = PPush(); push.id = id; push.join = join
            var r = PReply(); r.push = push
            send(currentConn(), r)
        }
        func sendLeave(_ id: Int64, _ client: String) {
            var info = Centrifugal_Centrifuge_Protocol_ClientInfo(); info.client = client
            var leave = Centrifugal_Centrifuge_Protocol_Leave(); leave.info = info
            var push = PPush(); push.id = id; push.leave = leave
            var r = PReply(); r.push = push
            send(currentConn(), r)
        }
    }

    private final class SubDelegate: CentrifugeSubscriptionDelegate {
        var onSub: ((CentrifugeSubscribedEvent) -> Void)?
        var onPub: ((CentrifugePublicationEvent) -> Void)?
        var onJoinH: ((CentrifugeJoinEvent) -> Void)?
        var onLeaveH: ((CentrifugeLeaveEvent) -> Void)?
        var onUnsub: ((CentrifugeUnsubscribedEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?(e) }
        func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) { onPub?(e) }
        func onJoin(_ s: CentrifugeSubscription, _ e: CentrifugeJoinEvent) { onJoinH?(e) }
        func onLeave(_ s: CentrifugeSubscription, _ e: CentrifugeLeaveEvent) { onLeaveH?(e) }
        func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) { onUnsub?(e) }
    }

    private var server: FakeServer!

    override func setUpWithError() throws {
        server = FakeServer()
        try server.start()
    }

    override func tearDown() {
        server.stop()
    }

    private func makeClient() -> CentrifugeClient {
        var cfg = CentrifugeClientConfig()
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return CentrifugeClient(endpoint: "ws://127.0.0.1:\(server.port)/connection/websocket", config: cfg)
    }

    func testFlagOfferedAndPushesRoutedByID() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let pub = expectation(description: "pub")
        let join = expectation(description: "join")
        let leave = expectation(description: "leave")
        var pubData = Data()
        d.onSub = { _ in subscribed.fulfill() }
        d.onPub = { e in pubData = e.data; pub.fulfill() }
        d.onJoinH = { _ in join.fulfill() }
        d.onLeaveH = { _ in leave.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        XCTAssertEqual(server.lastFlag & 1, 1, "subscribe must offer the compaction flag")
        server.sendPub(42, Data("{\"a\":1}".utf8))
        wait(for: [pub], timeout: 5)
        XCTAssertEqual(String(data: pubData, encoding: .utf8), "{\"a\":1}")
        server.sendJoin(42, "joiner")
        server.sendLeave(42, "leaver")
        wait(for: [join, leave], timeout: 5)
    }

    func testUnknownIDDropped() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let pub = expectation(description: "pub")
        var lastData = Data()
        var pubCount = 0
        d.onSub = { _ in subscribed.fulfill() }
        d.onPub = { e in lastData = e.data; pubCount += 1; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        server.sendPub(99, Data("{\"stray\":true}".utf8)) // unknown id, dropped
        server.sendPub(42, Data("{\"ok\":true}".utf8))     // known id
        wait(for: [pub], timeout: 5)
        // Give a stray delivery a chance to (wrongly) arrive.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(pubCount, 1, "unknown id push must be dropped")
        XCTAssertEqual(String(data: lastData, encoding: .utf8), "{\"ok\":true}")
    }

    func testIDDroppedOnUnsubscribeRefreshedOnResubscribe() throws {
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let unsub = expectation(description: "unsubscribed")
        let resubscribed = expectation(description: "resubscribed")
        let pub = expectation(description: "pub")
        var subCount = 0
        var lastData = Data()
        var pubCount = 0
        d.onSub = { _ in subCount += 1; if subCount == 1 { subscribed.fulfill() } else { resubscribed.fulfill() } }
        d.onUnsub = { _ in unsub.fulfill() }
        d.onPub = { e in lastData = e.data; pubCount += 1; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        sub.unsubscribe()
        wait(for: [unsub], timeout: 5)
        server.sendPub(42, Data("{\"stale\":true}".utf8)) // old id, dropped
        server.setNextChannelId(43)
        sub.subscribe()
        wait(for: [resubscribed], timeout: 5)
        server.sendPub(43, Data("{\"fresh\":true}".utf8))
        wait(for: [pub], timeout: 5)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(pubCount, 1, "stale push for old id must be dropped")
        XCTAssertEqual(String(data: lastData, encoding: .utf8), "{\"fresh\":true}")
    }

    func testSameIDReRegisteredAfterReconnect() throws {
        // Regression guard (found in the dart port): the client drops the ID
        // registry on teardown (IDs are server-session-scoped), and on reconnect
        // the server commonly assigns the SAME ID again. The subscription must
        // re-register it even though its own remembered ID is unchanged.
        let client = makeClient()
        client.connect()
        defer { client.disconnect() }
        let d = SubDelegate()
        let subscribed = expectation(description: "subscribed")
        let resubscribed = expectation(description: "resubscribed")
        let pub = expectation(description: "pub")
        var subCount = 0
        var lastData = Data()
        d.onSub = { _ in subCount += 1; if subCount == 1 { subscribed.fulfill() } else { resubscribed.fulfill() } }
        d.onPub = { e in lastData = e.data; pub.fulfill() }
        let sub = try client.newSubscription(channel: "compacted", delegate: d)
        sub.subscribe()
        wait(for: [subscribed], timeout: 5)
        client.disconnect()
        client.connect()
        wait(for: [resubscribed], timeout: 8)
        server.sendPub(42, Data("{\"after\":true}".utf8)) // same id 42
        wait(for: [pub], timeout: 5)
        XCTAssertEqual(String(data: lastData, encoding: .utf8), "{\"after\":true}")
    }
}
