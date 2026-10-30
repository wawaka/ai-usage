#!/usr/bin/env python3
"""macOS menu bar wrapper around aqm. Requires `pip install rumps` (macOS only)."""
from __future__ import annotations

import queue
import threading

import rumps

import aqm

REFRESH_SECONDS = 300
NAMES = {"claude": "Claude", "codex": "Codex"}
SHORT = {"claude": "C", "codex": "X"}


def _title(results: dict) -> str:
    parts = []
    for prov, r in results.items():
        if "error" in r:
            parts.append(f"{SHORT[prov]} –")
            continue
        # Show the tighter of the two windows in the menu bar itself.
        pct = max((w["used_percent"] for w in (r.get("5h"), r.get("1w")) if w), default=None)
        if pct is None:
            parts.append(f"{SHORT[prov]} –")
        else:
            parts.append(f"{SHORT[prov]} {pct:.0f}%" + (" ⚠" if pct >= 90 else ""))
    return " · ".join(parts) or "aqm"


def _bar(pct: float, width: int = 10) -> str:
    filled = round(min(max(pct, 0), 100) / 100 * width)
    return "▓" * filled + "░" * (width - filled)


class QuotaApp(rumps.App):
    def __init__(self):
        super().__init__("aqm", title="aqm …", quit_button=None)
        self.updates: queue.Queue = queue.Queue()
        self.results: dict = {}
        self.busy = False
        self._rebuild_menu()
        # rumps timers fire on the main thread: one polls for finished background work,
        # the other kicks off periodic refreshes.
        rumps.Timer(self._drain, 0.5).start()
        rumps.Timer(lambda _: self.refresh(), REFRESH_SECONDS).start()
        self.refresh()

    # ------------------------------------------------------------ data

    def refresh(self, _=None):
        if self.busy:
            return
        self.busy = True
        threading.Thread(target=self._fetch_all, daemon=True).start()

    def _fetch_all(self):
        results: dict = {}
        threads = [threading.Thread(target=lambda p=p: results.__setitem__(p, aqm.fetch(p))) for p in NAMES]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.updates.put(("results", {p: results[p] for p in NAMES}))

    def _login(self, provider: str):
        def run():
            try:
                rec = (aqm.login_claude if provider == "claude" else aqm.login_codex)(False)
                creds = aqm.load_creds()
                creds[provider] = rec
                aqm.save_creds(creds)
                self.updates.put(("notify", f"Logged in to {NAMES[provider]}"))
            except BaseException as e:  # login helpers raise SystemExit on user-facing failures
                self.updates.put(("notify", f"{NAMES[provider]} login failed: {e}"))
            self.updates.put(("refresh", None))

        threading.Thread(target=run, daemon=True).start()

    def _logout(self, provider: str):
        creds = aqm.load_creds()
        creds.pop(provider, None)
        aqm.save_creds(creds)
        self.refresh()

    def _drain(self, _):
        while True:
            try:
                kind, payload = self.updates.get_nowait()
            except queue.Empty:
                return
            if kind == "results":
                self.busy = False
                self.results = payload
                self.title = _title(payload)
                self._rebuild_menu()
            elif kind == "notify":
                rumps.notification("Agent Quota Monitor", "", payload)
            elif kind == "refresh":
                self.refresh()

    # ------------------------------------------------------------ menu

    def _rebuild_menu(self):
        self.menu.clear()
        items: list = []
        for prov, name in NAMES.items():
            r = self.results.get(prov)
            header = name + (f" ({r['plan']})" if r and r.get("plan") else "")
            items.append(rumps.MenuItem(header))
            if r is None:
                items.append(rumps.MenuItem("   loading…"))
            elif "error" in r:
                items.append(rumps.MenuItem("   " + r["error"][:80]))
            else:
                rows = [("5h", r.get("5h")), ("1w", r.get("1w"))] + list(r.get("extra", {}).items())
                for label, w in rows:
                    text = f"   {label:<4} n/a" if w is None else \
                        f"   {label:<4} {_bar(w['used_percent'])} {w['used_percent']:.0f}%  {aqm._until(w['resets_at'])}"
                    items.append(rumps.MenuItem(text))
                items.append(rumps.MenuItem(f"   via {r.get('source')}"))
            acct = rumps.MenuItem("   Account")
            acct.add(rumps.MenuItem(f"Log in to {name}…", callback=lambda _, p=prov: self._login(p)))
            acct.add(rumps.MenuItem("Log out", callback=lambda _, p=prov: self._logout(p)))
            items += [acct, None]
        items += [
            rumps.MenuItem("Refresh", callback=self.refresh, key="r"),
            None,
            rumps.MenuItem("Quit", callback=rumps.quit_application, key="q"),
        ]
        self.menu = items


def main():
    try:  # hide the Dock icon when run as a plain script (py2app sets LSUIElement instead)
        from AppKit import NSApplication
        NSApplication.sharedApplication().setActivationPolicy_(1)  # accessory
    except ImportError:
        pass
    QuotaApp().run()


if __name__ == "__main__":
    main()
