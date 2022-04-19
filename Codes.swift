//
//  Codes.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 19.04.2022.
//

import Foundation

let disconnectedCodeDisconnectCalled: UInt32 = 0;
let disconnectedCodeUnauthorized: UInt32 = 1;
let disconnectCodeBadProtocol: UInt32 = 2;
let disconnectCodeMessageSizeLimit: UInt32 = 3;

let connectingCodeConnectCalled: UInt32 = 0;
let connectingCodeTransportClosed: UInt32 = 1;
let connectingCodeNoPing: UInt32 = 2;
let connectingCodeSubscribeTimeout: UInt32 = 3;
let connectingCodeUnsubscribeError: UInt32 = 4;

let subscribingCodeSubscribeCalled: UInt32 = 0;
let subscribingCodeTransportClosed: UInt32 = 1;

let unsubscribedCodeUnsubscribeCalled: UInt32 = 0;
let unsubscribedCodeUnauthorized: UInt32 = 1;
let unsubscribedCodeClientClosed: UInt32 = 2;
