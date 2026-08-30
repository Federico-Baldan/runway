# Homebrew formula for Runway.
#
# This repository IS the tap. There is no second `homebrew-tap` repo to create
# and no token to configure: Homebrew reads formulae from a tap's `Formula/`
# directory, and `brew tap` accepts an explicit URL for repositories that are
# not named `homebrew-*`. So:
#
#     brew tap Federico-Baldan/runway https://github.com/Federico-Baldan/runway
#     brew install Federico-Baldan/runway/runway
#
# The release workflow rewrites `version`, `url` and `sha256` below on every
# tag and commits the result back to main, using the workflow's own
# GITHUB_TOKEN. Nothing to set up, and nothing to remember to do by hand.
#
# A formula, not a cask, and that distinction is the whole packaging strategy.
#
# A cask downloads an artefact somebody else already built — a .app, .dmg or
# .pkg — verifies it and moves it into place. It does not compile anything. But
# shipping a prebuilt .app needs a paid Apple Developer ID: without one the app
# can only be ad-hoc signed, and macOS refuses to open a *downloaded* ad-hoc app
# at all ("Runway is damaged and can't be opened"). An app compiled on the
# user's own machine never gets the quarantine attribute, so the problem simply
# does not arise.
#
# Compiling from a source tarball is what a formula is for.
class Runway < Formula
  desc "Live GitHub Actions runs in the macOS notch and menu bar"
  homepage "https://github.com/Federico-Baldan/runway"
  version "0.0.1"
  url "https://github.com/Federico-Baldan/runway/archive/refs/tags/v0.0.1.tar.gz"
  sha256 "cf30070eb2dd320983bc6a17b7dd1b894fc357f96c8abf9761eb679294b330c2"
  license "MIT"
  head "https://github.com/Federico-Baldan/runway.git", branch: "main"

  # Swift 6 and the macOS 14 SDK. Xcode 16 is the first release that ships a
  # Swift 6 compiler, so an older toolchain fails at `swift build` rather than
  # at install time.
  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    # Release configuration on purpose: `make app` defaults to debug for the
    # development loop, which is not what should land in someone's Cellar.
    system "make", "app", "CONFIG=release"

    prefix.install ".build/release/Runway.app"

    # A wrapper on PATH, so the CLI surface works without digging into the
    # bundle: `runway store <token>`, `runway verify`, `runway --diagnose`.
    bin.write_exec_script prefix/"Runway.app/Contents/MacOS/Runway"
  end

  def caveats
    <<~EOS
      Runway is a menu-bar app, so it is installed into the Cellar rather than
      /Applications. Launch it with:

        open #{opt_prefix}/Runway.app

      To keep it in Launchpad and Spotlight, link it into your own Applications
      folder once:

        ln -sfn #{opt_prefix}/Runway.app ~/Applications/Runway.app

      Then click the menu bar icon, open Settings, and paste a fine-grained
      GitHub token with:

        Actions   : Read
        Contents  : Read

      macOS will ask for keychain access once. That prompt is the point: the app
      cannot read your token without your consent.

      The CLI is on your PATH as `runway` — try `runway --diagnose` if the
      island never appears.
    EOS
  end

  test do
    # The binary is a GUI accessory, so the only thing safe to assert in a
    # sandbox is that it starts, parses arguments and exits. `--diagnose` needs
    # a window server; the usage path does not.
    output = shell_output("#{bin}/runway --nonsense 2>&1", 1)
    assert_match "usage: Runway", output
  end
end
