import Foundation
import Network

/// TCP proxy in front of a test server that can turn the link into a dead one:
/// after `blackhole()` it drops every byte in both directions and closes nothing,
/// like a network path that silently went away (or a peer that was frozen). Only
/// a raw TCP proxy can do this: a WebSocket server, even a fake one, still answers
/// close frames at the protocol level.
final class BlackholeProxy: @unchecked Sendable {
    /// One client connection and its upstream connection. Its mutable state is
    /// guarded by the proxy's lock.
    private final class Link: @unchecked Sendable {
        let client: NWConnection
        let upstream: NWConnection
        var dead = false
        var clientOpen = true
        init(client: NWConnection, upstream: NWConnection) {
            self.client = client
            self.upstream = upstream
        }
    }

    private var listener: NWListener!
    private let upstreamPort: UInt16
    private let queue = DispatchQueue(label: "blackhole.proxy")
    private let lock = NSLock()
    private var links: [Link] = []

    init(upstreamPort: UInt16) {
        self.upstreamPort = upstreamPort
    }

    var port: UInt16 { listener.port!.rawValue }
    var url: String { "ws://127.0.0.1:\(port)/connection/websocket" }

    /// Number of client connections accepted so far.
    var accepted: Int { lock.lock(); defer { lock.unlock() }; return links.count }

    /// Number of accepted client connections the client has not closed yet.
    var openConnections: Int { lock.lock(); defer { lock.unlock() }; return links.filter(\.clientOpen).count }

    /// Kill the links open now: their bytes are dropped from here on, in both
    /// directions, and they are never closed. New connections work normally.
    func blackhole() {
        lock.lock(); defer { lock.unlock() }
        links.forEach { $0.dead = true }
    }

    func start() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] client in
            guard let self = self else { return }
            let upstream = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.upstreamPort)!, using: .tcp)
            let link = Link(client: client, upstream: upstream)
            self.lock.lock(); self.links.append(link); self.lock.unlock()
            client.start(queue: self.queue)
            upstream.start(queue: self.queue)
            self.pipe(link, from: client, to: upstream)
            self.pipe(link, from: upstream, to: client)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
        lock.lock(); let all = links; lock.unlock()
        all.forEach { $0.client.cancel(); $0.upstream.cancel() }
    }

    private func pipe(_ link: Link, from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            let closed = isComplete || error != nil
            self.lock.lock()
            let dead = link.dead
            if closed && from === link.client { link.clientOpen = false }
            self.lock.unlock()
            // A dead link drops everything, a close included: it never closes.
            if !dead, let data = data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if closed {
                if !dead { to.cancel() }
                return
            }
            self.pipe(link, from: from, to: to)
        }
    }
}
