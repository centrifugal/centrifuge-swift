//
//  ClientSubscription.swift
//  SwiftCentrifuge
//
//  Created by shalom-aviv on 12/01/2025.
//  Copyright © 2025 shalom-aviv. All rights reserved.
//

import Foundation

public protocol ClientSubscription: AnyObject {
    var channel: String { get }
    
    var state: CentrifugeSubscriptionState { get set }

    func subscribe()

    func unsubscribe()

    func publish(data: Data, completion: @escaping (Result<CentrifugePublishResult, Error>) -> Void)
    
    func presence(completion: @escaping (Result<CentrifugePresenceResult, Error>) -> Void)
    
    func presenceStats(completion: @escaping (Result<CentrifugePresenceStatsResult, Error>) -> Void)
    
    func history(
        limit: Int32,
        since: CentrifugeStreamPosition?,
        reverse: Bool,
        completion: @escaping (Result<CentrifugeHistoryResult, Error>) -> Void
    )
}

public extension ClientSubscription {
    func history(
        limit: Int32 = 0,
        sincePosition: CentrifugeStreamPosition? = nil,
        reverse: Bool = false,
        completion: @escaping (Result<CentrifugeHistoryResult, Error>) -> Void
    ) {
        history(
            limit: limit,
            since: sincePosition,
            reverse: reverse,
            completion: completion
        )
    }
}
