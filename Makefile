APP := Kuroneko
BUNDLE := dist/$(APP).app
BINARY := .build/release/$(APP)
# A stable certificate keeps the TCC grants (mic, system audio) across
# rebuilds; ad-hoc signatures change the cdhash and macOS forgets them.
SIGN_IDENTITY ?= Apple Development

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
	codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE)
	@echo "Bundle pronto: $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	swift package clean
	rm -rf dist
