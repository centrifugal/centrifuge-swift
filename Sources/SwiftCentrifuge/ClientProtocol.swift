//
//  Client.swift
//  SwiftCentrifuge
//
//  Created by shalom-aviv on 12/01/2025.
//  Copyright © 2025 shalom-aviv. All rights reserved.
//

import Foundation

public protocol Client: AnyObject {
    var delegate: CentrifugeClientDelegate? { get set }

    var state: CentrifugeClientState { get }

    func connect()

    func disconnect()

    func resetReconnectState()

    func setToken(token: String)

    func newSubscription(
        channel: String,
        delegate: CentrifugeSubscriptionDelegate,
        config: CentrifugeSubscriptionConfig?
    ) throws -> CentrifugeSubscription

    func getSubscription(channel: String) -> CentrifugeSubscription?

    func removeSubscription(_ sub: CentrifugeSubscription)

    func getSubscriptions() -> [String: CentrifugeSubscription]

    func send(data: Data, completion: @escaping (Error?) -> Void)

    func publish(channel: String, data: Data, completion: @escaping (Result<CentrifugePublishResult, Error>) -> Void)

    func rpc(method: String, data: Data, completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void)

    func presence(channel: String, completion: @escaping (Result<CentrifugePresenceResult, Error>) -> Void)

    func presenceStats(channel: String, completion: @escaping (Result<CentrifugePresenceStatsResult, Error>) -> Void)

    func history(
        channel: String,
        limit: Int32,
        since: CentrifugeStreamPosition?,
        reverse: Bool,
        completion: @escaping (Result<CentrifugeHistoryResult, Error>) -> Void
    )
}

public extension Client {
    func newSubscription(channel: String, delegate: CentrifugeSubscriptionDelegate) throws -> CentrifugeSubscription {
        try newSubscription(
            channel: channel,
            delegate: delegate,
            config: nil
        )
    }

    func history(
        channel: String,
        limit: Int32 = 0,
        sincePosition: CentrifugeStreamPosition? = nil,
        reverse: Bool = false,
        completion: @escaping (Result<CentrifugeHistoryResult, Error>) -> Void
    ) {
        history(
            channel: channel,
            limit: limit,
            since: sincePosition,
            reverse: reverse,
            completion: completion
        )
    }
}

/// Adopt Client protocol to use protocol ClientSubscription instead of CentrifugeSubscription class
public extension Client {

    func newClientSubscription(
        channel: String,
        delegate: CentrifugeSubscriptionDelegate,
        config: CentrifugeSubscriptionConfig?
    ) throws -> CentrifugeSubscription {
        try newSubscription(channel: channel, delegate: delegate, config: config)
    }

    func newClientSubscription(
        channel: String,
        delegate: CentrifugeSubscriptionDelegate
    ) throws -> CentrifugeSubscription {
        try newClientSubscription(channel: channel, delegate: delegate, config: nil)
    }

    func getClientSubscription(channel: String) -> ClientSubscription? {
        getSubscription(channel: channel)
    }

    func removeClientSubscription(_ sub: ClientSubscription) {
        guard let sub = sub as? CentrifugeSubscription else { return }

        removeSubscription(sub)
    }

    func getClientSubscription() -> [String: ClientSubscription] {
        getSubscriptions()
    }

}

public extension CentrifugeClient {
    /// Static constructor that create CentrifugeClient and return it as Client protocol
    ///
    /// - Parameters:
    ///   - url: protobuf URL endpoint of Centrifugo/Centrifuge.
    ///   - config: config object.
    ///   - delegate: delegate protocol implementation to react on client events.
    static func newClient(endpoint: String, config: CentrifugeClientConfig, delegate: CentrifugeClientDelegate? = nil) -> Client {
        CentrifugeClient(
            endpoint: endpoint,
            config: config,
            delegate: delegate
        )
    }
}
