//
//  Types.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 05/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation
import SwiftProtobuf

public struct CentrifugePublication {
    public var offset: UInt64
    public var data: Data
    public var clientInfo: CentrifugeClientInfo?

    public init(offset: UInt64, data: Data, clientInfo: CentrifugeClientInfo? = nil) {
        self.offset = offset
        self.data = data
        self.clientInfo = clientInfo
    }
}

public struct CentrifugeHistoryResult {
    public var publications: [CentrifugePublication]
    public var offset: UInt64
    public var epoch: String

    public init(publications: [CentrifugePublication], offset: UInt64, epoch: String) {
        self.publications = publications
        self.offset = offset
        self.epoch = epoch
    }
}

public struct CentrifugeClientInfo {
    public var client: String
    public var user: String
    public var connInfo: Data
    public var chanInfo: Data

    public init(client: String, user: String, connInfo: Data, chanInfo: Data) {
        self.client = client
        self.user = user
        self.connInfo = connInfo
        self.chanInfo = chanInfo
    }
}

public struct CentrifugePublishResult {
    public init() {}
}

public struct CentrifugeRpcResult {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct CentrifugePresenceResult {
    public var presence: [String: CentrifugeClientInfo]

    public init(presence: [String : CentrifugeClientInfo]) {
        self.presence = presence
    }
}

public struct CentrifugePresenceStatsResult {
    public var numClients: UInt32
    public var numUsers: UInt32

    public init(numClients: UInt32, numUsers: UInt32) {
        self.numClients = numClients
        self.numUsers = numUsers
    }
}

public struct CentrifugeStreamPosition {
    public init(offset: UInt64, epoch: String) {
        self.offset = offset
        self.epoch = epoch
    }
    
    public var offset: UInt64
    public var epoch: String
}

struct ServerSubscription {
    var recoverable: Bool
    var offset: UInt64
    var epoch: String
}
