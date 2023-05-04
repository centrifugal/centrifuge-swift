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

    private let log: CentrifugeLogger
    private let request: URLRequest
    private let queue: DispatchQueue

    /// The websocket is considered 'active' when `task` is not nil
    private var task: URLSessionWebSocketTask?

    init(request: URLRequest, queue: DispatchQueue, log: CentrifugeLogger) {
        // TODO: add "centrifuge-protobuf"
        // TODO: add disableSSLCertValidation
        // TODO: use url request hack from Signal app
        self.request = request
        self.log = log
        self.queue = queue
    }

    func connect() {
        assertIsOnQueue(queue)
        guard task == nil else {
            log.warning("The websocket is already connected, ignoring connect request")
            return
        }

        log.debug("Connecting...")

        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue
        let session = URLSession(
            configuration: URLSessionConfiguration.default, delegate: self,
            delegateQueue: operationQueue)
        task = session.webSocketTask(with: request)
        doRead()
        task?.resume()
    }

    func disconnect() {
        assertIsOnQueue(queue)
        log.debug("Disconnecting...")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
                            self.log.trace("Received data packet")
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