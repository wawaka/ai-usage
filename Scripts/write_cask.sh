#!/usr/bin/env bash
# Prints the Homebrew cask for a release (the release workflow writes it into the tap):
#
#   Scripts/write_cask.sh <version> <sha256 of AIUsage-<version>.zip> [owner/repo]
set -euo pipefail

VERSION="$1"
SHA="$2"
REPO="${3:-wawaka/ai-usage}"

cat <<EOF
cask "ai-usage" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/AIUsage-#{version}.zip"
  name "AI Usage"
  desc "Menu bar app showing subscription and coding-plan usage for AI tools"
  homepage "https://github.com/$REPO"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "AI Usage.app"

  # The app isn't notarized: clear the quarantine flag so Gatekeeper doesn't block its first launch.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/AI Usage.app"]
  end

  uninstall quit: "dev.ai-usage.app"

  zap trash: [
    "~/Library/Application Support/ai-usage",
    "~/Library/Preferences/dev.ai-usage.app.plist",
  ]
end
EOF
