# How AI Usage works

## Where accounts come from

### Found on this Mac (read-only)

| Source | Provider(s) |
|---|---|
| Claude Code: `~/.claude*/.credentials.json`, Keychain `Claude Code-credentials*` | Claude |
| Codex CLI: `~/.codex*/auth.json` (`$CODEX_HOME`) | Codex |
| OpenCode: `~/.local/share/opencode/auth.json` | Claude, Codex, GLM, DeepSeek, MiniMax, Kimi |
| Pi: `~/.pi/agent/auth.json` | Claude, Codex, GLM (Z.ai) |
| Claude Code `settings.json` `env` (`ANTHROPIC_BASE_URL` pointing at GLM / Kimi / MiniMax / DeepSeek) | GLM, Kimi, MiniMax, DeepSeek |
| claude-lanes: `~/.config/claude-lanes/config.env` | same as above |

Each account's card in the dropdown shows which of these it came from.

These sources are **strictly read-only**:
- Files are only opened for reading, and Keychain items are only read.
- **Tokens are never refreshed.** Refreshing would rotate the owning tool's refresh token and log
  it out. An expired or rejected token is reported on the card instead.
- A test checks that a full discovery and poll leaves every file under `$HOME` byte-for-byte unchanged.

### Keychain access

Reading Claude Code's Keychain item makes macOS ask for access. AI Usage keeps the number of prompts
as low as possible:
- **Allow vs Always Allow:** answering *Allow* leaves Claude Code's item and its access list
  untouched. *Always Allow* would add AI Usage to that list.
- **Own copy:** after a successful read, AI Usage keeps a copy of the token in its own item
  (`dev.ai-usage.borrowed`), so later launches don't need to ask.
- **Expired tokens:** an expired token is re-read from Claude Code's item at most once, to pick up
  a renewed login. This is tracked by a hash of the token.
- **One attempt per run:** each item is tried at most once per run.
- **Denials:** a denial is remembered until you press *Try again* in Accounts or turn the
  source back on in Settings.

Each build signed differently looks like a new app to macOS, so expect prompts again after
rebuilding with ad-hoc signing (see [DEVELOPMENT.md](DEVELOPMENT.md#signing-for-development)).

### Added in AI Usage

- **Claude and Codex:** OAuth with PKCE through the browser, with a localhost callback (Codex uses
  the fixed port 1455) or by pasting the code.
- **GLM, DeepSeek, MiniMax and Kimi:** API keys, validated against the provider before saving.

These secrets are stored in AI Usage's own Keychain items (`dev.ai-usage.accounts`). Their OAuth
tokens are refreshed automatically.

## Polling

Each account has its own schedule:
- **While usage changes:** it's checked every *minimum* interval (default 2 min).
- **While it doesn't:** each check that returns the same numbers, or fails, doubles the wait, up to
  the *maximum* (default 30 min). A change resets it to the minimum.
- **After a reset:** it's checked about 30 s after one of its windows resets.
- **Relaunch and wake:** the schedule is saved, so a relaunch or wake shows the saved numbers and
  fetches only accounts whose interval has passed. Opening the dropdown never polls.

**Rate limits.** HTTP 429 from any provider counts as a rate limit, as do GLM codes 1302/1303 and
MiniMax code 1002. The account keeps its last numbers and shows when the next try is.
- **With `Retry-After`:** nothing is sent until that time has passed, not even on a manual refresh.
- **Without it:** there's a 2-minute cooldown, then the normal back-off applies.

## Display

- **States:** *High* from 70% and *Limit* at 90%+ of the most-used window. DeepSeek shows its balance instead.
- **Title width:** *Auto* measures the space to the right of the notch, or half the menu bar on
  displays without one. It shows all accounts if they fit, then only the most urgent account, then
  a single gauge icon.
- **Usage refresh guide:** the cursor sits at the fraction of the window's time that has elapsed,
  or remained when *Show remaining* is on.
- **Notifications** are sent once when an account reaches 90% or its balance runs out.

## Files AI Usage writes

| Where | What |
|---|---|
| `~/Library/Application Support/ai-usage/accounts.json` | added accounts, hidden/renamed/order, menu bar choices |
| `~/Library/Application Support/ai-usage/snapshots.json` | last numbers per account |
| `~/Library/Application Support/ai-usage/schedule.json` | next check and rate-limit wait per account |
| Keychain `dev.ai-usage.accounts`, `dev.ai-usage.borrowed` | secrets of added accounts, copies of borrowed tokens |
| Preferences `dev.ai-usage.app` | settings |
