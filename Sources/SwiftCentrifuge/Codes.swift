//
//  Codes.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 26.04.2022.
//

import Foundation

let disconnectedCodeDisconnectCalled: UInt32 = 0
let disconnectedCodeUnauthorized: UInt32 = 1
let disconnectCodeBadProtocol: UInt32 = 2
let disconnectCodeMessageSizeLimit: UInt32 = 3

let connectingCodeConnectCalled: UInt32 = 0
let connectingCodeTransportClosed: UInt32 = 1
let connectingCodeNoPing: UInt32 = 2
let connectingCodeSubscribeTimeout: UInt32 = 3
let connectingCodeUnsubscribeError: UInt32 = 4

let subscribingCodeSubscribeCalled: UInt32 = 0
let subscribingCodeTransportClosed: UInt32 = 1

let unsubscribedCodeUnsubscribeCalled: UInt32 = 0
let unsubscribedCodeUnauthorized: UInt32 = 1
let unsubscribedCodeClientClosed: UInt32 = 2

func interpretCloseCode(_ code: UInt32) -> (code: UInt32, reconnect: Bool) {
    // We act according to Disconnect code semantics.
    // See https://github.com/centrifugal/centrifuge/blob/master/disconnect.go.
    var code = code
    var reconnect = code < 3500 || code >= 5000 || (code >= 4000 && code < 4500)
    if code < 3000 {
        // We expose codes defined by Centrifuge protocol, hiding details
        // about transport-specific error codes. We may have extra optional
        // transportCode field in the future.
        if code == 1009 {
            code = disconnectCodeMessageSizeLimit
            reconnect = false
        } else {
            code = connectingCodeTransportClosed
        }
    }
    
    return (code, reconnect)
}
