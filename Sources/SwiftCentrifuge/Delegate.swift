//
//  Delegate.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public struct CentrifugeConnectEvent{
    public var client: String
}

public struct CentrifugeDisconnectEvent{
    public var code: UInt32
    public var reason: String
    public var reconnect: Bool
}

public struct CentrifugeFailEvent{
    public var reason: CentrifugeClientFailReason
}

public struct CentrifugeTokenEvent {}

public struct CentrifugeJoinEvent {
    public var client: String
    public var user: String
    public var connInfo: Data
    public var chanInfo: Data
}

public struct CentrifugeLeaveEvent {
    public var client: String
    public var user: String
    public var connInfo: Data
    public var chanInfo: Data
}

public struct CentrifugeMessageEvent {
    public var data: Data
}

public struct CentrifugeErrorEvent {
    public var error: Error
}

public struct CentrifugePublicationEvent {
    public var data: Data
    public var offset: UInt64
    public var tags: [String: String]
    var info: CentrifugeClientInfo?
}

public struct CentrifugeSubscriptionTokenEvent {
    public var channel: String
}

public struct CentrifugeSubscriptionErrorEvent {
    public var error: Error
}

public struct CentrifugeSubscribeEvent {
    public var recovered = false
}

public struct CentrifugeUnsubscribeEvent {}

public struct CentrifugeSubscriptionFailEvent {
    public var reason: CentrifugeSubscriptionFailReason
}

public struct CentrifugeServerSubscribeEvent {
    public var channel: String
    public var recovered = false
}

public struct CentrifugeServerUnsubscribeEvent {
    public var channel: String
}

public struct CentrifugeServerPublicationEvent {
    public var channel: String
    public var data: Data
    public var offset: UInt64
    public var tags: [String: String]
    var info: CentrifugeClientInfo?
}

public struct CentrifugeServerJoinEvent {
    public var channel: String
    public var client: String
    public var user: String
    public var connInfo: Data?
    public var chanInfo: Data?
}

public struct CentrifugeServerLeaveEvent {
    public var channel: String
    public var client: String
    public var user: String
    public var connInfo: Data?
    public var chanInfo: Data?
}

public protocol CentrifugeClientDelegate: AnyObject {
    func onConnect(_ client: CentrifugeClient, _ event: CentrifugeConnectEvent)
    func onDisconnect(_ client: CentrifugeClient, _ event: CentrifugeDisconnectEvent)
    func onFail(_ client: CentrifugeClient, _ event: CentrifugeFailEvent)

    func onConnectionToken(_ client: CentrifugeClient, _ event: CentrifugeTokenEvent, completion: @escaping (Result<String, Error>) -> ())
    func onSubscriptionToken(_ client: CentrifugeClient, _ event: CentrifugeSubscriptionTokenEvent, completion: @escaping (Result<String, Error>) -> ())

    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent)
    
    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent)
    
    func onSubscribe(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribeEvent)
    func onUnsubscribe(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribeEvent)
    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent)
    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent)
    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent)
}

public extension CentrifugeClientDelegate {
    func onConnect(_ client: CentrifugeClient, _ event: CentrifugeConnectEvent) {}
    func onDisconnect(_ client: CentrifugeClient, _ event: CentrifugeDisconnectEvent) {}
    func onFail(_ client: CentrifugeClient, _ event: CentrifugeFailEvent) {}

    func onSubscriptionToken(_ client: CentrifugeClient, _ event: CentrifugeSubscriptionTokenEvent, completion: @escaping (Result<String, Error>) -> ()) {
        completion(.success(""))
    }
    func onConnectionToken(_ client: CentrifugeClient, _ event: CentrifugeTokenEvent, completion: @escaping (Result<String, Error>) -> ()) {
        completion(.success(""))
    }
    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {}
    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent) {}
    func onSubscribe(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribeEvent) {}
    func onUnsubscribe(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribeEvent) {}
    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {}
    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent) {}
    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent) {}
}

public protocol CentrifugeSubscriptionDelegate: AnyObject {
    func onSubscribe(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribeEvent)
    func onUnsubscribe(_ sub: CentrifugeSubscription, _ event: CentrifugeUnsubscribeEvent)
    func onFail(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionFailEvent)

    func onError(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionErrorEvent)
    
    func onPublication(_ sub: CentrifugeSubscription, _ event: CentrifugePublicationEvent)
    func onJoin(_ sub: CentrifugeSubscription, _ event: CentrifugeJoinEvent)
    func onLeave(_ sub: CentrifugeSubscription, _ event: CentrifugeLeaveEvent)
}

public extension CentrifugeSubscriptionDelegate {
    func onSubscribe(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribeEvent) {}
    func onUnsubscribe(_ sub: CentrifugeSubscription, _ event: CentrifugeUnsubscribeEvent) {}
    func onFail(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionFailEvent) {}
    
    func onError(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionErrorEvent) {}
    
    func onPublication(_ sub: CentrifugeSubscription, _ event: CentrifugePublicationEvent) {}
    func onJoin(_ sub: CentrifugeSubscription, _ event: CentrifugeJoinEvent) {}
    func onLeave(_ sub: CentrifugeSubscription, _ event: CentrifugeLeaveEvent) {}
}
