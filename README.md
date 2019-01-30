# SwiftCentrifuge

SwiftCentrifuge is a Websocket client for Centrifugo and Centrifuge library. This client uses Protobuf protocol for client-server communication.

This library is a work in progress.

### Feature matrix

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
