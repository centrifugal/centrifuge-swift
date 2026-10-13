import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// Connection lifecycle tests over both transports: the client opens a new
/// transport for every connection attempt, closes the old one itself (also on a
/// dead link or mid-handshake), and limits the opening handshake by
/// `config.timeout`.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class TransportTests: @unchecked Sendable {

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        let lock = NSLock()
        var connected = 0
        var connecting = 0
        var errors: [Error] = []
        var onConn: (() -> Void)?
        var onErr: ((CentrifugeErrorEvent) -> Void)?
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) {
            lock.lock(); connected += 1; lock.unlock()
            onConn?()
        }
        func onConnecting(_ c: CentrifugeClient, _ e: CentrifugeConnectingEvent) {
            lock.lock(); connecting += 1; lock.unlock()
        }
        func onError(_ c: CentrifugeClient, _ e: CentrifugeErrorEvent) {
            lock.lock(); errors.append(e.error); lock.unlock()
            onErr?(e)
        }
        var connectingCount: Int { lock.lock(); defer { lock.unlock() }; return connecting }
        var connectedCount: Int { lock.lock(); defer { lock.unlock() }; return connected }
    }

    private final class SubDelegate: CentrifugeSubscriptionDelegate, @unchecked Sendable {
        var onSub: (() -> Void)?
        var onPub: ((CentrifugePublicationEvent) -> Void)?
        func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) { onSub?() }
        func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) { onPub?(e) }
    }

    /// Accepts TCP connections and never answers: a server (or a proxy) that hangs
    /// in the WebSocket upgrade.
    private final class SilentTCPServer: @unchecked Sendable {
        private var listener: NWListener!
        private let queue = DispatchQueue(label: "silent.tcp.server")
        private let lock = NSLock()
        private var _accepted = 0
        private var open = Set<ObjectIdentifier>()

        var port: UInt16 { listener.port!.rawValue }
        var url: String { "ws://127.0.0.1:\(port)/connection/websocket" }
        var accepted: Int { lock.lock(); defer { lock.unlock() }; return _accepted }
        var openConnections: Int { lock.lock(); defer { lock.unlock() }; return open.count }

        func start() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                self.lock.lock(); self._accepted += 1; self.open.insert(ObjectIdentifier(conn)); self.lock.unlock()
                conn.start(queue: self.queue)
                self.receive(conn)
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
        }

        func stop() { listener.cancel() }

        private func receive(_ conn: NWConnection) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
                guard let self = self else { return }
                if isComplete || error != nil {
                    self.lock.lock(); self.open.remove(ObjectIdentifier(conn)); self.lock.unlock()
                    conn.cancel()
                    return
                }
                self.receive(conn)
            }
        }
    }

    private func makeConfig(native: Bool) -> CentrifugeClientConfig {
        var cfg = CentrifugeClientConfig()
        cfg.useNativeWebSocket = native
        cfg.minReconnectDelay = 0.05
        cfg.maxReconnectDelay = 0.2
        return cfg
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// A link that goes dead without closing (no data, no FIN): the client notices
    /// the missing pings and must reconnect at once, without waiting for the old
    /// socket to close - it never will.
    @Test(arguments: [false, true])
    func deadLinkReconnects(native: Bool) async throws {
        let server = FakeCentrifugoServer()
        var res = FakeCentrifugoServer.PConnectResult()
        res.client = "fake-client"; res.version = "0.0.0"; res.ping = 1
        server.connectResult = res
        try server.start()
        defer { server.stop() }
        let proxy = BlackholeProxy(upstreamPort: server.port)
        try proxy.start()
        defer { proxy.stop() }

        var cfg = makeConfig(native: native)
        cfg.maxServerPingDelay = 0.3
        let delegate = ClientDelegate()
        let first = Expectation("connected")
        let second = Expectation("reconnected after the link went dead")
        second.expectedFulfillmentCount = 2
        delegate.onConn = { first.fulfill(); second.fulfill() }
        let client = CentrifugeClient(endpoint: proxy.url, config: cfg, delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: first, within: 5)
        proxy.blackhole()
        await fulfillment(of: second, within: 5)
        #expect(proxy.accepted == 2)
        // The dead socket is closed by the client, not left behind.
        #expect(await waitUntil(3) { proxy.openConnections == 1 }, "open connections: \(proxy.openConnections)")
    }

    /// A server that accepts the TCP connection but never answers the upgrade: each
    /// attempt fails after `config.timeout` with an error event and the client
    /// retries. `disconnect()` closes the socket of the attempt in progress, and a
    /// later `connect()` starts a new attempt.
    @Test(arguments: [false, true])
    func hangingHandshakeTimesOut(native: Bool) async throws {
        let server = SilentTCPServer()
        try server.start()
        defer { server.stop() }

        var cfg = makeConfig(native: native)
        cfg.timeout = 0.5
        let delegate = ClientDelegate()
        let timedOut = Expectation("transport timeout reported")
        timedOut.expectedFulfillmentCount = 2
        delegate.onErr = { e in
            if case CentrifugeError.transportError(let error) = e.error,
               case CentrifugeError.timeout? = error as? CentrifugeError {
                timedOut.fulfill()
            }
        }
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        await fulfillment(of: timedOut, within: 5)
        #expect(await waitUntil(3) { server.accepted >= 3 }, "accepted: \(server.accepted)")
        #expect(client.state == .connecting)

        client.disconnect()
        #expect(await waitUntil(3) { server.openConnections == 0 }, "open connections: \(server.openConnections)")

        let before = server.accepted
        client.connect()
        #expect(await waitUntil(3) { server.accepted > before }, "connect() after disconnect() made no attempt")
    }

    /// Messages larger than 1 MiB (URLSessionWebSocketTask's default limit) are
    /// delivered; the server decides how large a message may be.
    @Test(arguments: [false, true])
    func largeMessageDelivered(native: Bool) async throws {
        let server = FakeCentrifugoServer()
        try server.start()
        defer { server.stop() }

        let delegate = ClientDelegate()
        let client = CentrifugeClient(endpoint: server.url, config: makeConfig(native: native), delegate: delegate)
        client.connect()
        defer { client.disconnect() }

        let subscribed = Expectation("subscribed")
        let published = Expectation("large publication")
        let size = 2 * 1024 * 1024
        let d = SubDelegate()
        d.onSub = { subscribed.fulfill() }
        d.onPub = { e in if e.data.count == size { published.fulfill() } }
        let sub = try client.newSubscription(channel: "big", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)

        server.publishChannel("big", Data(repeating: 0x61, count: size))
        await fulfillment(of: published, within: 10)
        #expect(delegate.connectingCount == 1, "the client reconnected \(delegate.connectingCount - 1) time(s)")
    }

    /// A message that ends the connection (here a disconnect push) also ends the
    /// frame it came in: the rest of the frame is not delivered.
    @Test(arguments: [false, true])
    func restOfFrameDroppedAfterDisconnectPush(native: Bool) async throws {
        let server = FakeCentrifugoServer()
        try server.start()
        defer { server.stop() }

        let client = CentrifugeClient(endpoint: server.url, config: makeConfig(native: native))
        client.connect()
        defer { client.disconnect() }

        let subscribed = Expectation("subscribed")
        let published = Expectation("publication after the disconnect push")
        published.isInverted = true
        let d = SubDelegate()
        d.onSub = { subscribed.fulfill() }
        d.onPub = { _ in published.fulfill() }
        let sub = try client.newSubscription(channel: "ch", delegate: d)
        sub.subscribe()
        await fulfillment(of: subscribed, within: 5)

        var disconnect = Centrifugal_Centrifuge_Protocol_Disconnect()
        disconnect.code = 3000
        disconnect.reason = "reconnect"
        var r1 = FakeCentrifugoServer.PReply()
        r1.push.disconnect = disconnect
        var pub = Centrifugal_Centrifuge_Protocol_Publication()
        pub.data = Data("{}".utf8)
        var r2 = FakeCentrifugoServer.PReply()
        r2.push.channel = "ch"
        r2.push.pub = pub
        server.sendFrame([r1, r2])

        await fulfillment(of: published, within: 0.5)
    }

    /// Many short-lived connections in a row: every attempt has its own socket,
    /// which is closed and released while the server may still be sending.
    @Test(arguments: [false, true])
    func rapidReconnectsAreSafe(native: Bool) async throws {
        let server = FakeCentrifugoServer()
        try server.start()
        defer { server.stop() }

        let delegate = ClientDelegate()
        let client = CentrifugeClient(endpoint: server.url, config: makeConfig(native: native), delegate: delegate)
        defer { client.disconnect() }
        for i in 1...150 {
            client.connect()
            #expect(await waitUntil(3) { delegate.connectedCount == i }, "connect \(i)")
            // Keep the server writing while the client closes the socket.
            for _ in 0..<20 { server.publishChannel("ch", Data(repeating: 0x61, count: 1024)) }
            client.disconnect()
        }
    }
}
