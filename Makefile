.PHONY: all lint lint-fix format format-check generate build \
       extension extension-dev extension-install extension-clean clean

# ---------- Top-level ----------

all: build extension

# ---------- Swift / Xcode ----------

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

# ---------- Chrome Extension ----------

extension-install:
	cd chrome-extension && pnpm install

extension: extension-install
	cd chrome-extension && pnpm build

extension-dev: extension-install
	cd chrome-extension && pnpm dev

extension-clean:
	rm -rf chrome-extension/.output chrome-extension/node_modules

# ---------- Clean ----------

clean: extension-clean
	xcodebuild -scheme OakReader clean 2>/dev/null || true
