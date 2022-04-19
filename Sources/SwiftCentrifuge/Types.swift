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
}

public struct CentrifugeHistoryResult {
    public var publications: [CentrifugePublication]
    public var offset: UInt64
    public var epoch: String
}

public struct CentrifugeClientInfo {
    public var client: String
    public var user: String
    public var connInfo: Data
    public var chanInfo: Data
}

public struct CentrifugePublishResult {}

public struct CentrifugeRpcResult {
    public var data: Data
}

public struct CentrifugePresenceResult {
    public var presence: [String: CentrifugeClientInfo]
}

public struct CentrifugePresenceStatsResult {
    public var numClients: UInt32
    public var numUsers: UInt32
}

public struct CentrifugeStreamPosition {
    public init(offset: UInt64, epoch: String) {
        self.offset = offset
        self.epoch = epoch
    }
    
    public var offset: UInt64
    public var epoch: String
}

struct serverSubscription {
    var recoverable: Bool
    var offset: UInt64
    var epoch: String
}
