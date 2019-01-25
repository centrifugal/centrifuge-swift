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
    var uid: String
    var data: Data
}

public struct CentrifugeClientInfo {
    var client: String
    var user: String
    var connInfo: Data
    var chanInfo: Data
}

public struct CentrifugePresenceStats {
    var numClients: UInt32
    var numUsers: UInt32
}
