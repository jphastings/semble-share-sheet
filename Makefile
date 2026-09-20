# Convenience targets. Everything here is a thin wrapper around a command
# you could run yourself; see README.md.

PROJECT = SembleShare.xcodeproj
SCHEME  = SembleShare
PACKAGE = Packages/SembleKit

.PHONY: help generate open test build icon clean

help:
	@echo "make generate  - generate $(PROJECT) from project.yml (needs xcodegen)"
	@echo "make open      - generate and open the project in Xcode"
	@echo "make test      - run the SembleKit unit tests"
	@echo "make build     - build the app for the iOS Simulator (no signing)"
	@echo "make icon      - re-render the app icon PNGs from Design/icon.svg"
	@echo "make clean     - remove generated project and build output"

generate:
	xcodegen generate

open: generate
	open $(PROJECT)

test:
	swift test --package-path $(PACKAGE) --parallel

build: generate
	set -o pipefail; xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGN_IDENTITY="" \
		| (command -v xcbeautify >/dev/null && xcbeautify || cat)

icon:
	TMP=$$(mktemp -d) && npm install --prefix "$$TMP" @resvg/resvg-js && NODE_PATH="$$TMP/node_modules" node Design/render-icon.cjs

clean:
	rm -rf $(PROJECT) $(PACKAGE)/.build build fastlane/builds
