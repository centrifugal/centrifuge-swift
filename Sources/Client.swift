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
    var conn: WebSocket?
    var token: String?
    public var client: String?
    var commandId: UInt32 = 0
    var commandIdLock: NSLock = NSLock()
    var url: String
    var config: CentrifugeClientConfig
    var status: CentrifugeClientStatus = CentrifugeClientStatus.new
    var opCallbacks: [UInt32: ((resolveData) -> ())] = [:]
    var connectCallbacks: [String: ((Error?) -> ())] = [:]
    var subscriptionsLock = NSLock()
    var subscriptions = [CentrifugeSubscription]()
    var needReconnect = true
    var numReconnectAttempts = 0
    var pingTimer: DispatchSourceTimer?
    var disconnectOpts: disconnectOptions?
    var refreshTask: DispatchWorkItem?
    var delegate: CentrifugeClientDelegate
    var workQueue: DispatchQueue
    var delegateQueue: OperationQueue
    var syncQueue: DispatchQueue
    var connecting = false

    public init(url: String, config: CentrifugeClientConfig, delegate: CentrifugeClientDelegate, delegateQueue: OperationQueue? = nil) {
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

    public func setToken(_ token: String) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.token = token
        }
    }

    func getSubscriptionToken(channel: String, completion: @escaping (String)->()) {
        guard let client = self.client else { completion(""); return }
        self.delegateQueue.addOperation { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.delegate.onPrivateSub(
                strongSelf,
                CentrifugePrivateSubEvent(client: client, channel: channel)
            ) {[weak self] token in
                guard let _ = self else { return }
                completion(token)
            }
        }
    }

    public func publish(channel: String, data: Data, completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(err)
                    return
                }
                do {
                    let _ = try strongSelf.sendPublish(channel: channel, data: data)
                    completion(nil)
                } catch {
                    completion(error)
                }
            })
        }
    }
    
    func presence(channel: String, completion: @escaping ([String: CentrifugeClientInfo]?, Error?)->()) {
        self.workQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.status == .connected else { completion(nil, CentrifugeError.disconnected); return }
            do {
                let result = try strongSelf.sendPresence(channel: channel)
                completion(result, nil)
            } catch {
                completion(nil, error)
            }
        }
    }
    
    func presenceStats(channel: String, completion: @escaping (CentrifugePresenceStats?, Error?)->()) {
        self.workQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.status == .connected else { completion(nil, CentrifugeError.disconnected); return }
            do {
                let result = try strongSelf.sendPresenceStats(channel: channel)
                completion(result, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    func history(channel: String, completion: @escaping ([CentrifugePublication]?, Error?)->()) {
        self.workQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.status == .connected else { completion(nil, CentrifugeError.disconnected); return }
            do {
                let result = try strongSelf.sendHistory(channel: channel)
                completion(result, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    public func rpc(data: Data, completion: @escaping (Data?, Error?)->()) {
        self.workQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(nil, err)
                    return
                }
                do {
                    let result = try strongSelf.sendRPC(data: data)
                    completion(result.data, nil)
                } catch {
                    completion(nil, error)
                }
            })
        }
    }

    public func send(data: Data, completion: @escaping (Error?)->()) {
        self.workQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(err)
                    return
                }
                do {
                    let _ = try strongSelf.sendSend(data: data)
                    completion(nil)
                } catch {
                    completion(error)
                }
            })
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
                if strongSelf.needReconnect {
                    strongSelf.conn?.open()
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
                self.delegate.onMessage(self, CentrifugeMessageEvent(data: message.data))
            }
        }
    }

    func handleData(data: Data) {
        do {
            let replies = try deserializeCommands(data: data)
            for reply in replies {
                if reply.id > 0 {
                    self.opCallbacks[reply.id]?(resolveData(error: nil, reply: reply))
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

    func resubscribe() {
        subscriptionsLock.lock()
        for sub in self.subscriptions {
            sub.resubscribeIfNecessary()
        }
        subscriptionsLock.unlock()
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
                let _ = try strongSelf.sendCommand(command: command)
            } catch CentrifugeError.timeout {
                strongSelf.close(reason: "no ping", reconnect: true)
            } catch {
                return
            }
        }
        self.pingTimer?.schedule(deadline: .now() + self.config.pingInterval, repeating: self.config.pingInterval)
        self.pingTimer?.resume()
    }

    func close(reason: String, reconnect: Bool) {
        self.disconnectOpts = disconnectOptions(reason: reason, reconnect: reconnect)
        self.conn?.close()
    }

    func stopPing() {
         self.pingTimer?.cancel()
    }
    
    func refreshWithToken(token: String) {
        self.syncQueue.async { [weak self] in
            if let strongSelf = self {
                strongSelf.token = token
                strongSelf.workQueue.async { [weak self] in
                    if let strongSelf = self {
                        do {
                            let result = try strongSelf.sendRefresh(token: token)
                            if result.expires {
                                strongSelf.startConnectionRefresh(ttl: result.ttl)
                            }
                        } catch {
                            // TODO: handle error.
                        }
                    }
                }
            }
        }
    }
    
    func startConnectionRefresh(ttl: UInt32) {
        let refreshTask = DispatchWorkItem {
            self.delegateQueue.addOperation {
                self.delegate.onRefresh(self, CentrifugeRefreshEvent()) {[weak self] token in
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
                    do {
                        let result = try strongSelf.sendConnect()
                        strongSelf.connecting = false
                        strongSelf.status = .connected
                        strongSelf.numReconnectAttempts = 0
                        strongSelf.client = result.client
                        strongSelf.delegateQueue.addOperation { [weak self] in
                            guard let strongSelf = self else { return }
                            strongSelf.delegate.onConnect(strongSelf, CentrifugeConnectEvent(client: result.client))
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
                    } catch CentrifugeError.replyError(let code, let message) {
                        if code == 109 {
                            strongSelf.delegateQueue.addOperation { [weak self] in
                                guard let strongSelf = self else { return }
                                strongSelf.delegate.onRefresh(strongSelf, CentrifugeRefreshEvent()) {[weak self] token in
                                    guard let strongSelf = self else { return }
                                    if token != "" {
                                        strongSelf.token = token
                                    }
                                    strongSelf.close(reason: message, reconnect: true)
                                    return
                                }
                            }
                        }
                    } catch {
                        strongSelf.close(reason: "connect error", reconnect: true)
                    }
                }
            }
            ws.event.close = { code, reason, clean in
                strongSelf.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    let decoder = JSONDecoder()
                    let disconnect: disconnectOptions
                    do {
                        disconnect = try decoder.decode(disconnectOptions.self, from: reason.data(using: .utf8)!)
                    } catch {
                        if let d = strongSelf.disconnectOpts {
                            disconnect = d
                        } else {
                            disconnect = disconnectOptions(reason: "connection closed", reconnect: true)
                        }
                        strongSelf.disconnectOpts = nil
                    }
                    strongSelf.scheduleDisconnect(reason: disconnect.reason, reconnect: disconnect.reconnect)
                }
            }
            ws.event.message = { [weak self] message in
                guard let strongSelf = self else { return }
                if let data = message as? NSData {
                    strongSelf.workQueue.sync{ [weak self] in
                        guard let strongSelf = self else { return }
                        strongSelf.handleData(data: data as Data)
                    }
                }
            }
            strongSelf.conn = ws
        }
    }

    func scheduleDisconnect(reason: String, reconnect: Bool) {
        let previousStatus = self.status
        self.status = .disconnected
        self.client = nil

        for (_, resolveFunc) in self.opCallbacks {
            resolveFunc(resolveData(error: CentrifugeError.disconnected, reply: nil))
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
                strongSelf.delegate.onDisconnect(
                    strongSelf,
                    CentrifugeDisconnectEvent(reason: reason, reconnect: reconnect)
                )
            }
        }

        if reconnect {
            self.scheduleReconnect()
        }
    }

    public func disconnect() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.needReconnect = false
            strongSelf.close(reason: "clean disconnect", reconnect: false)
        }
    }

    public func newSubscription(channel: String, delegate: CentrifugeSubscriptionDelegate) throws -> CentrifugeSubscription {
        subscriptionsLock.lock()
        guard self.subscriptions.filter({ $0.channel == channel }).count == 0 else { throw CentrifugeError.duplicateSub }
        let sub = CentrifugeSubscription(centrifuge: self, channel: channel, delegate: delegate)
        self.subscriptions.append(sub)
        subscriptionsLock.unlock()
        return sub
    }

    func unsubscribe(sub: CentrifugeSubscription) {
        let channel = sub.channel
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if strongSelf.status == .connected {
                strongSelf.workQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    do {
                        let _ = try strongSelf.sendUnsubscribe(channel: channel)
                    } catch {}
                }
            }
        }
    }

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
    
    func sendConnect() throws -> Proto_ConnectResult {
        var params = Proto_ConnectRequest()
        if self.token != nil {
            params.token = self.token!
        }
        let paramsData = try params.serializedData()
        let command = newCommand(method: .connect, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_ConnectResult(serializedData: reply.result)
        return result
    }
    
    func sendRefresh(token: String) throws -> Proto_RefreshResult {
        var params = Proto_RefreshRequest()
        if self.token != nil {
            params.token = self.token!
        }
        let paramsData = try params.serializedData()
        let command = newCommand(method: .refresh, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_RefreshResult(serializedData: reply.result)
        return result
    }
    
    func sendSubscribe(channel: String, token: String) throws -> Proto_SubscribeResult {
        var params = Proto_SubscribeRequest()
        params.channel = channel
        if token != "" {
            params.token = token
        }
        let paramsData = try params.serializedData()
        let command = newCommand(method: .subscribe, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_SubscribeResult(serializedData: reply.result)
        return result
    }
    
    func sendUnsubscribe(channel: String) throws -> Proto_UnsubscribeResult {
        var params = Proto_UnsubscribeRequest()
        params.channel = channel
        let paramsData = try params.serializedData()
        let command = newCommand(method: .unsubscribe, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_UnsubscribeResult(serializedData: reply.result)
        return result
    }
    
    func sendPublish(channel: String, data: Data) throws -> Proto_PublishResult {
        if self.status != .connected {
            throw CentrifugeError.disconnected
        }
        var params = Proto_PublishRequest()
        params.channel = channel
        params.data = data
        let paramsData = try params.serializedData()
        let command = self.newCommand(method: .publish, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_PublishResult(serializedData: reply.result)
        return result
    }
    
    func sendHistory(channel: String) throws -> [CentrifugePublication] {
        if self.status != .connected {
            throw CentrifugeError.disconnected
        }
        var params = Proto_HistoryRequest()
        params.channel = channel
        let paramsData = try params.serializedData()
        let command = newCommand(method: .history, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_HistoryResult(serializedData: reply.result)
        
        var pubs = [CentrifugePublication]()
        for pub in result.publications {
            pubs.append(CentrifugePublication(uid: pub.uid, data: pub.data))
        }
        return pubs
    }

    func sendPresence(channel: String) throws -> [String:CentrifugeClientInfo]{
        if self.status != .connected {
            throw CentrifugeError.disconnected
        }
        var params = Proto_PresenceRequest()
        params.channel = channel
        let paramsData = try params.serializedData()
        let command = newCommand(method: .presence, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_PresenceResult(serializedData: reply.result)
        var presence = [String: CentrifugeClientInfo]()
        for (client, info) in result.presence {
            presence[client] = CentrifugeClientInfo(client: info.client, user: info.user, connInfo: info.connInfo, chanInfo: info.chanInfo)
        }
        return presence
    }

    func sendPresenceStats(channel: String) throws -> CentrifugePresenceStats {
        if self.status != .connected {
            throw CentrifugeError.disconnected
        }
        var params = Proto_PresenceStatsRequest()
        params.channel = channel
        let paramsData = try params.serializedData()
        let command = newCommand(method: .presenceStats, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_PresenceStatsResult(serializedData: reply.result)
        return CentrifugePresenceStats(numClients: result.numClients, numUsers: result.numUsers)
    }

    func sendRPC(data: Data) throws -> Proto_RPCResult {
        if self.status != .connected {
            throw CentrifugeError.disconnected
        }
        var params = Proto_RPCRequest()
        params.data = data
        let paramsData = try params.serializedData()
        let command = self.newCommand(method: .rpc, params: paramsData)
        let reply = try self.sendCommand(command: command)
        if reply.hasError {
            throw CentrifugeError.replyError(code: reply.error.code, message: reply.error.message)
        }
        let result = try Proto_RPCResult(serializedData: reply.result)
        return result
    }

    func sendSend(data: Data) throws {
        if self.status != .connected {
            throw CentrifugeError.disconnected
        }
        var params = Proto_SendRequest()
        params.data = data
        let paramsData = try params.serializedData()
        let command = self.newCommand(method: .send, params: paramsData)
        try self.sendCommandAsync(command: command)
    }
    
    func sendCommand(command: Proto_Command) throws -> Proto_Reply {
        let commands: [Proto_Command] = [command]
        let data = try serializeCommands(commands: commands)
        self.conn?.send(data: data)
        let reply = try self.waitForReply(id: command.id)
        return reply
    }
    
    func sendCommandAsync(command: Proto_Command) throws {
        let commands: [Proto_Command] = [command]
        let data = try serializeCommands(commands: commands)
        self.conn?.send(data: data)
    }

    func waitForReply(id: UInt32) throws -> Proto_Reply {
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
        
        func resolve(rep: resolveData) {
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
        self.workQueue.asyncAfter(deadline: .now() + self.config.timeout, execute: timeoutTask)
        
        // wait for resolve or timeout
        group.wait()
        self.opCallbacks.removeValue(forKey: id)
        if let err = opError {
            throw err
        }
        if timedOut {
            throw CentrifugeError.timeout
        }
        return reply
    }

    func waitForConnect(completion: @escaping (Error?)->()) {
        self.syncQueue.async { [weak self] in
            if let strongSelf = self {
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
                strongSelf.workQueue.asyncAfter(deadline: .now() + strongSelf.config.timeout, execute: timeoutTask)
                
                strongSelf.workQueue.async { [weak self] in
                    guard let client = self else {return}
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
        }
    }
}
