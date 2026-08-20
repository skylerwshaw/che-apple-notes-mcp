BINARY_NAME := CheAppleNotesMCP

FALLBACK_FLAGS := $(shell swift build 2>&1 | grep -q "SendingRisksDataRace" && echo "-Xswiftc -swift-version -Xswiftc 5")

.PHONY: build release install clean test test-unit test-e2e clean-test-data

build:
	swift build $(FALLBACK_FLAGS)

release:
	swift build -c release $(FALLBACK_FLAGS)

install: release
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign - ~/bin/$(BINARY_NAME)
	@echo "Installed: ~/bin/$(BINARY_NAME)"

test:
	swift test $(FALLBACK_FLAGS)

# Unit tests only — safe for CI (no Notes.app, no Automation permission).
test-unit:
	swift test $(FALLBACK_FLAGS) --filter CheAppleNotesMCPTests

# E2E tests — requires Notes.app, Full Disk Access, and Automation permission
# for the debug binary. Run `make build` implicitly so the subprocess target
# is up to date, then probe FDA via grant-debug-fda.sh (non-blocking: the
# script exits 1 if FDA missing, prints instructions, and we continue so
# AS-fallback tests still run).
# Sweeps fixture folders afterwards even when tests fail — per-test teardown
# is best-effort and a failed test can orphan its folder.
#
# --no-parallel: E2E suites contend for exclusive real-world resources — the
# ShareWorkflow tests drive Notes.app's actual menus and focus, and every
# AppleScript call shares one serial main-thread lane in the shared server
# process. Run in parallel, UI tests fail with "share menu unavailable" and
# queued calls (e.g. a batch create behind two ~25s share scripts) blow the
# client deadline. Serial suites still finish in a couple of minutes.
test-e2e: build
	@./scripts/grant-debug-fda.sh || true
	swift test $(FALLBACK_FLAGS) --no-parallel --filter CheAppleNotesMCPE2ETests; \
	status=$$?; ./scripts/cleanup-test-folders.sh || true; exit $$status

# Delete any __CheMCPTest_* folders left in Notes.app by aborted test runs.
clean-test-data:
	./scripts/cleanup-test-folders.sh

clean:
	swift package clean
