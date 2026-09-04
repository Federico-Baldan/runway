# Runway — build the .app bundle around the SPM binary.
# Staying on SPM (not an Xcode project) so contributors can `git clone && make`.

BINARY   := Runway
CONFIG   := debug
BUILDDIR := .build/$(CONFIG)
APP      := $(BUILDDIR)/$(BINARY).app
CONTENTS := $(APP)/Contents

.PHONY: all build app package run demo demo-notch clean verify verify-ui diagnose spikes spikes-offline spike-run signing-identity icon snapshot

all: app

build:
	swift build -c $(CONFIG)

# Assemble a minimal LSUIElement app bundle around the built executable.
# `icon` is a prerequisite rather than something you remember to run: the
# bundle's Info.plist has always declared CFBundleIconFile, but nothing ever
# built the .icns it points at — it is generated, never committed, and no CI
# step called `make icon`. Every shipped build therefore carried a dangling
# icon reference and showed the generic app tile.
app: build icon
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BUILDDIR)/$(BINARY)" "$(CONTENTS)/MacOS/$(BINARY)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@echo "APPL????" > "$(CONTENTS)/PkgInfo"
	@# Sign with the local self-signed identity when it exists, else ad-hoc.
	@# This matters for the Keychain: an ad-hoc signature's designated
	@# requirement is the binary's cdhash, which changes on EVERY rebuild, so
	@# macOS treats each build as a new app and re-prompts for the password.
	@# A certificate-based requirement is stable. See scripts/create-signing-identity.sh
	@# Never fatal: under Homebrew's build environment a codesign failure would
	@# abort `make app` and so the whole `brew install`. An unsigned app still
	@# runs; it just re-prompts for keychain access more often.
	@if security find-certificate -c "Runway Dev" >/dev/null 2>&1; then \
		codesign --force --sign "Runway Dev" --identifier "com.runway.app" "$(APP)" 2>/dev/null \
			&& echo "  signed with 'Runway Dev' (stable identity)" \
			|| echo "  codesign failed - the app still runs"; \
	else \
		codesign --force --sign - "$(APP)" 2>/dev/null \
			&& echo "  ad-hoc signed - run 'make signing-identity' to stop keychain prompts" \
			|| echo "  codesign failed - the app still runs"; \
	fi
	@echo "built $(APP)"

run: app
	open "$(APP)"

# The shipping bundle: universal, ad-hoc signed, zipped. This is what CI
# publishes and what the Homebrew formula installs, so building it by hand is
# the way to reproduce a release locally.
package:
	@scripts/package.sh

# Scripted fake runs — no GitHub calls, no keychain, no real CI minutes.
demo: build
	@pkill -f "$(BUILDDIR)/$(BINARY)" 2>/dev/null || true
	@"$(BUILDDIR)/$(BINARY)" --demo

# Demo with a SIMULATED MacBook notch (190x32pt), so the notched layout can be
# worked on with the laptop lid closed.
demo-notch: build
	@pkill -f "$(BUILDDIR)/$(BINARY)" 2>/dev/null || true
	@"$(BUILDDIR)/$(BINARY)" --demo-notch

# Token/auth commands.
verify: build
	@"$(BUILDDIR)/$(BINARY)" verify

diagnose: build
	@"$(BUILDDIR)/$(BINARY)" --diagnose

# Stand the real panel up, print its measured frame, exit non-zero if no window
# with non-zero bounds ever appears. Must run from the bundle so LSUIElement
# applies.
verify-ui: app
	@"$(CONTENTS)/MacOS/$(BINARY)" --verify-ui

# Render the island to a PNG, for reviewing a layout change without a Mac in
# front of you.
snapshot: build
	@"$(BUILDDIR)/$(BINARY)" --snapshot island.png
	@"$(BUILDDIR)/$(BINARY)" --snapshot-notch island-notch.png

# Regression suite.
#
# Spikes are COMPILED against the real sources rather than run with `swift
# file.swift`. A spike that re-implements the logic it checks passes forever
# while the app rots; these fail when the app changes, which is the point.
API      := Sources/Runway/API
SPIKEOUT := .build/spikes

$(SPIKEOUT):
	@mkdir -p "$(SPIKEOUT)"

spikes: spikes-offline
	@echo "── auth ──"   && $(MAKE) -s spike-run SPIKE=AuthSpike  SRC="$(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift" ARGS=check
	@echo "── runs ──"   && $(MAKE) -s spike-run SPIKE=RunsSpike  SRC="$(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── schema ──" && $(MAKE) -s spike-run SPIKE=SchemaVerify SRC="$(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"

spikes-offline:
	@echo "── status ──"    && $(MAKE) -s spike-run SPIKE=StatusFusionVerify   SRC="$(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift"
	@echo "── codable ──"   && $(MAKE) -s spike-run SPIKE=CodableVerify        SRC="$(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift"
	@echo "── approvals ──" && $(MAKE) -s spike-run SPIKE=ApprovalVerify      SRC="$(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift"
	@echo "── rejections ──" && $(MAKE) -s spike-run SPIKE=RejectionVerify    SRC="$(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift"
	@echo "── environments ──" && $(MAKE) -s spike-run SPIKE=EnvironmentVerify  SRC="$(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift"
	@echo "── actors ──"    && $(MAKE) -s spike-run SPIKE=ActorFilterVerify    SRC="$(API)/RunScope.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift"
	@echo "── budget ──"    && $(MAKE) -s spike-run SPIKE=RateBudgetVerify     SRC="$(API)/ETagStore.swift $(API)/RunScope.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift"
	@echo "── cadence ──"   && $(MAKE) -s spike-run SPIKE=CadenceVerify       SRC="Sources/Runway/Core/RunMonitor.swift $(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── polls ──"    && $(MAKE) -s spike-run SPIKE=PollConcurrencyVerify SRC="Sources/Runway/Core/RunMonitor.swift $(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── errors ──"   && $(MAKE) -s spike-run SPIKE=ErrorPathVerify SRC="Sources/Runway/Core/RunMonitor.swift $(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── gates ──"    && $(MAKE) -s spike-run SPIKE=RequestGateVerify   SRC="Sources/Runway/Core/RunMonitor.swift $(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── scopes ──"    && $(MAKE) -s spike-run SPIKE=ReentrancyVerify   SRC="Sources/Runway/Core/RunMonitor.swift $(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── dismissal ──" && $(MAKE) -s spike-run SPIKE=DismissVerify      SRC="Sources/Runway/Core/DismissedRuns.swift Sources/Runway/Core/RunMonitor.swift $(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── centering ──" && $(MAKE) -s spike-run SPIKE=CenteringVerify      SRC="Sources/Runway/UI/NotchMath.swift"
	@echo "── notch ──"     && $(MAKE) -s spike-run SPIKE=NotchPlacementVerify SRC="Sources/Runway/UI/NotchMath.swift"
	@echo "── sso ──"       && $(MAKE) -s spike-run SPIKE=SSOVerify           SRC="$(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── 304 ──"      && $(MAKE) -s spike-run SPIKE=ConditionalVerify SRC="$(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"
	@echo "── dates ──"    && $(MAKE) -s spike-run SPIKE=DateVerify        SRC="$(API)/GitHubClient.swift $(API)/Models.swift $(API)/Approvals.swift $(API)/DeployTarget.swift $(API)/RunScope.swift $(API)/ETagStore.swift Sources/Runway/Auth/Keychain.swift"

# Compile one spike against the real sources, then run it.
spike-run: $(SPIKEOUT)
	@swiftc -o "$(SPIKEOUT)/$(SPIKE)" "spike/$(SPIKE).swift" $(SRC)
	@"$(SPIKEOUT)/$(SPIKE)" $(ARGS)

# Create a stable local signing identity so the keychain stops re-prompting on
# every rebuild. Run once; asks for the login password a single time.
signing-identity:
	@bash scripts/create-signing-identity.sh

# Regenerate the app icon from scripts/make-icon.swift.
icon:
	@swift scripts/make-icon.swift
	@iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
	@rm -rf AppIcon.iconset
	@echo "  built Resources/AppIcon.icns"

clean:
	rm -rf .build
