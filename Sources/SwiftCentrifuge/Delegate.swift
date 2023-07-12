//
//  Delegate.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public struct CentrifugeConnectedEvent{
    public var client: String
    public var data: Data?
}

public struct CentrifugeDisconnectedEvent{
    public var code: UInt32
    public var reason: String
}

public struct CentrifugeConnectingEvent{
    public var code: UInt32
    public var reason: String
}

public struct CentrifugeConnectionTokenEvent {}

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
    public var info: CentrifugeClientInfo?
}

public struct CentrifugeSubscriptionTokenEvent {
    public var channel: String
}

public struct CentrifugeSubscriptionErrorEvent {
    public var error: Error
}

public struct CentrifugeSubscribedEvent {
    public var wasRecovering = false
    public var recovered = false
    public var positioned = false
    public var recoverable = false
    public var streamPosition: StreamPosition? = nil
    public var data: Data?
}

public struct CentrifugeUnsubscribedEvent {
    public var code: UInt32
    public var reason: String
}

public struct CentrifugeSubscribingEvent {
    public var code: UInt32
    public var reason: String
}

public struct CentrifugeServerSubscribedEvent {
    public var channel: String
    public var wasRecovering = false
    public var recovered = false
    public var positioned = false
    public var recoverable = false
    public var streamPosition: StreamPosition? = nil
    public var data: Data?
}

public struct CentrifugeServerSubscribingEvent {
    public var channel: String
}

public struct CentrifugeServerUnsubscribedEvent {
    public var channel: String
}

public struct CentrifugeServerPublicationEvent {
    public var channel: String
    public var data: Data
    public var offset: UInt64
    public var tags: [String: String]
    public var info: CentrifugeClientInfo?
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
    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent)
    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent)
    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent)
    
    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent)
    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent)
    
    func onSubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribedEvent)
    func onUnsubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribedEvent)
    func onSubscribing(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribingEvent)

    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent)
    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent)
    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent)
}

public extension CentrifugeClientDelegate {
    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {}
    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {}
    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {}
    
    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {}
    
    func onMessage(_ client: CentrifugeClient, _ event: CentrifugeMessageEvent) {}
    
    func onSubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribedEvent) {}
    func onUnsubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribedEvent) {}
    func onSubscribing(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribingEvent) {}
    
    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {}
    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent) {}
    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent) {}
}

public protocol CentrifugeSubscriptionDelegate: AnyObject {
    func onSubscribed(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribedEvent)
    func onUnsubscribed(_ sub: CentrifugeSubscription, _ event: CentrifugeUnsubscribedEvent)
    func onSubscribing(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribingEvent)
    
    func onError(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionErrorEvent)
    
    func onPublication(_ sub: CentrifugeSubscription, _ event: CentrifugePublicationEvent)
    func onJoin(_ sub: CentrifugeSubscription, _ event: CentrifugeJoinEvent)
    func onLeave(_ sub: CentrifugeSubscription, _ event: CentrifugeLeaveEvent)
}

public extension CentrifugeSubscriptionDelegate {
    func onSubscribed(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribedEvent) {}
    func onUnsubscribed(_ sub: CentrifugeSubscription, _ event: CentrifugeUnsubscribedEvent) {}
    func onSubscribing(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribingEvent) {}
    
    func onError(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionErrorEvent) {}
    
    func onPublication(_ sub: CentrifugeSubscription, _ event: CentrifugePublicationEvent) {}
    func onJoin(_ sub: CentrifugeSubscription, _ event: CentrifugeJoinEvent) {}
    func onLeave(_ sub: CentrifugeSubscription, _ event: CentrifugeLeaveEvent) {}
}
