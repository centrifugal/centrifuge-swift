//
//  Subscription.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public struct CentrifugeSubscriptionConfig {
    public init(minResubscribeDelay: Double = 0.5, maxResubscribeDelay: Double = 20.0, token: String? = nil, data: Data? = nil, since: CentrifugeStreamPosition? = nil) {
        self.minResubscribeDelay = minResubscribeDelay
        self.maxResubscribeDelay = maxResubscribeDelay
        self.token = token
        self.data = data
        self.since = since
    }

    public var minResubscribeDelay = 0.5
    public var maxResubscribeDelay = 20.0
    public var token: String? = nil
    public var data: Data? = nil
    public var since: CentrifugeStreamPosition? = nil
}

public enum CentrifugeSubscriptionState {
    case unsubscribed
    case subscribing
    case subscribed
    case failed
}

public enum CentrifugeSubscriptionFailReason {
    case server
    case subscribeFailed
    case refreshFailed
    case unauthorized
    case unrecoverable
}

public class CentrifugeSubscription {

    public let channel: String

    private var state: CentrifugeSubscriptionState = .unsubscribed

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

    public func subscribe() {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard
                let strongSelf = self,
                strongSelf.state == .unsubscribed || strongSelf.state == .failed
                else { return }
            strongSelf.centrifuge?.debugLog("start subscribing \(strongSelf.channel)")
            strongSelf.state = .subscribing
            if strongSelf.centrifuge?.state == .connected {
                strongSelf.resubscribe()
            }
        }
    }

    public func unsubscribe() {
        processUnsubscribe(fromClient: true)
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

    func sendSubscribe(channel: String, token: String) {
        var streamPosition = StreamPosition()
        if self.recover {
            if self.offset > 0 {
                streamPosition.offset = self.offset
            }
            streamPosition.epoch = self.epoch
        }
        self.centrifuge?.subscribe(channel: self.channel, token: token, data: self.config.data, recover: self.recover, streamPosition: streamPosition, completion: { [weak self, weak centrifuge = self.centrifuge] res, error in
            guard let centrifuge = centrifuge else { return }
            guard let strongSelf = self else { return }
            guard strongSelf.state == .subscribing else { return }

            if let err = error {
                defer {
                    strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionSubscribeError(error: err))
                        )
                    }
                }
                switch err {
                case CentrifugeError.replyError(let code, _, let temporary):
                    if code == 109 { // Token expired.
                        strongSelf.token = nil
                        strongSelf.scheduleResubscribe(zeroDelay: true)
                        return
                    } else if code == 112 { // Unrecoverable position.
                        strongSelf.failUnrecoverable()
                        return
                    } else if temporary {
                        strongSelf.scheduleResubscribe()
                        return
                    } else {
                        strongSelf.subscribeFailed()
                        return
                    }
                case CentrifugeError.timeout:
                    centrifuge.syncQueue.async { [weak centrifuge = centrifuge] in
                        centrifuge?.close(code: 10, reason: "subscribe timeout", reconnect: true)
                    }
                    return
                default:
                    strongSelf.scheduleResubscribe()
                    return
                }
            }

            guard let result = res else { return }
            self?.centrifuge?.syncQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.recover = result.recoverable
                strongSelf.epoch = result.epoch
                for cb in strongSelf.callbacks.values {
                    cb(nil)
                }
                strongSelf.callbacks.removeAll(keepingCapacity: false)
                strongSelf.state = .subscribed
                strongSelf.resubscribeAttempts = 0
                
                if result.expires {
                    strongSelf.startSubscriptionRefresh(ttl: result.ttl)
                }
                
                strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.delegate?.onSubscribe(
                        strongSelf,
                        CentrifugeSubscribeEvent(recovered: result.recovered)
                    )
                    result.publications.forEach { [weak self] pub in
                        guard let strongSelf = self else { return }
                        var info: CentrifugeClientInfo? = nil;
                        if pub.hasInfo {
                            info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
                        }
                        let event = CentrifugePublicationEvent(data: pub.data, offset: pub.offset, tags: pub.tags, info: info)
                        strongSelf.delegate?.onPublication(strongSelf, event)
                        strongSelf.setOffset(pub.offset)
                    }
                    if result.publications.isEmpty {
                        strongSelf.setOffset(result.offset)
                    }
                }
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
                            strongSelf.failUnauthorized();
                            return
                        }
                        strongSelf.refreshWithToken(token: token)
                    case .failure(let error):
                        guard strongSelf.centrifuge != nil else { return }
                        let ttl = UInt32(floor((strongSelf.centrifuge!.getBackoffDelay(step: 0, minDelay: 5, maxDelay: 10))))
                        strongSelf.startSubscriptionRefresh(ttl: ttl)
                        strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                            guard let strongSelf = self else { return }
                            strongSelf.delegate?.onError(
                                strongSelf,
                                CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionTokenError(error: error))
                            )
                        }
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
                    case CentrifugeError.replyError(_, _, let temporary):
                        if temporary {
                            let ttl = UInt32(floor((strongSelf.centrifuge!.getBackoffDelay(step: 0, minDelay: 5, maxDelay: 10))))
                            strongSelf.startSubscriptionRefresh(ttl: ttl)
                            return
                        } else {
                            strongSelf.refreshFailed()
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
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if (strongSelf.state == .subscribing) {
                strongSelf.resubscribe()
            }
        }
    }

    func resubscribe() {
        guard let centrifuge = self.centrifuge else { return }
        if self.channel.hasPrefix(centrifuge.config.privateChannelPrefix) {
            if self.token != nil {
                let token = self.token!
                self.centrifuge?.syncQueue.async { [weak self] in
                    guard let strongSelf = self, strongSelf.state == .subscribing else { return }
                    strongSelf.sendSubscribe(channel: strongSelf.channel, token: token)
                }
            } else {
                centrifuge.getSubscriptionToken(channel: self.channel, completion: { [weak self] result in
                    guard let strongSelf = self, strongSelf.state == .subscribing else { return }
                    switch result {
                    case .success(let token):
                        if token == "" {
                            strongSelf.failUnauthorized();
                            return
                        }
                        strongSelf.centrifuge?.syncQueue.async { [weak self] in
                            guard let strongSelf = self, strongSelf.state == .subscribing else { return }
                            strongSelf.sendSubscribe(channel: strongSelf.channel, token: token)
                        }
                    case .failure(let error):
                        strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                            guard let strongSelf = self else { return }
                            strongSelf.delegate?.onError(
                                strongSelf,
                                CentrifugeSubscriptionErrorEvent(error: CentrifugeError.subscriptionTokenError(error: error))
                            )
                        }
                        strongSelf.scheduleResubscribe()
                        return
                    }
                })
            }
        } else {
            centrifuge.syncQueue.async { [weak self] in
                guard let strongSelf = self, strongSelf.state == .subscribing else { return }
                strongSelf.sendSubscribe(channel: strongSelf.channel, token: "")
            }
        }
    }

    private func waitForSubscribe(completion: @escaping (Error?) -> ()) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self, let timeout = strongSelf.centrifuge?.config.timeout else { return }

            if strongSelf.state == .unsubscribed {
                completion(CentrifugeError.subscriptionUnsubscribed)
                return
            }
            
            if strongSelf.state == .failed {
                completion(CentrifugeError.subscriptionFailed)
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
    
    func setOffset(_ offset: UInt64) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.offset = offset
        }
    }

    func moveToSubscribingUponDisconnect() {
        if self.state != .subscribed {
            return
        }
        self.state = .subscribing
        self.resubscribeAttempts = 0
        self.refreshTask?.cancel()
        self.resubscribeTask?.cancel()

        // Only call unsubscribe event if Subscription was successfully subscribed.
        self.centrifuge?.delegateQueue.addOperation { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.delegate?.onUnsubscribe(
                strongSelf,
                CentrifugeUnsubscribeEvent()
            )
        }
    }

    func processUnsubscribe(fromClient: Bool) {
        self.centrifuge?.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if strongSelf.state == .unsubscribed || strongSelf.state == .failed  {
                return
            }

            let previousStatus = strongSelf.state

            strongSelf.refreshTask?.cancel()
            strongSelf.resubscribeTask?.cancel()
            
            strongSelf.state = .unsubscribed
            strongSelf.resubscribeAttempts = 0

            for cb in strongSelf.callbacks.values {
                cb(CentrifugeError.subscriptionUnsubscribed)
            }

            strongSelf.callbacks.removeAll(keepingCapacity: true)
            
            if previousStatus != .subscribed {
                return
            }

            // Only call unsubscribe event if Subscription was successfully subscribed.
            strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.delegate?.onUnsubscribe(
                    strongSelf,
                    CentrifugeUnsubscribeEvent()
                )
            }

            if fromClient && strongSelf.centrifuge?.getState() == .connected {
                strongSelf.centrifuge?.unsubscribe(sub: strongSelf)
            }
        }
    }

    private func fail(reason: CentrifugeSubscriptionFailReason, fromClient: Bool) -> Void {
        self.centrifuge?.syncQueue.async{ [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.state != .failed else { return }
            strongSelf.processUnsubscribe(fromClient: fromClient)
            strongSelf.state = .failed
            if reason == .unrecoverable {
                strongSelf.clearPositionState();
            }
            strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.delegate?.onFail(
                    strongSelf,
                    CentrifugeSubscriptionFailEvent(reason: reason)
                )
            }
        }
    }

    func clearPositionState() -> Void {
        self.recover = false;
        self.offset = 0;
        self.epoch = "";
    }

    func failServer() -> Void {
        self.fail(reason: CentrifugeSubscriptionFailReason.server, fromClient: false)
    }
    
    private func subscribeFailed() -> Void {
        self.fail(reason: CentrifugeSubscriptionFailReason.subscribeFailed, fromClient: true)
    }
    
    private func refreshFailed() -> Void {
        self.fail(reason: CentrifugeSubscriptionFailReason.refreshFailed, fromClient: true)
    }
    
    private func failUnauthorized() -> Void {
        self.fail(reason: CentrifugeSubscriptionFailReason.unauthorized, fromClient: true)
    }

    func failUnrecoverable() -> Void {
        self.fail(reason: CentrifugeSubscriptionFailReason.unrecoverable, fromClient: false)
    }
}
