//
//  Client.swift
//  SwiftCentrifuge
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import Foundation
import SwiftProtobuf
//import os.log

public enum CentrifugeError: Error {
    case timeout
    case duplicateSub
    case clientDisconnected
    case subscriptionUnsubscribed
    case transportError(error: Error)
    case tokenError(error: Error)
    case connectError(error: Error)
    case refreshError(error: Error)
    case subscriptionSubscribeError(error: Error)
    case subscriptionTokenError(error: Error)
    case subscriptionRefreshError(error: Error)
    case replyError(code: UInt32, message: String, temporary: Bool)
}

public protocol CentrifugeConnectionTokenGetter {
    func getConnectionToken(_ event: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> ())
}

public struct CentrifugeClientConfig {
    public init(timeout: Double = 5.0, headers: [String : String] = [String:String](), tlsSkipVerify: Bool = false, minReconnectDelay: Double = 0.5, maxReconnectDelay: Double = 20.0, maxServerPingDelay: Double = 10.0, name: String = "swift", version: String = "", token: String? = nil, data: Data? = nil, debug: Bool = false, tokenGetter: CentrifugeConnectionTokenGetter? = nil) {
        self.timeout = timeout
        self.headers = headers
        self.tlsSkipVerify = tlsSkipVerify
        self.minReconnectDelay = minReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.maxServerPingDelay = maxServerPingDelay
        self.name = name
        self.version = version
        self.token = token
        self.data = data
        self.debug = debug
        self.tokenGetter = tokenGetter
    }
    
    public var timeout = 5.0
    public var headers = [String:String]()
    public var tlsSkipVerify = false
    public var minReconnectDelay = 0.5
    public var maxReconnectDelay = 20.0
    public var maxServerPingDelay = 10.0
    public var name = "swift"
    public var version = ""
    public var token: String?  = nil
    public var data: Data? = nil
    public var debug: Bool = false
    public var tokenGetter: CentrifugeConnectionTokenGetter?
}

public enum CentrifugeClientState {
    case disconnected
    case connecting
    case connected
}

public class CentrifugeClient {
    public weak var delegate: CentrifugeClientDelegate?
    
    //MARK -
    fileprivate(set) var url: String
    fileprivate(set) var syncQueue: DispatchQueue
    fileprivate(set) var config: CentrifugeClientConfig
    
    //MARK -
    fileprivate(set) var internalState: CentrifugeClientState = .disconnected
    fileprivate var conn: WebSocket?
    fileprivate var client: String?
    fileprivate var token: String?
    fileprivate var data: Data?
    fileprivate var commandId: UInt32 = 0
    fileprivate var commandIdLock: NSLock = NSLock()
    fileprivate var opCallbacks: [UInt32: ((CentrifugeResolveData) -> ())] = [:]
    fileprivate var connectCallbacks: [String: ((Error?) -> ())] = [:]
    fileprivate var subscriptionsLock = NSLock()
    fileprivate var subscriptions = [CentrifugeSubscription]()
    fileprivate var serverSubs = [String: ServerSubscription]()
    fileprivate var reconnectAttempts = 0
    fileprivate var disconnectOpts: CentrifugeDisconnectOptions?
    fileprivate var refreshTask: DispatchWorkItem?
    fileprivate var refreshRequired: Bool = false
    fileprivate var pingTimer: DispatchSourceTimer?
    fileprivate var pingInterval: UInt32 = 0
    fileprivate var sendPong: Bool = false
    fileprivate var reconnectTask: DispatchWorkItem?
    
    static let barrierQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.barrier<\(UUID().uuidString)>", attributes: .concurrent)
    
    public var state: CentrifugeClientState {
        get {
            return CentrifugeClient.barrierQueue.sync { internalState }
        }
        set (newState) {
            CentrifugeClient.barrierQueue.async(flags: .barrier) { self.internalState = newState }
        }
    }
    
    /// Initialize client.
    ///
    /// - Parameters:
    ///   - url: protobuf URL endpoint of Centrifugo/Centrifuge.
    ///   - config: config object.
    ///   - delegate: delegate protocol implementation to react on client events.
    public init(endpoint: String, config: CentrifugeClientConfig, delegate: CentrifugeClientDelegate? = nil) {
        self.url = endpoint
        self.config = config
        self.delegate = delegate
        
        if config.token != nil {
            self.token = config.token;
        }
        if config.data != nil {
            self.data = config.data;
        }
        
        let queueID = UUID().uuidString
        self.syncQueue = DispatchQueue(label: "com.centrifugal.centrifuge-swift.sync<\(queueID)>")
        
        var request = URLRequest(url: URL(string: self.url)!)
        for (key, value) in self.config.headers {
            request.addValue(value, forHTTPHeaderField: key)
        }
        
        let ws = WebSocket(request: request, protocols: ["centrifuge-protobuf"])
        if self.config.tlsSkipVerify {
            ws.disableSSLCertValidation = true
        }
        ws.onConnect = { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.onTransportOpen()
        }
        ws.onDisconnect = { [weak self] (error: Error?) in
            guard let strongSelf = self else { return }
            strongSelf.syncQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                
                if strongSelf.state == .disconnected {
                    return
                }
                
                if (strongSelf.state == .connecting) {
                    if let err = error {
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeErrorEvent(error: CentrifugeError.transportError(error: err))
                        )
                    }
                }
                
                var disconnect: CentrifugeDisconnectOptions
                
                // We act according to Disconnect code semantics.
                // See https://github.com/centrifugal/centrifuge/blob/master/disconnect.go.
                if let err = error as? WSError {
                    var code: UInt32 = UInt32(err.code)
                    var reconnect = code < 3500 || code >= 5000 || (code >= 4000 && code < 4500)
                    if code < 3000 {
                        // We expose codes defined by Centrifuge protocol, hiding details
                        // about transport-specific error codes. We may have extra optional
                        // transportCode field in the future.
                        if code == 1009 {
                            code = disconnectCodeMessageSizeLimit
                            reconnect = false
                        } else {
                            code = connectingCodeTransportClosed
                        }
                    }
                    disconnect = CentrifugeDisconnectOptions(code: UInt32(code), reason: err.message, reconnect: reconnect)
                } else {
                    disconnect = CentrifugeDisconnectOptions(code: connectingCodeTransportClosed, reason: "transport closed", reconnect: true)
                }
                
                if strongSelf.state != .disconnected {
                    strongSelf.processDisconnect(code: disconnect.code, reason: disconnect.reason, reconnect: disconnect.reconnect)
                }
                
                if strongSelf.state == .connecting {
                    strongSelf.scheduleReconnect()
                }
            }
        }
        ws.onData = { [weak self] data in
            guard let strongSelf = self else { return }
            strongSelf.onData(data: data)
        }
        self.conn = ws
    }
    
    /**
     Connect to server.
     */
    public func connect() {
        self.syncQueue.async{ [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.state != .connecting else { return }
            guard strongSelf.state != .connected else { return }
            strongSelf.debugLog("start connecting")
            strongSelf.state = .connecting
            strongSelf.delegate?.onConnecting(strongSelf, CentrifugeConnectingEvent(code: connectingCodeConnectCalled, reason: "connect called"))
            strongSelf.reconnectAttempts = 0
            strongSelf.conn?.connect()
        }
    }
    
    /**
     Disconnect from server.
     */
    public func disconnect() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.processDisconnect(code: disconnectedCodeDisconnectCalled, reason: "disconnect called", reconnect: false)
        }
    }
    
    /**
     Create subscription object to specific channel with delegate
     - parameter channel: String
     - parameter delegate: CentrifugeSubscriptionDelegate
     - returns: CentrifugeSubscription
     */
    public func newSubscription(channel: String, delegate: CentrifugeSubscriptionDelegate, config: CentrifugeSubscriptionConfig? = nil) throws -> CentrifugeSubscription {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        guard self.subscriptions.filter({ $0.channel == channel }).count == 0 else { throw CentrifugeError.duplicateSub }
        let sub = CentrifugeSubscription(
            centrifuge: self,
            channel: channel,
            config: config ?? CentrifugeSubscriptionConfig(),
            delegate: delegate
        )
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
     * Say Client that Subscription should be removed from the internal registry. Subscription will be
     * automatically unsubscribed before removing.
     - parameter sub: CentrifugeSubscription
     */
    public func removeSubscription(_ sub: CentrifugeSubscription) {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        self.subscriptions
            .filter({ $0.channel == sub.channel })
            .forEach { sub in
                sub.processUnsubscribe(sendUnsubscribe: true, code: unsubscribedCodeUnsubscribeCalled, reason: "unsubscribe called")
            }
        self.subscriptions.removeAll(where: { $0.channel == sub.channel })
    }
    
    /**
     * Get a map with all client-side suscriptions in client's internal registry.
     */
    public func getSubscriptions() -> [String: CentrifugeSubscription] {
        defer { subscriptionsLock.unlock() }
        subscriptionsLock.lock()
        var subs = [String : CentrifugeSubscription]()
        self.subscriptions.forEach { sub in
            subs[sub.channel] = sub
        }
        return subs
    }
    
    /**
     Send raw asynchronous (without waiting for a response) message to server.
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
     Publish message Data to channel.
     - parameter channel: String channel name
     - parameter data: Data message data
     - parameter completion: Completion block
     */
    public func publish(channel: String, data: Data, completion: @escaping (Result<CentrifugePublishResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendPublish(channel: channel, data: data, completion: { _, error in
                    guard self != nil else { return }
                    if let err = error {
                        completion(.failure(err))
                        return
                    }
                    completion(.success(CentrifugePublishResult()))
                })
            })
        }
    }
    
    /**
     Send RPC  command.
     - parameter method: String
     - parameter data: Data
     - parameter completion: Completion block
     */
    public func rpc(method: String, data: Data, completion: @escaping (Result<CentrifugeRpcResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendRPC(method: method, data: data, completion: {result, error in
                    if let err = error {
                        completion(.failure(err))
                        return
                    }
                    completion(.success(CentrifugeRpcResult(data: result!.data)))
                })
            })
        }
    }
    
    public func presence(channel: String, completion: @escaping (Result<CentrifugePresenceResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendPresence(channel: channel, completion: completion)
            })
        }
    }
    
    public func presenceStats(channel: String, completion: @escaping (Result<CentrifugePresenceStatsResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendPresenceStats(channel: channel, completion: completion)
            })
        }
    }
    
    public func history(channel: String, limit: Int32 = 0, since: CentrifugeStreamPosition? = nil, reverse: Bool = false, completion: @escaping (Result<CentrifugeHistoryResult, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.waitForConnect(completion: { [weak self] error in
                guard let strongSelf = self else { return }
                if let err = error {
                    completion(.failure(err))
                    return
                }
                strongSelf.sendHistory(channel: channel, limit: limit, since: since, reverse: reverse, completion: completion)
            })
        }
    }
}

internal extension CentrifugeClient {
    
    func refreshWithToken(token: String) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.token = token
            strongSelf.sendRefresh(token: token, completion: { [weak self] result, error in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .connected else { return }
                if let err = error {
                    defer {
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeErrorEvent(error: CentrifugeError.refreshError(error: err))
                        )
                    }
                    switch err {
                    case CentrifugeError.replyError(let code, let message, let temporary):
                        if temporary {
                            strongSelf.startConnectionRefresh(ttl: UInt32(floor(strongSelf.getBackoffDelay(step: 0, minDelay: 5, maxDelay: 10))))
                            return
                        } else {
                            strongSelf.processDisconnect(code: code, reason: message, reconnect: false)
                            return
                        }
                    default:
                        strongSelf.startConnectionRefresh(ttl: UInt32(floor(strongSelf.getBackoffDelay(step: 0, minDelay: 5, maxDelay: 10))))
                        return
                    }
                }
                if let res = result {
                    if res.expires {
                        strongSelf.startConnectionRefresh(ttl: res.ttl)
                    }
                }
            })
        }
    }
    
    func getBackoffDelay(step: Int, minDelay: Double, maxDelay: Double) -> Double {
        // Full jitter technique, details:
        // https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
        // Example delays for steps 0 ... 9, minDelay: 0.5, maxDelay: 20.0
        // 0:       0.5116465680544957
        // 1:       0.9243348276211367
        // 2:       2.178205903666517
        // 3:       2.3306662375223826
        // 4:       6.011917228522875
        // 5:       4.514918385024222
        // 6:       18.60093247413233
        // 7:       19.42679889496607
        // 8:       10.569444750143937
        // 9:       16.69024085860802
        var currentStep = step;
        if (currentStep > 31) { currentStep = 31 }
        return min(maxDelay, minDelay + Double.random(in: 0 ... min(maxDelay, minDelay * pow(2, Double(currentStep)))));
    }
    
    func debugLog(_ message: String) {
        guard self.config.debug else { return }
        //        os_log("CentrifugeClient: %{public}@", log: OSLog.default, type: .debug, message)
        print(message)
    }
    
    func sendSubRefresh(token: String, channel: String, completion: @escaping (Centrifugal_Centrifuge_Protocol_SubRefreshResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_SubRefreshRequest()
        req.token = token
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.subRefresh = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.subRefresh, nil)
            }
        })
    }
        
    func getConnectionToken(completion: @escaping (Result<String, Error>)->()) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.config.tokenGetter != nil else { return }
            strongSelf.config.tokenGetter!.getConnectionToken(
                CentrifugeConnectionTokenEvent()
            ) {[weak self] result in
                guard let strongSelf = self else { return }
                strongSelf.syncQueue.async { [weak self] in
                    guard self != nil else { return }
                    completion(result)
                }
            }
        }
    }
    
    func getClient() -> String? {
        return self.client;
    }
    
    func unsubscribe(sub: CentrifugeSubscription) {
        let channel = sub.channel
        if self.state == .connected {
            self.sendUnsubscribe(channel: channel, completion: { [weak self] _, error in
                guard let strongSelf = self else { return }
                if let _ = error {
                    strongSelf.reconnect(
                        code: connectingCodeUnsubscribeError, reason: "unsubscribe error")
                    return
                }
            })
        }
    }
    
    func resubscribe() {
        subscriptionsLock.lock()
        for sub in self.subscriptions {
            sub.resubscribeIfNecessary()
        }
        subscriptionsLock.unlock()
    }
    
    func subscribe(channel: String, token: String, data: Data?, recover: Bool, streamPosition: StreamPosition, positioned: Bool, recoverable: Bool, completion: @escaping (Centrifugal_Centrifuge_Protocol_SubscribeResult?, Error?)->()) {
        self.sendSubscribe(channel: channel, token: token, data: data, recover: recover, streamPosition: streamPosition, positioned: positioned, recoverable: recoverable, completion: completion)
    }
    
    func reconnect(code: UInt32, reason: String) {
        self.processDisconnect(code: code, reason: reason, reconnect: true)
    }
}

fileprivate extension CentrifugeClient {
    func onTransportOpen() {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.state == .connecting else { return }
            
            if strongSelf.refreshRequired || (strongSelf.token == "" && strongSelf.config.tokenGetter != nil) {
                strongSelf.getConnectionToken(completion: { [weak self] result in
                    guard let strongSelf = self, strongSelf.state == .connecting else { return }
                    switch result {
                    case .success(let token):
                        if token == "" {
                            strongSelf.failUnauthorized();
                            return
                        }
                        strongSelf.syncQueue.async { [weak self] in
                            guard let strongSelf = self, strongSelf.state == .connecting else { return }
                            strongSelf.token = token
                            strongSelf.sendConnect(completion: { [weak self] res, error in
                                guard let strongSelf = self else { return }
                                strongSelf.handleConnectResult(res: res, error: error)
                            })
                        }
                    case .failure(let error):
                        guard let strongSelf = self else { return }
                        strongSelf.delegate?.onError(
                            strongSelf,
                            CentrifugeErrorEvent(error: CentrifugeError.tokenError(error: error))
                        )
                        strongSelf.conn?.disconnect()
                        return
                    }
                })
            }
            
            strongSelf.sendConnect(completion: { [weak self] res, error in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .connecting else { return }
                strongSelf.handleConnectResult(res: res, error: error)
            })
        }
    }
    
    func handleConnectResult(res: Centrifugal_Centrifuge_Protocol_ConnectResult?, error: Error?) {
        if let err = error {
            defer {
                self.delegate?.onError(
                    self,
                    CentrifugeErrorEvent(error: CentrifugeError.connectError(error: err))
                )
            }
            switch err {
            case CentrifugeError.replyError(let code, let message, let temporary):
                if code == 109 { // Token expired.
                    self.refreshRequired = true
                    self.conn?.disconnect()
                    return
                } else if temporary {
                    self.conn?.disconnect()
                    return
                } else {
                    self.processDisconnect(code: code, reason: message, reconnect: false)
                    return
                }
            default:
                self.conn?.disconnect()
                return
            }
        }
        
        if let result = res {
            self.state = .connected
            self.reconnectAttempts = 0
            self.client = result.client
            self.delegate?.onConnected(self, CentrifugeConnectedEvent(client: result.client, data: result.data))
            for cb in self.connectCallbacks.values {
                cb(nil)
            }
            self.connectCallbacks.removeAll(keepingCapacity: false)
            
            // Process server-side subscriptions.
            for (channel, subResult) in result.subs {
                self.serverSubs[channel] = ServerSubscription(recoverable: subResult.recoverable, offset: subResult.offset, epoch: subResult.epoch)
                let event = CentrifugeServerSubscribedEvent(channel: channel, wasRecovering: subResult.wasRecovering, recovered: subResult.recovered, positioned: subResult.positioned, recoverable: subResult.recoverable, streamPosition: subResult.positioned || subResult.recoverable ? StreamPosition(offset: subResult.offset, epoch: subResult.epoch) : nil, data: subResult.data)
                self.delegate?.onSubscribed(self, event)
                subResult.publications.forEach{ pub in
                    var info: CentrifugeClientInfo? = nil;
                    if pub.hasInfo {
                        info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
                    }
                    let pubEvent = CentrifugeServerPublicationEvent(channel: channel, data: pub.data, offset: pub.offset, tags: pub.tags, info: info)
                    self.delegate?.onPublication(self, pubEvent)
                }
                for (channel, _) in self.serverSubs {
                    if result.subs[channel] == nil {
                        self.delegate?.onUnsubscribed(self, CentrifugeServerUnsubscribedEvent(channel: channel))
                        self.serverSubs.removeValue(forKey: channel)
                    }
                }
            }
            // Resubscribe to client-side subscriptions.
            self.resubscribe()
            
            // Start reacting on pings from a server.
            if result.ping > 0 {
                self.pingInterval = result.ping
                self.sendPong = result.pong
                self.startWaitPing()
            }
            
            // Periodically refresh connection token.
            if result.expires {
                self.startConnectionRefresh(ttl: result.ttl)
            }
        }
    }
    
    func onData(data: Data) {
        self.syncQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.handleData(data: data as Data)
        }
    }
    
    private func nextCommandId() -> UInt32 {
        self.commandIdLock.lock()
        self.commandId += 1
        let cid = self.commandId
        self.commandIdLock.unlock()
        return cid
    }
    
    private func sendCommand(command: Centrifugal_Centrifuge_Protocol_Command, completion: @escaping (Centrifugal_Centrifuge_Protocol_Reply?, Error?)->()) {
        let strongSelf = self
        let commands: [Centrifugal_Centrifuge_Protocol_Command] = [command]
        do {
            let data = try CentrifugeSerializer.serializeCommands(commands: commands)
            strongSelf.conn?.write(data: data)
            strongSelf.waitForReply(id: command.id, completion: completion)
        } catch {
            completion(nil, error)
            return
        }
    }
    
    private func sendCommandAsync(command: Centrifugal_Centrifuge_Protocol_Command) throws {
        let commands: [Centrifugal_Centrifuge_Protocol_Command] = [command]
        let data = try CentrifugeSerializer.serializeCommands(commands: commands)
        self.conn?.write(data: data)
    }
    
    private func waitForReply(id: UInt32, completion: @escaping (Centrifugal_Centrifuge_Protocol_Reply?, Error?)->()) {
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.opCallbacks[id] = nil
            completion(nil, CentrifugeError.timeout)
        }
        self.syncQueue.asyncAfter(deadline: .now() + self.config.timeout, execute: timeoutTask)
        
        self.opCallbacks[id] = { [weak self] rep in
            guard let strongSelf = self else { return }
            timeoutTask.cancel()
            
            strongSelf.opCallbacks[id] = nil
            
            if let err = rep.error {
                completion(nil, err)
            } else {
                completion(rep.reply, nil)
            }
        }
    }
    
    private func waitForConnect(completion: @escaping (Error?)->()) {
        if self.state == .disconnected {
            completion(CentrifugeError.clientDisconnected)
            return
        }
        if self.state == .connected {
            completion(nil)
            return
        }
        
        // OK, let's wait.
        
        let uid = UUID().uuidString
        
        let timeoutTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.connectCallbacks[uid] = nil
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
            guard strongSelf.state == .connecting else { return }
            let delay = strongSelf.getBackoffDelay(
                step: strongSelf.reconnectAttempts,
                minDelay: strongSelf.config.minReconnectDelay,
                maxDelay: strongSelf.config.maxReconnectDelay
            )
            strongSelf.reconnectAttempts += 1
            strongSelf.reconnectTask?.cancel()
            strongSelf.reconnectTask = DispatchWorkItem { [weak self] in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .connecting else { return }
                strongSelf.syncQueue.async { [weak self] in
                    guard let strongSelf = self else { return }
                    guard strongSelf.state == .connecting else { return }
                    strongSelf.debugLog("start reconnecting")
                    strongSelf.conn?.connect()
                }
            }
            strongSelf.debugLog("schedule reconnect in \(delay) seconds")
            strongSelf.syncQueue.asyncAfter(deadline: .now() + delay, execute: strongSelf.reconnectTask!)
        }
    }
    
    private func handlePub(channel: String, pub: Centrifugal_Centrifuge_Protocol_Publication) {
        subscriptionsLock.lock()
        let subs = self.subscriptions.filter({ $0.channel == channel })
        if subs.count == 0 {
            subscriptionsLock.unlock()
            if let _ = self.serverSubs[channel] {
                //                self.delegateQueue.addOperation {
                var info: CentrifugeClientInfo? = nil;
                if pub.hasInfo {
                    info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
                }
                let event = CentrifugeServerPublicationEvent(channel: channel, data: pub.data, offset: pub.offset, tags: pub.tags, info: info)
                self.delegate?.onPublication(self, event)
                if self.serverSubs[channel]?.recoverable == true && pub.offset > 0 {
                    self.serverSubs[channel]?.offset = pub.offset
                }
                //                }
            }
            return
        }
        let sub = subs[0]
        subscriptionsLock.unlock()
        var info: CentrifugeClientInfo? = nil;
        if pub.hasInfo {
            info = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
        }
        let event = CentrifugePublicationEvent(data: pub.data, offset: pub.offset, tags: pub.tags, info: info)
        if pub.offset > 0 {
            sub.setOffset(offset: pub.offset)
        }
        sub.delegate?.onPublication(sub, event)
    }
    
    private func handleJoin(channel: String, join: Centrifugal_Centrifuge_Protocol_Join) {
        subscriptionsLock.lock()
        let subs = self.subscriptions.filter({ $0.channel == channel })
        if subs.count == 0 {
            subscriptionsLock.unlock()
            if let _ = self.serverSubs[channel] {
                let event = CentrifugeServerJoinEvent(channel: channel, client: join.info.client, user: join.info.user, connInfo: join.info.connInfo, chanInfo: join.info.chanInfo)
                self.delegate?.onJoin(self, event)
            }
            return
        }
        let sub = subs[0]
        subscriptionsLock.unlock()
        sub.delegate?.onJoin(sub, CentrifugeJoinEvent(client: join.info.client, user: join.info.user, connInfo: join.info.connInfo, chanInfo: join.info.chanInfo))
    }
    
    private func handleLeave(channel: String, leave: Centrifugal_Centrifuge_Protocol_Leave) {
        subscriptionsLock.lock()
        let subs = self.subscriptions.filter({ $0.channel == channel })
        if subs.count == 0 {
            subscriptionsLock.unlock()
            if let _ = self.serverSubs[channel] {
                let event = CentrifugeServerLeaveEvent(channel: channel, client: leave.info.client, user: leave.info.user, connInfo: leave.info.connInfo, chanInfo: leave.info.chanInfo)
                self.delegate?.onLeave(self, event)
            }
            return
        }
        let sub = subs[0]
        subscriptionsLock.unlock()
        sub.delegate?.onLeave(sub, CentrifugeLeaveEvent(client: leave.info.client, user: leave.info.user, connInfo: leave.info.connInfo, chanInfo: leave.info.chanInfo))
    }
    
    private func handleUnsubscribe(channel: String, unsubscribe: Centrifugal_Centrifuge_Protocol_Unsubscribe) {
        subscriptionsLock.lock()
        let subs = self.subscriptions.filter({ $0.channel == channel })
        if subs.count == 0 {
            subscriptionsLock.unlock()
            if let _ = self.serverSubs[channel] {
                let event = CentrifugeServerUnsubscribedEvent(channel: channel)
                self.delegate?.onUnsubscribed(self, event)
                self.serverSubs.removeValue(forKey: channel)
            }
            return
        }
        let sub = subs[0]
        subscriptionsLock.unlock()
        
        if (unsubscribe.code < 2500) {
            sub.processUnsubscribe(sendUnsubscribe: false, code: unsubscribe.code, reason: unsubscribe.reason)
        } else {
            sub.moveToSubscribingUponDisconnect(code: unsubscribe.code, reason: unsubscribe.reason)
            sub.resubscribeIfNecessary()
        }
    }
    
    private func handleSubscribe(channel: String, sub: Centrifugal_Centrifuge_Protocol_Subscribe) {
        self.serverSubs[channel] = ServerSubscription(recoverable: sub.recoverable, offset: sub.offset, epoch: sub.epoch)
        let event = CentrifugeServerSubscribedEvent(channel: channel, wasRecovering: false, recovered: false, positioned: sub.positioned, recoverable: sub.recoverable, streamPosition: sub.positioned || sub.recoverable ? StreamPosition(offset: sub.offset, epoch: sub.epoch): nil, data: sub.data)
        self.delegate?.onSubscribed(self, event)
    }
    
    private func handleMessage(message: Centrifugal_Centrifuge_Protocol_Message) {
        self.delegate?.onMessage(self, CentrifugeMessageEvent(data: message.data))
    }
    
    private func handleDisconnect(disconnect: Centrifugal_Centrifuge_Protocol_Disconnect) {
        let code = disconnect.code
        let reconnect = code < 3500 || code >= 5000 || (code >= 4000 && code < 4500)
        self.processDisconnect(code: code, reason: disconnect.reason, reconnect: reconnect)
    }
    
    private func handlePing() {
        guard self.state == .connected else { return }
        self.stopWaitPing()
        self.startWaitPing()
        if self.sendPong {
            try? self.sendCommandAsync(command: Centrifugal_Centrifuge_Protocol_Command())
        }
    }
    
    private func handlePush(push: Centrifugal_Centrifuge_Protocol_Push) {
        let channel = push.channel
        if push.hasPub {
            let pub = push.pub
            self.handlePub(channel: channel, pub: pub)
        } else if push.hasJoin {
            let join = push.join
            self.handleJoin(channel: channel, join: join)
        } else if push.hasLeave {
            let leave = push.leave
            self.handleLeave(channel: channel, leave: leave)
        } else if push.hasUnsubscribe {
            let unsubscribe = push.unsubscribe
            self.handleUnsubscribe(channel: channel, unsubscribe: unsubscribe)
        } else if push.hasSubscribe {
            let sub = push.subscribe
            self.handleSubscribe(channel: channel, sub: sub)
        } else if push.hasMessage {
            let message = push.message
            self.handleMessage(message: message)
        } else if push.hasDisconnect {
            let disconnect = push.disconnect
            self.handleDisconnect(disconnect: disconnect)
        }
    }
    
    private func handleData(data: Data) {
        guard let replies = try? CentrifugeSerializer.deserializeCommands(data: data) else { return }
        for reply in replies {
            if reply.id > 0 {
                self.opCallbacks[reply.id]?(CentrifugeResolveData(error: nil, reply: reply))
            } else {
                if !reply.hasPush {
                    self.handlePing()
                } else {
                    self.handlePush(push: reply.push)
                }
            }
        }
    }
    
    private func startWaitPing() {
        if self.pingInterval == 0 {
            return
        }
        self.pingTimer = DispatchSource.makeTimerSource()
        self.pingTimer?.setEventHandler { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.state == .connected else { return }
            strongSelf.processDisconnect(code: connectingCodeNoPing, reason: "no ping", reconnect: true)
        }
        self.pingTimer?.schedule(deadline: .now() + Double(self.pingInterval) + self.config.maxServerPingDelay)
        self.pingTimer?.resume()
    }
    
    private func stopWaitPing() {
        self.pingTimer?.cancel()
    }
    
    private func startConnectionRefresh(ttl: UInt32) {
        let refreshTask = DispatchWorkItem { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.config.tokenGetter != nil else { return }
            strongSelf.config.tokenGetter!.getConnectionToken(CentrifugeConnectionTokenEvent()) { [weak self] result in
                guard let strongSelf = self else { return }
                guard strongSelf.state == .connected else { return }
                switch result {
                case .success(let token):
                    if token == "" {
                        strongSelf.failUnauthorized();
                        return
                    }
                    strongSelf.refreshWithToken(token: token)
                case .failure(let error):
                    guard let strongSelf = self else { return }
                    strongSelf.delegate?.onError(
                        strongSelf,
                        CentrifugeErrorEvent(error: CentrifugeError.tokenError(error: error))
                    )
                    break
                }
            }
        }
        
        self.syncQueue.asyncAfter(deadline: .now() + Double(ttl), execute: refreshTask)
        self.refreshTask = refreshTask
    }
    
    private func stopConnectionRefresh() {
        self.refreshTask?.cancel()
    }
    
    private func stopReconnect() {
        self.reconnectTask?.cancel()
    }
    
    // Caller must synchronize access.
    private func processDisconnect(code: UInt32, reason: String, reconnect: Bool) {
        if (self.state == .disconnected) {
            return
        }
        
        let previousStatus = self.state
        
        if reconnect {
            self.state = .connecting
        } else {
            self.state = .disconnected
        }
        
        self.client = nil
        
        for resolveFunc in self.opCallbacks.values {
            resolveFunc(CentrifugeResolveData(error: CentrifugeError.clientDisconnected, reply: nil))
        }
        self.opCallbacks.removeAll(keepingCapacity: false)
        
        for resolveFunc in self.connectCallbacks.values {
            resolveFunc(CentrifugeError.clientDisconnected)
        }
        self.connectCallbacks.removeAll(keepingCapacity: false)
        
        self.stopReconnect()
        self.stopWaitPing()
        self.stopConnectionRefresh()
        
        subscriptionsLock.lock()
        for sub in self.subscriptions {
            sub.moveToSubscribingUponDisconnect(code: subscribingCodeTransportClosed, reason: "transport closed")
        }
        subscriptionsLock.unlock()
        
        if previousStatus == .connected  {
            for (channel, _) in self.serverSubs {
                let event = CentrifugeServerSubscribingEvent(channel: channel)
                self.delegate?.onSubscribing(self, event)
            }
        }
        
        if (self.state == .disconnected) {
            self.delegate?.onDisconnected(
                self,
                CentrifugeDisconnectedEvent(code: code, reason: reason)
            )
        } else {
            self.delegate?.onConnecting(
                self,
                CentrifugeConnectingEvent(code: code, reason: reason)
            )
        }
        
        self.conn?.disconnect()
    }
    
    private func sendConnect(completion: @escaping (Centrifugal_Centrifuge_Protocol_ConnectResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_ConnectRequest()
        if self.token != nil {
            req.token = self.token!
        }
        if self.data != nil {
            req.data = self.data!
        }
        req.name = self.config.name
        req.version = self.config.version
        if !self.serverSubs.isEmpty {
            var subs = [String: Centrifugal_Centrifuge_Protocol_SubscribeRequest]()
            for (channel, serverSub) in self.serverSubs {
                var subRequest = Centrifugal_Centrifuge_Protocol_SubscribeRequest();
                subRequest.recover = serverSub.recoverable
                subRequest.offset = serverSub.offset
                subRequest.epoch = serverSub.epoch
                subs[channel] = subRequest
            }
            req.subs = subs
        }
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.connect = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.connect, nil)
            }
        })
    }
    
    private func sendRefresh(token: String, completion: @escaping (Centrifugal_Centrifuge_Protocol_RefreshResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_RefreshRequest()
        req.token = token
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.refresh = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.refresh, nil)
            }
        })
    }
    
    private func sendUnsubscribe(channel: String, completion: @escaping (Centrifugal_Centrifuge_Protocol_UnsubscribeResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_UnsubscribeRequest()
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.unsubscribe = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.unsubscribe, nil)
            }
        })
    }
    
    private func sendSubscribe(channel: String, token: String, data: Data?, recover: Bool, streamPosition: StreamPosition, positioned: Bool, recoverable: Bool, completion: @escaping (Centrifugal_Centrifuge_Protocol_SubscribeResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_SubscribeRequest()
        req.channel = channel
        if recover {
            req.recover = true
            req.epoch = streamPosition.epoch
            req.offset = streamPosition.offset
        }
        req.positioned = positioned
        req.recoverable = recoverable
        if data != nil {
            req.data = data!
        }
        if token != "" {
            req.token = token
        }
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.subscribe = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.subscribe, nil)
            }
        })
    }
    
    private func sendPublish(channel: String, data: Data, completion: @escaping (Centrifugal_Centrifuge_Protocol_PublishResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_PublishRequest()
        req.channel = channel
        req.data = data
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.publish = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                completion(rep.publish, nil)
            }
        })
    }
    
    private func sendHistory(channel: String, limit: Int32 = 0, since: CentrifugeStreamPosition?, reverse: Bool = false, completion: @escaping (Result<CentrifugeHistoryResult, Error>)->()) {
        var req = Centrifugal_Centrifuge_Protocol_HistoryRequest()
        req.channel = channel
        req.limit = limit
        req.reverse = reverse
        if since != nil {
            var sp = Centrifugal_Centrifuge_Protocol_StreamPosition()
            sp.offset = since!.offset
            sp.epoch = since!.epoch
            req.since = sp
        }
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.history = req
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(.failure(err))
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(.failure(CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary)))
                    return
                }
                let result = rep.history
                var pubs = [CentrifugePublication]()
                for pub in result.publications {
                    var clientInfo: CentrifugeClientInfo?
                    if pub.hasInfo {
                        clientInfo = CentrifugeClientInfo(client: pub.info.client, user: pub.info.user, connInfo: pub.info.connInfo, chanInfo: pub.info.chanInfo)
                    }
                    pubs.append(CentrifugePublication(offset: pub.offset, data: pub.data, clientInfo: clientInfo))
                }
                completion(.success(CentrifugeHistoryResult(publications: pubs, offset: result.offset, epoch: result.epoch)))
            }
        })
    }
    
    private func sendPresence(channel: String, completion: @escaping (Result<CentrifugePresenceResult, Error>)->()) {
        var req = Centrifugal_Centrifuge_Protocol_PresenceRequest()
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.presence = req
        
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(.failure(err))
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(.failure(CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary)))
                    return
                }
                let result = rep.presence
                var presence = [String: CentrifugeClientInfo]()
                for (client, info) in result.presence {
                    presence[client] = CentrifugeClientInfo(client: info.client, user: info.user, connInfo: info.connInfo, chanInfo: info.chanInfo)
                }
                completion(.success(CentrifugePresenceResult(presence: presence)))
            }
        })
    }
    
    private func sendPresenceStats(channel: String, completion: @escaping (Result<CentrifugePresenceStatsResult, Error>)->()) {
        var req = Centrifugal_Centrifuge_Protocol_PresenceStatsRequest()
        req.channel = channel
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.presenceStats = req
        
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(.failure(err))
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(.failure(CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary)))
                    return
                }
                let result = rep.presenceStats
                let stats = CentrifugePresenceStatsResult(numClients: result.numClients, numUsers: result.numUsers)
                completion(.success(stats))
            }
        })
    }
    
    private func sendRPC(method: String, data: Data, completion: @escaping (Centrifugal_Centrifuge_Protocol_RPCResult?, Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_RPCRequest()
        req.data = data
        req.method = method
        
        var command = Centrifugal_Centrifuge_Protocol_Command()
        command.id = self.nextCommandId()
        command.rpc = req
        
        self.sendCommand(command: command, completion: { [weak self] reply, error in
            guard self != nil else { return }
            if let err = error {
                completion(nil, err)
                return
            }
            if let rep = reply {
                if rep.hasError {
                    completion(nil, CentrifugeError.replyError(code: rep.error.code, message: rep.error.message, temporary: rep.error.temporary))
                    return
                }
                let result = rep.rpc
                completion(result, nil)
            }
        })
    }
    
    private func sendSend(data: Data, completion: @escaping (Error?)->()) {
        var req = Centrifugal_Centrifuge_Protocol_SendRequest()
        req.data = data
        do {
            var command = Centrifugal_Centrifuge_Protocol_Command()
            command.send = req
            try self.sendCommandAsync(command: command)
            completion(nil)
        } catch {
            completion(error)
        }
    }
    
    private func failUnauthorized() -> Void {
        self.processDisconnect(code: disconnectedCodeUnauthorized, reason: "unauthorized", reconnect: false)
    }
}
