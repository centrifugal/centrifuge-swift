.PHONY: all proto test release run-console-example

all: proto

proto:
	protoc --swift_out=Sources/SwiftCentrifuge client.proto

# Runs the full suite when Xcode is installed, and the swift-testing suites
# only when it is not (XCTest ships inside Xcode.app). See CLAUDE.md.
test:
	./scripts/test.sh

release:
	pod trunk push SwiftCentrifuge.podspec

run-console-example:
	cd Examples/ConsoleExample && swift run
