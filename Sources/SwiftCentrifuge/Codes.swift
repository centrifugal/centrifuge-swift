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

// Subscription feature flags — bitmask sent in SubscribeRequest flag field.
//
// channelCompaction asks the server to replace the string channel name with a
// short numeric ID in subscription pushes (bandwidth optimization). Safe to
// request unconditionally: servers that don't support or don't allow it simply
// ignore the bit and keep sending the full channel name.
let subscriptionFlagChannelCompaction: Int64 = 1
let subscriptionFlagRejectUnrecovered: Int64 = 2

// Server error code returned when recovery from the provided position is
// impossible (only sent when subscriptionFlagRejectUnrecovered was requested).
let errorCodeUnrecoverablePosition: UInt32 = 112

// Server-sent "state invalidated" codes. The server determines that the client's
// cached state and/or token are no longer valid and asks the client to drop them
// and re-sync. 2502 arrives in an Unsubscribe push for a single subscription (the
// client clears the subscription state and resubscribes, since it's >= 2500); 3014
// arrives for the whole connection (the client clears the connection token to force
// a fresh one via the token getter, invalidates all subscriptions, reconnects).
let unsubscribedStateInvalidated: UInt32 = 2502
let disconnectedStateInvalidated: UInt32 = 3014

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
