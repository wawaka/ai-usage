# AGENTS.md

Guidance for coding agents (Codex, Claude Code, Cursor, …) working in this repository.

AI Usage is a native macOS menu bar app (Swift 6.2+ package; AppKit + SwiftUI; runs on macOS 14+). It shows subscription and coding-plan usage for Claude, Codex, GLM, DeepSeek, MiniMax and Kimi.

## Commands

```sh
swift test                                   # core tests (macOS or Linux)
swift test --filter PollingTests             # one test class
swift test --filter PollingTests/testRateLimitHonoursRetryAfterAndBlocksRequests   # one test
Scripts/dev.sh                               # macOS: debug build, quit running app, replace build/AI Usage.app, relaunch
SIGN_IDENTITY="AI Usage Dev" Scripts/dev.sh  # same, with a stable signature (avoids repeated Keychain prompts)
Scripts/package_app.sh                       # universal release build → dist/AIUsage-<version>.zip
python3 Scripts/embed_marks.py               # regenerate Sources/AIUsage/ProviderIcons.swift from Assets/ProviderMarks/*.svg (needs rsvg-convert)
```

Off a Mac (e.g. a Linux sandbox), only `AIUsageCore` and its tests build. Run them in Docker, and syntax-check the app sources:

```sh
docker run --rm -v "$PWD":/src -w /src swift:6.4-noble bash -c "swift test --build-path /tmp/build"
docker run --rm -v "$PWD":/src -w /src swift:6.4-noble swiftc -parse Sources/AIUsage/*.swift
```

`Package.swift` declares the `AIUsage` app target only inside `#if os(macOS)`. `AIUsageCore`, the CLI and the tests use the Swift 6 language mode (strict concurrency). The app target stays in Swift 5 mode, because it can't be compiled off a Mac to audit it. CI (`.github/workflows/build.yml`) runs the core tests on Linux. On macOS it also packages the app; `v*` tags attach the zip to a release.

## Architecture

There are three targets:
- **`AIUsageCore`** (Foundation only): all logic.
- **`AIUsage`**: the menu bar app UI.
- **`ai-usage-cli`** (`Sources/AIUsageCLI`): a diagnostic CLI on the same core. It is bundled at `Contents/Helpers/ai-usage-cli`.

The CLI source directory is not called `aiusage` because the repo sits on a case-insensitive filesystem, where `Sources/aiusage` and `Sources/AIUsage` collide.

**Data flow.**
1. `LocalDiscovery` finds credentials other tools already have.
2. `UsageService` (an actor) merges them with accounts added in the app. It owns account state and polling.
3. `UsageFetcher` (`Providers.swift`) dispatches to a parser/fetcher for each provider. It turns HTTP JSON into a `UsageSnapshot` (5h/7d `UsageWindow`s, extra windows, or a `Balance`).
4. `AppModel` (`@MainActor`) publishes `[AccountStatus]` to the views.
5. `StatusItemController` + `TitleRenderer` draw the menu bar image natively. `PanelView` is the popover. `AccountsView.swift` also contains the Accounts and Settings windows and the login sheets.

**Account sources.**
- **Local accounts** (`AccountOrigin.local`) are discovered read-only from these sources:
  - `~/.claude*/.credentials.json`, or the Keychain `Claude Code-credentials*` items
  - `~/.codex*/auth.json`
  - OpenCode and Pi `auth.json`
  - Claude Code `settings.json` env blocks
  - claude-lanes
- **Managed accounts** come from an OAuth login (`OAuth.swift` + `LoginController.swift`, a loopback NWListener with a paste fallback) or an API key. Their secrets are stored through `SecretStore`, which is `KeychainSecretStore` on macOS.

**Polling** is adaptive per account and lives in `UsageService`, not the app.
- Each account has a `PollState`. The interval doubles while `usageDiffers` is false and resets to `PollPolicy.minInterval` on a change. A poll is pulled forward to just after a window's reset.
- `UsageError.rateLimited` comes from HTTP 429 with `Retry-After`, or from provider codes (GLM 1302/1303, MiniMax 1002). It sets `blockedUntil`, which refuses even manual refreshes.
- `AppModel` only ticks every 30 s, asking `dueAccounts()`. Opening the popover does not poll.
- The schedule is persisted in `schedule.json`, so launch and wake honour intervals and rate limits. Without an entry, an account is due `minInterval` after its saved snapshot's `observedAt`.

## Hard rules

- **Local credentials are strictly read-only.**
  - Never write, refresh or rotate another tool's token or file. Refreshing would rotate that tool's refresh token and log it out.
  - An expired or 401 local token becomes `UsageError.expiredLocalToken`.
  - Only managed tokens get refreshed.
  - `testPollingNeverWritesOrRefreshesLocalCredentials` checks that `$HOME` stays byte-for-byte unchanged.
- **The app writes only to its own state:** `~/Library/Application Support/ai-usage/` (`accounts.json`, `snapshots.json`, `schedule.json`; overridable with `AI_USAGE_HOME`), its own Keychain items (`dev.ai-usage.accounts`, `dev.ai-usage.borrowed`), and its UserDefaults.
- **Keychain access is built to prompt as rarely as possible** (`Keychain.swift`).
  - Each item is attempted once per run, and denials are persisted.
  - A borrowed token is copied into AI Usage's own item.
  - An expired borrowed token is re-read at most once ever (hash in `AccountsState.recheckedExpiredTokens`).
  - Keep these properties when touching discovery or fetch code; a regression shows up as repeated macOS access prompts.
- **Paths:** use `AppPaths.userHome`, not `homeDirectoryForCurrentUser`, so tests can redirect `$HOME`.

## Conventions and gotchas

- **No `@State`:** the user builds with only the Command Line Tools, which lack the SwiftUI macro plugin. Hold view state in small `ObservableObject` classes (`Flag`, `AccountsUIState`, …) with `@StateObject`/`@ObservedObject`.
- **Entry point:** `main.swift` starts the app inside `MainActor.assumeIsolated`.
- **Persisted state:** `AccountsState` uses a custom `init(from:)` with `decodeIfPresent`. Add new fields the same way so older `accounts.json` files still load.
- **Provider marks** are vector PDFs embedded as base64 in the generated `ProviderIcons.swift`. Don't edit that file by hand. The SVG sources and trademark notice are in `Assets/ProviderMarks/`.
- **Undocumented endpoints:** the Claude and Codex usage endpoints and OAuth clients are the ones the official CLIs use, so they may change without notice.
