# SwiftCentrifuge

Websocket client for [Centrifugo](https://github.com/centrifugal/centrifugo) server and [Centrifuge](https://github.com/centrifugal/centrifuge) library. 

There is no v1 release of this library yet – API still evolves. At the moment patch version updates only contain backwards compatible changes, minor version updates can have backwards incompatible API changes.

Check out [client SDK API specification](https://centrifugal.dev/docs/transports/client_api) to learn how this SDK behaves. It's recommended to read that before starting to work with this SDK as the spec covers common SDK behavior - describes client and subscription state transitions, main options and methods. Also check out examples folder.

The features implemented by this SDK can be found in [SDK feature matrix](https://centrifugal.dev/docs/transports/client_sdk#sdk-feature-matrix).

> **The latest `centrifuge-swift` is compatible with [Centrifugo](https://github.com/centrifugal/centrifugo) server v5 and v4 and [Centrifuge](https://github.com/centrifugal/centrifuge) >= 0.25.0. For Centrifugo v2, Centrifugo v3 and Centrifuge < 0.25.0 you should use `centrifuge-swift` v0.4.6.**

## Installation

There are several convenient ways.

### CocoaPods

To integrate SwiftCentrifuge into your Xcode project using CocoaPods, specify it in your `Podfile`:

```ruby
pod 'SwiftCentrifuge'
```

### Swift Package Manager

SwiftCentrifuge is compatible with SPM. If you get a warning complaining about missing pc file, you may need to install `pkg-config`. On macOS, this can be achieved with `brew install pkg-config`.

### Manual

Clone the repo and drag files from `Sources` folder into your Xcode project.

## Dependencies

This library depends on [SwiftProtobuf](https://github.com/apple/swift-protobuf)

## Requirements

- iOS 12.0
- Xcode 13.0

## Getting Started

An [example app](Example) is included demonstrating basic client functionality.

## Usage in background

When a mobile application goes to the background there are OS-specific limitations for established persistent connections - which can be silently closed shortly. Thus in most cases you need to disconnect from a server when app moves to the background and connect again when app goes to the foreground.

## Using URLSessionWebSocketTask

See `useNativeWebSocket` option of Client which allows using `URLSessionWebSocketTask` instead of our fork of Starscream v3. Please report if you have successful setup of `centrifuge-swift` with `URLSessionWebSocketTask` – so we could eventually make it default.

### URLSessionWebSocketTask: configuring Proxy Settings

If you need to manually configure proxy settings for URLSessionWebSocketTask, follow these steps:
1.    Set up a proxy tool:
Configure your preferred proxy tool (e.g., Charles Proxy, Proxyman, or mitmproxy) according to its documentation. Ensure that it is properly set up to intercept traffic from your device.
2.    Verify proxy functionality:
Enable system-wide proxy settings on your device and check that traffic from system calls is captured in your proxy tool.
3.    Disable system proxy:
After verifying that the proxy tool works as expected, disable the system-wide proxy settings on your device.
4.    Configure CentrifugeClient for proxying:
Use the urlSessionConfigurationProvider option in WebSocketTransport to explicitly provide proxy settings for URLSessionWebSocketTask.
5.    Test the connection:
Run your application and ensure that WebSocket traffic from centrifuge-swift is properly routed through your proxy tool.

## License

SwiftCentrifuge is available under the MIT license. See LICENSE for details.

## Release (for maintainers)

Bump version in `SwiftCentrifuge.podspec`

Push to master and create new version tag.

Then run:

```
pod trunk push SwiftCentrifuge.podspec --allow-warnings
```
