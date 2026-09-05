# SwiftCentrifuge

Websocket client for [Centrifugo](https://github.com/centrifugal/centrifugo) server and [Centrifuge](https://github.com/centrifugal/centrifuge) library. 

There is no v1 release of this library yet – API still evolves. At the moment patch version updates only contain backwards compatible changes, minor version updates can have backwards incompatible API changes.

Check out [client SDK API specification](https://centrifugal.dev/docs/transports/client_api) to learn how this SDK behaves. It's recommended to read that before starting to work with this SDK as the spec covers common SDK behavior - describes client and subscription state transitions, main options and methods. Also check out examples folder.

The features implemented by this SDK can be found in [SDK feature matrix](https://centrifugal.dev/docs/transports/client_sdk#sdk-feature-matrix).

> **The latest `centrifuge-swift` is compatible with [Centrifugo](https://github.com/centrifugal/centrifugo) server v6, v5 and v4 and [Centrifuge](https://github.com/centrifugal/centrifuge) >= 0.25.0. For Centrifugo v2, Centrifugo v3 and Centrifuge < 0.25.0 you should use `centrifuge-swift` v0.4.6.**

## Installation

### Swift Package Manager (recommended)

In Xcode, use `File` -> `Add Package Dependencies...` and enter:

```
https://github.com/centrifugal/centrifuge-swift.git
```

Or add it to your `Package.swift` dependencies (replace `<version>` with the latest [release tag](https://github.com/centrifugal/centrifuge-swift/releases)):

```swift
.package(url: "https://github.com/centrifugal/centrifuge-swift.git", from: "<version>")
```

If you get a warning complaining about missing pc file, you may need to install `pkg-config`. On macOS, this can be achieved with `brew install pkg-config`.

### CocoaPods

CocoaPods support is still maintained, but SPM is the primary and recommended way to install this library going forward.

To integrate SwiftCentrifuge into your Xcode project using CocoaPods, specify it in your `Podfile`:

```ruby
pod 'SwiftCentrifuge'
```

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

If you need to manually configure proxy settings for `URLSessionWebSocketTask`, follow these steps:
1.    Set up a proxy tool:
Configure your preferred proxy tool (e.g., Charles Proxy, Proxyman, or mitmproxy) according to its documentation. Ensure that it is properly set up to intercept traffic from your device.
2.    Verify proxy functionality:
Enable system-wide proxy settings on your device and check that traffic from system calls is captured in your proxy tool.
3.    Disable system proxy:
After verifying that the proxy tool works as expected, disable the system-wide proxy settings on your device.
4.    Configure CentrifugeClient for proxying:
Use the `urlSessionConfigurationProvider` option in `CentrifugeClientConfig` to explicitly provide proxy settings for `URLSessionWebSocketTask`.
5.    Test the connection:
Run your application and ensure that WebSocket traffic from centrifuge-swift is properly routed through your proxy tool.

## Running tests

```bash
make test
```

The suite uses [swift-testing](https://github.com/swiftlang/swift-testing), which ships with the Swift toolchain, so a full Xcode install is not required — `make test` wires up the framework search paths when only the Command Line Tools are present, and defers to plain `swift test` when Xcode is there.

Most suites talk to an in-process fake Centrifugo server and need no external dependencies. The suite which covers recovery and state loading (`GetStateTests`) needs a real Centrifugo (>= 6.8.0) configured as in [docker-compose.yml](docker-compose.yml):

```bash
docker compose up -d
make test
```

To run a single suite use a filter, for example:

```bash
./scripts/test.sh --filter GetStateTests
```

## License

SwiftCentrifuge is available under the MIT license. See LICENSE for details.

## Release (for maintainers)

Swift Package Manager needs no publish step - pushing a version tag is enough for SPM consumers to pick it up. Releases are also automated via the [`release`](.github/workflows/release.yml) GitHub Actions workflow, which publishes the podspec to CocoaPods trunk for CocoaPods consumers. No local Xcode or CocoaPods setup is required.

1. Bump `s.version` in `SwiftCentrifuge.podspec`.
2. Push to `master` and create a matching version tag (e.g. `0.9.0`).

Pushing the tag triggers the workflow automatically. The workflow verifies that the podspec version matches the tag before pushing, so make sure the version is bumped before tagging.

To (re)publish an already-existing tag manually:

```
gh workflow run release.yml -f tag=0.9.0
```

The workflow authenticates to CocoaPods trunk using the `COCOAPODS_TRUNK_TOKEN` repository secret.
