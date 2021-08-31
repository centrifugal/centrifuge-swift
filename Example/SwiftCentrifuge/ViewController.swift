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
    
    @IBOutlet weak var connectionStatus: UILabel!
    @IBOutlet weak var lastMessage: UILabel!
    @IBOutlet weak var newMessage: UITextField!
    @IBOutlet weak var connectButton: UIButton!
    
    private var client: CentrifugeClient?
    private var sub: CentrifugeSubscription?
    private var isConnected: Bool = false
    private var subscriptionCreated: Bool = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let config = CentrifugeClientConfig()
        let url = "ws://127.0.0.1:8000/connection/websocket?format=protobuf"
        self.client = CentrifugeClient(url: url, config: config, delegate: self)
        let token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0c3VpdGVfand0In0.hPmHsVqvtY88PvK4EmJlcdwNuKFuy3BGaF7dMaKdPlw"
        self.client?.setToken(token)
    }
    
    @IBAction func send(_ sender: Any) {
        let data = ["input": self.newMessage.text ?? ""]
        self.newMessage.text = ""
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) else {return}
        sub?.publish(data: jsonData, completion: { _, error in
            if let err = error {
                print("Unexpected publish error: \(err)")
            }
        })
    }
    
    @IBAction func connect(_ sender: Any) {
        if self.isConnected {
            self.client?.disconnect()
        } else {
            self.client?.connect()
            if !self.subscriptionCreated {
                // Only subscribe once, after this client will internally keep all subscriptions
                // so we don't need to subscribe again.
                self.createSubscription()
                self.subscriptionCreated = true
            }
        }
    }
    
    private func createSubscription() {
        do {
            sub = try self.client?.newSubscription(channel: "chat:index", delegate: self)
        } catch {
            print("Can not create subscription: \(error)")
            return
        }
        sub?.subscribe()
    }
}

extension ViewController: CentrifugeClientDelegate {
    func onConnect(_ c: CentrifugeClient, _ e: CentrifugeConnectEvent) {
        self.isConnected = true
        print("connected with id", e.client)
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus.text = "Connected"
            self?.connectButton.setTitle("Disconnect", for: .normal)
        }
    }
    
    func onDisconnect(_ c: CentrifugeClient, _ e: CentrifugeDisconnectEvent) {
        self.isConnected = false
        print("disconnected", e.reason, "reconnect", e.reconnect)
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus.text = "Disconnected"
            self?.connectButton.setTitle("Connect", for: .normal)
        }
    }

    func onSubscribe(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribeEvent) {
        print("server-side subscribe to", event.channel, "recovered", event.recovered, "resubscribe", event.resubscribe)
    }

    func onPublish(_ client: CentrifugeClient, _ event: CentrifugeServerPublishEvent) {
        print("server-side publication from", event.channel, "offset", event.offset)
    }

    func onUnsubscribe(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribeEvent) {
        print("server-side unsubscribe from", event.channel)
    }

    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent) {
        print("server-side join in", event.channel, "client", event.client)
    }

    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent) {
        print("server-side leave in", event.channel, "client", event.client)
    }
}

extension ViewController: CentrifugeSubscriptionDelegate {
    func onPublish(_ s: CentrifugeSubscription, _ e: CentrifugePublishEvent) {
        let data = String(data: e.data, encoding: .utf8) ?? ""
        print("message from channel", s.channel, data)
        DispatchQueue.main.async { [weak self] in
            self?.lastMessage.text = data
        }
    }
    
    func onSubscribeSuccess(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeSuccessEvent) {
        s.presence(completion: { result, error in
            if let err = error {
                print("Unexpected presence error: \(err)")
            } else if let presence = result {
                print(presence)
            }
        })
        s.history(limit: 10, completion: { result, error in
            if let err = error {
                print("Unexpected history error: \(err)")
            } else if let res = result {
                print("Num publications returned: \(res.publications.count)")
            }
        })
        print("successfully subscribed to channel \(s.channel)")
    }
    
    func onSubscribeError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeErrorEvent) {
        print("failed to subscribe to channel", e.code, e.message)
    }
    
    func onUnsubscribe(_ s: CentrifugeSubscription, _ e: CentrifugeUnsubscribeEvent) {
        print("unsubscribed from channel", s.channel)
    }
    
    func onJoin(_ s: CentrifugeSubscription, _ e: CentrifugeJoinEvent) {
        print("client joined channel \(s.channel), user ID \(e.user)")
    }
    
    func onLeave(_ s: CentrifugeSubscription, _ e: CentrifugeLeaveEvent) {
        print("client left channel \(s.channel), user ID \(e.user)")
    }
}
