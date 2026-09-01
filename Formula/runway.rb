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
# A formula shipping a PREBUILT app, which is an unusual combination and the
# whole packaging strategy. The three options each fail differently:
#
#   * A cask downloads a prebuilt .app — but the cask installer stamps
#     `com.apple.quarantine` on it, and Gatekeeper then refuses to open an app
#     that is not notarized. Notarization needs a $99/year Developer ID. Apps
#     in this position ship a cask anyway and tell the user to walk through
#     System Settings → Privacy & Security → Open Anyway on first launch.
#
#   * A formula that COMPILES from source, which is what this one used to do,
#     sidesteps quarantine entirely — but makes a 10 GB Xcode install the price
#     of admission for a menu-bar app, and then ad-hoc signs the result anyway,
#     so it does not even buy a stable keychain identity in exchange.
#
#   * A formula that INSTALLS a prebuilt app, which is this one. Formulae do
#     not apply quarantine, so the ad-hoc signature is never put in front of
#     Gatekeeper and the app opens on the first try, with no Xcode anywhere.
#
# The catch, and it is a real one: an ad-hoc signature's designated requirement
# is the binary's cdhash, which changes on every build. macOS therefore treats
# each upgrade as a different app and re-prompts for keychain access to reach
# the stored token. Compiling locally had exactly the same problem, so nothing
# was lost here — but it is the one thing a Developer ID would fix.
#
# Downloading Runway.zip from the releases page by hand DOES quarantine it.
# Install through brew.
class Runway < Formula
  desc "Live GitHub Actions runs in the macOS notch and menu bar"
  homepage "https://github.com/Federico-Baldan/runway"
  version "0.2.1"
  url "https://github.com/Federico-Baldan/runway/releases/download/v0.2.1/Runway.zip"
  sha256 "44653c41804490a8c535e577e829069fe2150687e6d871522e3ff207e26d290c"
  license "MIT"

  depends_on macos: :sonoma

  # Building from source is still supported, it is just no longer the default.
  # `brew install --HEAD` takes this path and needs a Swift 6 compiler, which
  # Xcode 16 is the first release to ship.
  head do
    url "https://github.com/Federico-Baldan/runway.git", branch: "main"
    depends_on xcode: ["16.0", :build]
  end

  def install
    if build.head?
      # The same script the release workflow runs, so a HEAD install and a
      # release install produce the same bundle.
      system "scripts/package.sh"
      prefix.install ".build/release/Runway.app"
    elsif File.directory?("Runway.app")
      prefix.install "Runway.app"
    else
      # Runway.zip holds exactly one top-level entry — the bundle itself — and
      # Homebrew chdirs into a lone top-level directory before `install` runs
      # (AbstractDownloadStrategy#chdir). So the working directory IS
      # Runway.app, and the plain `prefix.install "Runway.app"` this used to be
      # looked for Runway.app/Runway.app and raised ENOENT on every release
      # install. The branch above still covers an archive that grows a wrapper
      # directory or a sibling file, which would stop brew descending.
      #
      # Move the bundle's CONTENTS, not the directory we are standing in: after
      # `install` returns, brew calls prefix.install_metafiles(buildpath) to
      # sweep up LICENSE and friends, and that walks the path with no existence
      # check — moving buildpath away just trades one ENOENT for another.
      (prefix/"Runway.app").install Dir["*"]
    end

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
      GitHub token with just:

        Actions : Read

      and the repositories you want to watch selected. Runway only reads
      workflow runs — it never reads your code.

      macOS will ask for keychain access once. That prompt is the point: the app
      cannot read your token without your consent. Runway is ad-hoc signed
      rather than notarized, so that prompt comes back after each upgrade.

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
