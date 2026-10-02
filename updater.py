"""Self-update from GitHub Releases for the built (py2app) app.

The release has two zips: the full app (with the ~1.5 GB Whisper model, for first installs) and
`Transcriber-update.zip` (everything but the model, ~200 MB). Updates use the small one and
carry the existing model over, so people never re-download it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path

from version import __version__

REPO = "iamanthonyterry/transcriber"
UPDATE_ASSET = "Transcriber-update.zip"
API = f"https://api.github.com/repos/{REPO}/releases/latest"


def app_bundle() -> Path | None:
    """The installed .app, or None when running from source / an alias build (nothing to replace)."""
    res = os.environ.get("RESOURCEPATH")
    if not res:
        return None
    bundle = Path(res).resolve().parent.parent
    # A dev build (setup.py py2app -A) lives in <project>/dist and points at the source; don't replace that.
    if bundle.suffix != ".app" or (bundle.parent.parent / "setup.py").exists():
        return None
    return bundle


def parse(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", v)[:3])


def latest() -> dict | None:
    """{'version', 'url', 'sha256', 'notes'} for the newest release if it is newer than this app."""
    req = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json", "User-Agent": "transcriber"})
    with urllib.request.urlopen(req, timeout=15) as r:
        rel = json.load(r)
    version = rel["tag_name"].lstrip("v")
    if parse(version) <= parse(__version__):
        return None
    for a in rel.get("assets", []):
        if a["name"] == UPDATE_ASSET:
            digest = (a.get("digest") or "").removeprefix("sha256:") or None
            return {"version": version, "url": a["browser_download_url"], "sha256": digest, "notes": rel.get("body") or ""}
    return None


def download_and_stage(info: dict, bundle: Path, progress=lambda pct: None) -> Path:
    """Download + unzip the update next to the installed app (same volume, so the swap is a rename)."""
    staged = bundle.with_name(f".{bundle.stem}.update.app")
    shutil.rmtree(staged, ignore_errors=True)
    with tempfile.TemporaryDirectory(prefix="lp-update-") as tmp:
        zpath = Path(tmp) / UPDATE_ASSET
        h = hashlib.sha256()
        with urllib.request.urlopen(info["url"], timeout=30) as r, open(zpath, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done = 0
            while chunk := r.read(1 << 20):
                f.write(chunk)
                h.update(chunk)
                done += len(chunk)
                if total:
                    progress(int(done * 100 / total))
        if info["sha256"] and h.hexdigest() != info["sha256"]:
            raise RuntimeError("Downloaded update is corrupt (checksum mismatch)")
        out = Path(tmp) / "x"
        subprocess.run(["ditto", "-x", "-k", str(zpath), str(out)], check=True)
        apps = list(out.glob("*.app"))
        if len(apps) != 1:
            raise RuntimeError("Update zip did not contain exactly one app")
        shutil.move(str(apps[0]), str(staged))
    return staged


SWAP = r"""#!/bin/bash
# Waits for the old app to quit, swaps in the new one (keeping the model), relaunches.
OLD="$1"; NEW="$2"; PID="$3"; BAK="$OLD.old"
while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
[ -d "$NEW/Contents/Resources/model" ] || cp -c -R "$OLD/Contents/Resources/model" "$NEW/Contents/Resources/model"
rm -rf "$BAK"
if mv "$OLD" "$BAK" && mv "$NEW" "$OLD"; then
  rm -rf "$BAK"
else
  [ -d "$BAK" ] && [ ! -d "$OLD" ] && mv "$BAK" "$OLD"
fi
open "$OLD"
"""


def install_and_relaunch(staged: Path, bundle: Path) -> None:
    """Start the detached swap script; the caller must quit the app right after."""
    script = Path(tempfile.gettempdir()) / "lifepoint-transcriber-swap.sh"
    script.write_text(SWAP)
    script.chmod(0o700)
    subprocess.Popen(["/bin/bash", str(script), str(bundle), str(staged), str(os.getpid())],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
