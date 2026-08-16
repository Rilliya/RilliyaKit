# SPDX-License-Identifier: Apache-2.0

SWIFT := xcrun swift
SWIFT_FORMAT := xcrun swift-format
SWIFT_INPUTS := Package.swift Sources Tests Examples/Package.swift Examples/Sources

.PHONY: all repository-hygiene format format-check build-debug build-release build-examples test check clean

all: check

repository-hygiene:
	./scripts/check-repository-hygiene.sh

format:
	$(SWIFT_FORMAT) format --configuration .swift-format --in-place --parallel --recursive $(SWIFT_INPUTS)

format-check:
	$(SWIFT_FORMAT) lint --configuration .swift-format --strict --parallel --recursive $(SWIFT_INPUTS)

build-debug:
	$(SWIFT) build --configuration debug

build-release:
	$(SWIFT) build --configuration release

build-examples:
	$(SWIFT) build --package-path Examples --configuration debug

test:
	$(SWIFT) test --configuration debug --parallel

check: repository-hygiene format-check build-debug build-release build-examples test

clean:
	$(SWIFT) package clean
	$(SWIFT) package --package-path Examples clean
