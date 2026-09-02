CONFIG ?= debug
# SwiftPM manifest evaluation is sandboxed via sandbox-exec, which this
# machine's session policy forbids; --disable-sandbox works around it.
SWIFT_FLAGS ?= --disable-sandbox

.PHONY: build test app run clean

build:
	swift build $(SWIFT_FLAGS) -c $(CONFIG)

test:
	swift test $(SWIFT_FLAGS)

app:
	scripts/make-app.sh release

run: app
	open build/Anchor.app

clean:
	rm -rf .build build
