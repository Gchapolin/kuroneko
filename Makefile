APP := Kuroneko
BUNDLE := dist/$(APP).app
BINARY := .build/release/$(APP)

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
	codesign --force --sign - $(BUNDLE)
	@echo "Bundle pronto: $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	swift package clean
	rm -rf dist
