//
//  Subscription.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation

public enum CentrifugeSubscriptionStatus {
    case unsubscribed
    case subscribing
    case subscribeSuccess
    case subscribeError
}

public class CentrifugeSubscription {
    var centrifuge: CentrifugeClient
    public var channel: String
    var status: CentrifugeSubscriptionStatus = .unsubscribed
    var isResubscribe = false
    var needResubscribe = true
    var callbacks: [String: ((Error?) -> ())] = [:]
    weak var delegate: CentrifugeSubscriptionDelegate?
    private let syncQueue: DispatchQueue
    
    init(centrifuge: CentrifugeClient, channel: String, delegate: CentrifugeSubscriptionDelegate) {
        self.centrifuge = centrifuge
        self.channel = channel
        self.delegate = delegate
        self.isResubscribe = false
        self.syncQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.sync<\(UUID().uuidString)>")
    }
    
    public func subscribe() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if strongSelf.status != .unsubscribed {
                return
            }
            strongSelf.status = .subscribing
            strongSelf.needResubscribe = true
            if strongSelf.centrifuge.status != CentrifugeClientStatus.connected {
                return
            }
            strongSelf.resubscribe()
        }
    }
    
    public func publish(data: Data, completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForSubscribe(completion: {[weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(err)
                    return
                }
                strongSelf.centrifuge.publish(channel: strongSelf.channel, data: data, completion: completion)
            })
        }
    }
    
    public func presence(completion: @escaping ([String: CentrifugeClientInfo]?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForSubscribe(completion: {[weak self] error in
                if let sub = self {
                    if let err = error {
                        completion(nil, err)
                        return
                    }
                    sub.centrifuge.presence(channel: sub.channel, completion: completion)
                }
            })
        }
    }
    
    public func presenceStats(completion: @escaping (CentrifugePresenceStats?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForSubscribe(completion: {[weak self] error in
                if let sub = self {
                    if let err = error {
                        completion(nil, err)
                        return
                    }
                    sub.centrifuge.presenceStats(channel: sub.channel, completion: completion)
                }
            })
        }
    }
    
    public func history(completion: @escaping ([CentrifugePublication]?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForSubscribe(completion: {[weak self] error in
                if let sub = self {
                    if let err = error {
                        completion(nil, err)
                        return
                    }
                    sub.centrifuge.history(channel: sub.channel, completion: completion)
                }
            })
        }
    }
    
    private func sendSubscribe(channel: String, token: String) {
        self.centrifuge.subscribe(channel: self.channel, token: token, completion: { res, error in
            if let err = error {
                switch err {
                case CentrifugeError.replyError(let code, let message):
                    if code == 100 { // Internal error
                        self.centrifuge.syncQueue.async { [weak self] in
                            self?.centrifuge.close(reason: "internal error", reconnect: true)
                        }
                        return
                    }
                    self.syncQueue.async {
                        self.status = .subscribeError
                        self.centrifuge.delegateQueue.addOperation {
                            self.delegate?.onSubscribeError(self, CentrifugeSubscribeErrorEvent(code: code, message: message))
                        }
                        for cb in self.callbacks.values {
                            cb(CentrifugeError.replyError(code: code, message: message))
                        }
                        self.callbacks.removeAll(keepingCapacity: true)
                    }
                case CentrifugeError.timeout:
                    self.centrifuge.syncQueue.async { [weak self] in
                        self?.centrifuge.close(reason: "timeout", reconnect: true)
                    }
                    return
                default:
                    self.centrifuge.syncQueue.async { [weak self] in
                        self?.centrifuge.close(reason: "subscription error", reconnect: true)
                    }
                    return
                }
            }
            if let result = res {
                self.syncQueue.async {
                    self.isResubscribe = true
                    for cb in self.callbacks.values {
                        cb(nil)
                    }
                    self.callbacks.removeAll(keepingCapacity: true)
                    self.status = .subscribeSuccess
                    self.centrifuge.delegateQueue.addOperation {
                        self.delegate?.onSubscribeSuccess(
                            self,
                            CentrifugeSubscribeSuccessEvent(resubscribe: self.isResubscribe, recovered: result.recovered)
                        )
                    }
                }
            }
        })
    }
    
    func resubscribeIfNecessary() {
        self.syncQueue.async { [weak self] in
            guard let sub = self else { return }
            if (sub.status == .unsubscribed || sub.status == .subscribing) && sub.needResubscribe {
                sub.status = .subscribing
                sub.resubscribe()
            }
        }
    }
    
    func resubscribe() {
        if self.channel.hasPrefix(self.centrifuge.config.privateChannelPrefix) {
            self.centrifuge.getSubscriptionToken(channel: self.channel, completion: { [weak self] token in
                guard let sub = self else { return }
                sub.syncQueue.async { [weak self] in
                    guard let sub = self else { return }
                    guard sub.status == .subscribing else { return }
                    sub.sendSubscribe(channel: sub.channel, token: token)
                }
            })
        } else {
            self.syncQueue.async { [weak self] in
                guard let sub = self else { return }
                guard sub.status == .subscribing else { return }
                sub.sendSubscribe(channel: sub.channel, token: "")
            }
        }
    }
    
    private func waitForSubscribe(completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            
            guard !strongSelf.needResubscribe else {
                completion(CentrifugeError.unsubscribed)
                return
            }
            
            let needWait = strongSelf.status == .subscribing || (strongSelf.status == .unsubscribed && strongSelf.needResubscribe)
            guard !needWait else {
                completion(nil)
                return
            }
            
            let uid = UUID().uuidString
            
            let timeoutTask = DispatchWorkItem { [weak self] in
                self?.callbacks[uid] = nil
                completion(CentrifugeError.timeout)
            }
            
            strongSelf.callbacks[uid] = { error in
                timeoutTask.cancel()
                completion(error)
            }
            
            strongSelf.syncQueue.asyncAfter(deadline: .now() + strongSelf.centrifuge.config.timeout, execute: timeoutTask)
        }
    }
    
    // Access must be serialized from outside.
    private func moveToUnsubscribed() {
        if self.status != .subscribeSuccess && self.status != .subscribeError {
            return
        }
        let previousStatus = self.status
        self.status = .unsubscribed
        if previousStatus == .subscribeSuccess {
            // Only call unsubscribe event if Subscription wass successfully subscribed.
            self.centrifuge.delegateQueue.addOperation {
                self.delegate?.onUnsubscribe(
                    self,
                    CentrifugeUnsubscribeEvent()
                )
            }
        }
    }
    
    func unsubscribeOnDisconnect() {
        self.syncQueue.sync { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.moveToUnsubscribed()
        }
    }
    
    public func unsubscribe() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.needResubscribe = false
            strongSelf.moveToUnsubscribed()
            strongSelf.centrifuge.unsubscribe(sub: strongSelf)
        }
    }
}
