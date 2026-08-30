.PHONY: bootstrap generate test-core

MISE ?= mise

bootstrap: generate

generate:
	$(MISE) exec -- ./scripts/generate-xcodeproj.sh

test-core:
	$(MISE) exec -- swift test --package-path Packages/HerdrKit
