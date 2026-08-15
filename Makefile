# SPDX-License-Identifier: Apache-2.0

SWIFT := xcrun swift
SWIFT_FORMAT := xcrun swift-format
SWIFT_INPUTS := Package.swift Sources Tests

.PHONY: all format format-check build-debug build-release test check clean

all: check

format:
	$(SWIFT_FORMAT) format --configuration .swift-format --in-place --parallel --recursive $(SWIFT_INPUTS)

format-check:
	$(SWIFT_FORMAT) lint --configuration .swift-format --strict --parallel --recursive $(SWIFT_INPUTS)

build-debug:
	$(SWIFT) build --configuration debug

build-release:
	$(SWIFT) build --configuration release

test:
	$(SWIFT) test --configuration debug --parallel

check: format-check build-debug build-release test

clean:
	$(SWIFT) package clean
