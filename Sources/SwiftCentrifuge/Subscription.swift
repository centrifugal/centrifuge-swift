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
    
    private var status: CentrifugeSubscriptionStatus = .unsubscribed
    private var isResubscribe = false
    private var needResubscribe = true

    private var lastOffset: UInt64 = 0
    private var recover: Bool = false
    private var subscribedAt: UInt64 = 0
    private var lastEpoch: String = ""
    private var lastSeq: UInt32 = 0
    private var lastGen: UInt32 = 0
    
    weak var delegate: CentrifugeSubscriptionDelegate?
    
    private var callbacks: [String: ((Error?) -> ())] = [:]
    private let syncQueue: DispatchQueue
    private weak var centrifuge: CentrifugeClient?
    
    init(centrifuge: CentrifugeClient, channel: String, delegate: CentrifugeSubscriptionDelegate) {
        self.centrifuge = centrifuge
        self.channel = channel
        self.delegate = delegate
        self.isResubscribe = false
        self.syncQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.sync<\(UUID().uuidString)>")
    }
    
    public func subscribe() {
        self.syncQueue.async { [weak self] in
            guard
                let strongSelf = self,
                strongSelf.status == .unsubscribed
                else { return }
            strongSelf.status = .subscribing
            strongSelf.needResubscribe = true
            if strongSelf.centrifuge?.status == .connected {
                strongSelf.resubscribe()
            }
        }
    }
    
    public func publish(data: Data, completion: @escaping (Error?) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(err)
            } else {
                self?.centrifuge?.publish(channel: channel, data: data, completion: completion)
            }
        })
    }
    
    public func presence(completion: @escaping ([String: CentrifugeClientInfo]?, Error?) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(nil, err)
            } else {
                self?.centrifuge?.presence(channel: channel, completion: completion)
            }
        })
    }
    
    public func presenceStats(completion: @escaping (CentrifugePresenceStats?, Error?) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(nil, err)
            } else {
                self?.centrifuge?.presenceStats(channel: channel, completion: completion)
            }
        })
    }
    
    public func history(completion: @escaping ([CentrifugePublication]?, Error?) -> ()) {
        self.waitForSubscribe(completion: { [weak self, channel = self.channel] error in
            if let err = error {
                completion(nil, err)
            } else {
                self?.centrifuge?.history(channel: channel, completion: completion)
            }
        })
    }
    
    func sendSubscribe(channel: String, token: String) {
        var isRecover = false
        var streamPosition = StreamPosition()
        if (self.subscribedAt != 0 && self.recover) {
            isRecover = true;
            if (self.lastOffset > 0) {
                streamPosition.Offset = self.lastOffset
            } else if (self.lastGen > 0 || self.lastSeq > 0) {
                streamPosition.Seq = self.lastSeq
                streamPosition.Gen = self.lastGen
            }

            streamPosition.Epoch = self.lastEpoch

        }
        self.centrifuge?.subscribe(channel: self.channel, token: token, isRecover: isRecover, streamPosition: streamPosition, completion: { [weak self, weak centrifuge = self.centrifuge] res, error in
            guard let centrifuge = centrifuge else { return }
            if let err = error {
                switch err {
                case CentrifugeError.replyError(let code, let message):
                    guard code == 100 else { // Internal error
                        centrifuge.syncQueue.async { [weak centrifuge = centrifuge] in
                            centrifuge?.close(reason: "internal error", reconnect: true)
                        }
                        return
                    }
                    self?.syncQueue.async { [weak self] in
                        guard let strongSelf = self else { return }
                        strongSelf.status = .subscribeError
                        strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                            guard let strongSelf = self else { return }
                            strongSelf.delegate?.onSubscribeError(strongSelf, CentrifugeSubscribeErrorEvent(code: code, message: message))
                        }
                        
                        for cb in strongSelf.callbacks.values {
                            cb(CentrifugeError.replyError(code: code, message: message))
                        }
                        
                        strongSelf.callbacks.removeAll(keepingCapacity: true)
                    }
                case CentrifugeError.timeout:
                    centrifuge.syncQueue.async { [weak centrifuge = centrifuge] in
                        centrifuge?.close(reason: "timeout", reconnect: true)
                    }
                    return
                default:
                    centrifuge.syncQueue.async { [weak centrifuge = centrifuge] in
                        centrifuge?.close(reason: "subscription error", reconnect: true)
                    }
                    return
                }
            }
            guard let result = res else { return }
            self?.syncQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.isResubscribe = true
                strongSelf.recover = true
                strongSelf.lastEpoch = result.epoch
                strongSelf.lastSeq = result.seq
                strongSelf.lastGen = result.gen
                strongSelf.lastOffset = result.offset
                for cb in strongSelf.callbacks.values {
                    cb(nil)
                }
                strongSelf.callbacks.removeAll(keepingCapacity: true)
                strongSelf.status = .subscribeSuccess
                strongSelf.centrifuge?.delegateQueue.addOperation { [weak self] in
                    guard let strongSelf = self else { return }
                    result.publications.forEach { [weak self] pub in
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onPublish(strongSelf, CentrifugePublishEvent(uid: pub.uid, data: pub.data, info: pub.info))
                    }
                    strongSelf.delegate?.onSubscribeSuccess(
                        strongSelf,
                        CentrifugeSubscribeSuccessEvent(resubscribe: strongSelf.isResubscribe, recovered: result.recovered)
                    )
                }
            }
        })
    }
    
    func resubscribeIfNecessary() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if (strongSelf.status == .unsubscribed || strongSelf.status == .subscribing) && strongSelf.needResubscribe {
                strongSelf.status = .subscribing
                strongSelf.resubscribe()
            }
        }
    }
    
    func resubscribe() {
        guard let centrifuge = self.centrifuge else { return }
        if self.channel.hasPrefix(centrifuge.config.privateChannelPrefix) {
            centrifuge.getSubscriptionToken(channel: self.channel, completion: { [weak self] token in
                guard let strongSelf = self else { return }
                strongSelf.syncQueue.async { [weak self] in
                    guard let strongSelf = self, strongSelf.status == .subscribing else { return }
                    strongSelf.sendSubscribe(channel: strongSelf.channel, token: token)
                    strongSelf.subscribedAt = UInt64(Date().timeIntervalSince1970)
                }
            })
        } else {
            self.syncQueue.async { [weak self] in
                guard let strongSelf = self, strongSelf.status == .subscribing else { return }
                strongSelf.sendSubscribe(channel: strongSelf.channel, token: "")
                strongSelf.subscribedAt = UInt64(Date().timeIntervalSince1970)
            }
        }
    }
    
    private func waitForSubscribe(completion: @escaping (Error?) -> ()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self, let timeout = strongSelf.centrifuge?.config.timeout else { return }
            
            if !strongSelf.needResubscribe {
                completion(CentrifugeError.unsubscribed)
                return
            }
            
            let needWait = strongSelf.status == .subscribing || (strongSelf.status == .unsubscribed && strongSelf.needResubscribe)
            if !needWait {
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
            
            strongSelf.syncQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
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
            self.centrifuge?.delegateQueue.addOperation { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.delegate?.onUnsubscribe(
                    strongSelf,
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
            strongSelf.centrifuge?.unsubscribe(sub: strongSelf)
        }
    }
}
