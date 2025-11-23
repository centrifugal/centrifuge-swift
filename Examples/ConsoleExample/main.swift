import Foundation
import SwiftCentrifuge

// MARK: - Console Logger

class ConsoleLogger: CentrifugeLogger {
    func log(level: CentrifugeLoggerLevel, message: @autoclosure () -> String, file: StaticString, function: StaticString, line: UInt) {
        print("[\(level)] \(message())")
    }
}

// MARK: - Client Delegate

class ClientDelegate: CentrifugeClientDelegate {
    func onConnected(_ client: CentrifugeClient, _ event: CentrifugeConnectedEvent) {
        print("[Client] Connected!")
        print("  Client ID: \(event.client)")
    }

    func onConnecting(_ client: CentrifugeClient, _ event: CentrifugeConnectingEvent) {
        print("[Client] Connecting: \(event.code) - \(event.reason)")
    }

    func onDisconnected(_ client: CentrifugeClient, _ event: CentrifugeDisconnectedEvent) {
        print("[Client] Disconnected: \(event.code) - \(event.reason)")
    }

    func onError(_ client: CentrifugeClient, _ event: CentrifugeErrorEvent) {
        print("[Client] Error: \(event.error)")
    }

    func onSubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribedEvent) {
        print("[Client] Server-side subscribed to: \(event.channel)")
    }

    func onSubscribing(_ client: CentrifugeClient, _ event: CentrifugeServerSubscribingEvent) {
        print("[Client] Server-side subscribing to: \(event.channel)")
    }

    func onUnsubscribed(_ client: CentrifugeClient, _ event: CentrifugeServerUnsubscribedEvent) {
        print("[Client] Server-side unsubscribed from: \(event.channel)")
    }

    func onPublication(_ client: CentrifugeClient, _ event: CentrifugeServerPublicationEvent) {
        let data = String(data: event.data, encoding: .utf8) ?? "<binary>"
        print("[Client] Server-side publication from \(event.channel): \(data)")
    }

    func onJoin(_ client: CentrifugeClient, _ event: CentrifugeServerJoinEvent) {
        print("[Client] Server-side join in \(event.channel): \(event.client)")
    }

    func onLeave(_ client: CentrifugeClient, _ event: CentrifugeServerLeaveEvent) {
        print("[Client] Server-side leave in \(event.channel): \(event.client)")
    }
}

// MARK: - Subscription Delegate

class SubscriptionDelegate: CentrifugeSubscriptionDelegate {
    func onSubscribed(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribedEvent) {
        print("[Subscription] Subscribed to \(sub.channel)!")
        if event.wasRecovering {
            print("  Recovery attempted, recovered: \(event.recovered)")
        }
    }

    func onSubscribing(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscribingEvent) {
        print("[Subscription] Subscribing to \(sub.channel): \(event.code) - \(event.reason)")
    }

    func onUnsubscribed(_ sub: CentrifugeSubscription, _ event: CentrifugeUnsubscribedEvent) {
        print("[Subscription] Unsubscribed from \(sub.channel): \(event.code) - \(event.reason)")
    }

    func onPublication(_ sub: CentrifugeSubscription, _ event: CentrifugePublicationEvent) {
        let data = String(data: event.data, encoding: .utf8) ?? "<binary>"
        print("[Subscription] Publication received:")
        print("  Channel: \(sub.channel)")
        print("  Data: \(data)")
        if event.offset > 0 {
            print("  Offset: \(event.offset)")
        }
        if let info = event.info {
            print("  From: \(info.client) (user: \(info.user))")
        }
    }

    func onJoin(_ sub: CentrifugeSubscription, _ event: CentrifugeJoinEvent) {
        print("[Subscription] Client joined \(sub.channel): \(event.client)")
    }

    func onLeave(_ sub: CentrifugeSubscription, _ event: CentrifugeLeaveEvent) {
        print("[Subscription] Client left \(sub.channel): \(event.client)")
    }

    func onError(_ sub: CentrifugeSubscription, _ event: CentrifugeSubscriptionErrorEvent) {
        print("[Subscription] Error: \(event.error)")
    }
}

// MARK: - Main

print("SwiftCentrifuge Console Example")
print("===============================\n")

// Configuration
let endpoint = "ws://localhost:8000/connection/websocket"
let channel = "chat"

// Create delegates (must keep strong references)
let clientDelegate = ClientDelegate()
let subscriptionDelegate = SubscriptionDelegate()

// Configure client
let config = CentrifugeClientConfig(
    // token: "your-jwt-token",  // Uncomment and set if auth is required
    logger: ConsoleLogger()
)

// Create client
let client = CentrifugeClient(
    endpoint: endpoint,
    config: config,
    delegate: clientDelegate
)

// Connect to server
print("Connecting to \(endpoint)...")
client.connect()

// Create subscription
var subscription: CentrifugeSubscription?
do {
    subscription = try client.newSubscription(
        channel: channel,
        delegate: subscriptionDelegate
    )
} catch {
    print("Failed to create subscription: \(error)")
    exit(1)
}

// Subscribe to channel
print("Subscribing to channel '\(channel)'...")
subscription?.subscribe()

// Publish a message
print("\nPublishing message...")
let messageData = "{\"text\":\"Hello from Swift SDK!\"}".data(using: .utf8)!
subscription?.publish(data: messageData) { result in
    switch result {
    case .success:
        print("[Subscription] Message published successfully")
    case .failure(let error):
        print("[Subscription] Publish failed: \(error)")
    }
}

// Fetch presence
print("\nFetching presence...")
subscription?.presence { result in
    switch result {
    case .success(let presenceResult):
        print("Clients in channel: \(presenceResult.presence.count)")
        for (clientId, info) in presenceResult.presence {
            print("  - \(clientId): user=\(info.user)")
        }
    case .failure(let error):
        print("Presence not available: \(error)")
    }
}

// Fetch history
print("\nFetching history...")
subscription?.history(limit: 10) { result in
    switch result {
    case .success(let history):
        print("History: \(history.publications.count) messages")
        for pub in history.publications {
            let data = String(data: pub.data, encoding: .utf8) ?? "<binary>"
            print("  - \(data)")
        }
    case .failure(let error):
        print("History not available: \(error)")
    }
}

// RPC example
print("\nSending RPC...")
let rpcData = "{\"method\":\"getCurrentTime\"}".data(using: .utf8)!
client.rpc(method: "time", data: rpcData) { result in
    switch result {
    case .success(let response):
        let data = String(data: response.data, encoding: .utf8) ?? "<binary>"
        print("RPC response: \(data)")
    case .failure(let error):
        print("RPC failed: \(error)")
    }
}

// Keep running and wait for user input
print("\nPress Enter to disconnect...")
_ = readLine()

// Cleanup
print("\nUnsubscribing...")
subscription?.unsubscribe()

print("Disconnecting...")
client.disconnect()

print("\nDone!")
