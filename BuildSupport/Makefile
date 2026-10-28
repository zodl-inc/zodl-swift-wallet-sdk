SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

PLATFORMS = ios-device macos ios-simulator
IOS_DEVICE_ARCHS = aarch64-apple-ios
IOS_SIM_ARCHS_STABLE = x86_64-apple-ios  aarch64-apple-ios-sim
MACOS_ARCHS = x86_64-apple-darwin aarch64-apple-darwin
IOS_SIM_ARCHS = $(IOS_SIM_ARCHS_STABLE)
ALL_ARCHS = $(IOS_DEVICE_ARCHS) $(IOS_SIM_ARCHS) $(MACOS_ARCHS)

# The minimum OS versions every slice is built for; keep them equal to
# Package.swift's platforms. rustc and the cc crate both read these variables.
# Without them, C that a dependency's build script compiles (lzma-sys, zstd-sys,
# ring) took the Xcode SDK's own version as its minimum, so an Xcode 27 build
# claimed macOS and iOS 27. IPHONEOS_DEPLOYMENT_TARGET also covers the
# simulator slices. rustc applies MACOSX_DEPLOYMENT_TARGET to the build scripts
# and proc macros it builds for this Mac as well; ../Cargo.toml's
# [profile.release.build-override] explains why those stay unstripped.
MACOSX_DEPLOYMENT_TARGET = 14.0
IPHONEOS_DEPLOYMENT_TARGET = 16.0

# Cargo serialises concurrent invocations behind a lock on the shared host
# artifact directory (../target/release), so running one `cargo build --target X`
# per architecture cannot overlap them — `make -j` does not help. That matters
# most for the link step: `lto = true` is a single-threaded whole-program pass
# costing roughly two minutes per architecture, so five of them run back to back.
#
# Passing several `--target` flags to one invocation puts every architecture in a
# single job graph, letting those passes run concurrently.
CARGO_BUILD = RUSTUP_TOOLCHAIN=stable MACOSX_DEPLOYMENT_TARGET=$(MACOSX_DEPLOYMENT_TARGET) IPHONEOS_DEPLOYMENT_TARGET=$(IPHONEOS_DEPLOYMENT_TARGET) cargo build --locked --manifest-path ../Cargo.toml --release
cargo_targets = $(addprefix --target ,$(1))

RUST_SRCS = $(shell find ../rust -name "*.rs") ../Cargo.toml
STATIC_LIBS = $(shell find ../target -name "libzcashlc.a")

install:
	rustup toolchain add stable
	rustup +stable target add aarch64-apple-ios x86_64-apple-ios x86_64-apple-darwin aarch64-apple-darwin aarch64-apple-ios-sim
	
.PHONY: install

release: clean xcframework
.PHONY: release

# Discard assembled build products. ../target is deliberately preserved so that
# cargo's fingerprints (and CI's restored Rust cache) still apply; cargo decides
# what genuinely needs rebuilding. Every framework under products/ is rebuilt
# from scratch, so no stale slice can survive this.
clean:
	rm -rf products
.PHONY: clean

# Additionally discard the cargo target directory, forcing a from-scratch build.
distclean: clean
	rm -rf ../target
.PHONY: distclean

xcframework: products/libzcashlc.xcframework
.PHONY: xcframework

# cargo-all is listed first so a full build compiles every architecture in one
# invocation. The per-platform cargo rules below then find their work already
# done and reduce to a fingerprint check.
products/libzcashlc.xcframework: cargo-all $(PLATFORMS)
	rm -rf $@
	mkdir -p $@
	cp -R products/ios-device/frameworks $@/ios-arm64
	cp -R products/ios-simulator/frameworks $@/ios-arm64_x86_64-simulator
	cp -R products/macos/frameworks $@/macos-arm64_x86_64
	cp Info.plist $@

frameworks: $(PLATFORMS)
.PHONY: frameworks

$(PLATFORMS): %: products/%/frameworks/libzcashlc.framework
.PHONY: $(PLATFORMS)

products/%/frameworks/libzcashlc.framework: products/%/universal/libzcashlc.a
	rm -rf $@
	mkdir -p $@
	cp products/$*/universal/libzcashlc.a $@/libzcashlc
	cp -R ../target/Headers $@
	mkdir $@/Modules
	cp module.modulemap $@/Modules
	# Workaround for a bug in the XCode 15.3 build system.
	# https://github.com/Electric-Coin-Company/zashi-ios/issues/1166
	cp platform-Info.plist $@/Info.plist

products/macos/universal/libzcashlc.a: $(MACOS_ARCHS)
	mkdir -p $(@D)
	lipo -create $(shell find products/macos/static-libraries -name "libzcashlc.a") -output $@

products/ios-simulator/universal/libzcashlc.a: $(IOS_SIM_ARCHS)
	mkdir -p $(@D)
	lipo -create $(shell find products/ios-simulator/static-libraries -name "libzcashlc.a") -output $@

products/ios-device/universal/libzcashlc.a: $(IOS_DEVICE_ARCHS)
	mkdir -p $(@D)
	lipo -create $(shell find products/ios-device/static-libraries -name "libzcashlc.a") -output $@

$(MACOS_ARCHS): %: cargo-macos
	mkdir -p products/macos/static-libraries/$*
	cp ../target/$*/release/libzcashlc.a products/macos/static-libraries/$*
.PHONY: $(MACOS_ARCHS)

$(IOS_DEVICE_ARCHS): %: cargo-ios-device
	mkdir -p products/ios-device/static-libraries/$*
	cp ../target/$*/release/libzcashlc.a products/ios-device/static-libraries/$*
.PHONY: $(IOS_DEVICE_ARCHS)

$(IOS_SIM_ARCHS_STABLE): %: cargo-ios-simulator
	mkdir -p products/ios-simulator/static-libraries/$*
	cp ../target/$*/release/libzcashlc.a products/ios-simulator/static-libraries/$*
.PHONY: $(IOS_SIM_ARCHS_STABLE)

# Each platform builds only its own architectures, so `make macos` still needs
# just the macOS rustup targets installed.
cargo-all:
	$(CARGO_BUILD) $(call cargo_targets,$(ALL_ARCHS))
.PHONY: cargo-all

cargo-macos:
	$(CARGO_BUILD) $(call cargo_targets,$(MACOS_ARCHS))
.PHONY: cargo-macos

cargo-ios-device:
	$(CARGO_BUILD) $(call cargo_targets,$(IOS_DEVICE_ARCHS))
.PHONY: cargo-ios-device

cargo-ios-simulator:
	$(CARGO_BUILD) $(call cargo_targets,$(IOS_SIM_ARCHS))
.PHONY: cargo-ios-simulator
