#!/usr/bin/env bash
# Cut a release: bump the version, tag, push. CI does the rest.
#
#   scripts/release.sh 0.2.0
#
# Pushing the tag triggers .github/workflows/build.yml, which builds on macOS,
# publishes a source tarball with its sha256, then rewrites Formula/runway.rb
# in this repo and commits it to main. This repo is its own Homebrew tap, so
# `brew upgrade runway` picks the new version up with no extra setup.
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

# The formula's version/url/sha256 are rewritten by CI once the tarball exists
# and its checksum is known, so nothing to do here.

git add Resources/Info.plist
git commit -m "Runway ${VERSION}"
git tag "v${VERSION}"

echo
echo "Committed and tagged v${VERSION}. Push it with:"
echo "  git push && git push origin v${VERSION}"
