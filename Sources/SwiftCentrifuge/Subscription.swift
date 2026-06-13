//
//  Subscription.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public typealias CentrifugeSubscriptionTokenGetter = (_ event: CentrifugeSubscriptionTokenEvent, _ completion: @escaping (Result<String, Error>) -> Void) -> Void

public typealias CentrifugeSubscriptionStateGetter = (_ event: CentrifugeSubscriptionGetStateEvent, _ completion: @escaping (Result<CentrifugeStreamPosition, Error>) -> Void) -> Void


public enum DeltaType: String {
    case fossil
}

public struct CentrifugeSubscriptionConfig {
    public init(minResubscribeDelay: Double = 0.5, maxResubscribeDelay: Double = 20.0, token: String = "", data: Data? = nil, since: CentrifugeStreamPosition? = nil, positioned: Bool = false, recoverable: Bool = false, joinLeave: Bool = false, tokenGetter: CentrifugeSubscriptionTokenGetter? = nil, delta: DeltaType? = nil, stateGetter: CentrifugeSubscriptionStateGetter? = nil) {
        self.minResubscribeDelay = minResubscribeDelay
        self.maxResubscribeDelay = maxResubscribeDelay
        self.token = token
        self.tokenGetter = tokenGetter
        self.data = data
        self.since = since
        self.positioned = positioned
        self.recoverable = recoverable
        self.joinLeave = joinLeave
        self.delta = delta
        self.stateGetter = stateGetter
    }

    public var minResubscribeDelay = 0.5
    public var maxResubscribeDelay = 20.0
    public var token: String = ""
    public var delta: DeltaType? = nil
    public var data: Data? = nil
    public var since: CentrifugeStreamPosition? = nil
    public var positioned: Bool = false
    public var recoverable: Bool = false
    public var joinLeave: Bool = false
    public var tokenGetter: CentrifugeSubscriptionTokenGetter?

    /// Called to load the app's current state and stream position.
    /// Requires Centrifugo >= 6.8.0.
    ///
    /// The SDK calls the getter:
    /// - On initial subscribe (no saved position)
    /// - On reconnect when recovery fails (server returns error 112 —
    ///   unrecoverable position)
    ///
    /// NOT called on reconnects where the server successfully recovers missed
    /// publications — in that case the recovered publications arrive as events
    /// and the getter is skipped.
    ///
    /// The app should load its data from its own source of truth (database,
    /// API), render it, and complete with the stream position. The SDK
    /// subscribes with recovery from the returned position, so any publications
    /// between the state read and the subscribe are delivered as publication
    /// events.
    ///
    /// IMPORTANT: inside the getter, read the stream position FIRST, then read
    /// your data. This ensures the position is a lower bound — any data loaded
    /// after the position read is guaranteed to be included. The reverse order
    /// can produce gaps.
    ///
    /// Recovered publications may overlap with data already loaded by the
    /// getter. This works correctly when updates are idempotent (applying the
    /// same update twice produces the same result). For non-idempotent updates,
    /// deduplicate by publication offset.
    ///
    /// On error, the SDK emits an error event with
    /// `CentrifugeError.subscriptionGetStateError` and retries with backoff.
    public var stateGetter: CentrifugeSubscriptionStateGetter?
}

public enum CentrifugeSubscriptionState: Sendable {
    case unsubscribed
    case subscribing
    case subscribed
}

public class CentrifugeSubscription: @unchecked Sendable {
    
    public let channel: String
    
    private var internalState: CentrifugeSubscriptionState = .unsubscribed
    
    private var recover: Bool = false
    private var offset: UInt64 = 0
    private var epoch: String = ""
    private var prevValue: Data?
    // Numeric channel ID assigned by the server when channel compaction is
    // negotiated. Pushes then carry this ID instead of the channel name.
    // Touched only on the client syncQueue (subscribe reply / unsubscribe).
    private var pushId: Int64 = 0
    
    fileprivate var token: String?
    fileprivate var delta: String?
    fileprivate var deltaNegotiated: Bool = false
    fileprivate var refreshTask: DispatchWorkItem?
    fileprivate var resubscribeTask: DispatchWorkItem?
    fileprivate var resubscribeAttempts: Int = 0
    
    weak var delegate: CentrifugeSubscriptionDelegate?
    var config: CentrifugeSubscriptionConfig
    
    private var callbacks: [String: ((Error?) -> ())] = [:]
    private weak var centrifuge: CentrifugeClient?
    private let log: CentrifugeLogger
    
    init(centrifuge: CentrifugeClient, channel: String, config: CentrifugeSubscriptionConfig, delegate: CentrifugeSubscriptionDelegate, log: CentrifugeLogger) {
        self.centrifuge = centrifuge
        self.channel = channel
        self.delegate = delegate
        self.config = config
        self.log = log
        if let since = config.since {
            self.recover = true
            self.offset = since.offset
            self.epoch = since.epoch
        }
        if (config.delta != nil) {
            self.delta = config.delta?.rawValue
        }
        if (config.token != "") {
            self.token = config.token;
        }
    }
    
    public var state: CentrifugeSubscriptionState {
        get {
            return CentrifugeClient.barrierQueue.sync { internalState }
        }
        set (newState) {
            CentrifugeClient.barrierQueue.async(flags: .barrier) { self.internalState = newState }
        }
    }
    
    public func subscribe() {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard
                let strongSelf = self,
                strongSelf.state == .unsubscribed
            else { return }
            strongSelf.log.debug("start subscribing \(strongSelf.channel)")
            strongSelf.state = .subscribing
            if strongSelf.centrifuge?.state == .connected {
                strongSelf.resubscribe()
            }
        }
    }
    
    public func unsubscribe() {
        processUnsubscribe(sendUnsubscribe: true, code: unsubscribedCodeUnsubscribeCalled, reason: "unsubscribe called")
    }
    
    public func publish(data: Data, completion: @escaping (Result<CentrifugePublishResult, Error>) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(.failure(err))
                return
            }
            self?.centrifuge?.publish(channel: channel, data: data, completion: completion)
        })
    }
    
    public func presence(completion: @escaping (Result<CentrifugePresenceResult, Error>) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(.failure(err))
                return
            }
            self?.centrifuge?.presence(channel: channel, completion: completion)
        })
    }
    
    public func presenceStats(completion: @escaping (Result<CentrifugePresenceStatsResult, Error>) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(.failure(err))
                return
            }
            self?.centrifuge?.presenceStats(channel: channel, completion: completion)
        })
    }
    
    public func history(limit: Int32 = 0, since: CentrifugeStreamPosition? = nil, reverse: Bool = false, completion: @escaping (Result<CentrifugeHistoryResult, Error>) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(.failure(err))
                return
            }
            self?.centrifuge?.history(channel: channel, limit: limit, since: since, reverse: reverse, completion: completion)
        })
    }
    
    func setOffset(offset: UInt64) {
        self.offset = offset
    }
    
    func emitSubscribeError(err: Error) {
        self.delegate?.onError(
            self,
            CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionSubscribeError(error: err))
        )
    }
    
    func sendSubscribe(channel: String, token: String) {
        var streamPosition = StreamPosition()
        if self.recover {
            streamPosition.offset = self.offset
            streamPosition.epoch = self.epoch
        }
        // Always offer channel compaction: when the server supports and allows it,
        // the subscribe result carries a numeric channel ID and subsequent pushes
        // use that ID instead of the string channel name.
        var flag: Int64 = subscriptionFlagChannelCompaction
        if self.config.stateGetter != nil {
            // Ask the server to reject the subscribe with error 112 when recovery
            // from the provided position is impossible, instead of returning
            // recovered=false — so we can call the state getter again to reload state.
            flag |= subscriptionFlagRejectUnrecovered
        }
        self.centrifuge?.subscribe(channel: self.channel, token: token, delta: self.delta, data: self.config.data, recover: self.recover, streamPosition: streamPosition, positioned: self.config.positioned, recoverable: self.config.recoverable, joinLeave: self.config.joinLeave, flag: flag, completion: { [weak self, weak centrifuge = self.centrifuge] res, error in
            guard let centrifuge = centrifuge else { return }
            guard let strongSelf = self else { return }
            guard strongSelf.state == .subscribing else { return }
            
            if let err = error {
                switch err {
                case CentrifugeError.replyError(let code, let message, let temporary):
                    if code == errorCodeUnrecoverablePosition && strongSelf.config.stateGetter != nil {
                        // Unrecoverable position with state getter: reset position so the
                        // next subscribe attempt calls the getter to reload app state from
                        // scratch. No error event emitted — matches other SDKs.
                        strongSelf.recover = false
                        strongSelf.offset = 0
                        strongSelf.epoch = ""
                        strongSelf.prevValue = nil
                        strongSelf.scheduleResubscribe()
                        return
                    }
                    if code == 109 { // Token expired.
                        strongSelf.token = nil
                        strongSelf.scheduleResubscribe(zeroDelay: true)
                        strongSelf.emitSubscribeError(err: err)
                        return
                    } else if temporary {
                        strongSelf.scheduleResubscribe()
                        strongSelf.emitSubscribeError(err: err)
                        return
                    } else {
                        self?.processUnsubscribe(sendUnsubscribe: false, code: code, reason: message)
                        return
                    }
                case CentrifugeError.timeout:
                    strongSelf.emitSubscribeError(err: err)
                    centrifuge.syncQueue.async { [weak centrifuge = centrifuge] in
                        centrifuge?.reconnect(code: connectingCodeSubscribeTimeout, reason: "subscribe timeout")
                    }
                    return
                default:
                    strongSelf.emitSubscribeError(err: err)
                    strongSelf.scheduleResubscribe()
                    return
                }
            }
            
            guard let result = res else { return }
            
            strongSelf.recover = result.recoverable
            strongSelf.epoch = result.epoch
            strongSelf.offset = result.offset
            strongSelf.deltaNegotiated = result.delta
            // Channel compaction: register the numeric channel ID assigned by the
            // server (0 when not negotiated — also clears a stale ID from a previous
            // subscribe session).
            strongSelf.setPushId(result.id)
            for cb in strongSelf.callbacks.values {
                cb(nil)
            }
            strongSelf.callbacks.removeAll(keepingCapacity: false)
            strongSelf.state = .subscribed
            strongSelf.resubscribeAttempts = 0
            
            if result.expires {
                strongSelf.startSubscriptionRefresh(ttl: result.ttl)
            }

            strongSelf.delegate?.onSubscribed(
                strongSelf,
                CentrifugeSubscribedEvent(wasRecovering: result.wasRecovering, recovered: result.recovered, positioned: result.positioned, recoverable: result.recoverable, streamPosition: result.positioned || result.recoverable ? StreamPosition(offset: result.offset, epoch: result.epoch) : nil, data: result.data)
            )
            result.publications.forEach { [weak self] pub in
                guard let strongSelf = self else { return }
                strongSelf.handlePublication(pub: pub)
            }
            if result.publications.isEmpty {
                strongSelf.offset = result.offset
            }
        })
    }
    
    func handlePublication(pub: Centrifugal_Centrifuge_Protocol_Publication) {
        var info: CentrifugeClientInfo? = nil;
        if pub.hasInfo {
            info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
        }
        let event = CentrifugePublicationEvent(data: applyDelta(pub: pub), offset: pub.offset, tags: pub.tags, info: info)
        if pub.offset > 0 {
            self.setOffset(offset: pub.offset)
        }
        self.delegate?.onPublication(self, event)
    }

    private func applyDelta(pub: Centrifugal_Centrifuge_Protocol_Publication) -> Data {
        var eventData = pub.data
        if pub.delta && self.deltaNegotiated {
            let data = try! DeltaFossil.applyDelta(source: prevValue!, delta: pub.data)
            eventData = data
            self.prevValue = data
        } else if deltaNegotiated {
            self.prevValue = pub.data
        }
        return eventData
    }

    private func scheduleResubscribe(zeroDelay: Bool = false) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.state == .subscribing else { return }
            guard strongSelf.centrifuge != nil else { return }
            var delay = strongSelf.centrifuge!.getBackoffDelay(
                step: strongSelf.resubscribeAttempts,
                minDelay: strongSelf.config.minResubscribeDelay,
                maxDelay: strongSelf.config.maxResubscribeDelay
            )
            if strongSelf.resubscribeAttempts == 0 && zeroDelay {
                // Only apply zero delay for cases when we got a first subscribe error.
                delay = 0
            }
            strongSelf.log.debug("schedule resubscribe for \(strongSelf.channel) in \(delay) seconds")
            strongSelf.resubscribeAttempts += 1
            strongSelf.resubscribeTask?.cancel()
            strongSelf.resubscribeTask = DispatchWorkItem { [weak self] in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .subscribing else { return }
                strongSelf.centrifuge?.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    guard strongSelf.state == .subscribing else { return }
                    if strongSelf.centrifuge?.state == .connected {
                        strongSelf.log.debug("resubscribing on \(strongSelf.channel)")
                        strongSelf.resubscribe()
                    }
                }
            }
            strongSelf.centrifuge?.syncQueue.asyncAfter(deadline: .now() + delay, execute: strongSelf.resubscribeTask!)
        }
    }
    
    private func getSubscriptionToken(channel: String, completion: @escaping (Result<String, Error>)->()) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.config.tokenGetter?(CentrifugeSubscriptionTokenEvent(channel: channel)) {[weak self] result in
                guard let strongSelf = self else { return }
                strongSelf.centrifuge?.syncQueue.async { [weak self] in
                    guard self != nil else { return }
                    completion(result)
                }
            }
        }
    }
    
    private func startSubscriptionRefresh(ttl: UInt32) {
        let refreshTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.centrifuge?.syncQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .subscribed else { return }
                strongSelf.getSubscriptionToken(channel: strongSelf.channel, completion: { [weak self] result in
                    guard let strongSelf = self else { return }
                    guard strongSelf.state == .subscribed else { return }
                    switch result {
                    case .success(let token):
                        if token == "" {
                            strongSelf.failUnauthorized(sendUnsubscribe: true);
                            return
                        }
                        strongSelf.refreshWithToken(token: token)
                    case .failure(let error):
                        guard strongSelf.centrifuge != nil else { return }
                        if let centrifugeError = error as? CentrifugeError {
                            switch centrifugeError {
                            case .unauthorized:
                                strongSelf.failUnauthorized(sendUnsubscribe: true);
                                return
                            default:
                                break
                            }
                        }
                        let ttl = UInt32(floor((strongSelf.centrifuge!.getBackoffDelay(step: 0, minDelay: 5, maxDelay: 10))))
                        strongSelf.startSubscriptionRefresh(ttl: ttl)
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionTokenError(error: error))
                        )
                        return
                    }
                })
            }
        }
        
        self.centrifuge?.syncQueue.asyncAfter(deadline: .now() + Double(ttl), execute: refreshTask)
        self.refreshTask = refreshTask
    }
    
    func refreshWithToken(token: String) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.token = token
            strongSelf.centrifuge?.sendSubRefresh(token: token, channel: strongSelf.channel, completion: { [weak self] result, error in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .subscribed else { return }
                guard strongSelf.centrifuge != nil else { return }
                if let err = error {
                    switch err {
                    case CentrifugeError.replyError(let code, let message, let temporary):
                        if temporary {
                            let ttl = UInt32(floor((strongSelf.centrifuge!.getBackoffDelay(step: 0, minDelay: 5, maxDelay: 10))))
                            strongSelf.startSubscriptionRefresh(ttl: ttl)
                            return
                        } else {
                            self?.processUnsubscribe(sendUnsubscribe: true, code: code, reason: message)
                            return
                        }
                    default:
                        let ttl = UInt32(floor((strongSelf.centrifuge!.getBackoffDelay(step: 0, minDelay: 5, maxDelay: 10))))
                        strongSelf.startSubscriptionRefresh(ttl: ttl)
                        return
                    }
                }
                if let res = result {
                    if res.expires {
                        strongSelf.startSubscriptionRefresh(ttl: res.ttl)
                    }
                }
            })
        }
    }
    
    func resubscribeIfNecessary() {
        if (self.state == .subscribing) {
            self.resubscribeTask?.cancel()
            self.resubscribe()
        }
    }
    
    func resubscribe() {
        // stateGetter: ask the app for its current state position. Only called
        // when we don't have a saved position (first subscribe or after a
        // position reset due to unrecoverable position error 112). On normal
        // reconnects with a valid saved position we skip the getter and let the
        // server try recovery — the getter is only called again if recovery fails.
        if self.config.stateGetter != nil && !self.recover {
            self.getSubscriptionState(channel: self.channel, completion: { [weak self] result in
                guard let strongSelf = self, strongSelf.state == .subscribing else { return }
                switch result {
                case .success(let position):
                    strongSelf.recover = true
                    strongSelf.offset = position.offset
                    strongSelf.epoch = position.epoch
                    strongSelf.continueResubscribe()
                case .failure(let error):
                    strongSelf.delegate?.onError(
                        strongSelf,
                        CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionGetStateError(error: error))
                    )
                    strongSelf.scheduleResubscribe()
                }
            })
            return
        }
        self.continueResubscribe()
    }

    private func getSubscriptionState(channel: String, completion: @escaping (Result<CentrifugeStreamPosition, Error>)->()) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.config.stateGetter?(CentrifugeSubscriptionGetStateEvent(channel: channel)) { [weak self] result in
                guard let strongSelf = self else { return }
                strongSelf.centrifuge?.syncQueue.async { [weak self] in
                    guard self != nil else { return }
                    completion(result)
                }
            }
        }
    }

    private func continueResubscribe() {
        if self.token != nil || self.config.tokenGetter != nil {
            if self.token != nil {
                let token = self.token!
                self.sendSubscribe(channel: self.channel, token: token)
            } else {
                self.getSubscriptionToken(channel: self.channel, completion: { [weak self] result in
                    guard let strongSelf = self, strongSelf.state == .subscribing else { return }
                    switch result {
                    case .success(let token):
                        if token == "" {
                            strongSelf.failUnauthorized(sendUnsubscribe: false);
                            return
                        }
                        strongSelf.centrifuge?.syncQueue.async { [weak self] in
                            guard let strongSelf = self, strongSelf.state == .subscribing else { return }
                            strongSelf.sendSubscribe(channel: strongSelf.channel, token: token)
                        }
                    case .failure(let error):
                        guard let strongSelf = self else { return }
                        if let centrifugeError = error as? CentrifugeError {
                            switch centrifugeError {
                            case .unauthorized:
                                strongSelf.failUnauthorized(sendUnsubscribe: false);
                                return
                            default:
                                break
                            }
                        }
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionTokenError(error: error))
                        )
                        strongSelf.scheduleResubscribe()
                        return
                    }
                })
            }
        } else {
            self.sendSubscribe(channel: self.channel, token: "")
        }
    }
    
    private func waitForSubscribe(completion: @escaping (Error?) -> ()) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self, let timeout = strongSelf.centrifuge?.config.timeout else { return }
            
            if strongSelf.state == .unsubscribed {
                completion(CentrifugeError.subscriptionUnsubscribed)
                return
            }
            
            if strongSelf.state == .subscribed {
                completion(nil)
                return
            }
            
            // OK, let's wait.
            
            let uid = UUID().uuidString
            
            let timeoutTask = DispatchWorkItem { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.callbacks[uid] = nil
                completion(CentrifugeError.timeout)
            }
            
            strongSelf.callbacks[uid] = { [weak self] error in
                guard self != nil else { return }
                timeoutTask.cancel()
                completion(error)
            }
            
            strongSelf.centrifuge?.syncQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
        }
    }
    
    func moveToSubscribingUponDisconnect(code: UInt32, reason: String) {
        if self.state == .unsubscribed {
            return
        }
        let prevState = self.state
        self.state = .subscribing
        self.resubscribeAttempts = 0
        self.refreshTask?.cancel()
        self.resubscribeTask?.cancel()
        
        if prevState == .subscribed {
            self.delegate?.onSubscribing(
                self,
                CentrifugeSubscribingEvent(code: code, reason: reason)
            )
        }
    }
    
    func processUnsubscribe(sendUnsubscribe: Bool, code: UInt32, reason: String) {
        // `self` subscription should not be weakified before sending to `async`
        // (i.e. keeping the strong reference should be safe)
        //
        // If we "weakify" `self` then important operations could be skipped:
        // - no callbacks or delegates will be invoked
        // - the client will not send "unsubscribe" command to the server
        self.centrifuge?.syncQueue.async {
            if self.state == .unsubscribed {
                return
            }

            self.refreshTask?.cancel()
            self.resubscribeTask?.cancel()

            self.state = .unsubscribed
            self.resubscribeAttempts = 0
            // Channel compaction ID is no longer valid once unsubscribed.
            self.setPushId(0)

            for cb in self.callbacks.values {
                cb(CentrifugeError.subscriptionUnsubscribed)
            }

            self.callbacks.removeAll(keepingCapacity: true)

            self.delegate?.onUnsubscribed(
                self,
                CentrifugeUnsubscribedEvent(code: code, reason: reason)
            )

            if sendUnsubscribe {
                self.centrifuge?.unsubscribe(sub: self)
            }
        }
    }
    
    private func failUnauthorized(sendUnsubscribe: Bool) -> Void {
        self.processUnsubscribe(sendUnsubscribe: sendUnsubscribe, code: unsubscribedCodeUnauthorized, reason: "unauthorized")
    }

    // Update the channel compaction ID registration in the client's push routing
    // registry. Pass 0 to clear (no compaction / sub gone). Always re-registers
    // even when the ID is unchanged: the client drops the registry on transport
    // teardown and on reconnect the server commonly assigns the same ID again, so
    // the registration must be restored. Runs on the client syncQueue.
    private func setPushId(_ id: Int64) {
        if id == 0 && self.pushId == 0 {
            return
        }
        let oldId = self.pushId
        self.pushId = id
        self.centrifuge?.updateSubscriptionPushId(sub: self, oldId: oldId, newId: id)
    }
}
