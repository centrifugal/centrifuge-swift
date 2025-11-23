.PHONY: all proto release run-console-example

all: proto

proto:
	protoc --swift_out=Sources/SwiftCentrifuge client.proto

release:
	pod trunk push SwiftCentrifuge.podspec

run-console-example:
	cd Examples/ConsoleExample && swift run
