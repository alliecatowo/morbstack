# Makefile for Morbstack.
#
# Two toolchains live side by side: Swift (host daemon + CLI, under mac/)
# and Rust (guest PID 1, under guest/morbinit/). This file is the single
# source of truth for build logic; mise.toml tasks just shell out to it.
#
# Kept POSIX-make friendly: no GNU-only functions, explicit .PHONY list,
# no order-only prerequisites.

.PHONY: setup build build-mac build-guest cross-build-guest guest-image sign run-daemon test clean app app-icon run-app clean-app shots-live

# How to invoke cargo. Resolved by the recipe's shell (command substitution,
# not a GNU-make function) so this stays POSIX-make friendly: use the
# mise-managed toolchain when mise is installed, otherwise whatever cargo is
# already on PATH.
CARGO = `if command -v mise >/dev/null 2>&1; then echo "mise x -- cargo"; else echo cargo; fi`

# Where the Swift build products land.
MAC_BUILD_DIR = mac/.build/debug

# Install the pinned toolchain versions (currently: Rust, via mise.toml).
# Swift comes from Xcode and is not managed by mise.
#
# `mise trust` is required on a fresh clone: mise refuses to read a config
# file it has not been told to trust, and the error is easy to mistake for a
# broken toolchain.
setup:
	mise trust
	mise install

# Build everything: the mac host binaries and the guest init binary.
build: build-mac build-guest

# Host side: morbstackd (daemon) and morb (CLI), built together as one
# Swift package.
build-mac:
	cd mac && swift build

# Guest side: morbinit, the Rust PID 1 that runs inside the VM. Prefer the
# mise-managed Rust toolchain; fall back to whatever `cargo` is already on
# PATH if mise isn't installed (e.g. a quick local iteration loop).
#
# The fallback keys off `command -v mise`, not off the exit status of the
# build: keying off the build would swallow real compile errors and retry
# with a different toolchain, and redirecting cargo's stderr to /dev/null to
# hide the "mise not found" noise would also hide every warning and error.
build-guest:
	cd guest/morbinit && $(CARGO) build

# Where the messense/homebrew-macos-cross-toolchains aarch64-unknown-linux-musl
# GCC cross toolchain lives (see dist/CROSS_COMPILE.md for the install
# recipe). Only used by cross-build-guest / guest-image, so a plain
# build-guest (host-arch dev loop) never needs it on PATH.
CROSS_TOOLCHAIN_BIN = /opt/homebrew/opt/aarch64-unknown-linux-musl/bin

# Guest side, cross-compiled: morbinit built for aarch64-unknown-linux-musl,
# the actual target triple that runs inside the VM (build-guest above just
# builds for the host arch, useful for `cargo test`/`cargo check` but not
# bootable).
#
# The linker is wired through env vars here, and guest/morbinit/.cargo/config.toml
# also pins it so a bare `cargo build --release --target
# aarch64-unknown-linux-musl` works from inside that directory. The two
# coexist: cargo gives CARGO_TARGET_..._LINKER precedence over config.toml, so
# this recipe wins and stays the single source of truth for `make`.
#
# CC_... / CARGO_TARGET_..._LINKER: point the target-specific C compiler and
# linker at the cross toolchain. PATH is extended so `cargo` can also find
# the cross `ar`/`strip`/etc that rustc shells out to.
cross-build-guest:
	if [ ! -x "$(CROSS_TOOLCHAIN_BIN)/aarch64-unknown-linux-musl-gcc" ]; then \
		echo "error: aarch64-unknown-linux-musl cross toolchain not found at $(CROSS_TOOLCHAIN_BIN)" >&2; \
		echo "       see dist/CROSS_COMPILE.md for the install recipe (brew tap" >&2; \
		echo "       messense/macos-cross-toolchains && brew install" >&2; \
		echo "       messense/macos-cross-toolchains/aarch64-unknown-linux-musl)" >&2; \
		exit 1; \
	fi
	cd guest/morbinit && \
		PATH="$(CROSS_TOOLCHAIN_BIN):$$PATH" \
		CC_aarch64_unknown_linux_musl="$(CROSS_TOOLCHAIN_BIN)/aarch64-unknown-linux-musl-gcc" \
		CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$(CROSS_TOOLCHAIN_BIN)/aarch64-unknown-linux-musl-gcc" \
		$(CARGO) build --release --target aarch64-unknown-linux-musl

# Build the bootable initramfs: cross-compiled morbinit as /init, plus the
# Alpine minirootfs and the static Docker engine binaries from dist/. Writes
# $(MORBSTACK_HOME)/data/kernel/initrd.img (default ~/.morbstack, override
# via the MORBSTACK_HOME env var, honoured by scripts/mkinitramfs.sh itself).
guest-image: cross-build-guest
	scripts/mkinitramfs.sh

# Ad-hoc codesign with the entitlements morbstackd needs to open a
# Virtualization.framework VM (com.apple.security.virtualization, etc.).
# Development-only: signs with the local machine identity ("-"), not a
# Developer ID. Depends on build-mac so that `make sign` works on a fresh
# checkout instead of failing on a missing binary.
sign: build-mac
	codesign --force --sign - --entitlements mac/Resources/morbstackd.entitlements $(MAC_BUILD_DIR)/morbstackd

# Build, sign, and run the daemon in the foreground for local development.
run-daemon: sign
	exec $(MAC_BUILD_DIR)/morbstackd --foreground

# Run both test suites. The Swift suite only exists once mac/Tests is
# populated, so guard on that to keep `make test` green on a fresh checkout.
test:
	if [ -d mac/Tests ]; then cd mac && swift test; fi
	cd guest/morbinit && $(CARGO) test

# Self-capture the *real* MorbstackApp window — titlebar, toolbar, sidebar material and
# Liquid Glass and all — instead of MorbShots' offscreen approximation (dist/shots),
# which cannot render any of those. See Sources/MorbstackAppCore/Shots/LiveCapture.swift
# for why an offscreen bitmap structurally can't and this can.
#
# `--tour-fixtures` serves the same canned Docker world MorbShots renders offscreen, so
# no morbstackd and no VM are needed — this never starts the engine. Only `build-mac`,
# not `sign`: nothing here touches the daemon, so morbstackd's virtualization
# entitlement is irrelevant to this target.
#
# Two full launches, not one: SwiftUI's `.preferredColorScheme` is applied when the
# window is created, so light and dark each need their own process. The app briefly
# takes focus and shows real windows on screen while each run captures — that is the
# whole mechanism, not a side effect to suppress.
SHOTS_LIVE_DIR = dist/shots-live

shots-live: build-mac
	rm -rf $(SHOTS_LIVE_DIR)
	mkdir -p $(SHOTS_LIVE_DIR)
	$(MAC_BUILD_DIR)/MorbstackApp --tour-fixtures --tour-capture $(SHOTS_LIVE_DIR) \
		--window-size 1440x900 --appearance light
	$(MAC_BUILD_DIR)/MorbstackApp --tour-fixtures --tour-capture $(SHOTS_LIVE_DIR) \
		--window-size 1440x900 --appearance dark

# ---------------------------------------------------------------------------
# The SwiftUI app bundle.
#
# SwiftPM builds executables, not `.app`s, so the bundle is assembled by hand
# here. That is a feature rather than a workaround: the layout is thirty lines
# of `cp` and `mkdir` that anyone can read, with no Xcode project to drift out
# of sync with Package.swift and nothing to regenerate on a fresh clone.
# ---------------------------------------------------------------------------

APP_NAME = Morbstack
APP_BUNDLE = dist/$(APP_NAME).app
APP_RELEASE_DIR = mac/.build/release
ICONSET_DIR = mac/.build/AppIcon.iconset

# Render the icon PNGs and pack them into an .icns.
#
# `iconutil` is part of the base system, so this needs nothing installed. The
# iconset directory is rebuilt from scratch each time: a stale PNG left over
# from an earlier design silently ends up in the icns, and the only symptom is
# a Dock icon that is wrong at exactly one size.
app-icon:
	rm -rf $(ICONSET_DIR)
	mkdir -p $(ICONSET_DIR)
	swift mac/AppResources/make-icon.swift $(ICONSET_DIR)
	iconutil --convert icns --output mac/.build/AppIcon.icns $(ICONSET_DIR)

# Build a launchable Morbstack.app in dist/.
#
# The daemon and CLI are copied in beside the app binary on purpose:
# `DaemonClient.locateDaemonExecutable` looks for `morbstackd` next to the
# running executable first, so a bundle assembled here can start the engine
# without anything being installed on PATH. That is what makes the app work on
# a machine that has only ever seen the repository.
#
# Ad-hoc signing (`--sign -`) is the last step because every earlier step
# mutates the bundle, and a signature only covers what was there when it was
# made. Unsigned, macOS 15 refuses to launch the bundle at all.
app: app-icon
	# One product per invocation: `swift build` accepts a single `--product`, and
	# passing two silently builds only the last one — which then fails three lines
	# down on a missing binary rather than at the flag that was wrong.
	cd mac && swift build -c release --product MorbstackApp
	cd mac && swift build -c release --product morbstackd
	cd mac && swift build -c release --product morb
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(APP_RELEASE_DIR)/MorbstackApp $(APP_BUNDLE)/Contents/MacOS/MorbstackApp
	cp $(APP_RELEASE_DIR)/morbstackd $(APP_BUNDLE)/Contents/MacOS/morbstackd
	cp $(APP_RELEASE_DIR)/morb $(APP_BUNDLE)/Contents/MacOS/morb
	cp mac/.build/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp mac/AppResources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	printf 'APPL????' > $(APP_BUNDLE)/Contents/PkgInfo
	# Stamp the real version in, so the bundle and `morb version` agree.
	VERSION=`sed -n 's/.*public static let string = "\(.*\)".*/\1/p' mac/Sources/MorbstackKit/Version.swift`; \
		if [ -n "$$VERSION" ]; then \
			/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$VERSION" $(APP_BUNDLE)/Contents/Info.plist; \
			/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$VERSION" $(APP_BUNDLE)/Contents/Info.plist; \
		fi
	# Sign inside-out: nested helpers first, then the bundle that contains them.
	#
	# morbstackd needs the virtualization entitlement to open a VM at all, and it
	# is signed separately because the app itself must not carry that
	# entitlement. The order matters and so does the absence of --deep: --deep
	# re-signs nested code with the *outer* invocation's arguments, so signing
	# the app with --deep after signing morbstackd silently re-signs morbstackd
	# with no entitlements at all. The symptom is not a build failure — it is a
	# shipped app whose bundled daemon cannot create a VZVirtualMachine, which is
	# the one thing it is in there to do. Signing the outer bundle on its own
	# seals the helpers by reference through CodeResources and leaves their own
	# signatures, and their entitlements, intact.
	codesign --force --sign - $(APP_BUNDLE)/Contents/MacOS/morb
	codesign --force --sign - --entitlements mac/Resources/morbstackd.entitlements \
		$(APP_BUNDLE)/Contents/MacOS/morbstackd
	codesign --force --sign - $(APP_BUNDLE)
	# Fail loudly rather than shipping a daemon that cannot boot the guest.
	@codesign -d --entitlements - $(APP_BUNDLE)/Contents/MacOS/morbstackd 2>&1 \
		| grep -q "com.apple.security.virtualization" \
		|| { echo "error: morbstackd lost its virtualization entitlement during signing" >&2; exit 1; }
	@echo "built $(APP_BUNDLE)"

# Build and launch it.
run-app: app
	open $(APP_BUNDLE)

clean-app:
	rm -rf $(APP_BUNDLE) mac/.build/AppIcon.icns $(ICONSET_DIR)

# Remove build outputs from both toolchains.
clean: clean-app
	rm -rf mac/.build
	cd guest/morbinit && $(CARGO) clean
