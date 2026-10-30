# agent-quota-monitor (POC)

A small CLI that shows how much of your **Claude (Pro/Max)** and **OpenAI Codex (ChatGPT plan)**
subscription quotas you've used in the 5-hour and weekly windows. It uses only the Python standard library.

```
$ ./aqm.py
Anthropic Claude
  5h                ██░░░░░░░░░░░░░░░░░░░░░░   7.0%  resets in 4h 36m (Fri 14:59)
  1w                ███░░░░░░░░░░░░░░░░░░░░░  11.0%  resets in 6d 0h (Thu 10:59)
  via aqm login

OpenAI Codex (plus)
  5h                ██████████░░░░░░░░░░░░░░  42.0%  resets in 1h 23m (Fri 11:46)
  1w                █████████████████████░░░  88.0%  resets in 3d 11h (Mon 21:43)
  via aqm login
```

## Usage

```sh
./aqm.py login claude          # opens browser, OAuth+PKCE, redirect to a random localhost port
./aqm.py login codex           # opens browser, redirect to localhost:1455 (fixed by OpenAI's client)
./aqm.py                       # show quotas (same as `status`)
./aqm.py --json -p codex       # JSON, one provider
./aqm.py logout [claude|codex]
```

Or install it: `pip install -e .` gives you an `aqm` command.

### Headless / remote machines

- **Claude:** `aqm login claude --no-browser` uses Anthropic's hosted callback page. It displays
  a `code#state` string, and you paste that into the terminal.
- **Codex:** the browser redirects to `http://localhost:1455/...`, which fails to load when the
  browser is on another machine. Copy that URL from the address bar and paste it into the terminal.
  You can also forward the port with `ssh -L 1455:localhost:1455 host`.

### Credentials

- Tokens from `aqm login` are stored in `~/.config/agent-quota-monitor/credentials.json` (mode 600)
  and refreshed automatically. Set `AQM_CONFIG_DIR` to use a different directory.
- If you haven't run `aqm login`, it falls back **read-only** to tokens that Claude Code
  (`~/.claude/.credentials.json`) or Codex CLI (`~/.codex/auth.json`) already stored. It never
  refreshes those tokens: refreshing would rotate the refresh token and log the official CLI out.

## How it works

| | Claude | Codex |
|---|---|---|
| OAuth client | Claude Code public client | Codex CLI public client |
| Authorize | `claude.ai/oauth/authorize` | `auth.openai.com/oauth/authorize` |
| Token | `console.anthropic.com/v1/oauth/token` (override: `AQM_CLAUDE_TOKEN_URL`) | `auth.openai.com/oauth/token` |
| Usage | `GET api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) → `five_hour`, `seven_day` | `GET chatgpt.com/backend-api/wham/usage` (+ `ChatGPT-Account-Id`) → `rate_limit.primary_window` / `secondary_window` |

Codex windows are matched to 5h or 1w by `limit_window_seconds`, not by the order they come back in.

**Caveat:** these are undocumented endpoints used by the official CLIs. They may change or break
without notice.
