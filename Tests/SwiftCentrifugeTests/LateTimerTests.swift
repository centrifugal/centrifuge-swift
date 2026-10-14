import Foundation
import Network
import SwiftProtobuf
import Testing
@testable import SwiftCentrifuge

/// A timeout that fires late, because the process was suspended, lets what arrived
/// meanwhile be handled first. The suspension is simulated by an event handler that
/// blocks the client's queue; the server sends the awaited frame right after it.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class LateTimerTests: @unchecked Sendable {

    private final class ClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
        let lock = NSLock()
        var connecting = 0
        var connected = 0
        /// How long onMessage blocks the client's queue.
        var freeze: TimeInterval = 0
        func onConnecting(_ c: CentrifugeClient, _ e: CentrifugeConnectingEvent) { lock.lock(); connecting += 1; lock.unlock() }
        func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) { lock.lock(); connected += 1; lock.unlock() }
        func onMessage(_ c: CentrifugeClient, _ e: CentrifugeMessageEvent) { Thread.sleep(forTimeInterval: freeze) }
        var connectingCount: Int { lock.lock(); defer { lock.unlock() }; return connecting }
        var connectedCount: Int { lock.lock(); defer { lock.unlock() }; return connected }
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var get: T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    }

    private let server: FakeCentrifugoServer

    init() throws {
        server = FakeCentrifugoServer()
        try server.start()
    }

    deinit {
        server.stop()
    }

    private func messagePush() -> FakeCentrifugoServer.PPush {
        var push = FakeCentrifugoServer.PPush()
        push.message = Centrifugal_Centrifuge_Protocol_Message()
        return push
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// The reply to a call arrives right after a freeze that outlasted the call's
    /// timeout: the call succeeds.
    @Test func replyArrivingRightAfterFreezeWins() async throws {
        let server = self.server
        server.dropCommand = { cmd in
            guard cmd.hasRpc else { return false }
            // Freeze the client for 2 s, and reply right after that.
            server.sendPush(self.messagePush())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.2) {
                var reply = FakeCentrifugoServer.PReply()
                reply.id = cmd.id
                reply.rpc = Centrifugal_Centrifuge_Protocol_RPCResult()
                server.sendReply(reply)
            }
            return true
        }
        let delegate = ClientDelegate()
        delegate.freeze = 2
        var cfg = CentrifugeClientConfig()
        cfg.timeout = 0.5
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        #expect(await waitUntil(3) { delegate.connectedCount == 1 })

        let done = Expectation("rpc completed")
        let result = Box<Error?>(nil)
        client.rpc(method: "m", data: Data()) { res in
            if case .failure(let error) = res { result.set(error) }
            done.fulfill()
        }
        await fulfillment(of: done, within: 5)
        #expect(result.get == nil, "rpc failed: \(String(describing: result.get))")
    }

    /// A server ping arrives right after a freeze that outlasted the ping timeout:
    /// the client stays connected.
    @Test func pingArrivingRightAfterFreezeKeepsConnection() async throws {
        var res = FakeCentrifugoServer.PConnectResult()
        res.client = "fake-client"; res.version = "0.0.0"; res.ping = 1
        server.connectResult = res
        let delegate = ClientDelegate()
        delegate.freeze = 3
        var cfg = CentrifugeClientConfig()
        cfg.maxServerPingDelay = 0.3
        let client = CentrifugeClient(endpoint: server.url, config: cfg, delegate: delegate)
        client.connect()
        defer { client.disconnect() }
        #expect(await waitUntil(3) { delegate.connectedCount == 1 })

        // The ping timer is due 1.3 s after connecting; the client is frozen for 3 s.
        server.sendPush(messagePush())
        try await Task.sleep(nanoseconds: 3_200_000_000)
        for _ in 0..<3 {
            server.sendReply(FakeCentrifugoServer.PReply())
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(delegate.connectingCount == 1, "the client reconnected")
        #expect(client.state == .connected)
    }
}
