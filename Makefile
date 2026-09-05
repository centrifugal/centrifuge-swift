.PHONY: all proto test release run-console-example

all: proto

proto:
	protoc --swift_out=Sources/SwiftCentrifuge client.proto

# Runs the suite with or without Xcode installed - swift-testing ships with the
# Command Line Tools, the script just wires up its search paths. See CLAUDE.md.
test:
	./scripts/test.sh

release:
	pod trunk push SwiftCentrifuge.podspec

run-console-example:
	cd Examples/ConsoleExample && swift run
