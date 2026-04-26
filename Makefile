.PHONY: lint lint-fix format format-check generate build

lint:
	swiftlint

lint-fix:
	swiftlint --fix

format:
	swiftformat .

format-check:
	swiftformat --lint .

generate:
	xcodegen generate

build: generate
	xcodebuild -scheme OakReader build
