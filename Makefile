.PHONY: all proto

all: proto

proto:
	protoc --swift_out=Sources/SwiftCentrifuge client.proto

release:
	pod trunk push SwiftCentrifuge.podspec
