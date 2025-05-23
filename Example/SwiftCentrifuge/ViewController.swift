//
//  ViewController.swift
//  CentrifugePlayground
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import UIKit
import SwiftCentrifuge

class ViewController: UIViewController {
    
    @IBOutlet weak var clientState: UILabel!
    @IBOutlet weak var lastMessage: UILabel!
    @IBOutlet weak var newMessage: UITextField!
    @IBOutlet weak var connectButton: UIButton!
    @IBOutlet weak var resetReconnectStateButton: UIButton!
    @IBOutlet weak var configureProxyButton: UIButton!

    private var client: CentrifugeClient?
    private var sub: CentrifugeSubscription?
    
    // Note, this token is only for example purposes, in reality it should be issued by your backend!!
    // This token is built using "secret" as HMAC secret key.
    private let jwtToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzd2lmdCIsImlhdCI6MTc0Nzk3MzA5M30.mH5xZ2kesDg1xJgqkOEsdOZExNIo35crjTfgYPgBAgs"
    
    // Note, this sub token is only for example purposes, in reality it should be issued by your backend!!
    // This token is built using "secret" as HMAC secret key.
    private let subToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzd2lmdCIsImlhdCI6MTc0Nzk3MzEyOSwiY2hhbm5lbCI6ImluZGV4In0.m33zSZn45UmvbMWIB_G_Kn4RfU5pPCEVifJc8WqA3Q8"
    
    private let endpoint = "ws://127.0.0.1:8000/connection/websocket?cf_protocol=protobuf"
    private var proxySetting: ProxySetting = .off {
        didSet {
            guard oldValue != proxySetting else { return }
            reconnect(with: proxySetting)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        resetReconnectStateButton.isHidden = true

        NotificationCenter.default.addObserver(self, selector: #selector(self.disconnectClient(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.connectClient(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)

        let config = centrifugeClientConfig(with: proxySetting)
        self.client = CentrifugeClient(endpoint: endpoint, config: config, delegate: self)
        do {
            sub = try self.client?.newSubscription(
                channel: "index",
                delegate: self,
                config: CentrifugeSubscriptionConfig( // Example of using Subscription config.
//                    delta: .fossil,
                    token: subToken,
                    tokenGetter: {[weak self] event, completion in
                        guard let strongSelf = self else { return }
                        completion(.success(strongSelf.subToken))
                    }
                )
            )
            sub!.subscribe()
        } catch {
            print("Can not create subscription: \(error)")
            return
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        client?.connect()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
    }
    
    @objc func disconnectClient(_ notification: Notification) {
        client?.disconnect()
    }
    
    @objc func connectClient(_ notification: Notification) {
        client?.connect()
    }

    @IBAction func send(_ sender: Any) {
        let data = ["input": self.newMessage.text ?? ""]
        self.newMessage.text = ""
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) else {return}
        sub?.publish(data: jsonData, completion: { result in
            switch result {
            case .success(_):
                break
            case .failure(let err):
                print("Unexpected publish error: \(err)")
            }
        })
    }

    @IBAction func connect(_ sender: Any) {
        let state = self.client?.state;
        if state == .connecting || state == .connected {
            self.client?.disconnect()
            DispatchQueue.main.async { [weak self] in
                self?.clientState.text = "Disconnected"
                self?.connectButton.setTitle("Connect", for: .normal)
            }
        } else {
            self.client?.connect()
            DispatchQueue.main.async { [weak self] in
                self?.clientState.text = "Connecting"
                self?.connectButton.setTitle("Disconnect", for: .normal)
            }
        }
    }

    @IBAction func resetReconnectState(_ sender: Any) {
        self.client?.resetReconnectState()
    }

    @IBAction func configureProxy(_ sender: Any) {
        let proxyVC = ProxySettingsViewController(isProxyEnabled: proxySetting != .off)
        let navigationController = UINavigationController(rootViewController: proxyVC)

        proxyVC.onSave = { [weak self] proxySetting in
            guard let self = self else { return }
            self.proxySetting = proxySetting
        }
        present(navigationController, animated: true, completion: nil)
    }

    func updateProxyButtonTitleWith(isProxyOn: Bool) {
        configureProxyButton.setTitle(
            "Proxy: \(isProxyOn ? "ON" : "OFF")",
            for: .normal
        )
        configureProxyButton.setTitleColor(isProxyOn ? .systemGreen : .systemRed, for: .normal)
        configureProxyButton.titleLabel?.font = .systemFont(ofSize: 16, weight: isProxyOn ? .bold : .light)
    }

}

extension ViewController: CentrifugeClientDelegate {
    func onConnected(_ c: CentrifugeClient, _ e: CentrifugeConnectedEvent) {
        print("connected with id", e.client)
        DispatchQueue.main.async { [weak self] in
            self?.clientState.text = "Connected"
            self?.connectButton.setTitle("Disconnect", for: .normal)
            self?.resetReconnectStateButton.isHidden = true
        }
    }
    
    func onDisconnected(_ c: CentrifugeClient, _ e: CentrifugeDisconnectedEvent) {
        print("disconnected with code", e.code, "and reason", e.reason)
        DispatchQueue.main.async { [weak self] in
            self?.clientState.text = "Disconnected"
            self?.connectButton.setTitle("Connect", for: .normal)
            self?.resetReconnectStateButton.isHidden = true
        }
    }
    
    func onConnecting(_ c: CentrifugeClient, _ e: CentrifugeConnectingEvent) {
        print("connecting with code", e.code, "and reason", e.reason)
        DispatchQueue.main.async { [weak self] in
            self?.clientState.text = "Connecting"
            self?.connectButton.setTitle("Disconnect", for: .normal)
            self?.resetReconnectStateButton.isHidden = false
        }
    }

    func onSubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribedEvent) {
        print("server-side subscribe to", event.channel, "recovered", event.recovered)
    }

    func onSubscribing(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribingEvent) {
        print("server-side subscribing to", event.channel)
    }
    
    func onUnsubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribedEvent) {
        print("server-side unsubscribe from", event.channel)
    }

    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {
        print("server-side publication from", event.channel, "offset", event.offset)
    }
    
    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent) {
        print("server-side join in", event.channel, "client", event.client)
    }

    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent) {
        print("server-side leave in", event.channel, "client", event.client)
    }
    
    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        print("client error \(event.error)")
    }
}

extension ViewController: CentrifugeSubscriptionDelegate {
    func onSubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribedEvent) {
        print("successfully subscribed to channel \(s.channel), was recovering \(e.wasRecovering), recovered \(e.recovered)")
        s.presence(completion: { result in
            switch result {
            case .success(let presence):
                print(presence)
            case .failure(let err):
                print("Unexpected presence error: \(err)")
            }
        })
        s.history(limit: 10, completion: { result in
            switch result {
            case .success(let res):
                print("Num publications returned: \(res.publications.count)")
            case .failure(let err):
                print("Unexpected history error: \(err)")
            }
        })
    }

    func onSubscribing(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribingEvent) {
        print("subscribing to channel", s.channel, e.code, e.reason)
    }
    
    func onUnsubscribed(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribedEvent) {
        print("unsubscribed from channel", s.channel, e.code, e.reason)
    }
    
    func onError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscriptionErrorEvent) {
        print("subscription error: \(e.error)")
    }
    
    func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) {
        let data = String(data: e.data, encoding: .utf8) ?? ""
        print("message from channel", s.channel, data)
        DispatchQueue.main.async { [weak self] in
            self?.lastMessage.text = data
        }
    }
    
    func onJoin(_ s: CentrifugeSubscription, _ e: CentrifugeJoinEvent) {
        print("client joined channel \(s.channel), user ID \(e.user)")
    }
    
    func onLeave(_ s: CentrifugeSubscription, _ e: CentrifugeLeaveEvent) {
        print("client left channel \(s.channel), user ID \(e.user)")
    }
}

extension ViewController {
    enum ProxySetting: Equatable {
        case on(URLSessionConfiguration.ProxyParams)
        case off
    }

    func centrifugeClientConfig(with proxySetting: ProxySetting) -> CentrifugeClientConfig {
        updateProxyButtonTitleWith(isProxyOn: proxySetting != .off)
        let config: CentrifugeClientConfig

        switch proxySetting {
        case let .on(params):
            let provider: URLSessionConfigurationProvider = {
                let configuration = URLSessionConfiguration.default
                configuration.set(socksProxy: params)
                return configuration
            }
            config = .init(
                token: jwtToken,
                useNativeWebSocket: true,
                urlSessionConfigurationProvider: provider,
                tokenGetter: {[weak self] event, completion in
                    guard let strongSelf = self else { return }
                    completion(.success(strongSelf.jwtToken))
                },
                logger: PrintLogger()
            )
        case .off:
            config = .init(
                token: jwtToken,
                tokenGetter: {[weak self] event, completion in
                    guard let strongSelf = self else { return }
                    completion(.success(strongSelf.jwtToken))
                },
                logger: PrintLogger()
            )
        }
        return config
    }

    func reconnect(with proxySetting: ProxySetting) {
        self.client?.disconnect()
        self.client = nil

        let config = centrifugeClientConfig(with: proxySetting)
        self.client = CentrifugeClient(
            endpoint: endpoint,
            config: config,
            delegate: self
        )
        self.client?.connect()
        do {
            sub = try self.client?.newSubscription(
                channel: "index",
                delegate: self,
                config: CentrifugeSubscriptionConfig(
                    token: subToken
                )
            )
            sub!.subscribe()
        } catch {
            print("Can not create subscription: \(error)")
            return
        }
    }
}
