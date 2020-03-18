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
    public var data: Data
}

public struct CentrifugeClientInfo {
    public var client: String
    public var user: String
    public var connInfo: Data
    public var chanInfo: Data
}

public struct CentrifugePresenceStats {
    public var numClients: UInt32
    public var numUsers: UInt32
}
