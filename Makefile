.PHONY: bootstrap generate test-core

MISE ?= mise

bootstrap: generate

generate:
	$(MISE) exec -- xcodegen generate

test-core:
	$(MISE) exec -- swift test --package-path Packages/HerdrKit
