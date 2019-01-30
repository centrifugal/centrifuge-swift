//
//  ViewController.swift
//  CentrifugePlayground
//
//  Created by Alexander Emelin on 03/01/2019.
//  Copyright © 2019 Alexander Emelin. All rights reserved.
//

import UIKit

class ClientDelegate : NSObject, CentrifugeClientDelegate {
    func onConnect(_ c: CentrifugeClient, _ e: CentrifugeConnectEvent) {
        print("connected with id", e.client)
    }
    
    func onDisconnect(_ c: CentrifugeClient, _ e: CentrifugeDisconnectEvent) {
        print("disconnected", e.reason, "reconnect", e.reconnect)
    }
    
    func onPrivateSub(_ c: CentrifugeClient, _ e: CentrifugePrivateSubEvent, completion: (_ token: String) -> ()) {
        // Replace XXX with real generated JTW based on e.client and e.channel as
        // described in docs: https://centrifugal.github.io/centrifugo/server/private_channels/
        // Note that here you most probably need to ask your backend for this token as
        // only your backend knows Centrifugo secret key to generate JWT and that secret
        // must never be shared with any client.
        completion("XXX")
    }
}

class SubscriptionDelegate: NSObject, CentrifugeSubscriptionDelegate {
    func onPublish(_ s: CentrifugeSubscription, _ e: CentrifugePublishEvent) {
        let data = String(data: e.data, encoding: .utf8) ?? ""
        print("message from channel", s.channel, data)
    }
    
    func onSubscribeSuccess(_ s: CentrifugeSubscription, _ e: CentrifugeSubscribeSuccessEvent) {
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

class ViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let config = CentrifugeClientConfig()
        let url = "ws://127.0.0.1:8000/connection/websocket?format=protobuf"
        let client = CentrifugeClient(url: url, config: config, delegate: ClientDelegate())
        let token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0c3VpdGVfand0In0.hPmHsVqvtY88PvK4EmJlcdwNuKFuy3BGaF7dMaKdPlw"
        client.setToken(token)
        
        let pubData = "{\"input\": \"hello\"}".data(using: .utf8)!
        client.publish(channel: "chat:index", data: pubData, completion: { error in
            if let err = error {
                print("Unexpected client publish error: \(err)")
            }
        })
        
        client.connect()
        
        var sub: CentrifugeSubscription
        do {
            sub = try client.newSubscription(channel: "chat:index", delegate: SubscriptionDelegate())
        } catch {
            print("Can not create subscription: \(error)")
            return
        }
        sub.presence(completion: { result, error in
            if let err = error {
                print("Unexpected presence error: \(err)")
            } else if let presence = result {
                print(presence)
            }
        })
        sub.subscribe()
        
        let oneMorePubData = "{\"input\": \"hello again\"}".data(using: .utf8)!
        sub.publish(data: oneMorePubData, completion: { error in
            if let err = error {
                print("Unexpected publish error: \(err)")
            }
        })
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0, execute: {
            //            sub.unsubscribe()
        })
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0, execute: {
            //            client.disconnect()
        })
        
        // Do any additional setup after loading the view, typically from a nib.
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
}
