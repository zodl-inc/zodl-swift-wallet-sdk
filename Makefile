# Makefile for the Zcash Swift wallet SDK. Run from the repo root.
#
# Every command the project needs goes through a target here, so that local
# runs and CI runs are identical: .github/workflows/ invokes these targets
# rather than repeating the commands.
#
# Run `make help` for the target list, and `make info` for the resolved
# toolchain.
#
# Layout
# ------
# The Rust FFI build graph lives in BuildSupport/Makefile; the ffi-* targets
# here delegate to it and then assemble the XCFramework, and ffi-ci does so
# exactly as CI does.
# The Swift package itself is built with SwiftPM from the repo root.
#
# Portability
# -----------
# Written for GNU Make 3.81, which is what macOS ships, so it avoids the
# 4.x-only features (`!=`, `$(file ...)`, `.ONESHELL`). The swift build and
# test targets work anywhere SwiftPM does; the ffi-* targets produce an Apple
# XCFramework and therefore require macOS with Xcode, which they check for
# rather than failing obscurely.

SWIFT ?= swift
CARGO ?= cargo
PYTHON ?= python3
BUILD_SUPPORT := BuildSupport
SCRIPTS := Scripts

# The XCFramework the Swift package links against when built locally.
XCFRAMEWORK := $(BUILD_SUPPORT)/products/libzcashlc.xcframework

# Empty by default so a local build is quiet; CI passes -v for a full log.
SWIFT_BUILD_FLAGS ?=

# The test suite that runs without network or a live lightwalletd.
OFFLINE_TEST_FILTER := OfflineTests

# Which slice rebuild-ffi rebuilds: ios-sim, ios-device or macos.
REBUILD_TARGET ?= ios-sim

# SwiftPM and Cargo parallelize internally; running two at once only contends
# on their own locks, so never run these targets concurrently.
.NOTPARALLEL:

.DEFAULT_GOAL := help

.PHONY: help
help: ## Ask for help!
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; \
		{printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: info
info: ## Print the resolved toolchain and FFI state
	@printf "Swift:        "; \
		if command -v $(SWIFT) >/dev/null 2>&1; then \
			$(SWIFT) --version 2>&1 | head -1; else echo "absent"; fi
	@printf "Cargo:        "; \
		if command -v $(CARGO) >/dev/null 2>&1; then $(CARGO) --version; \
		else echo "absent"; fi
	@printf "Xcode:        "; \
		if command -v xcode-select >/dev/null 2>&1; then \
			xcode-select -p 2>/dev/null || echo "not selected"; \
		else echo "absent (not macOS)"; fi
	@printf "XCFramework:  "; \
		if [ -d "$(XCFRAMEWORK)" ]; then echo "$(XCFRAMEWORK)"; \
		else echo "<not built; run make ffi-ci>"; fi
	@printf "LocalPackages:"; \
		if [ -d LocalPackages ]; then echo " present (local FFI in use)"; \
		else echo " absent (Package.swift uses the released FFI)"; fi

.PHONY: print-swift-version
print-swift-version: ## Print the complete version of the selected Swift compiler
	@$(SWIFT) --version

# The FFI targets produce an Apple XCFramework, which only Xcode can do.
.PHONY: require-macos
require-macos:
	@[ "$$(uname -s)" = "Darwin" ] || { \
		echo "This target builds an Apple XCFramework and needs macOS"; \
		echo "with Xcode. The build and test targets work here."; \
		exit 1; }

# ---------------------------------------------------------------------------
# Aggregate targets
# ---------------------------------------------------------------------------

.PHONY: build
build: ## Build the Swift package
	$(SWIFT) build $(SWIFT_BUILD_FLAGS)

.PHONY: build-release
build-release: ## Build the Swift package in release mode
	$(SWIFT) build -c release $(SWIFT_BUILD_FLAGS)

.PHONY: test
test: test-scripts test-offline ## Run the script and offline test suites

.PHONY: check
check: build test test-rust ## Build, run the offline tests, then the Rust tests

# `build` links whatever FFI is already in place; these build the Rust from
# source first, so the XCFramework matches the tree.
.PHONY: build-all
build-all: ffi-macos configure-local-ffi build ## Build the FFI from source, then the Swift package

.PHONY: build-all-release
build-all-release: ffi-macos configure-local-ffi build-release ## Build the FFI and the Swift package in release mode

.PHONY: check-all
check-all: build-all test ## Build everything from source and run the offline tests

.PHONY: clean
clean: ## Clean the SwiftPM build directory
	$(SWIFT) package clean

# reset-ffi last: it removes LocalPackages/, which would otherwise survive as a
# stale copy that Package.swift keeps linking after everything else is gone.
.PHONY: clean-all
clean-all: clean clean-ffi clean-rust reset-ffi ## Clean all artifacts and reset the FFI mode

.PHONY: setup
setup: ## Set up the development environment
	@$(MAKE) --no-print-directory info
	@echo ""
	@echo "For a local FFI build, run: make init-ffi"

# ---------------------------------------------------------------------------
# Swift package
# ---------------------------------------------------------------------------

.PHONY: resolve
resolve: ## Resolve the SwiftPM dependencies
	$(SWIFT) package resolve

.PHONY: test-offline
test-offline: ## Run the offline tests (no network, no lightwalletd)
	$(SWIFT) test --filter $(OFFLINE_TEST_FILTER)

.PHONY: test-scripts
test-scripts: ## Run the shell and Python script unit tests
	./$(SCRIPTS)/tests/run-tests.sh
	$(PYTHON) -m unittest discover -s $(SCRIPTS)/tests -p 'test_*.py' -v

.PHONY: test-all
test-all: ## Run the whole test suite, including networked tests
	$(SWIFT) test

# The Rust unit tests. These cover the FFI layer below the Swift package, so
# they are not reached by any `swift test` filter and need their own target.
.PHONY: test-rust
test-rust: ## Run the Rust unit tests
	$(CARGO) test --locked

.PHONY: format-rust
format-rust: ## Format the Rust sources with rustfmt
	$(CARGO) fmt --all

.PHONY: check-format-rust
check-format-rust: ## Check that the Rust sources are rustfmt-clean
	$(CARGO) fmt --all -- --check

.PHONY: lint
lint: ## Lint the Swift sources with SwiftLint
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint not found. Install it with: brew install swiftlint"; \
		exit 1; }
	swiftlint lint --quiet

.PHONY: format
format: ## Apply SwiftLint autocorrections
	@command -v swiftlint >/dev/null 2>&1 || { \
		echo "swiftlint not found. Install it with: brew install swiftlint"; \
		exit 1; }
	swiftlint --fix

# Kept as an alias: this was the target name before the Makefile grew.
.PHONY: swift-build
swift-build: build ## Alias for `make build`

# ---------------------------------------------------------------------------
# Rust crate
# ---------------------------------------------------------------------------
#
# Cargo.toml is at the repo root, so cargo runs from here. These build for the
# host only; the ffi-* targets below cross-compile for Apple platforms.

.PHONY: build-rust
build-rust: ## Build the Rust crate for the host (debug)
	$(CARGO) build

.PHONY: build-rust-release
build-rust-release: ## Build the Rust crate for the host (release)
	$(CARGO) build --release

# Removes target/ entirely, including the cross-compiled slices the ffi-*
# targets build. clean-ffi preserves those on purpose.
.PHONY: clean-rust
clean-rust: ## Clean the Cargo build artifacts (target/)
	$(CARGO) clean

# ---------------------------------------------------------------------------
# Rust FFI (BuildSupport/)
# ---------------------------------------------------------------------------
#
# ffi-macos builds the ARM64 macOS slice with the release profile. It owns
# the assembled product, so stale slices cannot survive a platform-only build.

.PHONY: ffi-macos
ffi-macos: require-macos ## Build the macOS FFI and assemble the XCFramework
	$(MAKE) -C $(BUILD_SUPPORT) macos
	rm -rf $(XCFRAMEWORK)
	mkdir -p $(XCFRAMEWORK)
	cp -R $(BUILD_SUPPORT)/products/macos/frameworks $(XCFRAMEWORK)/macos-arm64
	python3 $(SCRIPTS)/lib/ffi_layout.py manifest $(XCFRAMEWORK)/Info.plist macos-arm64
	python3 $(SCRIPTS)/lib/ffi_layout.py validate $(XCFRAMEWORK)

# CI uses the same ARM64 slice without release whole-program LTO. Keep rm
# separate from recursive make so dry runs cannot delete build products.
.PHONY: ffi-ci
ffi-ci: require-macos ## Build the FFI the way CI does: arm64 macOS only, without fat LTO
	rm -rf $(BUILD_SUPPORT)/products/macos
	CARGO_PROFILE_RELEASE_LTO=false $(MAKE) ffi-macos MACOS_ARCHS=aarch64-apple-darwin

# Releases never get extra Cargo features (ohttp-trace), whatever the environment holds.
.PHONY: ffi-all
ffi-all: require-macos ## Build the full XCFramework for every platform
	$(MAKE) -C $(BUILD_SUPPORT) xcframework FFI_CARGO_FEATURES=

.PHONY: verify-ffi
verify-ffi: ## Check the XCFramework exists and show its contents
	@if [ ! -d "$(XCFRAMEWORK)" ]; then \
		echo "Error: $(XCFRAMEWORK) not found"; \
		exit 1; fi
	@echo "XCFramework contents:"
	@ls -la $(XCFRAMEWORK)/

# Package.swift auto-detects LocalPackages/ and links the local FFI instead of
# the released binary target.
.PHONY: configure-local-ffi
configure-local-ffi: verify-ffi ## Point Package.swift at the locally built FFI
	$(PYTHON) $(SCRIPTS)/lib/ffi_layout.py install "$(XCFRAMEWORK)" "$(BUILD_SUPPORT)/LocalPackages-Package.swift" LocalPackages
	@echo "LocalPackages created; Package.swift will use the local FFI"

.PHONY: clean-ffi
clean-ffi: ## Clean the FFI build artifacts
	$(MAKE) -C $(BUILD_SUPPORT) clean

# ---------------------------------------------------------------------------
# Local FFI development helpers (Scripts/)
# ---------------------------------------------------------------------------

.PHONY: init-ffi
init-ffi: ## Initialize the local FFI development environment
	./$(SCRIPTS)/init-local-ffi.sh

.PHONY: rebuild-ffi
rebuild-ffi: ## Rebuild the local FFI (REBUILD_TARGET=ios-sim by default)
	./$(SCRIPTS)/rebuild-local-ffi.sh $(REBUILD_TARGET)

.PHONY: reset-ffi
reset-ffi: ## Reset the local FFI development environment
	./$(SCRIPTS)/reset-local-ffi.sh

.PHONY: ffi-artifacts
ffi-artifacts: require-macos ## Build and upload the release XCFramework (VERSION=X.Y.Z)
	@[ -n "$(VERSION)" ] || { echo "Set VERSION, e.g. make ffi-artifacts VERSION=2.7.1"; exit 1; }
	./$(SCRIPTS)/prepare-release.sh artifacts $(VERSION)
