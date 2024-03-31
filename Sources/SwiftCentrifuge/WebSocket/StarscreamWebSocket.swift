//
//  StarscreamWebSocket.swift
//  SwiftCentrifuge
//
//  Created by Anton Selyanin on 03.05.2023.
//

import Foundation

final class StarscreamWebSocket: WebSocketInterface {
    private let log: CentrifugeLogger

    var onConnect: (() -> Void)?
    var onDisconnect: ((CentrifugeDisconnectOptions, Error?) -> Void)?
    var onData: ((Data) -> Void)?

    private let socket: WebSocket
    private let queue: DispatchQueue

    init(request: URLRequest, tlsSkipVerify: Bool, queue: DispatchQueue, log: CentrifugeLogger) {
        self.socket = WebSocket(request: request, protocols: ["centrifuge-protobuf"])
        self.log = log
        self.queue = queue

        self.socket.callbackQueue = queue
        self.socket.disableSSLCertValidation = tlsSkipVerify
        setup()
    }

    func connect() {
        assertIsOnQueue(queue)
        log.debug("Connecting...")
        socket.connect()
    }

    func disconnect() {
        assertIsOnQueue(queue)
        log.debug("Disconnecting...")
        socket.disconnect()
    }

    func write(data: Data) {
        assertIsOnQueue(queue)
        socket.write(data: data)
    }

    func update(headers: [String : String?]) {
        for (key, value) in headers {
            self.socket.request.setValue(value, forHTTPHeaderField: key)
        }
    }
    
    private func setup() {
        socket.onConnect = { [weak self] in
            self?.onConnect?()
        }

        socket.onDisconnect = { [weak self] error in
            guard let self = self else { return }

            let disconnect: CentrifugeDisconnectOptions

            if let error = error as? WSError {
                let (code, reconnect) = interpretCloseCode(UInt32(error.code))
                disconnect = CentrifugeDisconnectOptions(code: code, reason: error.message, reconnect: reconnect)
            } else {
                disconnect = CentrifugeDisconnectOptions(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
            }
            self.onDisconnect?(disconnect, error)
        }

        socket.onData = { [weak self] data in
            self?.onData?(data)
        }
    }
}
