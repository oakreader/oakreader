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

# ---------- Browser Extension ----------

extension-install:
	cd browser-extension && pnpm install

extension: extension-install
	cd browser-extension && pnpm build

extension-dev: extension-install
	cd browser-extension && pnpm dev

extension-clean:
	rm -rf browser-extension/.output browser-extension/node_modules

# ---------- Clean ----------

clean: extension-clean
	xcodebuild -scheme OakReader clean 2>/dev/null || true
