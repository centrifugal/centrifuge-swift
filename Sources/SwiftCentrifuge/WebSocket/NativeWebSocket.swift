//
//  NativeWebSocket.swift
//  SwiftCentrifuge
//
//  Created by Anton Selyanin on 03.05.2023.
//

import Foundation


import Foundation

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class NativeWebSocket: NSObject, WebSocketInterface, URLSessionWebSocketDelegate {

    var onConnect: (() -> Void)?

    var onDisconnect: ((CentrifugeDisconnectOptions, Error?) -> Void)?

    var onData: ((Data) -> Void)?

    private var session: URLSession?

    private let log: CentrifugeLogger
    private var request: URLRequest //this is only to allow headers, timeout, etc to be modified on reconnect
    private let queue: DispatchQueue

    /// The websocket is considered 'active' when `task` is not nil
    private var task: URLSessionWebSocketTask?

    init(request: URLRequest, queue: DispatchQueue, log: CentrifugeLogger) {
        var request = request
        request.setValue("Sec-WebSocket-Protocol", forHTTPHeaderField: "centrifuge-protobuf")
        self.request = request
        self.log = log
        self.queue = queue
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func connect() {
        assertIsOnQueue(queue)
        if let task = task {
            log.warning("Creating a new connection while the previous is active, socket state: \(task.state.asString)")
        }

        log.debug("Connecting...")

        task = getOrCreateSession().webSocketTask(with: request)
        doRead()
        task?.resume()
    }

    func disconnect() {
        assertIsOnQueue(queue)

        guard task != nil else { return }

        log.debug("Disconnecting...")
        // This will trigger "did close" delegate method invocation
        task?.cancel(with: .goingAway, reason: nil)
    }

    func write(data: Data) {
        assertIsOnQueue(queue)
        guard let task = task else {
            log.warning("Attempted to write to an inactive websocket connection")
            return
        }

        task.send(.data(data), completionHandler: { [weak self] error in
            guard let error = error else { return }
            self?.log.trace("Failed to send message, error: \(error)")
        })
    }

    func update(headers: [String : String?]) {
        for (key, value) in headers {
            self.request.setValue(value, forHTTPHeaderField: key)
        }
    }
    
    private func doRead() {
        task?.receive { [weak self] (result) in
            guard let self = self else { return }
            assertIsOnQueue(self.queue)

            switch result {
                case .success(let message):
                    switch message {
                        case .string:
                            self.log.warning("Received unexpected string packet")
                        case .data(let data):
                            self.onData?(data)

                        @unknown default:
                            break
                    }

                case .failure(let error):
                    self.log.trace("Read error: \(error)")
            }

            self.doRead()
        }
    }

    private func getOrCreateSession() -> URLSession {
        if let session = session {
            return session
        }

        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue

        // For some reason, `URLSessionWebSocketTask` will only respect the proxy
        // configuration if started with a URL and not a URLRequest. As a temporary
        // workaround, port header information from the request to the session.
        //
        // We copied this workaround from Signal-iOS web socket implementation
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = request.allHTTPHeaderFields

        let delegate = URLSessionDelegateBox(delegate: self)

        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: operationQueue)
        self.session = session

        return session
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        assertIsOnQueue(queue)
        log.debug("Connected")
        self.onConnect?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        assertIsOnQueue(queue)
        guard let task = self.task, task === webSocketTask else {
            // Ignore callbacks from obsolete tasks
            return
        }

        handleTaskClose(task: task, code: closeCode, reason: reason, error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        assertIsOnQueue(queue)
        guard let task = task as? URLSessionWebSocketTask, task === self.task else {
            // Ignore callbacks from obsolete tasks
            return
        }

        handleTaskClose(task: task, code: task.closeCode, reason: task.closeReason, error: error)
    }

    private func handleTaskClose(task: URLSessionWebSocketTask,
                                 code: URLSessionWebSocketTask.CloseCode, reason: Data?, error: Error?) {
        let reason = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "transport closed"

        log.debug("WebSocket closed, code: \(code.rawValue), reason: \(reason)")

        let (code, reconnect) = interpretCloseCode(UInt32(code.rawValue))
        let disconnect = CentrifugeDisconnectOptions(code: code, reason: reason, reconnect: reconnect)

        self.log.trace("Socket disconnected, code: \(task.closeCode.rawValue), reconnect: \(reconnect)")

        self.task?.cancel()
        self.task = nil
        self.onDisconnect?(disconnect, error)
    }
}


/// URLSession holds it's delegate by strong reference.
/// We need a wrapper to break a reference cycle between `NativeWebSocket` and `URLSession`
///
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private final class URLSessionDelegateBox: NSObject, URLSessionWebSocketDelegate {
    private weak var delegate: URLSessionWebSocketDelegate?

    init(delegate: URLSessionWebSocketDelegate?) {
        self.delegate = delegate
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        delegate?.urlSession?(
            session, webSocketTask: webSocketTask, didOpenWithProtocol: `protocol`)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        delegate?.urlSession?(
            session, webSocketTask: webSocketTask, didCloseWith: closeCode, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        delegate?.urlSession?(session, task: task, didCompleteWithError: error)
    }
}

private extension URLSessionTask.State {
    var asString: String {
        switch self {
            case .running:
                return "running"
            case .suspended:
                return "suspended"
            case .canceling:
                return "cancelling"
            case .completed:
                return "completed"
            @unknown default:
                return "unknown"
        }
    }
}
