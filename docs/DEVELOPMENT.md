# Development

Building requires Xcode 26+ or its Command Line Tools (Swift 6.2+). The app itself runs on macOS 14+. Architecture notes and
project rules for coding agents are in [AGENTS.md](../AGENTS.md).

## Layout

```
Sources/AIUsageCore   providers, local discovery, OAuth, polling, storage (Foundation only)
Sources/AIUsage       menu bar app: title renderer, dropdown, accounts/settings windows, login
Sources/AIUsageCLI    diagnostic CLI
Tests/                core tests, including the read-only guarantee
Scripts/              dev loop, packaging, icon generation
Assets/ProviderMarks  provider logo SVGs
Packaging/            Info.plist
```

## Build and test

```sh
swift test                                           # core tests (also run on Linux)
swift test --filter PollingTests                     # one test class
Scripts/dev_rebuild_and_relaunch.sh                  # debug build → replaces and relaunches build/AI Usage.app
CONFIG=release Scripts/dev_rebuild_and_relaunch.sh   # same, optimised
Scripts/package_app.sh                               # Apple Silicon release build → dist/AIUsage-<version>.zip
```

Release builds are Apple Silicon only. The code still builds for Intel: `ARCHS="arm64 x86_64" Scripts/package_app.sh`
produces a universal app, but it's untested on Intel Macs.

`Scripts/dev_rebuild_and_relaunch.sh` quits whichever copy of AI Usage is running, wherever it was
launched from, then starts the fresh build. It builds with Xcode's toolchain (/Applications/Xcode.app),
because the Command Line Tools lack prebuilt SDK modules and make each rebuild take about 18 s instead of
about 1.3 s; it fails if Xcode is missing. The script's header lists the measured alternatives.

## Signing for development

When you answer *Always Allow*, Keychain remembers the app by its Team ID if it has one, and
otherwise by the hash of that exact build. Without a Team ID, every rebuild is a new app to Keychain
and it asks again, even with a stable self-signed certificate.

`Scripts/dev_rebuild_and_relaunch.sh` therefore signs with your **Apple Development** certificate when
one is installed. It's free with any Apple ID: in Xcode, Settings → Accounts → add the Apple ID →
Manage Certificates → + → Apple Development. (If Xcode says "Failed to retrieve development teams",
sign in once at developer.apple.com and accept the agreement.) Check it with
`security find-identity -v -p codesigning | grep "Apple Development"`. After the first *Always Allow*,
rebuilds stop prompting.

Without one, the script falls back to a self-signed certificate it generates into `.dev-signing/`
(git-ignored, with its own keychain; `Scripts/dev_cert.sh` regenerates it) and warns that Keychain will
keep asking. `SIGN_IDENTITY="…" Scripts/dev_rebuild_and_relaunch.sh` overrides both. Releases are signed
with the same Apple Development certificate, from a repo secret (see [RELEASE.md](RELEASE.md)), never
with the self-signed one.

## Releases

Releases are published by `.github/workflows/release.yml` on a `v*` tag and installed with
`brew install --cask wawaka/tap/ai-usage`. See [RELEASE.md](RELEASE.md) for the one-time setup
(certificate, secrets, tap), the per-release steps and yearly certificate renewal.

CI (`.github/workflows/build.yml`) runs the core tests on Linux, and on macOS builds an ad-hoc signed
zip, uploaded as the `AIUsage-zip` artifact of each run.

## CLI

`ai-usage-cli [status|accounts] [--json]` uses the same core as the app. It's handy for checking
discovery and provider responses. It's bundled at `AI Usage.app/Contents/Helpers/ai-usage-cli`, or
you can run it with `swift run ai-usage-cli`.

## Provider marks

`Assets/ProviderMarks/*.svg` come from [Lobe Icons](https://github.com/lobehub/lobe-icons) (MIT).
See `NOTICE.md` there for the trademark note. They're embedded as vector PDFs in
`Sources/AIUsage/ProviderIcons.swift`. After changing an SVG, regenerate it:

```sh
brew install librsvg       # once, for rsvg-convert
Scripts/embed_marks.py
```
