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

    /// Starts opening the connection. A transport object is used for one connection
    /// attempt only: `connect()` is called once.
    func connect()
    /// Closes the connection, or aborts the attempt in progress. The transport calls
    /// none of its callbacks afterwards.
    func close()
    func write(data: Data)
}
