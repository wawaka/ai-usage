#!/usr/bin/env python3
"""agent-quota-monitor (POC): show Claude and Codex subscription quotas (5h / 1w).

Stdlib only. Usage:
    aqm.py login claude|codex [--no-browser]
    aqm.py logout [claude|codex]
    aqm.py [status] [--json]
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timezone
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("AQM_CONFIG_DIR", Path.home() / ".config" / "agent-quota-monitor"))
CREDS_FILE = CONFIG_DIR / "credentials.json"

# Public OAuth clients used by the official CLIs (Claude Code / Codex CLI).
CLAUDE = {
    "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
    "authorize_url": "https://claude.ai/oauth/authorize",
    "token_url": os.environ.get("AQM_CLAUDE_TOKEN_URL", "https://console.anthropic.com/v1/oauth/token"),
    "manual_redirect": "https://console.anthropic.com/oauth/code/callback",
    "scope": "org:create_api_key user:profile user:inference",
    "usage_url": "https://api.anthropic.com/api/oauth/usage",
}
CODEX = {
    "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
    "authorize_url": "https://auth.openai.com/oauth/authorize",
    "token_url": "https://auth.openai.com/oauth/token",
    "port": 1455,  # the Codex client only accepts this redirect port
    "scope": "openid profile email offline_access",
    "usage_url": "https://chatgpt.com/backend-api/wham/usage",
}
USER_AGENT = "agent-quota-monitor/0.1"


class AuthError(Exception):
    pass


# ---------------------------------------------------------------- storage

def load_creds() -> dict:
    try:
        return json.loads(CREDS_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_creds(creds: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CREDS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(creds, indent=2))
    tmp.chmod(0o600)
    tmp.replace(CREDS_FILE)


def external_creds(provider: str) -> dict | None:
    """Read-only fallback to tokens already stored by the official CLIs.

    These are never refreshed by us: refreshing rotates the refresh token and
    would log the official CLI out.
    """
    try:
        if provider == "claude":
            data = json.loads((Path.home() / ".claude" / ".credentials.json").read_text())["claudeAiOauth"]
            return {"access_token": data["accessToken"], "expires_at": data.get("expiresAt", 0) / 1000,
                    "source": "~/.claude/.credentials.json"}
        data = json.loads((Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "auth.json").read_text())
        tok = data["tokens"]
        return {"access_token": tok["access_token"], "account_id": tok.get("account_id"),
                "expires_at": jwt_claims(tok["access_token"]).get("exp", 0), "source": "~/.codex/auth.json"}
    except (FileNotFoundError, KeyError, json.JSONDecodeError, TypeError):
        return None


# ---------------------------------------------------------------- http helpers

def request(method: str, url: str, headers: dict | None = None, body: bytes | None = None) -> dict:
    req = urllib.request.Request(url, data=body, method=method,
                                 headers={"User-Agent": USER_AGENT, "Accept": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        if e.code in (401, 403):
            raise AuthError(f"HTTP {e.code}: {detail}") from None
        raise RuntimeError(f"HTTP {e.code} from {url}: {detail}") from None


def post_json(url: str, payload: dict) -> dict:
    return request("POST", url, {"Content-Type": "application/json"}, json.dumps(payload).encode())


def post_form(url: str, payload: dict) -> dict:
    return request("POST", url, {"Content-Type": "application/x-www-form-urlencoded"},
                urllib.parse.urlencode(payload).encode())


def jwt_claims(token: str) -> dict:
    try:
        part = token.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except (IndexError, ValueError):
        return {}


def pkce() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


# ---------------------------------------------------------------- browser auth

class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    result: dict = {}
    path_expected = "/callback"

    def do_GET(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != self.path_expected:
            self.send_response(404)
            self.end_headers()
            return
        type(self).result = dict(urllib.parse.parse_qsl(parsed.query))
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"<h2>agent-quota-monitor: login complete. You can close this tab.</h2>")

    def log_message(self, *args):
        pass


def browser_login(auth_url: str, port: int, path: str, manual_hint: str, no_browser: bool) -> dict:
    """Open auth_url and wait for the localhost redirect, or accept a pasted redirect URL / code."""
    handler = type("Handler", (_CallbackHandler,), {"result": {}, "path_expected": path})
    server = None
    try:
        server = http.server.HTTPServer(("127.0.0.1", port), handler)
    except OSError as e:
        print(f"! could not listen on localhost:{port} ({e}); falling back to paste mode", file=sys.stderr)

    print("\nOpen this URL to authenticate:\n\n  " + auth_url + "\n")
    if not no_browser:
        webbrowser.open(auth_url)

    if server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"Waiting for browser redirect on http://localhost:{server.server_port}{path} ...")
        print(f"(If the browser runs on another machine, {manual_hint} and press Enter.)")

    # Wait for either the local callback or pasted input, whichever comes first.
    pasted: list[str] = []

    def read_stdin():
        try:
            pasted.append(input("> ").strip())
        except EOFError:
            pass

    threading.Thread(target=read_stdin, daemon=True).start()
    deadline = time.time() + 300
    while time.time() < deadline and not handler.result and not pasted:
        time.sleep(0.2)
    if server:
        server.shutdown()

    if handler.result:
        return handler.result
    if pasted and pasted[0]:
        return parse_pasted(pasted[0])
    raise SystemExit("login timed out")


def parse_pasted(text: str) -> dict:
    """Accept a full redirect URL, a query string, or Anthropic's `code#state`."""
    if "://" in text or text.startswith("?") or "code=" in text:
        query = urllib.parse.urlparse(text).query if "://" in text else text.lstrip("?")
        return dict(urllib.parse.parse_qsl(query))
    code, _, state = text.partition("#")
    return {"code": code, "state": state}


def check_callback(result: dict, state: str) -> str:
    if "error" in result:
        raise SystemExit(f"authorization failed: {result.get('error')} {result.get('error_description', '')}")
    if result.get("state") and result["state"] != state:
        raise SystemExit("state mismatch; aborting")
    if not result.get("code"):
        raise SystemExit("no authorization code received")
    return result["code"]


def login_claude(no_browser: bool) -> dict:
    verifier, challenge = pkce()
    state = secrets.token_urlsafe(32)
    # Use a free port picked up front so the redirect_uri matches the listener.
    port = 0 if no_browser else _free_port()
    redirect = CLAUDE["manual_redirect"] if no_browser else f"http://localhost:{port}/callback"
    params = {
        "code": "true", "client_id": CLAUDE["client_id"], "response_type": "code",
        "redirect_uri": redirect, "scope": CLAUDE["scope"],
        "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
    }
    url = CLAUDE["authorize_url"] + "?" + urllib.parse.urlencode(params)
    if no_browser:
        print("\nOpen this URL in any browser, authorize, then paste the shown code here:\n\n  " + url + "\n")
        result = parse_pasted(input("code> ").strip())
    else:
        result = browser_login(url, port, "/callback", "use `aqm login claude --no-browser` instead", False)
    code = check_callback(result, state)
    tok = post_json(CLAUDE["token_url"], {
        "grant_type": "authorization_code", "code": code, "state": state,
        "client_id": CLAUDE["client_id"], "redirect_uri": redirect, "code_verifier": verifier,
    })
    return _token_record(tok)


def login_codex(no_browser: bool) -> dict:
    verifier, challenge = pkce()
    state = secrets.token_urlsafe(32)
    redirect = f"http://localhost:{CODEX['port']}/auth/callback"
    params = {
        "response_type": "code", "client_id": CODEX["client_id"], "redirect_uri": redirect,
        "scope": CODEX["scope"], "code_challenge": challenge, "code_challenge_method": "S256",
        "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true",
        "state": state, "originator": "codex_cli_rs",
    }
    url = CODEX["authorize_url"] + "?" + urllib.parse.urlencode(params)
    result = browser_login(url, CODEX["port"], "/auth/callback",
                           "copy the final localhost URL from the address bar, paste it here", no_browser)
    code = check_callback(result, state)
    tok = post_form(CODEX["token_url"], {
        "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
        "client_id": CODEX["client_id"], "code_verifier": verifier,
    })
    rec = _token_record(tok)
    rec["account_id"] = _codex_account_id(tok.get("id_token", "")) or _codex_account_id(tok["access_token"])
    return rec


def _free_port() -> int:
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _codex_account_id(jwt: str) -> str | None:
    return jwt_claims(jwt).get("https://api.openai.com/auth", {}).get("chatgpt_account_id")


def _token_record(tok: dict, old: dict | None = None) -> dict:
    rec = dict(old or {})
    rec.update({
        "access_token": tok["access_token"],
        "refresh_token": tok.get("refresh_token") or rec.get("refresh_token"),
        "expires_at": time.time() + int(tok.get("expires_in", 3600)),
    })
    return rec


# ---------------------------------------------------------------- token refresh

def refresh(provider: str, rec: dict) -> dict:
    if not rec.get("refresh_token"):
        raise AuthError("token expired and no refresh token; run `login` again")
    if provider == "claude":
        tok = post_json(CLAUDE["token_url"], {"grant_type": "refresh_token",
                                              "refresh_token": rec["refresh_token"],
                                              "client_id": CLAUDE["client_id"]})
    else:
        tok = post_json(CODEX["token_url"], {"grant_type": "refresh_token", "refresh_token": rec["refresh_token"],
                                             "client_id": CODEX["client_id"], "scope": "openid profile email"})
    return _token_record(tok, rec)


def get_token(provider: str, force_refresh: bool = False) -> dict:
    creds = load_creds()
    rec = creds.get(provider)
    if rec:
        if force_refresh or rec.get("expires_at", 0) < time.time() + 60:
            rec = creds[provider] = refresh(provider, rec)
            save_creds(creds)
        rec["source"] = "aqm login"
        return rec
    ext = external_creds(provider)
    if ext:
        return ext
    raise AuthError(f"not logged in; run `aqm login {provider}`")


# ---------------------------------------------------------------- usage fetch

def fetch_claude(tok: dict) -> dict:
    data = request("GET", CLAUDE["usage_url"], {
        "Authorization": f"Bearer {tok['access_token']}",
        "anthropic-beta": "oauth-2025-04-20",
    })

    def win(w):
        if not w:
            return None
        return {"used_percent": float(w.get("utilization") or 0), "resets_at": _parse_iso(w.get("resets_at"))}

    extra = {k: win(data.get(k)) for k in ("seven_day_opus", "seven_day_sonnet") if data.get(k)}
    return {"5h": win(data.get("five_hour")), "1w": win(data.get("seven_day")), "extra": extra}


def fetch_codex(tok: dict) -> dict:
    headers = {"Authorization": f"Bearer {tok['access_token']}"}
    if tok.get("account_id"):
        headers["ChatGPT-Account-Id"] = tok["account_id"]
    data = request("GET", CODEX["usage_url"], headers)
    rl = data.get("rate_limit") or {}
    out: dict = {"5h": None, "1w": None, "plan": data.get("plan_type"), "extra": {}}
    for key in ("primary_window", "secondary_window"):
        w = rl.get(key)
        if not w:
            continue
        secs = w.get("limit_window_seconds") or 0
        reset = w.get("reset_at")
        if reset is None and w.get("reset_after_seconds") is not None:
            reset = time.time() + w["reset_after_seconds"]
        entry = {"used_percent": float(w.get("used_percent") or 0),
                 "resets_at": datetime.fromtimestamp(reset, timezone.utc) if reset else None}
        # Classify by window length rather than trusting primary/secondary order.
        label = "5h" if secs and secs <= 6 * 3600 else "1w" if secs and secs >= 6 * 86400 else key
        if label in ("5h", "1w"):
            out[label] = entry
        else:
            out["extra"][f"{secs // 3600}h" if secs else key] = entry
    return out


FETCHERS = {"claude": fetch_claude, "codex": fetch_codex}


def fetch(provider: str) -> dict:
    try:
        tok = get_token(provider)
        try:
            result = FETCHERS[provider](tok)
        except AuthError:
            if tok.get("source") != "aqm login":
                raise
            result = FETCHERS[provider](get_token(provider, force_refresh=True))
        result["source"] = tok.get("source")
        return result
    except (AuthError, RuntimeError, urllib.error.URLError, OSError) as e:
        return {"error": str(e)}


def _parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


# ---------------------------------------------------------------- display

def _bar(pct: float, width: int = 24) -> str:
    filled = round(min(max(pct, 0), 100) / 100 * width)
    color = "32" if pct < 60 else "33" if pct < 85 else "31"
    bar = "█" * filled + "░" * (width - filled)
    return f"\033[{color}m{bar}\033[0m" if sys.stdout.isatty() else bar


def _until(dt: datetime | None) -> str:
    if not dt:
        return ""
    secs = int((dt - datetime.now(timezone.utc)).total_seconds())
    if secs <= 0:
        return "resets now"
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    span = f"{d}d {h}h" if d else f"{h}h {m:02d}m" if h else f"{m}m"
    return f"resets in {span} ({dt.astimezone().strftime('%a %H:%M')})"


def render(results: dict) -> None:
    names = {"claude": "Anthropic Claude", "codex": "OpenAI Codex"}
    for provider, r in results.items():
        title = names[provider]
        if r.get("plan"):
            title += f" ({r['plan']})"
        print(f"\n{title}")
        if "error" in r:
            print(f"  error: {r['error']}")
            continue
        rows = [("5h", r.get("5h")), ("1w", r.get("1w"))] + list(r.get("extra", {}).items())
        for label, w in rows:
            if w is None:
                print(f"  {label:<17} n/a")
                continue
            print(f"  {label:<17} {_bar(w['used_percent'])} {w['used_percent']:5.1f}%  {_until(w['resets_at'])}")
        print(f"  \033[2mvia {r['source']}\033[0m" if sys.stdout.isatty() else f"  via {r['source']}")
    print()


def to_json(results: dict) -> str:
    def default(o):
        return o.isoformat() if isinstance(o, datetime) else str(o)
    return json.dumps(results, indent=2, default=default)


# ---------------------------------------------------------------- cli

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="aqm", description="Show Claude / Codex subscription quotas (5h / 1w).")
    sub = p.add_subparsers(dest="cmd")
    lg = sub.add_parser("login", help="authenticate via browser (OAuth + PKCE)")
    lg.add_argument("provider", choices=["claude", "codex"])
    lg.add_argument("--no-browser", action="store_true",
                    help="don't open a browser; print the URL and paste the code/redirect back")
    lo = sub.add_parser("logout", help="forget stored tokens")
    lo.add_argument("provider", nargs="?", choices=["claude", "codex"])
    st = sub.add_parser("status", help="show quotas (default)")
    for parser in (p, st):
        parser.add_argument("--json", action="store_true", help="machine-readable output")
        parser.add_argument("-p", "--provider", choices=["claude", "codex"], action="append",
                            help="limit to provider (repeatable)")
    args = p.parse_args(argv)

    if args.cmd == "login":
        rec = (login_claude if args.provider == "claude" else login_codex)(args.no_browser)
        creds = load_creds()
        creds[args.provider] = rec
        save_creds(creds)
        print(f"✓ logged in to {args.provider}; tokens saved to {CREDS_FILE}")
        return 0
    if args.cmd == "logout":
        creds = load_creds()
        for prov in [args.provider] if args.provider else list(creds):
            creds.pop(prov, None)
        save_creds(creds)
        print("✓ logged out")
        return 0

    providers = args.provider or ["claude", "codex"]
    results: dict = {}
    threads = [threading.Thread(target=lambda pr=pr: results.__setitem__(pr, fetch(pr))) for pr in providers]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    results = {pr: results[pr] for pr in providers}
    if args.json:
        print(to_json(results))
    else:
        render(results)
    return 0 if all("error" not in r for r in results.values()) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
