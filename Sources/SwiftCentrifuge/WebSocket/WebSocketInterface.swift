//
//  WebSocketInterface.swift
//  SwiftCentrifuge
//
//  Created by Anton Selyanin on 03.05.2023.
//

import Foundation


protocol WebSocketInterface: AnyObject {
    var onConnect: (() -> Void)? { get set }
    var onDisconnect: ((CentrifugeDisconnectOptions, Error?) -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }

    func update(headers: [String: String?])
    
    func connect()
    func disconnect()
    func write(data: Data)
}
