//
//  Client.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation
import SwiftWebSocket
import SwiftProtobuf

public enum CentrifugeError: Error {
    case timeout
    case duplicateSub
    case disconnected
    case unsubscribed
    case replyError(code: UInt32, message: String)
}

public struct CentrifugeClientConfig {
    var timeout = 5.0
    var debug = false
    var headers = [String:String]()
    var tlsSkipVerify = false
    var maxReconnectDelay = 20.0
    var privateChannelPrefix = "$"
    var pingInterval = 25.0
    
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
    fileprivate(set) var workQueue: DispatchQueue
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
    
    public init(url: String, config: CentrifugeClientConfig, delegate: CentrifugeClientDelegate? = nil, delegateQueue: OperationQueue? = nil) {
        self.url = url
        
        // iOS client work only over Protobuf protocol.
        if self.url.range(of: "format=protobuf") == nil {
            self.url += "?format=protobuf"
        }
        
        self.config = config
        self.delegate = delegate
        
        let queueID = UUID().uuidString
        self.syncQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.sync<\(queueID)>")
        self.workQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.work<\(queueID)>", attributes: .concurrent)
        
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
     - parameter data: Data
     - parameter completion: Completion block
     */
    public func rpc(data: Data, completion: @escaping (Data?, Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                strongSelf.sendRPC(data: data, completion: {result, error in
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
                ws.allowSelfSignedSSL = true
            }
            ws.binaryType = .nsData
            ws.event.open = {
                strongSelf.syncQueue.async { [weak self] in
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
                            for (_, cb) in strongSelf.connectCallbacks {
                                cb(nil)
                            }
                            strongSelf.connectCallbacks = [:]
                            strongSelf.resubscribe()
                            strongSelf.startPing()
                            if result.expires {
                                strongSelf.startConnectionRefresh(ttl: result.ttl)
                            }
                        }
                    })
                }
            }
            ws.event.close = { [weak self] code, reason, clean in
                guard let strongSelf = self else { return }
                strongSelf.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.connecting = false
                    let decoder = JSONDecoder()
                    let disconnect: CentrifugeDisconnectOptions
                    do {
                        disconnect = try decoder.decode(CentrifugeDisconnectOptions.self, from: reason.data(using: .utf8)!)
                    } catch {
                        if let d = strongSelf.disconnectOpts {
                            disconnect = d
                        } else {
                            disconnect = CentrifugeDisconnectOptions(reason: "connection closed", reconnect: true)
                        }
                        strongSelf.disconnectOpts = nil
                    }
                    strongSelf.scheduleDisconnect(reason: disconnect.reason, reconnect: disconnect.reconnect)
                }
            }
            ws.event.message = { [weak self] message in
                guard let strongSelf = self else { return }
                strongSelf.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    if let data = message as? NSData {
                        strongSelf.handleData(data: data as Data)
                    }
                }
            }
            strongSelf.conn = ws
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
        subscriptionsLock.lock()
        guard self.subscriptions.filter({ $0.channel == channel }).count == 0 else { throw CentrifugeError.duplicateSub }
        let sub = CentrifugeSubscription(centrifuge: self, channel: channel, delegate: delegate)
        self.subscriptions.append(sub)
        subscriptionsLock.unlock()
        return sub
    }
}

internal extension CentrifugeClient {
    
    func refreshWithToken(token: String) {
        self.syncQueue.async { [weak self] in
            if let strongSelf = self {
                strongSelf.token = token
                strongSelf.syncQueue.async { [weak self] in
                    if let strongSelf = self {
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
            }
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
    
    func subscribe(channel: String, token: String, completion: @escaping (Proto_SubscribeResult?, Error?)->()) {
        self.sendSubscribe(channel: channel, token: token, completion: completion)
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
        self.conn?.close()
    }
}

fileprivate extension CentrifugeClient {
    func log(_ items: Any) {
        print("CentrifugeClient: \n \(items)")
    }
}

fileprivate extension CentrifugeClient {
    func nextCommandId() -> UInt32 {
        self.commandIdLock.lock()
        self.commandId += 1
        let cid = self.commandId
        self.commandIdLock.unlock()
        return cid
    }
    
    func newCommand(method: Proto_MethodType, params: Data) -> Proto_Command {
        var command = Proto_Command()
        let nextId = self.nextCommandId()
        command.id = nextId
        command.method = method
        command.params = params
        return command
    }
    
    func sendCommand(command: Proto_Command, completion: @escaping (Proto_Reply?, Error?)->()) {
        self.syncQueue.async {
            let commands: [Proto_Command] = [command]
            do {
                let data = try CentrifugeSerializer.serializeCommands(commands: commands)
                self.conn?.send(data: data)
                self.waitForReply(id: command.id, completion: completion)
            } catch {
                completion(nil, error)
                return
            }
        }
    }
    
    func sendCommandAsync(command: Proto_Command) throws {
        let commands: [Proto_Command] = [command]
        let data = try CentrifugeSerializer.serializeCommands(commands: commands)
        self.conn?.send(data: data)
    }
    
    func waitForReply(id: UInt32, completion: @escaping (Proto_Reply?, Error?)->()) {
        let group = DispatchGroup()
        group.enter()
        
        var reply: Proto_Reply = Proto_Reply()
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
        
        func resolve(rep: CentrifugeResolveData) {
            if groupLeft {
                return
            }
            if let err = rep.error {
                opError = err
            } else if let r = rep.reply {
                reply = r
            }
            timeoutTask.cancel()
            groupLeft = true
            group.leave()
        }
        let resolveFunc = resolve
        self.opCallbacks[id] = resolveFunc
        self.syncQueue.asyncAfter(deadline: .now() + self.config.timeout, execute: timeoutTask)
        
        // wait for resolve or timeout
        self.workQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            group.wait()
            strongSelf.syncQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.opCallbacks.removeValue(forKey: id)
                if let err = opError {
                    completion(nil, err)
                    return
                }
                if timedOut {
                    completion(nil, CentrifugeError.timeout)
                    return
                }
                completion(reply, nil)
            }
        }
    }
    
    func waitForConnect(completion: @escaping (Error?)->()) {
        let strongSelf = self
        if !strongSelf.needReconnect {
            completion(CentrifugeError.disconnected)
            return
        }
        if strongSelf.status == .connected {
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
        strongSelf.connectCallbacks[uid] = resolveFunc
        strongSelf.syncQueue.asyncAfter(deadline: .now() + strongSelf.config.timeout, execute: timeoutTask)
        
        strongSelf.workQueue.async { [weak self] in
            guard let client = self else { return }
            group.wait()
            client.syncQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                strongSelf.connectCallbacks.removeValue(forKey: uid)
                if let err = opError {
                    completion(err)
                }
                if timedOut {
                    completion(CentrifugeError.timeout)
                }
                completion(nil)
            }
        }
    }
    
    func scheduleReconnect() {
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
                        strongSelf.conn?.open()
                    } else {
                        strongSelf.connecting = false
                    }
                }
            })
        }
    }
    
    func handleAsyncData(data: Data) throws {
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
                sub.delegate.onPublish(sub, CentrifugePublishEvent(uid: pub.uid, data: pub.data, info: pub.info))
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
                sub.delegate.onJoin(sub, CentrifugeJoinEvent(client: join.info.client, user: join.info.user, connInfo: join.info.connInfo, chanInfo: join.info.chanInfo))
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
                sub.delegate.onLeave(sub, CentrifugeLeaveEvent(client: leave.info.client, user: leave.info.user, connInfo: leave.info.connInfo, chanInfo: leave.info.chanInfo))
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
    
    func handleData(data: Data) {
        do {
            let replies = try CentrifugeSerializer.deserializeCommands(data: data)
            for reply in replies {
                if reply.id > 0 {
                    self.opCallbacks[reply.id]?(CentrifugeResolveData(error: nil, reply: reply))
                } else {
                    do {
                        try self.handleAsyncData(data: reply.result)
                    } catch {}
                }
            }
        } catch {
            return
        }
    }
    
    func startPing() {
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
    
    func stopPing() {
        self.pingTimer?.cancel()
    }
    
    func startConnectionRefresh(ttl: UInt32) {
        let refreshTask = DispatchWorkItem {
            self.delegateQueue.addOperation {
                self.delegate?.onRefresh(self, CentrifugeRefreshEvent()) {[weak self] token in
                    guard let strongSelf = self else { return }
                    if token == "" {
                        return
                    }
                    strongSelf.refreshWithToken(token: token)
                }
            }
        }
        self.workQueue.asyncAfter(deadline: .now() + Double(ttl), execute: refreshTask)
        self.refreshTask = refreshTask
    }
    
    func stopConnectionRefresh() {
        self.refreshTask?.cancel()
    }
    
    func scheduleDisconnect(reason: String, reconnect: Bool) {
        let previousStatus = self.status
        self.status = .disconnected
        self.client = nil
        
        for (_, resolveFunc) in self.opCallbacks {
            resolveFunc(CentrifugeResolveData(error: CentrifugeError.disconnected, reply: nil))
        }
        self.opCallbacks = [:]
        
        for (_, resolveFunc) in self.connectCallbacks {
            resolveFunc(CentrifugeError.disconnected)
        }
        self.connectCallbacks = [:]
        
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
    
    func sendConnect(completion: @escaping (Proto_ConnectResult?, Error?)->()) {
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
    
    func sendRefresh(token: String, completion: @escaping (Proto_RefreshResult?, Error?)->()) {
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
    
    func sendUnsubscribe(channel: String, completion: @escaping (Proto_UnsubscribeResult?, Error?)->()) {
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
    
    func sendSubscribe(channel: String, token: String, completion: @escaping (Proto_SubscribeResult?, Error?)->()) {
        var params = Proto_SubscribeRequest()
        params.channel = channel
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
    
    func sendPublish(channel: String, data: Data, completion: @escaping (Proto_PublishResult?, Error?)->()) {
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
    
    func sendHistory(channel: String, completion: @escaping ([CentrifugePublication]?, Error?)->()) {
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
                            pubs.append(CentrifugePublication(uid: pub.uid, data: pub.data))
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
    
    func sendPresence(channel: String, completion: @escaping ([String:CentrifugeClientInfo]?, Error?)->()) {
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
    
    func sendPresenceStats(channel: String, completion: @escaping (CentrifugePresenceStats?, Error?)->()) {
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
    
    func sendRPC(data: Data, completion: @escaping (Proto_RPCResult?, Error?)->()) {
        var params = Proto_RPCRequest()
        params.data = data
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
    
    func sendSend(data: Data, completion: @escaping (Error?)->()) {
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
