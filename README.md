# SwiftCentrifuge

SwiftCentrifuge is a Websocket client for Centrifugo and Centrifuge library. This client uses Protobuf protocol for client-server communication.

SwiftCentrifuge runs all operations in its own queues and provides necessary callbacks so you don't need to worry about managing concurrency yourself.

## Status of library

This library is feature rich and supports almost all available Centrifuge/Centrifugo features (see matrix below). But it's very young and not tested in production application yet. Any help and feedback is very appreciated to make it production ready and update library status. Any report will give us an understanding that the library works, is useful and we should continue developing it. Please share your stories.

## Installation

There are several convenient ways.

### CocoaPods

To integrate SwiftCentrifuge into your Xcode project using CocoaPods, specify it in your `Podfile`:

```ruby
pod 'SwiftCentrifuge'
```

### Carthage

Add the line `github "centrifugal/centrifuge-swift"` to your `Cartfile`. Then run `carthage update`.

### Manual

Clone the repo and drag files from `Sources` folder into your Xcode project.

## Dependencies

This library depends on two libraries:

- [SwiftProtobuf](https://github.com/apple/swift-protobuf)
- [Starscream](https://github.com/daltoniam/Starscream)

## Requirements

- iOS 9.0
- Xcode 10.0

## Getting Started

An [example app](Demo) is included demonstrating basic client functionality.

### Basic usage

Connect to server based on Centrifuge library:

```swift
import SwiftCentrifuge

class ClientDelegate : NSObject, CentrifugeClientDelegate {
    func onConnect(_ client: CentrifugeClient, _ e: CentrifugeConnectEvent) {
        print("connected with id", e.client)
    }
    func onDisconnect(_ client: CentrifugeClient, _ e: CentrifugeDisconnectEvent) {
        print("disconnected", e.reason, "reconnect", e.reconnect)
    }
}

let config = CentrifugeClientConfig()
let url = "ws://127.0.0.1:8000/connection/websocket?format=protobuf"
let client = CentrifugeClient(url: url, config: config, delegate: ClientDelegate())
client.connect()
```

Note that *you must use* `?format=protobuf` in connection URL as this client communicates with Centrifugo/Centrifuge over Protobuf protocol.

To connect to Centrifugo you need to additionally set connection JWT:

```swift
...
let client = CentrifugeClient(url: url, config: config, delegate: ClientDelegate())
client.setToken("YOUR CONNECTION JWT")
client.connect()
```

Now let's look at how to subscribe to channel and listen to messages published into it:

```swift
import SwiftCentrifuge

class ClientDelegate : NSObject, CentrifugeClientDelegate {
    func onConnect(_ client: CentrifugeClient, _ e: CentrifugeConnectEvent) {
        print("connected with id", e.client)
    }
    func onDisconnect(_ client: CentrifugeClient, _ e: CentrifugeDisconnectEvent) {
        print("disconnected", e.reason, "reconnect", e.reconnect)
    }
}

class SubscriptionDelegate : NSObject, CentrifugeClientDelegate {
    func onPublish(_ s: CentrifugeSubscription, _ e: CentrifugePublishEvent) {
        let data = String(data: e.data, encoding: .utf8) ?? ""
        print("message from channel", s.channel, data)
    }
}

let config = CentrifugeClientConfig()
let url = "ws://127.0.0.1:8000/connection/websocket?format=protobuf"
let client = CentrifugeClient(url: url, config: config, delegate: ClientDelegate())
client.connect()

do {
    let sub = try client.newSubscription(channel: "example", delegate: SubscriptionDelegate())
    sub.subscribe()
} catch {
    print("Can not create subscription: \(error)")
}
```

## Feature matrix

- [ ] connect to server using JSON protocol format
- [x] connect to server using Protobuf protocol format
- [x] connect with JWT
- [x] connect with custom header
- [x] support automatic reconnect in case of errors, network problems etc
- [x] connect and disconnect events
- [x] handle disconnect reason
- [x] subscribe on channel and handle asynchronous Publications
- [x] handle Join and Leave messages
- [x] handle Unsubscribe notifications
- [x] handle subscribe error
- [x] support publish, unsubscribe, presence, presence stats and history methods
- [x] send asynchronous messages to server
- [x] handle asynchronous messages from server
- [x] send RPC commands
- [x] subscribe to private channels with JWT
- [x] support connection JWT refresh
- [ ] support private channel subscription JWT refresh
- [x] ping/pong to find broken connection
- [ ] support message recovery mechanism

## License

SwiftCentrifuge is available under the MIT license. See LICENSE for details.
