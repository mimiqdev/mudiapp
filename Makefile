.PHONY: bootstrap generate test-core

bootstrap: generate

generate:
	@command -v xcodegen >/dev/null || (echo "xcodegen is required: brew install xcodegen" && exit 1)
	xcodegen generate

test-core:
	swift test --package-path Packages/HerdrKit
