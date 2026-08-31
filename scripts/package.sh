#!/usr/bin/env bash
# Build the shipping .app: universal, ad-hoc signed, zipped for a release.
#
# This is what `brew install` consumes. It used to compile on the user's own
# machine, which made a 10 GB Xcode install the price of admission for a
# menu-bar app. The binary is built here instead and the formula just unpacks
# it — see Formula/runway.rb.
#
# Ad-hoc signed (`codesign --sign -`) because a Developer ID costs $99/year.
# That is enough for the binary to RUN — arm64 refuses to execute anything
# unsigned — but not to be notarized, and notarization is what silences the
# "unidentified developer" wall. The wall only appears for a QUARANTINED file,
# and Homebrew applies quarantine from casks, not from formulae, so an app
# installed by the formula launches straight away. The same zip downloaded by
# hand from the releases page IS quarantined and does hit the wall; that is why
# the release notes point at brew rather than at the asset.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

APP=".build/release/Runway.app"
ZIP="Runway.zip"
ARM64_SCRATCH=".build-arm64"
X86_64_SCRATCH=".build-x86_64"

# Two single-arch builds and a lipo, rather than one `swift build --arch arm64
# --arch x86_64`. The combined form shares a scratch directory between the two
# slices, and the second pass can then link against the first one's artefacts.
# Separate scratch paths make each build independent.
echo "Building arm64..."
swift build -c release --arch arm64 --scratch-path "$ARM64_SCRATCH"
echo "Building x86_64..."
swift build -c release --arch x86_64 --scratch-path "$X86_64_SCRATCH"

# The icon is generated, never committed, and a tag build checks out a clean
# tree — so on the release path there is nothing to copy unless it is drawn
# here. `make app` builds it, but a tag build never runs `make app`; it runs
# this script. Every release before 0.1.4 therefore shipped without an icon:
# the copy below used to be guarded by `if [ -f ]` and quietly did nothing,
# and Info.plist has always pointed CFBundleIconFile at a file that was not
# in the bundle. Unguarded on purpose — a missing icon should stop the build,
# not slip into a release.
echo "Drawing the icon..."
make icon

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Runway" \
  "$ARM64_SCRATCH/release/Runway" \
  "$X86_64_SCRATCH/release/Runway"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --deep because the bundle is signed as a whole after the binary is swapped in.
echo "Ad-hoc signing..."
codesign --force --deep --sign - --identifier com.runway.app "$APP"
codesign --verify --deep --strict "$APP"

# ditto, not zip: a plain `zip` silently drops the extended attributes that the
# code signature lives in, and the unpacked app then refuses to launch.
echo "Packing ${ZIP}..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "architectures: $(lipo -archs "$APP/Contents/MacOS/Runway")"
echo "signature:     $(codesign -dv "$APP" 2>&1 | grep -i '^Signature' || echo 'ad-hoc')"
shasum -a 256 "$ZIP"
