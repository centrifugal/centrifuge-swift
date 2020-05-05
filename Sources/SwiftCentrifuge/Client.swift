//
//  Client.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation
import Starscream
import SwiftProtobuf

public enum CentrifugeError: Error {
    case timeout
    case duplicateSub
    case disconnected
    case unsubscribed
    case replyError(code: UInt32, message: String)
}

public struct StreamPosition {
    public var Offset: UInt64 = 0
    public var Epoch: String = ""
    public var Seq: UInt32 = 0
    public var Gen: UInt32 = 0

    public init() {}
}

public struct CentrifugeClientConfig {
    public var timeout = 5.0
    public var debug = false
    public var headers = [String:String]()
    public var tlsSkipVerify = false
    public var maxReconnectDelay = 20.0
    public var privateChannelPrefix = "$"
    public var pingInterval = 25.0
    
    public init() {}
}

public enum CentrifugeClientStatus {
    case new
    case connected
    case disconnected
}

public class CentrifugeClient {
    public weak var delegate: CentrifugeClientDelegate?
    
    //MARK -
    fileprivate(set) var url: String
    fileprivate(set) var delegateQueue: OperationQueue
    fileprivate(set) var syncQueue: DispatchQueue
    fileprivate(set) var config: CentrifugeClientConfig
    
    //MARK -
    fileprivate(set) var status: CentrifugeClientStatus = .new
    fileprivate var conn: WebSocket?
    fileprivate var token: String?
    fileprivate var client: String?
    fileprivate var commandId: UInt32 = 0
    fileprivate var commandIdLock: NSLock = NSLock()
    fileprivate var opCallbacks: [UInt32: ((CentrifugeResolveData) -> ())] = [:]
    fileprivate var connectCallbacks: [String: ((Error?) -> ())] = [:]
    fileprivate var subscriptionsLock = NSLock()
    fileprivate var subscriptions = [CentrifugeSubscription]()
    fileprivate var needReconnect = true
    fileprivate var numReconnectAttempts = 0
    fileprivate var pingTimer: DispatchSourceTimer?
    fileprivate var disconnectOpts: CentrifugeDisconnectOptions?
    fileprivate var refreshTask: DispatchWorkItem?
    fileprivate var connecting = false
    
    /// Initialize client.
    ///
    /// - Parameters:
    ///   - url: protobuf URL endpoint of Centrifugo/Centrifuge.
    ///   - config: config object.
    ///   - delegate: delegate protocol implementation to react on client events.
    ///   - delegateQueue: optional custom OperationQueue to execute client event callbacks.
    public init(url: String, config: CentrifugeClientConfig, delegate: CentrifugeClientDelegate? = nil, delegateQueue: OperationQueue? = nil) {
        self.url = url
        self.config = config
        self.delegate = delegate
        
        let queueID = UUID().uuidString
        self.syncQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.sync<\(queueID)>")
        
        if let _queue = delegateQueue {
            self.delegateQueue = _queue
        } else {
            self.delegateQueue = OperationQueue()
            self.delegateQueue.maxConcurrentOperationCount = 1
        }
    }
    
    /**
     Set connection JWT
     - parameter token: String
     */
    public func setToken(_ token: String) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.token = token
        }
    }
    
    /**
     Publish message Data to channel
     - parameter channel: String channel name
     - parameter data: Data message data
     - parameter completion: Completion block
     */
    public func publish(channel: String, data: Data, completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(err)
                    return
                }
                strongSelf.sendPublish(channel: channel, data: data, completion: { _, error in
                    completion(error)
                })
            })
        }
    }
    
    /**
     Send raw message to server
     - parameter data: Data
     - parameter completion: Completion block
     */
    public func send(data: Data, completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(err)
                    return
                }
                strongSelf.sendSend(data: data, completion: completion)
            })
        }
    }
    
    
    /**
     Send RPC  command
     - parameter method: String
     - parameter data: Data
     - parameter completion: Completion block
     */
    public func rpc(method: String = "", data: Data, completion: @escaping (Data?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                strongSelf.sendRPC(method: method, data: data, completion: {result, error in
                    if let err = error {
                        completion(nil, err)
                        return
                    }
                    completion(result?.data, nil)
                })
            })
        }
    }
    
    /**
     Connect to server
     */
    public func connect() {
        self.syncQueue.async{ [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.connecting == false else { return }
            strongSelf.connecting = true
            strongSelf.needReconnect = true
            var request = URLRequest(url: URL(string: strongSelf.url)!)
            for (key, value) in strongSelf.config.headers {
                request.addValue(value, forHTTPHeaderField: key)
            }
            let ws = WebSocket(request: request)
            if strongSelf.config.tlsSkipVerify {
                ws.disableSSLCertValidation = true
            }
            ws.onConnect = { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.onOpen()
            }
            ws.onDisconnect = { [weak self] (error: Error?) in
                guard let strongSelf = self else { return }
                let decoder = JSONDecoder()
                var serverDisconnect: CentrifugeDisconnectOptions?
                if let err = error as? WSError {
                    do {
                        let disconnect = try decoder.decode(CentrifugeDisconnectOptions.self, from: err.message.data(using: .utf8)!)
                        serverDisconnect = disconnect
                    } catch {}
                }
                strongSelf.onClose(serverDisconnect: serverDisconnect)
                
            }
            ws.onData = { [weak self] data in
                guard let strongSelf = self else { return }
                strongSelf.onData(data: data)
            }
            strongSelf.conn = ws
            strongSelf.conn?.connect()
        }
    }
    
    /**
     Disconnect from server
     */
    public func disconnect() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.needReconnect = false
            strongSelf.close(reason: "clean disconnect", reconnect: false)
        }
    }
    
    /**
     Create subscription object to specific channel with delegate
     - parameter channel: String
     - parameter delegate: CentrifugeSubscriptionDelegate
     - returns: CentrifugeSubscription
     */
    public func newSubscription(channel: String, delegate: CentrifugeSubscriptionDelegate) throws -> CentrifugeSubscription {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        guard self.subscriptions.filter({ $0.channel == channel }).count == 0 else { throw CentrifugeError.duplicateSub }
        let sub = CentrifugeSubscription(centrifuge: self, channel: channel, delegate: delegate)
        self.subscriptions.append(sub)
        return sub
    }

    /**
     Try to get Subscription from internal client registry. Can return nil if Subscription
     does not exist yet.
     - parameter channel: String
     - returns: CentrifugeSubscription?
     */
    public func getSubscription(channel: String) -> CentrifugeSubscription? {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        return self.subscriptions.first(where: { $0.channel == channel })
    }

    /**
     * Say Client that Subscription should be removed from internal registry. Subscription will be
     * automatically unsubscribed before removing.
     - parameter sub: CentrifugeSubscription
     */
    public func removeSubscription(_ sub: CentrifugeSubscription) {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        self.subscriptions
            .filter({ $0.channel == sub.channel })
            .forEach { sub in
                sub.unsubscribe()
            }
        self.subscriptions.removeAll(where: { $0.channel == sub.channel })
    }
}

internal extension CentrifugeClient {
    
    func refreshWithToken(token: String) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.token = token
            strongSelf.sendRefresh(token: token, completion: { result, error in
                if let _ = error {
                    strongSelf.close(reason: "refresh error", reconnect: true)
                    return
                }
                if let res = result {
                    if res.expires {
                        strongSelf.startConnectionRefresh(ttl: res.ttl)
                    }
                }
            })
        }
    }
    
    func getSubscriptionToken(channel: String, completion: @escaping (String)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard let client = strongSelf.client else { completion(""); return }
            strongSelf.delegateQueue.addOperation { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.delegate?.onPrivateSub(
                    strongSelf,
                    CentrifugePrivateSubEvent(client: client, channel: channel)
                ) {[weak self] token in
                    guard let strongSelf = self else { return }
                    strongSelf.syncQueue.async { [weak self] in
                        guard let strongSelf = self else { return }
                        guard strongSelf.client == client else { return }
                        completion(token)
                    }
                }
            }
        }
    }
    
    func unsubscribe(sub: CentrifugeSubscription) {
        let channel = sub.channel
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if strongSelf.status == .connected {
                guard let strongSelf = self else { return }
                strongSelf.sendUnsubscribe(channel: channel, completion: { res, error in
                    // Nothing to do here, we unsubscribed anyway.
                })
            }
        }
    }
    
    func resubscribe() {
        subscriptionsLock.lock()
        for sub in self.subscriptions {
            sub.resubscribeIfNecessary()
        }
        subscriptionsLock.unlock()
    }
    
    func subscribe(channel: String, token: String, isRecover: Bool, streamPosition: StreamPosition, completion: @escaping (Proto_SubscribeResult?, Error?)->()) {
        self.sendSubscribe(channel: channel, token: token, isRecover: isRecover, streamPosition: streamPosition, completion: completion)
    }
    
    func presence(channel: String, completion: @escaping ([String: CentrifugeClientInfo]?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.status == .connected else { completion(nil, CentrifugeError.disconnected); return }
            strongSelf.sendPresence(channel: channel, completion: completion)
        }
    }
    
    func presenceStats(channel: String, completion: @escaping (CentrifugePresenceStats?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.status == .connected else { completion(nil, CentrifugeError.disconnected); return }
            strongSelf.sendPresenceStats(channel: channel, completion: completion)
        }
    }
    
    func history(channel: String, completion: @escaping ([CentrifugePublication]?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.status == .connected else { completion(nil, CentrifugeError.disconnected); return }
            strongSelf.sendHistory(channel: channel, completion: completion)
        }
    }
    
    func close(reason: String, reconnect: Bool) {
        self.disconnectOpts = CentrifugeDisconnectOptions(reason: reason, reconnect: reconnect)
        self.conn?.disconnect()
    }
}

fileprivate extension CentrifugeClient {
    func log(_ items: Any) {
        print("CentrifugeClient: \n \(items)")
    }
}

fileprivate extension CentrifugeClient {
    func onOpen() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.sendConnect(completion: { [weak self] res, error in
                guard let strongSelf = self else { return }
                if let err = error {
                    switch err {
                    case CentrifugeError.replyError(let code, let message):
                        if code == 109 {
                            strongSelf.delegateQueue.addOperation { [weak self] in
                                guard let strongSelf = self else { return }
                                strongSelf.delegate?.onRefresh(strongSelf, CentrifugeRefreshEvent()) {[weak self] token in
                                    guard let strongSelf = self else { return }
                                    if token != "" {
                                        strongSelf.token = token
                                    }
                                    strongSelf.close(reason: message, reconnect: true)
                                    return
                                }
                            }
                        } else {
                            strongSelf.close(reason: "connect error", reconnect: true)
                            return
                        }
                    default:
                        strongSelf.close(reason: "connect error", reconnect: true)
                        return
                    }
                }
                
                if let result = res {
                    strongSelf.connecting = false
                    strongSelf.status = .connected
                    strongSelf.numReconnectAttempts = 0
                    strongSelf.client = result.client
                    strongSelf.delegateQueue.addOperation { [weak self] in
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onConnect(strongSelf, CentrifugeConnectEvent(client: result.client))
                    }
                    for cb in strongSelf.connectCallbacks.values {
                        cb(nil)
                    }
                    strongSelf.connectCallbacks.removeAll(keepingCapacity: true)
                    strongSelf.resubscribe()
                    strongSelf.startPing()
                    if result.expires {
                        strongSelf.startConnectionRefresh(ttl: result.ttl)
                    }
                }
            })
        }
    }
    
    func onData(data: Data) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.handleData(data: data as Data)
        }
    }
    
    func onClose(serverDisconnect: CentrifugeDisconnectOptions?) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            var disconnect: CentrifugeDisconnectOptions = CentrifugeDisconnectOptions(reason: "connection closed", reconnect: true)
            if let sd = serverDisconnect {
                disconnect = sd
            } else if let savedDisconnect = strongSelf.disconnectOpts {
                disconnect = savedDisconnect
            }
            strongSelf.connecting = false
            strongSelf.disconnectOpts = nil
            strongSelf.scheduleDisconnect(reason: disconnect.reason, reconnect: disconnect.reconnect)
        }
    }
    
    private func nextCommandId() -> UInt32 {
        self.commandIdLock.lock()
        self.commandId += 1
        let cid = self.commandId
        self.commandIdLock.unlock()
        return cid
    }
    
    private func newCommand(method: Proto_MethodType, params: Data) -> Proto_Command {
        var command = Proto_Command()
        let nextId = self.nextCommandId()
        command.id = nextId
        command.method = method
        command.params = params
        return command
    }
    
    private func sendCommand(command: Proto_Command, completion: @escaping (Proto_Reply?, Error?)->()) {
        self.syncQueue.async {
            let commands: [Proto_Command] = [command]
            do {
                let data = try CentrifugeSerializer.serializeCommands(commands: commands)
                self.conn?.write(data: data)
                self.waitForReply(id: command.id, completion: completion)
            } catch {
                completion(nil, error)
                return
            }
        }
    }
    
    private func sendCommandAsync(command: Proto_Command) throws {
        let commands: [Proto_Command] = [command]
        let data = try CentrifugeSerializer.serializeCommands(commands: commands)
        self.conn?.write(data: data)
    }
    
    private func waitForReply(id: UInt32, completion: @escaping (Proto_Reply?, Error?)->()) {
        let timeoutTask = DispatchWorkItem { [weak self] in
            self?.opCallbacks[id] = nil
            completion(nil, CentrifugeError.timeout)
        }
        self.syncQueue.asyncAfter(deadline: .now() + self.config.timeout, execute: timeoutTask)
        
        self.opCallbacks[id] = { [weak self] rep in
            timeoutTask.cancel()
            
            self?.opCallbacks[id] = nil

            if let err = rep.error {
                completion(nil, err)
            } else {
                completion(rep.reply, nil)
            }
        }
    }
    
    private func waitForConnect(completion: @escaping (Error?)->()) {
        if !self.needReconnect {
            completion(CentrifugeError.disconnected)
            return
        }
        if self.status == .connected {
            completion(nil)
            return
        }
        
        let uid = UUID().uuidString
        
        let timeoutTask = DispatchWorkItem { [weak self] in
            self?.connectCallbacks[uid] = nil
            completion(CentrifugeError.timeout)
        }
        self.syncQueue.asyncAfter(deadline: .now() + self.config.timeout, execute: timeoutTask)
        
        self.connectCallbacks[uid] = { error in
            timeoutTask.cancel()
            completion(error)
        }
    }
 
    private func scheduleReconnect() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.connecting = true
            // TODO: add jitter here
            let delay = min(pow(Double(strongSelf.numReconnectAttempts), 2), strongSelf.config.maxReconnectDelay)
            strongSelf.numReconnectAttempts += 1
            strongSelf.syncQueue.asyncAfter(deadline: .now() +  delay, execute: { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    if strongSelf.needReconnect {
                        strongSelf.conn?.connect()
                    } else {
                        strongSelf.connecting = false
                    }
                }
            })
        }
    }
    
    private func handleAsyncData(data: Data) throws {
        let push = try Proto_Push(serializedData: data)
        let channel = push.channel
        if push.type == Proto_PushType.publication {
            let pub = try Proto_Publication(serializedData: push.data)
            subscriptionsLock.lock()
            let subs = self.subscriptions.filter({ $0.channel == channel })
            if subs.count == 0 {
                subscriptionsLock.unlock()
                return
            }
            let sub = subs[0]
            subscriptionsLock.unlock()
            self.delegateQueue.addOperation {
                sub.delegate?.onPublish(sub, CentrifugePublishEvent(uid: pub.uid, data: pub.data, info: pub.info))
            }
        } else if push.type == Proto_PushType.join {
            let join = try Proto_Join(serializedData: push.data)
            subscriptionsLock.lock()
            let subs = self.subscriptions.filter({ $0.channel == channel })
            if subs.count == 0 {
                subscriptionsLock.unlock()
                return
            }
            let sub = subs[0]
            subscriptionsLock.unlock()
            self.delegateQueue.addOperation {
                sub.delegate?.onJoin(sub, CentrifugeJoinEvent(client: join.info.client, user: join.info.user, connInfo: join.info.connInfo, chanInfo: join.info.chanInfo))
            }
        } else if push.type == Proto_PushType.leave {
            let leave = try Proto_Leave(serializedData: push.data)
            subscriptionsLock.lock()
            let subs = self.subscriptions.filter({ $0.channel == channel })
            if subs.count == 0 {
                subscriptionsLock.unlock()
                return
            }
            let sub = subs[0]
            subscriptionsLock.unlock()
            self.delegateQueue.addOperation {
                sub.delegate?.onLeave(sub, CentrifugeLeaveEvent(client: leave.info.client, user: leave.info.user, connInfo: leave.info.connInfo, chanInfo: leave.info.chanInfo))
            }
        } else if push.type == Proto_PushType.unsub {
            let _ = try Proto_Unsub(serializedData: push.data)
            subscriptionsLock.lock()
            let subs = self.subscriptions.filter({ $0.channel == channel })
            if subs.count == 0 {
                subscriptionsLock.unlock()
                return
            }
            let sub = subs[0]
            subscriptionsLock.unlock()
            sub.unsubscribe()
        } else if push.type == Proto_PushType.message {
            let message = try Proto_Message(serializedData: push.data)
            self.delegateQueue.addOperation {
                self.delegate?.onMessage(self, CentrifugeMessageEvent(data: message.data))
            }
        }
    }
    
    private func handleData(data: Data) {
        guard let replies = try? CentrifugeSerializer.deserializeCommands(data: data) else { return }
        for reply in replies {
            if reply.id > 0 {
                self.opCallbacks[reply.id]?(CentrifugeResolveData(error: nil, reply: reply))
            } else {
                try? self.handleAsyncData(data: reply.result)
            }
        }
    }
    
    private func startPing() {
        if self.config.pingInterval == 0 {
            return
        }
        self.pingTimer = DispatchSource.makeTimerSource()
        self.pingTimer?.setEventHandler { [weak self] in
            guard let strongSelf = self else { return }
            let params = Proto_PingRequest()
            do {
                let paramsData = try params.serializedData()
                let command = strongSelf.newCommand(method: .ping, params: paramsData)
                strongSelf.sendCommand(command: command, completion: { [weak self] res, error in
                    guard let strongSelf = self else { return }
                    if let err = error {
                        switch err {
                        case CentrifugeError.timeout:
                            strongSelf.close(reason: "no ping", reconnect: true)
                            return
                        default:
                            // Nothing to do.
                            return
                        }
                    }
                })
            } catch {
                return
            }
        }
        self.pingTimer?.schedule(deadline: .now() + self.config.pingInterval, repeating: self.config.pingInterval)
        self.pingTimer?.resume()
    }
    
    private func stopPing() {
        self.pingTimer?.cancel()
    }
    
    private func startConnectionRefresh(ttl: UInt32) {
        let refreshTask = DispatchWorkItem { [weak self] in
            self?.delegateQueue.addOperation {
                guard let strongSelf = self else { return }
                strongSelf.delegate?.onRefresh(strongSelf, CentrifugeRefreshEvent()) { [weak self] token in
                    guard let strongSelf = self else { return }
                    if token == "" {
                        return
                    }
                    strongSelf.refreshWithToken(token: token)
                }
            }
        }

        self.syncQueue.asyncAfter(deadline: .now() + Double(ttl), execute: refreshTask)
        self.refreshTask = refreshTask
    }
    
    private func stopConnectionRefresh() {
        self.refreshTask?.cancel()
    }
    
    private func scheduleDisconnect(reason: String, reconnect: Bool) {
        let previousStatus = self.status
        self.status = .disconnected
        self.client = nil
        
        for resolveFunc in self.opCallbacks.values {
            resolveFunc(CentrifugeResolveData(error: CentrifugeError.disconnected, reply: nil))
        }
        self.opCallbacks.removeAll(keepingCapacity: true)
        
        for resolveFunc in self.connectCallbacks.values {
            resolveFunc(CentrifugeError.disconnected)
        }
        self.connectCallbacks.removeAll(keepingCapacity: true)
        
        subscriptionsLock.lock()
        for sub in self.subscriptions {
            sub.unsubscribeOnDisconnect()
        }
        subscriptionsLock.unlock()
        
        self.stopPing()
        
        self.stopConnectionRefresh()
        
        if previousStatus == .new || previousStatus == .connected  {
            self.delegateQueue.addOperation { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.delegate?.onDisconnect(
                    strongSelf,
                    CentrifugeDisconnectEvent(reason: reason, reconnect: reconnect)
                )
            }
        }
        
        if reconnect {
            self.scheduleReconnect()
        }
    }
    
    private func sendConnect(completion: @escaping (Proto_ConnectResult?, Error?)->()) {
        var params = Proto_ConnectRequest()
        if self.token != nil {
            params.token = self.token!
        }
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .connect, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_ConnectResult(serializedData: rep.result)
                        completion(result, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendRefresh(token: String, completion: @escaping (Proto_RefreshResult?, Error?)->()) {
        var params = Proto_RefreshRequest()
        params.token = token
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .refresh, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_RefreshResult(serializedData: rep.result)
                        completion(result, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendUnsubscribe(channel: String, completion: @escaping (Proto_UnsubscribeResult?, Error?)->()) {
        var params = Proto_UnsubscribeRequest()
        params.channel = channel
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .unsubscribe, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_UnsubscribeResult(serializedData: rep.result)
                        completion(result, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendSubscribe(channel: String, token: String, isRecover: Bool, streamPosition: StreamPosition, completion: @escaping (Proto_SubscribeResult?, Error?)->()) {
        var params = Proto_SubscribeRequest()
        params.channel = channel
        if isRecover {
            params.recover = true
            params.epoch = streamPosition.Epoch
            if (streamPosition.Gen > 0 || streamPosition.Seq > 0) {
                params.gen = streamPosition.Gen
                params.seq = streamPosition.Seq
            } else {
                params.offset = streamPosition.Offset
            }
        }

        if token != "" {
            params.token = token
        }
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .subscribe, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_SubscribeResult(serializedData: rep.result)
                        completion(result, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendPublish(channel: String, data: Data, completion: @escaping (Proto_PublishResult?, Error?)->()) {
        var params = Proto_PublishRequest()
        params.channel = channel
        params.data = data
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .publish, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_PublishResult(serializedData: rep.result)
                        completion(result, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendHistory(channel: String, completion: @escaping ([CentrifugePublication]?, Error?)->()) {
        var params = Proto_HistoryRequest()
        params.channel = channel
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .history, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_HistoryResult(serializedData: rep.result)
                        var pubs = [CentrifugePublication]()
                        for pub in result.publications {
                            pubs.append(CentrifugePublication(data: pub.data))
                        }
                        completion(pubs, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendPresence(channel: String, completion: @escaping ([String:CentrifugeClientInfo]?, Error?)->()) {
        var params = Proto_PresenceRequest()
        params.channel = channel
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .presence, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_PresenceResult(serializedData: rep.result)
                        var presence = [String: CentrifugeClientInfo]()
                        for (client, info) in result.presence {
                            presence[client] = CentrifugeClientInfo(client: info.client, user: info.user, connInfo: info.connInfo, chanInfo: info.chanInfo)
                        }
                        completion(presence, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendPresenceStats(channel: String, completion: @escaping (CentrifugePresenceStats?, Error?)->()) {
        var params = Proto_PresenceStatsRequest()
        params.channel = channel
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .presenceStats, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_PresenceStatsResult(serializedData: rep.result)
                        let stats = CentrifugePresenceStats(numClients: result.numClients, numUsers: result.numUsers)
                        completion(stats, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendRPC(method: String, data: Data, completion: @escaping (Proto_RPCResult?, Error?)->()) {
        var params = Proto_RPCRequest()
        params.data = data
        params.method = method
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .rpc, params: paramsData)
            self.sendCommand(command: command, completion: { [weak self] reply, error in
                guard let _ = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                if let rep = reply {
                    if rep.hasError {
                        completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message))
                        return
                    }
                    do {
                        let result = try Proto_RPCResult(serializedData: rep.result)
                        completion(result, nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            })
        } catch {
            completion(nil, error)
        }
    }
    
    private func sendSend(data: Data, completion: @escaping (Error?)->()) {
        var params = Proto_SendRequest()
        params.data = data
        do {
            let paramsData = try params.serializedData()
            let command = newCommand(method: .send, params: paramsData)
            try self.sendCommandAsync(command: command)
            completion(nil)
        } catch {
            completion(error)
        }
    }
}
