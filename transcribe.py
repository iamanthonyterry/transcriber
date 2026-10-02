#!/usr/bin/env python3
"""
Live English transcription for the Lifepoint website.

Listens to an audio input, detects when someone is speaking, transcribes each
phrase locally with Whisper (Apple Silicon GPU via MLX, no internet needed once
the model is downloaded) and POSTs the text to the website's /api/transcript.

    .venv/bin/python transcribe.py --list-devices
    .venv/bin/python transcribe.py --device "Scarlett" --dry-run
    .venv/bin/python transcribe.py                                # real run (see README.md)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import queue
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000
FRAME = 480  # 30 ms
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"


def default_model() -> str:
    """The model bundled inside the built .app if there is one, else download/cache by name."""
    bundled = Path(os.environ.get("RESOURCEPATH", "")) / "model"
    return str(bundled) if (bundled / "weights.safetensors").exists() else DEFAULT_MODEL

# Nudges Whisper toward our vocabulary. Add names/places that get misheard.
DEFAULT_PROMPT = "A Sunday sermon at Lifepoint Church in Ohio. Scripture, Jesus, grace, gospel, Galatians."

# Whisper invents these when it is fed silence or music.
HALLUCINATIONS = {
    "thank you",
    "thank you.",
    "thanks for watching",
    "thanks for watching!",
    "you",
    "bye",
    "bye.",
}


def load_env_file(path: Path) -> None:
    """Tiny .env reader so launchd/cron runs don't need exported variables."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip("\"'"))


def log(*args: object) -> None:
    print(dt.datetime.now().strftime("%H:%M:%S"), *args, flush=True)


# ───────────────────────── schedule ─────────────────────────

DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def parse_schedule(spec: str) -> tuple[int, dt.time, dt.time]:
    """'sun 08:00-12:30' -> (6, 08:00, 12:30)"""
    try:
        day, span = spec.lower().split()
        start, end = span.split("-")
        t = lambda s: dt.datetime.strptime(s, "%H:%M").time()  # noqa: E731
        return DAYS.index(day[:3]), t(start), t(end)
    except Exception:
        sys.exit(f"Bad --schedule {spec!r}. Use e.g. 'sun 08:00-12:30'.")


def in_window(windows: list[tuple[int, dt.time, dt.time]], now: dt.datetime) -> bool:
    if not windows:
        return True
    return any(now.weekday() == d and a <= now.time() <= b for d, a, b in windows)


# ───────────────────────── audio / VAD ─────────────────────────


class Segmenter:
    """Energy-based speech detector that cuts audio into phrases.

    The noise floor adapts, so it copes with different mixers and rooms. A phrase
    ends after a short pause; long run-on speech is cut at the next small pause.
    """

    def __init__(self, min_db: float, margin_db: float = 9.0):
        self.min_db = min_db
        self.margin_db = margin_db
        self.floor = min_db - 6.0
        self.preroll: deque[np.ndarray] = deque(maxlen=10)  # 300 ms before speech starts
        self.buf: list[np.ndarray] = []
        self.speaking = False
        self.silent_frames = 0
        self.speech_frames = 0

    def level_db(self, frame: np.ndarray) -> float:
        rms = float(np.sqrt(np.mean(frame * frame))) + 1e-9
        return 20 * np.log10(rms)

    def feed(self, frame: np.ndarray) -> np.ndarray | None:
        db = self.level_db(frame)
        threshold = max(self.min_db, self.floor + self.margin_db)
        loud = db > threshold

        if not loud:  # track the room's noise floor only while it is quiet
            self.floor = 0.98 * self.floor + 0.02 * db

        if not self.speaking:
            self.preroll.append(frame)
            if loud:
                self.speech_frames += 1
                if self.speech_frames >= 3:  # ~90 ms of sound, ignore clicks
                    self.speaking = True
                    self.buf = list(self.preroll)
                    self.silent_frames = 0
            else:
                self.speech_frames = 0
            return None

        self.buf.append(frame)
        self.silent_frames = 0 if loud else self.silent_frames + 1
        seconds = len(self.buf) * FRAME / SAMPLE_RATE
        pause = self.silent_frames * FRAME / SAMPLE_RATE

        done = pause >= 0.7 or (seconds >= 12 and pause >= 0.25) or seconds >= 22
        if not done:
            return None
        audio = np.concatenate(self.buf)
        self.reset()
        return audio if seconds - pause >= 0.4 else None  # drop blips

    def flush(self) -> np.ndarray | None:
        if self.speaking and self.buf:
            audio = np.concatenate(self.buf)
            self.reset()
            return audio
        return None

    def reset(self) -> None:
        self.buf = []
        self.speaking = False
        self.silent_frames = 0
        self.speech_frames = 0
        self.preroll.clear()


def ffmpeg_frames(path: str, realtime: bool):
    """Yield 30 ms frames from any audio file (used for testing without a mixer)."""
    proc = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-"],
        stdout=subprocess.PIPE,
    )
    size = FRAME * 4
    assert proc.stdout
    while chunk := proc.stdout.read(size):
        if len(chunk) < size:
            break
        yield np.frombuffer(chunk, dtype=np.float32)
        if realtime:
            time.sleep(FRAME / SAMPLE_RATE)
    proc.wait()


def mic_frames(device: str | int | None, channel: int, stop: threading.Event):
    import sounddevice as sd

    info = sd.query_devices(device, "input")
    channels = int(info["max_input_channels"])
    if channel > channels:
        sys.exit(f"--channel {channel} but '{info['name']}' only has {channels} input channel(s).")
    q: queue.Queue[np.ndarray] = queue.Queue()

    def callback(indata, frames, time_info, status):  # noqa: ARG001
        if status:
            log("audio warning:", status)
        q.put(indata[:, channel - 1].copy())

    log(f"Listening to '{info['name']}' (channel {channel} of {channels})")
    with sd.InputStream(
        device=device,
        samplerate=SAMPLE_RATE,
        channels=channels,
        blocksize=FRAME,
        dtype="float32",
        callback=callback,
    ):
        while not stop.is_set():
            try:
                yield q.get(timeout=0.5)
            except queue.Empty:
                continue


# ───────────────────────── transcription ─────────────────────────


class Transcriber:
    def __init__(self, model: str, prompt: str):
        import mlx_whisper

        self.mlx = mlx_whisper
        self.model = model
        self.prompt = prompt

    def warm_up(self) -> None:
        self.mlx.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), path_or_hf_repo=self.model, language="en")

    def text(self, audio: np.ndarray) -> str:
        result = self.mlx.transcribe(
            audio,
            path_or_hf_repo=self.model,
            language="en",
            temperature=0.0,
            condition_on_previous_text=False,
            initial_prompt=self.prompt,
            no_speech_threshold=0.6,
            compression_ratio_threshold=2.4,
            logprob_threshold=-1.0,
            word_timestamps=False,
        )
        parts = [
            s["text"].strip()
            for s in result.get("segments", [])
            if s.get("no_speech_prob", 0) < 0.6 and s.get("avg_logprob", 0) > -1.2
        ]
        text = " ".join(p for p in parts if p).strip()
        return "" if text.lower() in HALLUCINATIONS else text


# ───────────────────────── sending ─────────────────────────


class Sender(threading.Thread):
    """Posts text to the website without ever blocking transcription.

    If the internet or the site is down, text waits (newest 300 kept) and is
    resent in order once it is reachable again.
    """

    def __init__(self, url: str, token: str, dry_run: bool, on_status=None):
        super().__init__(daemon=True)
        self.url, self.token, self.dry_run = url, token, dry_run
        self.campus: str | None = None  # learned from the website: the key decides it
        self.on_status = on_status or (lambda s: None)
        self.bad = False
        self.q: queue.Queue[str] = queue.Queue(maxsize=300)

    def send(self, text: str) -> None:
        if self.q.full():
            self.q.get_nowait()
        self.q.put(text)

    def heartbeat(self) -> None:
        """Tell the website this campus is live. Best effort; never queued."""
        if self.dry_run:
            return
        try:
            self.post(None)
            if self.bad:
                self.bad = False
                self.on_status("Listening")
        except urllib.error.HTTPError as e:
            if e.code in (400, 401):
                self.bad = True
                self.on_status("Website rejected us — check the key in Website settings")
        except Exception:
            self.bad = True
            self.on_status("Can't reach the website — check the address in Website settings")

    def post(self, text: str | None) -> None:
        payload = {"text": text} if text is not None else {"heartbeat": True}
        body = json.dumps(payload).encode()
        req = urllib.request.Request(
            self.url,
            data=body,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.token}"},
        )
        with urllib.request.urlopen(req, timeout=10) as res:
            if text is None:
                try:
                    self.campus = json.load(res).get("campus") or self.campus
                except Exception:
                    pass

    def run(self) -> None:
        warned = False
        while True:
            text = self.q.get()
            if self.dry_run:
                continue
            delay = 1.0
            while True:
                try:
                    self.post(text)
                    if warned:
                        log("Website reachable again.")
                        self.on_status("Listening")
                        warned = False
                    break
                except urllib.error.HTTPError as e:
                    if e.code in (400, 401):  # retrying won't help; drop it and say why
                        log(f"Website rejected the text (HTTP {e.code}). Check the transcriber key.")
                        break
                    err = f"HTTP {e.code}"
                except Exception as e:  # offline, DNS, timeout...
                    err = type(e).__name__
                if not warned:
                    log(f"Can't reach the website ({err}). Transcribing continues; will retry.")
                    self.on_status("Listening (website unreachable — retrying)")
                    warned = True
                time.sleep(delay)
                delay = min(delay * 2, 15)


# ───────────────────────── runner ─────────────────────────


class Runner:
    """Everything needed to listen, transcribe and send. Used by the CLI and the menu-bar app.

    cfg keys: url, token, device, channel, model, prompt, min_db, schedule (list), dry_run
    """

    def __init__(self, cfg: dict, on_status=log, on_text=lambda text: None):
        self.cfg = cfg
        self.on_status = on_status
        self.on_text = on_text
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.audio_q: queue.Queue[np.ndarray | None] = queue.Queue(maxsize=8)
        self.engine: Transcriber | None = None
        self.sender: Sender | None = None
        self.listening = False

    # -- lifecycle --
    def start(self) -> None:
        if self.thread and self.thread.is_alive():
            return
        self.stop_event.clear()
        self.thread = threading.Thread(target=self._run_mic, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()

    @property
    def running(self) -> bool:
        return bool(self.thread and self.thread.is_alive())

    # -- internals --
    def _prepare(self) -> None:
        c = self.cfg
        if self.engine is None:
            self.on_status("Loading model…")
            self.engine = Transcriber(c["model"], c["prompt"])
            self.engine.warm_up()
        if self.sender is None:
            self.sender = Sender(c["url"], c["token"] or "", c.get("dry_run", False), self.on_status)
            self.sender.start()
            threading.Thread(target=self._worker, daemon=True).start()
            threading.Thread(target=self._heartbeat, daemon=True).start()

    def _heartbeat(self) -> None:
        # Lets the website show the transcription section only while this campus is really on.
        while True:
            if self.listening and self.sender:
                self.sender.heartbeat()
            time.sleep(15)

    def _worker(self) -> None:
        assert self.engine and self.sender
        while (audio := self.audio_q.get()) is not None:
            started = time.time()
            try:
                text = self.engine.text(audio)
            except Exception as e:  # keep going on a bad chunk
                log("transcribe error:", e)
                continue
            if text:
                log(f"({time.time() - started:.1f}s) {text}")
                self.sender.send(text)
                self.on_text(text)

    def _submit(self, audio: np.ndarray | None) -> None:
        if audio is None:
            return
        if self.audio_q.full():
            log("Falling behind — dropping the oldest phrase. Try a smaller model.")
            try:
                self.audio_q.get_nowait()
            except queue.Empty:
                pass
        self.audio_q.put(audio)

    def _run_mic(self) -> None:
        c = self.cfg
        windows = [parse_schedule(s) for s in c.get("schedule", [])]
        try:
            self._prepare()
            while not self.stop_event.is_set():
                if not in_window(windows, dt.datetime.now()):
                    self.on_status("Waiting for the schedule")
                    while not self.stop_event.is_set() and not in_window(windows, dt.datetime.now()):
                        time.sleep(1)
                    continue
                self.on_status("Listening")
                self.listening = True
                seg = Segmenter(c["min_db"])
                inner_stop = threading.Event()
                for frame in mic_frames(c.get("device"), c["channel"], inner_stop):
                    if self.stop_event.is_set() or (windows and not in_window(windows, dt.datetime.now())):
                        inner_stop.set()
                        break
                    self._submit(seg.feed(frame))
                self._submit(seg.flush())
                self.listening = False
        except SystemExit as e:  # mic_frames reports setup problems this way
            self.on_status(f"Error: {e}")
        except Exception as e:
            self.on_status(f"Error: {e}")
            log("error:", repr(e))
        else:
            self.on_status("Stopped")
        finally:
            self.listening = False

    def run_file(self, path: str, realtime: bool) -> None:
        self._prepare()
        seg = Segmenter(self.cfg["min_db"])
        for frame in ffmpeg_frames(path, realtime):
            self._submit(seg.feed(frame))
        self._submit(seg.flush())
        self.audio_q.put(None)
        while not self.audio_q.empty():
            time.sleep(0.2)
        time.sleep(3)  # let the last phrase finish transcribing and sending


# ───────────────────────── main ─────────────────────────


def main() -> None:
    load_env_file(Path(__file__).with_name(".env"))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default=os.environ.get("TRANSCRIPT_URL", "http://localhost:3000/api/transcript"))
    ap.add_argument("--token", default=os.environ.get("TRANSCRIPT_KEY") or os.environ.get("TRANSCRIPT_TOKEN"), help="this campus's transcriber key from the website's /admin page")
    ap.add_argument("--device", default=os.environ.get("AUDIO_DEVICE"), help="input device name (part of it) or number")
    ap.add_argument("--channel", type=int, default=int(os.environ.get("AUDIO_CHANNEL", "1")), help="which input channel carries the speaker (1-based)")
    ap.add_argument("--model", default=os.environ.get("WHISPER_MODEL") or default_model())
    ap.add_argument("--prompt", default=os.environ.get("WHISPER_PROMPT", DEFAULT_PROMPT))
    ap.add_argument("--min-db", type=float, default=float(os.environ.get("MIN_DB", "-50")), help="quietest level counted as speech (raise if it hears noise)")
    ap.add_argument("--schedule", action="append", default=[], metavar="'sun 08:00-12:30'", help="only listen in these windows (repeatable); default always on")
    ap.add_argument("--file", help="transcribe an audio file instead of the microphone (for testing)")
    ap.add_argument("--fast", action="store_true", help="with --file, don't wait for real time")
    ap.add_argument("--dry-run", action="store_true", help="print the text but don't send it")
    ap.add_argument("--list-devices", action="store_true")
    args = ap.parse_args()

    if args.list_devices:
        import sounddevice as sd

        print(sd.query_devices())
        return
    if not args.dry_run and not args.token:
        sys.exit("Need --token (or TRANSCRIPT_KEY in .env), the campus key from /admin, or use --dry-run.")
    for spec in args.schedule:
        parse_schedule(spec)

    device: str | int | None = args.device
    if isinstance(device, str) and device.isdigit():
        device = int(device)
    cfg = dict(
        url=args.url, token=args.token, device=device, channel=args.channel,
        model=args.model, prompt=args.prompt, min_db=args.min_db, schedule=args.schedule, dry_run=args.dry_run,
    )
    runner = Runner(cfg, on_status=lambda s: log(s))
    try:
        if args.file:
            runner.run_file(args.file, realtime=not args.fast)
        else:
            runner.start()
            while runner.running:
                time.sleep(0.5)
    except KeyboardInterrupt:
        runner.stop()
        log("Stopped.")


if __name__ == "__main__":
    main()
