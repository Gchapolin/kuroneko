APP := Kuroneko
BUNDLE := dist/$(APP).app
BINARY := .build/release/$(APP)
# A stable certificate keeps the TCC grants (mic, system audio) across
# rebuilds; ad-hoc signatures change the cdhash and macOS forgets them.
SIGN_IDENTITY ?= Apple Development
# Release builds stamp the tag's version and the CI run into the bundle.
VERSION ?=
BUILD_NUMBER ?=

.PHONY: build test bundle run clean

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
ifneq ($(VERSION),)
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(BUNDLE)/Contents/Info.plist
endif
ifneq ($(BUILD_NUMBER),)
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" $(BUNDLE)/Contents/Info.plist
endif
	# SwiftPM resource bundles (KeyboardShortcuts strings, FluidAudio, GRDB);
	# without them the app only works while .build/ exists.
	cp -R .build/release/*.bundle $(BUNDLE)/Contents/Resources/
	codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE)
	@echo "Bundle pronto: $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	swift package clean
	rm -rf dist
