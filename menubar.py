"""Menu-bar app for the live transcriber. Click the menu-bar icon to start/stop and change settings."""

from __future__ import annotations

import json
import os
import threading
import webbrowser
from pathlib import Path

import rumps

import transcribe as t
import updater
from version import __version__

SUNDAY = "sun 08:00-12:30"
ICON = next((p for p in (Path(os.environ.get("RESOURCEPATH", "/nonexistent")) / "menubarTemplate.png",
                         Path(__file__).with_name("icon") / "menubarTemplate.png") if p.exists()), None)
APP_ICON = next((p for p in (Path(os.environ.get("RESOURCEPATH", "/nonexistent")) / "icon-1024.png",
                             Path(__file__).with_name("icon") / "icon-1024.png") if p.exists()), None)
CONFIG = Path.home() / "Library/Application Support/LifepointTranscriber/config.json"

DEFAULTS = {
    "url": "http://localhost:3000/api/transcript",
    "token": "",
    "device": None,
    "channel": 1,
    "prompt": t.DEFAULT_PROMPT,
    "min_db": -50.0,
    "schedule_on": False,
}


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    t.load_env_file(Path(__file__).with_name(".env"))  # first-run convenience when run from the project
    for env, key in (("TRANSCRIPT_URL", "url"), ("TRANSCRIPT_KEY", "token"), ("TRANSCRIPT_TOKEN", "token")):
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    try:
        cfg.update(json.loads(CONFIG.read_text()))
    except Exception:
        pass
    return cfg


def save_config(cfg: dict) -> None:
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(cfg, indent=2))
    CONFIG.chmod(0o600)  # holds the transcriber key


def input_devices() -> list[tuple[str, int]]:
    import sounddevice as sd

    return [(d["name"], int(d["max_input_channels"])) for d in sd.query_devices() if d["max_input_channels"] > 0]


def clear(menu: rumps.MenuItem) -> None:
    """rumps raises on clear() while a submenu has never had items added."""
    if len(menu):
        menu.clear()


class App(rumps.App):
    def __init__(self):
        # Template icon: macOS tints it for light/dark menu bars. The title beside it is the status dot.
        super().__init__("Lifepoint Transcriber", title="" if ICON else "🎙", icon=str(ICON) if ICON else None,
                         template=True, quit_button=None)
        self.cfg = load_config()
        self.runner: t.Runner | None = None
        self.engine: t.Transcriber | None = None
        self.status = "Stopped"
        self.last_text = ""
        self.lock = threading.Lock()

        self.status_item = rumps.MenuItem("Stopped")
        self.text_item = rumps.MenuItem("")
        self.toggle_item = rumps.MenuItem("Start transcribing", callback=self.toggle)
        self.device_menu = rumps.MenuItem("Audio input")
        self.channel_menu = rumps.MenuItem("Input channel")
        self.schedule_item = rumps.MenuItem("Only Sundays 8:00–12:30", callback=self.toggle_schedule)
        self.live_item = rumps.MenuItem("Open live page", callback=self.open_live)
        self.settings_item = rumps.MenuItem("Website settings…", callback=self.website_settings)
        self.bundle = updater.app_bundle()
        self.update_info: dict | None = None
        self.staged = None
        self.update_busy = False
        self.update_item = rumps.MenuItem("Check for updates…", callback=self.check_updates)
        self.menu = [
            self.status_item, self.text_item, None, self.toggle_item, None,
            self.device_menu, self.channel_menu, self.schedule_item, None,
            self.live_item, self.settings_item, None,
            rumps.MenuItem(f"Version {__version__}"), self.update_item, None,
            rumps.MenuItem("Quit", callback=self.quit),
        ]
        self.build_menus()
        self.refresh(None)

    # ---- menus ----
    def build_menus(self) -> None:
        clear(self.device_menu)
        clear(self.channel_menu)
        try:
            devices = input_devices()
        except Exception:
            devices = []
        default = rumps.MenuItem("System default", callback=self.pick_device)
        default.dev = None
        default.state = self.cfg["device"] is None
        self.device_menu.add(default)
        current_channels = 1
        for name, channels in devices:
            item = rumps.MenuItem(f"{name} ({channels} ch)", callback=self.pick_device)
            item.dev = name
            item.state = self.cfg["device"] == name
            if item.state:
                current_channels = channels
            self.device_menu.add(item)
        for ch in range(1, max(current_channels, self.cfg["channel"]) + 1):
            item = rumps.MenuItem(f"Channel {ch}", callback=self.pick_channel)
            item.ch = ch
            item.state = ch == self.cfg["channel"]
            self.channel_menu.add(item)
        self.schedule_item.state = self.cfg["schedule_on"]

    def refresh(self, _) -> None:
        running = bool(self.runner and self.runner.running)
        self.status_item.title = self.status
        self.text_item.title = ("“" + self.last_text[:70] + ("…" if len(self.last_text) > 70 else "") + "”") if self.last_text else "(nothing heard yet)"
        self.toggle_item.title = "Stop transcribing" if running else "Start transcribing"
        listening = running and self.status.startswith("Listening")
        self.title = "🔴" if listening else ("🟡" if running else ("" if ICON else "🎙"))

    @rumps.timer(1)
    def tick(self, _):
        self.refresh(None)

    # ---- runner control ----
    def on_status(self, s: str) -> None:
        self.status = s

    def on_text(self, s: str) -> None:
        self.last_text = s

    def run_config(self) -> dict:
        c = dict(self.cfg)
        c["schedule"] = [SUNDAY] if c.pop("schedule_on") else []
        c["model"] = os.environ.get("WHISPER_MODEL") or t.default_model()
        return c

    def start(self) -> None:
        if not self.cfg["token"]:
            rumps.alert("Transcriber key needed", "Open “Website settings…” and enter the site address and this campus’s key (made in the website’s admin page) first.",
                         icon_path=str(APP_ICON) if APP_ICON else None)
            return
        with self.lock:
            self.runner = t.Runner(self.run_config(), self.on_status, self.on_text)
            self.runner.engine = self.engine  # keep the loaded model between restarts
            self.runner.start()
            self.status = "Starting…"

    def stop(self) -> None:
        with self.lock:
            if self.runner:
                self.runner.stop()
                if self.runner.thread:
                    self.runner.thread.join(timeout=5)
                self.engine = self.runner.engine or self.engine
            self.status = "Stopped"

    def apply(self) -> None:
        save_config(self.cfg)
        self.build_menus()
        if self.runner and self.runner.running:
            self.stop()
            self.start()

    # ---- actions ----
    def toggle(self, _) -> None:
        if self.runner and self.runner.running:
            self.stop()
        else:
            self.start()

    def pick_device(self, item) -> None:
        self.cfg["device"] = item.dev
        self.cfg["channel"] = 1
        self.apply()

    def pick_channel(self, item) -> None:
        self.cfg["channel"] = item.ch
        self.apply()

    def toggle_schedule(self, _) -> None:
        self.cfg["schedule_on"] = not self.cfg["schedule_on"]
        self.apply()

    def site_base(self) -> str:
        return self.cfg["url"].rsplit("/api/transcript", 1)[0]

    def open_live(self, _) -> None:
        campus = self.runner.sender.campus if self.runner and self.runner.sender else None
        webbrowser.open(f"{self.site_base()}/live/{campus}" if campus else self.site_base())

    def website_settings(self, _) -> None:
        w = rumps.Window("Address of the transcript endpoint:", "Website settings", self.cfg["url"], ok="Next", cancel="Cancel", dimensions=(380, 24))
        r = w.run()
        if not r.clicked:
            return
        url = r.text.strip()
        w = rumps.Window("Transcriber key (from the website's admin page, one per campus):", "Website settings", self.cfg["token"], ok="Save", cancel="Cancel", dimensions=(380, 24))
        r = w.run()
        if not r.clicked:
            return
        self.cfg["url"], self.cfg["token"] = url, r.text.strip()
        self.engine = self.engine  # model stays loaded
        self.apply()

    # ---- updates ----
    @rumps.timer(4 * 60 * 60)
    def auto_check(self, _) -> None:
        self.check_updates(None, silent=True)

    def check_updates(self, _, silent: bool = False) -> None:
        if self.update_busy:
            return
        if self.staged:  # already downloaded: this click is "Restart to update"
            return self.install_update()
        if not self.bundle:
            if not silent:
                rumps.alert("Updates", "This is a development build, so it doesn’t self-update.")
            return
        self.update_busy = True
        threading.Thread(target=self._update_worker, args=(silent,), daemon=True).start()

    def _update_worker(self, silent: bool) -> None:
        try:
            self.update_item.title = "Checking for updates…"
            info = updater.latest()
            if not info:
                self.update_item.title = "Check for updates…"
                if not silent:
                    rumps.alert("Up to date", f"You have the latest version ({__version__}).")
                return
            self.update_info = info
            self.update_item.title = f"Downloading {info['version']}…"
            self.staged = updater.download_and_stage(
                info, self.bundle, lambda pct: setattr(self.update_item, "title", f"Downloading {info['version']}… {pct}%"))
            self.update_item.title = f"Restart to update to {info['version']}"
            if not (self.runner and self.runner.running):  # never interrupt a live service
                self.install_update()
        except Exception as e:
            self.staged = None
            self.update_item.title = "Check for updates…"
            if not silent:
                rumps.alert("Update failed", str(e))
        finally:
            self.update_busy = False

    def install_update(self) -> None:
        self.stop()
        updater.install_and_relaunch(self.staged, self.bundle)
        rumps.quit_application()

    def quit(self, _) -> None:
        self.stop()
        rumps.quit_application()


if __name__ == "__main__":
    app = App()
    threading.Timer(10, lambda: app.check_updates(None, silent=True)).start()  # soon after launch
    app.run()
