//
//  Subscription.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public struct CentrifugeSubscriptionConfig {
    public init(minResubscribeDelay: Double = 0.5, maxResubscribeDelay: Double = 20.0, token: String? = nil, data: Data? = nil, since: CentrifugeStreamPosition? = nil, positioned: Bool = false, recoverable: Bool = false) {
        self.minResubscribeDelay = minResubscribeDelay
        self.maxResubscribeDelay = maxResubscribeDelay
        self.token = token
        self.data = data
        self.since = since
        self.positioned = positioned
        self.recoverable = recoverable
    }
    
    public var minResubscribeDelay = 0.5
    public var maxResubscribeDelay = 20.0
    public var token: String? = nil
    public var data: Data? = nil
    public var since: CentrifugeStreamPosition? = nil
    public var positioned: Bool = false
    public var recoverable: Bool = false
}

public enum CentrifugeSubscriptionState {
    case unsubscribed
    case subscribing
    case subscribed
}

public class CentrifugeSubscription {
    
    public let channel: String
    
    private var internalState: CentrifugeSubscriptionState = .unsubscribed
    
    private var recover: Bool = false
    private var offset: UInt64 = 0
    private var epoch: String = ""
    
    fileprivate var token: String?
    fileprivate var refreshTask: DispatchWorkItem?
    fileprivate var resubscribeTask: DispatchWorkItem?
    fileprivate var resubscribeAttempts: Int = 0
    
    weak var delegate: CentrifugeSubscriptionDelegate?
    var config: CentrifugeSubscriptionConfig
    
    private var callbacks: [String: ((Error?) -> ())] = [:]
    private weak var centrifuge: CentrifugeClient?
    
    init(centrifuge: CentrifugeClient, channel: String, config: CentrifugeSubscriptionConfig, delegate: CentrifugeSubscriptionDelegate) {
        self.centrifuge = centrifuge
        self.channel = channel
        self.delegate = delegate
        self.config = config
        if let since = config.since {
            self.recover = true
            self.offset = since.offset
            self.epoch = since.epoch
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
            strongSelf.centrifuge?.debugLog("start subscribing \(strongSelf.channel)")
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
        self.centrifuge?.subscribe(channel: self.channel, token: token, data: self.config.data, recover: self.recover, streamPosition: streamPosition, positioned: self.config.positioned, recoverable: self.config.recoverable, completion: { [weak self, weak centrifuge = self.centrifuge] res, error in
            guard let centrifuge = centrifuge else { return }
            guard let strongSelf = self else { return }
            guard strongSelf.state == .subscribing else { return }
            
            if let err = error {
                switch err {
                case CentrifugeError.replyError(let code, let message, let temporary):
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
                var info: CentrifugeClientInfo? = nil;
                if pub.hasInfo {
                    info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
                }
                let event = CentrifugePublicationEvent(data: pub.data, offset: pub.offset, tags: pub.tags, info: info)
                strongSelf.offset = pub.offset
                strongSelf.delegate?.onPublication(strongSelf, event)
            }
            if result.publications.isEmpty {
                strongSelf.offset = result.offset
            }
        })
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
            strongSelf.centrifuge?.debugLog("schedule resubscribe for \(strongSelf.channel) in \(delay) seconds")
            strongSelf.resubscribeAttempts += 1
            strongSelf.resubscribeTask?.cancel()
            strongSelf.resubscribeTask = DispatchWorkItem { [weak self] in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .subscribing else { return }
                strongSelf.centrifuge?.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    guard strongSelf.state == .subscribing else { return }
                    if strongSelf.centrifuge?.state == .connected {
                        strongSelf.centrifuge?.debugLog("resubscribing on \(strongSelf.channel)")
                        strongSelf.resubscribe()
                    }
                }
            }
            strongSelf.centrifuge?.syncQueue.asyncAfter(deadline: .now() + delay, execute: strongSelf.resubscribeTask!)
        }
    }
    
    private func startSubscriptionRefresh(ttl: UInt32) {
        let refreshTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.centrifuge?.syncQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .subscribed else { return }
                strongSelf.centrifuge?.getSubscriptionToken(channel: strongSelf.channel, completion: { [weak self] result in
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
        guard let centrifuge = self.centrifuge else { return }
        if self.channel.hasPrefix(centrifuge.config.privateChannelPrefix) {
            if self.token != nil {
                let token = self.token!
                self.sendSubscribe(channel: self.channel, token: token)
            } else {
                centrifuge.getSubscriptionToken(channel: self.channel, completion: { [weak self] result in
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
                        //                        strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionTokenError(error: error))
                        )
                        //                        }
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
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if strongSelf.state == .unsubscribed {
                return
            }
            
            strongSelf.refreshTask?.cancel()
            strongSelf.resubscribeTask?.cancel()
            
            strongSelf.state = .unsubscribed
            strongSelf.resubscribeAttempts = 0
            
            for cb in strongSelf.callbacks.values {
                cb(CentrifugeError.subscriptionUnsubscribed)
            }
            
            strongSelf.callbacks.removeAll(keepingCapacity: true)
            
            strongSelf.delegate?.onUnsubscribed(
                strongSelf,
                CentrifugeUnsubscribedEvent(code: code, reason: reason)
            )
            
            if sendUnsubscribe {
                strongSelf.centrifuge?.unsubscribe(sub: strongSelf)
            }
        }
    }
    
    private func failUnauthorized(sendUnsubscribe: Bool) -> Void {
        self.processUnsubscribe(sendUnsubscribe: sendUnsubscribe, code: unsubscribedCodeUnauthorized, reason: "unauthorized")
    }
}
