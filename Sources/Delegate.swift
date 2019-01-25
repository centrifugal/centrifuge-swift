//
//  Delegate.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public struct CentrifugeConnectEvent{
    var client: String
}

public struct CentrifugeDisconnectEvent{
    var reason: String
    var reconnect: Bool
}

public struct CentrifugeRefreshEvent{}

public struct CentrifugeJoinEvent {
    var client: String
    var user: String
    var connInfo: Data
    var chanInfo: Data
}

public struct CentrifugeLeaveEvent {
    var client: String
    var user: String
    var connInfo: Data
    var chanInfo: Data
}

public struct CentrifugeMessageEvent {
    var data: Data
}

public struct CentrifugePublishEvent {
    var uid: String
    var data: Data
    var info: Proto_ClientInfo?
}

public struct CentrifugePrivateSubEvent {
    var client: String
    var channel: String
}

public struct CentrifugeSubscribeErrorEvent {
    var code: UInt32
    var message: String
}

public struct CentrifugeSubscribeSuccessEvent {
    var resubscribe = false
    var recovered = false
}

public struct CentrifugeUnsubscribeEvent {}

public protocol CentrifugeClientDelegate {
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
