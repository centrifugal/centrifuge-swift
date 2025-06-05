//
//  Delegate.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public struct CentrifugeConnectedEvent{
    public let client: String
    public let data: Data?

    public init(client: String, data: Data? = nil) {
        self.client = client
        self.data = data
    }
}

public struct CentrifugeDisconnectedEvent{
    public let code: UInt32
    public let reason: String

    public  init(code: UInt32, reason: String) {
        self.code = code
        self.reason = reason
    }
}

public struct CentrifugeConnectingEvent{
    public let code: UInt32
    public let reason: String

    public init(code: UInt32, reason: String) {
        self.code = code
        self.reason = reason
    }
}

public struct CentrifugeConnectionTokenEvent {
    public init() {}
}

public struct CentrifugeJoinEvent {
    public let client: String
    public let user: String
    public let connInfo: Data
    public let chanInfo: Data

    public init(client: String, user: String, connInfo: Data, chanInfo: Data) {
        self.client = client
        self.user = user
        self.connInfo = connInfo
        self.chanInfo = chanInfo
    }
}

public struct CentrifugeLeaveEvent {
    public let client: String
    public let user: String
    public let connInfo: Data
    public let chanInfo: Data

    public init(client: String, user: String, connInfo: Data, chanInfo: Data) {
        self.client = client
        self.user = user
        self.connInfo = connInfo
        self.chanInfo = chanInfo
    }
}

public struct CentrifugeMessageEvent {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct CentrifugeErrorEvent {
    public let error: Error

    public init(error: Error) {
        self.error = error
    }
}

public struct CentrifugePublicationEvent {
    public let data: Data
    public let offset: UInt64
    public let tags: [String: String]
    public let info: CentrifugeClientInfo?

    public init(data: Data, offset: UInt64, tags: [String : String], info: CentrifugeClientInfo? = nil) {
        self.data = data
        self.offset = offset
        self.tags = tags
        self.info = info
    }
}

public struct CentrifugeSubscriptionTokenEvent {
    public let channel: String

    public init(channel: String) {
        self.channel = channel
    }
}

public struct CentrifugeSubscriptionErrorEvent {
    public let error: Error

    public init(error: Error) {
        self.error = error
    }
}

public struct CentrifugeSubscribedEvent {
    public let wasRecovering: Bool
    public let recovered: Bool
    public let positioned: Bool
    public let recoverable: Bool
    public let streamPosition: StreamPosition?
    public let data: Data?

    public init(
        wasRecovering: Bool = false,
        recovered: Bool = false,
        positioned: Bool = false,
        recoverable: Bool = false,
        streamPosition: StreamPosition? = nil,
        data: Data? = nil
    ) {
        self.wasRecovering = wasRecovering
        self.recovered = recovered
        self.positioned = positioned
        self.recoverable = recoverable
        self.streamPosition = streamPosition
        self.data = data
    }
}

public struct CentrifugeUnsubscribedEvent {
    public let code: UInt32
    public let reason: String

    public init(code: UInt32, reason: String) {
        self.code = code
        self.reason = reason
    }
}

public struct CentrifugeSubscribingEvent {
    public let code: UInt32
    public let reason: String

    public init(code: UInt32, reason: String) {
        self.code = code
        self.reason = reason
    }
}

public struct CentrifugeServerSubscribedEvent {
    public let channel: String
    public let wasRecovering: Bool
    public let recovered: Bool
    public let positioned: Bool
    public let recoverable: Bool
    public let streamPosition: StreamPosition?
    public let data: Data?

    public init(
        channel: String,
        wasRecovering: Bool = false,
        recovered: Bool = false,
        positioned: Bool = false,
        recoverable: Bool = false,
        streamPosition: StreamPosition? = nil,
        data: Data? = nil
    ) {
        self.channel = channel
        self.wasRecovering = wasRecovering
        self.recovered = recovered
        self.positioned = positioned
        self.recoverable = recoverable
        self.streamPosition = streamPosition
        self.data = data
    }
}

public struct CentrifugeServerSubscribingEvent {
    public let channel: String

    public  init(channel: String) {
        self.channel = channel
    }
}

public struct CentrifugeServerUnsubscribedEvent {
    public let channel: String

    public init(channel: String) {
        self.channel = channel
    }
}

public struct CentrifugeServerPublicationEvent {
    public let channel: String
    public let data: Data
    public let offset: UInt64
    public let tags: [String: String]
    public let info: CentrifugeClientInfo?

    public init(
        channel: String,
        data: Data,
        offset: UInt64,
        tags: [String : String],
        info: CentrifugeClientInfo? = nil
    ) {
        self.channel = channel
        self.data = data
        self.offset = offset
        self.tags = tags
        self.info = info
    }
}

public struct CentrifugeServerJoinEvent {
    public let channel: String
    public let client: String
    public let user: String
    public let connInfo: Data?
    public let chanInfo: Data?

    public init(
        channel: String,
        client: String,
        user: String,
        connInfo: Data? = nil,
        chanInfo: Data? = nil
    ) {
        self.channel = channel
        self.client = client
        self.user = user
        self.connInfo = connInfo
        self.chanInfo = chanInfo
    }
}

public struct CentrifugeServerLeaveEvent {
    public let channel: String
    public let client: String
    public let user: String
    public let connInfo: Data?
    public let chanInfo: Data?

    public init(
        channel: String,
        client: String,
        user: String,
        connInfo: Data? = nil,
        chanInfo: Data? = nil
    ) {
        self.channel = channel
        self.client = client
        self.user = user
        self.connInfo = connInfo
        self.chanInfo = chanInfo
    }
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
