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
swift test                           # core tests (also run on Linux)
swift test --filter PollingTests     # one test class
Scripts/dev.sh                       # debug build → replaces and relaunches build/AI Usage.app
CONFIG=release Scripts/dev.sh        # same, optimised
Scripts/package_app.sh               # universal release build → dist/AIUsage-<version>.zip
```

`Scripts/dev.sh` quits whichever copy of AI Usage is running, wherever it was launched from, then
starts the fresh build.

## Signing for development

By default, builds are signed ad hoc. macOS then treats every rebuild as a new app and asks for
Keychain access again. To avoid that, create a stable self-signed identity once:

1. In **Keychain Access**, choose **Certificate Assistant → Create a Certificate…**.
2. Name it `AI Usage Dev`, with Identity Type *Self-Signed Root* and Certificate Type *Code Signing*.
3. Build with `SIGN_IDENTITY="AI Usage Dev" Scripts/dev.sh`.

The first time, answer *Always Allow* for AI Usage's own `dev.ai-usage.*` items.

## Releases

For a release that opens without Gatekeeper warnings, sign it with a Developer ID and notarize it:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary Scripts/package_app.sh
```

Without that, users of a downloaded build need right-click → Open, or
`xattr -dr com.apple.quarantine "AI Usage.app"`, the first time.

CI (`.github/workflows/build.yml`):
- Runs the core tests on Linux.
- Builds and zips the app on macOS and uploads the zip as the `AIUsage-zip` artifact of each run.
- On a `v*` tag, attaches the zip to that GitHub release.

The version comes from `VERSION`.

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
