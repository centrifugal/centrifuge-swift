//
//  URLSessionConfiguration+proxy.swift
//  SwiftCentrifuge_Example
//
//  Created by Andrey Pochtarev on 07.12.2024.
//  Copyright © 2024 CocoaPods. All rights reserved.
//

import Foundation
import Network

extension URLSessionConfiguration {
    func set(socksProxy: ProxyParams) {
        if #available(iOS 17.0, *) {
           let endpoint: NWEndpoint = .hostPort(
               host: .init(socksProxy.host),
               port: .init(integerLiteral: socksProxy.port)
           )
           self.proxyConfigurations =  self.proxyConfigurations + [.init(socksv5Proxy: endpoint)]
        } else {
            self.connectionProxyDictionary = self.connectionProxyDictionary ?? [:]
            let host = socksProxy.host
            let port = socksProxy.port
            [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port,
                kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
            ].forEach {
                self.connectionProxyDictionary?[$0.key] = $0.value
            }
        }
    }
}

extension URLSessionConfiguration {
    struct ProxyParams: Equatable, Codable {
        let host: String
        let port: UInt16

        init?(host: String, port: UInt16) {
            guard IPv4Address(host) != nil else { return nil }
            self.host = host
            self.port = port
        }

        var jsonData: Data? { try? JSONEncoder().encode(self) }

        static func create(from data: Data) -> URLSessionConfiguration.ProxyParams? {
            try? JSONDecoder().decode(URLSessionConfiguration.ProxyParams.self, from: data)
        }
    }
}
