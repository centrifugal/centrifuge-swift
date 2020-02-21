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
    
    public let channel: String
    let centrifuge: CentrifugeClient
    var status: CentrifugeSubscriptionStatus = .unsubscribed
    var isResubscribe = false
    var needResubscribe = true
    var callbacks: [String: ((Error?) -> ())] = [:]
    weak var delegate: CentrifugeSubscriptionDelegate?
    let syncQueue: DispatchQueue
    
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
    
    func sendSubscribe(channel: String, token: String) {
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
                        for (_, cb) in self.callbacks {
                            cb(CentrifugeError.replyError(code: code, message: message))
                        }
                        self.callbacks = [:]
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
                    for (_, cb) in self.callbacks {
                        cb(nil)
                    }
                    self.callbacks = [:]
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
    
    func waitForSubscribe(completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if !strongSelf.needResubscribe {
                completion(CentrifugeError.unsubscribed)
                return
            }
            var needWait = strongSelf.status == .subscribing || (strongSelf.status == .unsubscribed && strongSelf.needResubscribe)
            if !needWait {
                completion(nil)
                return
            }
            let uid = UUID().uuidString
            let group = DispatchGroup()
            group.enter()
            
            var groupLeft = false
            var timedOut = false
            var opError: Error? = nil
            
            let timeoutTask = DispatchWorkItem {
                if groupLeft {
                    return
                }
                timedOut = true
                groupLeft = true
                group.leave()
            }
            
            func resolve(error: Error?) {
                if groupLeft {
                    return
                }
                if let err = error {
                    opError = err
                }
                timeoutTask.cancel()
                groupLeft = true
                group.leave()
            }
            
            let resolveFunc = resolve
            strongSelf.callbacks[uid] = resolveFunc
            strongSelf.syncQueue.asyncAfter(deadline: .now() + strongSelf.centrifuge.config.timeout, execute: timeoutTask)
            
            strongSelf.centrifuge.workQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                group.wait()
                strongSelf.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.callbacks.removeValue(forKey: uid)
                    if let err = opError {
                        completion(err)
                        return
                    }
                    if timedOut {
                        completion(CentrifugeError.timeout)
                        return
                    }
                    completion(nil)
                }
            }
        }
    }
    
    // Access must be serialized from outside.
    func moveToUnsubscribed() {
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
