# AI Usage

A native macOS menu bar app (Swift, AppKit + SwiftUI) that shows subscription and coding-plan
usage for **Claude, Codex, GLM (Zhipu / Z.ai), DeepSeek, MiniMax and Kimi**. Its look is modelled on
[coding-usage-bar](https://github.com/hanzhangzzz/coding-usage-bar):

- **Menu bar:** each account gets a provider mark and two stacked bars (5h on top, 7d below),
  coloured by usage: green below 70%, amber from 70%, coral at 90%+. Accounts are separated by thin dividers. Optionally the bars can show
  percentages, or be replaced by them.
- **Dropdown card:** one section per account, with the main percentage, 5h/7d meters with time
  left (e.g. `2d 5h`), and the time of the last update. Clicking the menu bar item refreshes.

## Accounts

**Found on this Mac (read-only).** AI Usage picks up logins other tools already have:

| Source | Provider(s) |
|---|---|
| Claude Code — `~/.claude*/.credentials.json`, Keychain `Claude Code-credentials*` | Claude |
| Codex CLI — `~/.codex*/auth.json` (`$CODEX_HOME`) | Codex |
| OpenCode — `~/.local/share/opencode/auth.json` | Claude, Codex, GLM, DeepSeek, MiniMax, Kimi |
| Pi — `~/.pi/agent/auth.json` | Claude, Codex, GLM (Z.ai) |
| Claude Code `settings.json` `env` (`ANTHROPIC_BASE_URL` pointing at GLM / Kimi / MiniMax / DeepSeek) | GLM, Kimi, MiniMax, DeepSeek |
| claude-lanes — `~/.config/claude-lanes/config.env` | same as above |

These sources are **strictly read-only**:
- Files are only opened for reading, and Keychain items are only read.
- Tokens are **never refreshed**, because refreshing would rotate the owning tool's refresh token
  and log it out. When a borrowed token expires, the card says so; open the owning tool to renew it.
- Reading Claude Code's Keychain item makes macOS ask for access. Choose **Allow**:
  **Always Allow** would change that item's access list. You can turn this source off in Settings.
- A test checks that a full discovery and poll leaves every file under `$HOME` byte-for-byte
  unchanged.

**Added in AI Usage.** Use *Accounts… → Add Account* to add any number of accounts, including
several for the same provider:
- **Claude and Codex:** sign in through the browser (OAuth with PKCE), with a localhost callback.
  If the browser can't reach this Mac, paste the code or the final URL instead.
- **GLM, DeepSeek, MiniMax and Kimi:** enter an API key. It is checked against the provider before
  it is saved.

These secrets live in AI Usage's own Keychain items (`dev.ai-usage.accounts`), and their tokens are
refreshed automatically.

AI Usage writes only to `~/Library/Application Support/ai-usage/` (account list, last snapshots), to its own Keychain items, and to its own preferences.

## Behaviour

- **Background polling:** every 5 minutes by default (1–30 minutes is configurable), plus right
  after the Mac wakes.
- **Title width:** *Auto* measures the space right of the notch (or half the menu bar). It picks all
  accounts if they fit, then the most urgent account, then a single gauge icon.
- **States:** *High* from 70%, *Limit* at 90%+. DeepSeek shows its balance instead.
- **Notifications:** sent when an account reaches 90% or its balance runs out. This can be turned
  off.

## Build

Requires macOS 14+ and Xcode 15+ (Swift 5.10+).

```sh
swift test                    # core tests (also run on Linux)
Scripts/package_app.sh        # → dist/AIUsage-<version>.zip (universal, ad-hoc signed)
open "build/AI Usage.app"
```

For a release that opens without Gatekeeper warnings, sign it with a Developer ID and notarize it:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary Scripts/package_app.sh
```

An ad-hoc build that was downloaded rather than built locally needs `xattr -dr com.apple.quarantine "AI Usage.app"`
(or right-click → Open) the first time.

CI (`.github/workflows/build.yml`) runs the core tests on Linux. On macOS it builds and zips the
app, uploads the zip as an artifact, and attaches it to `v*` tag releases.

### CLI

`ai-usage-cli [status|accounts] [--json]` uses the same core. It is bundled at
`AI Usage.app/Contents/Helpers/ai-usage-cli`.

## Layout

```
Sources/AIUsageCore   providers, local discovery, OAuth, storage (Foundation only)
Sources/AIUsage       menu bar app: status item renderer, dropdown, accounts/settings windows, login
Sources/AIUsageCLI    diagnostic CLI
Tests/                core tests incl. the read-only guarantee
Scripts/              packaging + icon generation
poc/                  original Python proof of concept
```

Caveat: the Claude and Codex usage endpoints and OAuth clients are the undocumented ones used by
the official CLIs, so they may change without notice. Provider marks are simple monograms rather
than vendor logos.
