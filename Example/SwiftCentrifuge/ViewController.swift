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
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let config = CentrifugeClientConfig(
            token: "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0c3VpdGVfand0In0.hPmHsVqvtY88PvK4EmJlcdwNuKFuy3BGaF7dMaKdPlw"
        )
        let url = "ws://127.0.0.1:8000/connection/websocket?cf_protocol=protobuf"
        self.client = CentrifugeClient(url: url, config: config, delegate: self)
        do {
            sub = try self.client?.newSubscription(channel: "chat:index", delegate: self)
            sub!.subscribe()
        } catch {
            print("Can not create subscription: \(error)")
            return
        }
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
        let state = self.client?.getState();
        if state == .connecting || state == .connected {
            self.client?.disconnect()
            DispatchQueue.main.async { [weak self] in
                self?.connectionStatus.text = "Disconnected"
                self?.connectButton.setTitle("Connect", for: .normal)
            }
        } else {
            self.client?.connect()
            DispatchQueue.main.async { [weak self] in
                self?.connectionStatus.text = "Connecting"
                self?.connectButton.setTitle("Disconnect", for: .normal)
            }
        }
    }
}

extension ViewController: CentrifugeClientDelegate {
    func onConnect(_ c: CentrifugeClient, _ e: CentrifugeConnectEvent) {
        print("connected with id", e.client)
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus.text = "Connected"
            self?.connectButton.setTitle("Disconnect", for: .normal)
        }
    }

    func onDisconnect(_ c: CentrifugeClient, _ e: CentrifugeDisconnectEvent) {
        print("disconnected", e.code, e.reason, "reconnect", e.reconnect)
        DispatchQueue.main.async { [weak self] in
            if e.reconnect {
                self?.connectionStatus.text = "Connecting"
                self?.connectButton.setTitle("Disconnect", for: .normal)
            } else {
                self?.connectionStatus.text = "Disconnected"
                self?.connectButton.setTitle("Connect", for: .normal)
            }
        }
    }
    
    func onFail(_ c: CentrifugeClient, _ e: CentrifugeFailEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus.text = "Failed"
            self?.connectButton.setTitle("Connect", for: .normal)
        }
    }

    func onSubscribe(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribeEvent) {
        print("server-side subscribe to", event.channel, "recovered", event.recovered)
    }

    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {
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
    
    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        print("client error \(event.error)")
    }
}

extension ViewController: CentrifugeSubscriptionDelegate {
    func onPublication(_ s: CentrifugeSubscription, _ e: CentrifugePublicationEvent) {
        let data = String(data: e.data, encoding: .utf8) ?? ""
        print("message from channel", s.channel, data)
        DispatchQueue.main.async { [weak self] in
            self?.lastMessage.text = data
        }
    }

    func onSubscribe(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeEvent) {
        print("successfully subscribed to channel \(s.channel)")
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
    
    func onError(_ s: CentrifugeSubscription, _ e: CentrifugeSubscriptionErrorEvent) {
        print("subscription error: \(e.error)")
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
