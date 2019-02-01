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
    public var reason: String
    public var reconnect: Bool
}

public struct CentrifugeRefreshEvent{}

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

public struct CentrifugePublishEvent {
    public var uid: String
    public var data: Data
    var info: Proto_ClientInfo?
}

public struct CentrifugePrivateSubEvent {
    public var client: String
    public var channel: String
}

public struct CentrifugeSubscribeErrorEvent {
    public var code: UInt32
    public var message: String
}

public struct CentrifugeSubscribeSuccessEvent {
    public var resubscribe = false
    public var recovered = false
}

public struct CentrifugeUnsubscribeEvent {}

public protocol CentrifugeClientDelegate: class {
    func onConnect(_ c: CentrifugeClient, _ e: CentrifugeConnectEvent)
    func onDisconnect(_ c: CentrifugeClient, _ e: CentrifugeDisconnectEvent)
    func onPrivateSub(_ c: CentrifugeClient, _ e: CentrifugePrivateSubEvent, completion: (_ token: String) -> ())
    func onRefresh(_ c: CentrifugeClient, _ e: CentrifugeRefreshEvent, completion: (_ token: String) -> ())
    func onMessage(_ c: CentrifugeClient, _ e: CentrifugeMessageEvent)
}

extension CentrifugeClientDelegate {
    func onConnect(_ c: CentrifugeClient, _ e: CentrifugeConnectEvent) {}
    func onDisconnect(_ c: CentrifugeClient, _ e: CentrifugeDisconnectEvent) {}
    func onPrivateSub(_ c: CentrifugeClient, _ e: CentrifugePrivateSubEvent, completion: (_ token: String) -> ()) {
        completion("")
    }
    func onRefresh(_ c: CentrifugeClient, _ e: CentrifugeRefreshEvent, completion: (_ token: String) -> ()) {
        completion("")
    }
    func onMessage(_ c: CentrifugeClient, _ e: CentrifugeMessageEvent) {}
}

public protocol CentrifugeSubscriptionDelegate {
    func onPublish(_ s: CentrifugeSubscription, _ e: CentrifugePublishEvent)
    func onJoin(_ s: CentrifugeSubscription, _ e: CentrifugeJoinEvent)
    func onLeave(_ s: CentrifugeSubscription, _ e: CentrifugeLeaveEvent)
    func onSubscribeError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeErrorEvent)
    func onSubscribeSuccess(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeSuccessEvent)
    func onUnsubscribe(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribeEvent)
}

extension CentrifugeSubscriptionDelegate {
    func onPublish(_ s: CentrifugeSubscription, _ e: CentrifugePublishEvent) {}
    func onJoin(_ s: CentrifugeSubscription, _ e: CentrifugeJoinEvent) {}
    func onLeave(_ s: CentrifugeSubscription, _ e: CentrifugeLeaveEvent) {}
    func onSubscribeError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeErrorEvent) {}
    func onSubscribeSuccess(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeSuccessEvent) {}
    func onUnsubscribe(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribeEvent) {}
}
