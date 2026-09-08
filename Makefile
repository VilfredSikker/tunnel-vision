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
	open build/TunnelVision.app

clean:
	rm -rf .build build

# Registers the bundled MCP server with Claude Code (user scope) so an agent
# can read and shape tasks, presets and the session through the running app.
mcp-register: app
	claude mcp add --scope user tunnelvision -- "$(CURDIR)/build/TunnelVision.app/Contents/Helpers/tunnelvision-mcp"
