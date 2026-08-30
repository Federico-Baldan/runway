#!/usr/bin/env bash
# Cut a release: bump the version, tag, push. CI does the rest.
#
#   scripts/release.sh 0.2.0
#
# Pushing the tag triggers .github/workflows/build.yml, which builds on macOS,
# publishes a source tarball with its sha256, and — if TAP_GITHUB_TOKEN is set —
# rewrites the formula in <owner>/homebrew-tap so `brew upgrade` picks it up.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
  echo "usage: scripts/release.sh <version>   e.g. 0.2.0" >&2
  exit 1
fi
if ! [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must be three numbers, e.g. 0.2.0" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "working tree is dirty — commit or stash first." >&2
  exit 1
fi

echo "Setting version to ${VERSION}…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Resources/Info.plist

# Keep the formula template honest, even though CI rewrites the tap's copy.
sed -i '' -E "s|/archive/refs/tags/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz|/archive/refs/tags/v${VERSION}.tar.gz|" \
  packaging/homebrew/runway.rb

git add Resources/Info.plist packaging/homebrew/runway.rb
git commit -m "Runway ${VERSION}"
git tag "v${VERSION}"

echo
echo "Committed and tagged v${VERSION}. Push it with:"
echo "  git push && git push origin v${VERSION}"
