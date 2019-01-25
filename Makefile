VERSION := $(shell git describe --tags | sed -e 's/^v//g' | awk -F "-" '{print $$1}')
ITERATION := $(shell git describe --tags --long | awk -F "-" '{print $$2}')

.PHONY: all proto gitversion

all: gitversion

proto:
	protoc --swift_out=Sources/ client.proto

gitversion:
	$(info VERSION is $(.VERSION))
