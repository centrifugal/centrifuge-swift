# SwiftCentrifuge

Websocket client for [Centrifugo](https://github.com/centrifugal/centrifugo) server and [Centrifuge](https://github.com/centrifugal/centrifuge) library. 

There is no v1 release of this library yet – API still evolves. At the moment patch version updates only contain backwards compatible changes, minor version updates can have backwards incompatible API changes.

Check out [client SDK API specification](https://centrifugal.dev/docs/transports/client_api) to learn how this SDK behaves. It's recommended to read that before starting to work with this SDK as the spec covers common SDK behavior - describes client and subscription state transitions, main options and methods. Also check out examples folder.

The features implemented by this SDK can be found in [SDK feature matrix](https://centrifugal.dev/docs/transports/client_sdk#sdk-feature-matrix).

> **The latest `centrifuge-swift` is compatible only with the latest [Centrifugo](https://github.com/centrifugal/centrifugo) server (v4) and [Centrifuge](https://github.com/centrifugal/centrifuge) >= 0.25.0. For Centrifugo v2, Centrifugo v3 and Centrifuge < 0.25.0 you should use `centrifuge-swift` v0.4.6.**

## Installation

There are several convenient ways.

### CocoaPods

To integrate SwiftCentrifuge into your Xcode project using CocoaPods, specify it in your `Podfile`:

```ruby
pod 'SwiftCentrifuge'
```

### Carthage

Add the line `github "centrifugal/centrifuge-swift"` to your `Cartfile`. Then run `carthage update`.

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

## License

SwiftCentrifuge is available under the MIT license. See LICENSE for details.

## Release (for maintainers)

Bump version in `SwiftCentrifuge.podspec`

Push to master and create new version tag.

Then run:

```
pod trunk push SwiftCentrifuge.podspec
```
