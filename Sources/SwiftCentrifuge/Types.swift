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
    public let offset: UInt64
    public let data: Data
    public let clientInfo: CentrifugeClientInfo?

    public init(offset: UInt64, data: Data, clientInfo: CentrifugeClientInfo? = nil) {
        self.offset = offset
        self.data = data
        self.clientInfo = clientInfo
    }
}

public struct CentrifugeHistoryResult {
    public let publications: [CentrifugePublication]
    public let offset: UInt64
    public let epoch: String

    public init(publications: [CentrifugePublication], offset: UInt64, epoch: String) {
        self.publications = publications
        self.offset = offset
        self.epoch = epoch
    }
}

public struct CentrifugeClientInfo {
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

public struct CentrifugePublishResult {
    public init() {}
}

public struct CentrifugeRpcResult {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

public struct CentrifugePresenceResult {
    public let presence: [String: CentrifugeClientInfo]

    public init(presence: [String : CentrifugeClientInfo]) {
        self.presence = presence
    }
}

public struct CentrifugePresenceStatsResult {
    public let numClients: UInt32
    public let numUsers: UInt32

    public init(numClients: UInt32, numUsers: UInt32) {
        self.numClients = numClients
        self.numUsers = numUsers
    }
}

public struct CentrifugeStreamPosition {
    public let offset: UInt64
    public let epoch: String

    public init(offset: UInt64, epoch: String) {
        self.offset = offset
        self.epoch = epoch
    }
}

struct ServerSubscription {
    var recoverable: Bool
    var offset: UInt64
    var epoch: String
}
