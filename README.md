# Live transcriber

Runs on the Mac mini. Listens to an audio input, transcribes English locally with
Whisper (MLX, Apple Silicon GPU) and sends each phrase to the website, where
`/live/<campus>` shows it. Transcription itself needs **no internet**; only sending
the text to the website does (it queues and catches up if the connection drops).

## One-time setup (needs internet)

```bash
cd transcriber
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Create `transcriber/.env` (git-ignored):

```
TRANSCRIPT_URL=https://YOUR-SITE/api/transcript
TRANSCRIPT_KEY=<this campus's key from the website's /admin page>
AUDIO_DEVICE=Scarlett      # part of the name from --list-devices
AUDIO_CHANNEL=1            # which input channel carries the pastor's mic
```

The first run downloads the model (~1.6 GB) into `~/.cache/huggingface`. After that,
set `HF_HUB_OFFLINE=1` to guarantee nothing is fetched.

macOS will ask for microphone permission the first time (for Terminal, or whatever launches it).

## Standalone app for another computer (no setup, works offline)

On a Mac with internet and about 6 GB free, run `./build_app.sh`. It produces
`dist/Lifepoint-Transcriber.zip` (~1.6 GB) containing the app with Python, every library
and the Whisper model inside. On the other Apple Silicon Mac (macOS 13+): unzip, drag
**Lifepoint Transcriber** to Applications, and open it. The app isn't Apple-notarized, so the
first time, right-click it → **Open** → **Open** (or allow it in System Settings → Privacy & Security).
Then follow "Clickable menu-bar app" below for the menu options. Nothing else needs installing.

## Releases and auto-update

The app updates itself from GitHub Releases (`iamanthonyterry/transcriber`). To ship a new version:

```bash
git tag v1.0.1 && git push --tags
```

GitHub Actions builds the app and publishes a release with two files: `Lifepoint-Transcriber.zip`
(full, with the model, for first installs) and `Lifepoint-Transcriber-update.zip` (small, no model,
used by the updater). Installed apps check on launch and every 4 hours; the menu shows the version and
**Check for updates…**. An update downloads in the background and installs/restarts on its own if the
transcriber is stopped; if it's running, the menu shows **Restart to update** so a live service isn't interrupted.
macOS may ask for microphone access again after an update (the app isn't signed with a developer ID).

## Clickable menu-bar app (recommended on the Mac mini)

Build it once on the Mac mini (after the setup above):

```bash
.venv/bin/python setup.py py2app -A
```

This creates `dist/Lifepoint Transcriber.app`. Drag it to the Dock or add it to
System Settings → General → Login Items so it starts when the Mac does.
(It points at this folder and its `.venv`, so keep the project where it is; rebuild if you move it.)

Click the 🎙 icon in the menu bar:

- **Start / Stop transcribing**: icon is 🎙 idle, 🟡 starting or waiting for the schedule, 🔴 listening.
- **Audio input**, **Input channel**: pick what to listen to. Changes apply immediately.
- **Only Sundays 8:00–12:30**: tick it to let the app switch itself on and off.
- **Website settings…**: the site's `/api/transcript` address and this campus's key (first time only).
- **Open live page**: opens `/live/<campus>` so you can see what viewers see.

Settings are saved in `~/Library/Application Support/LifepointTranscriber/config.json`.
macOS asks for microphone access the first time you press Start; click Allow.
To start listening automatically at launch, tell me and I'll add an "Auto-start" option.

## Command line (for testing)

```bash
.venv/bin/python transcribe.py --list-devices
.venv/bin/python transcribe.py --dry-run                 # print only, send nothing
.venv/bin/python transcribe.py                           # live
.venv/bin/python transcribe.py --schedule "sun 08:00-12:30"   # on/off by itself
.venv/bin/python transcribe.py --file sermon.mp3 --fast  # test with a recording
```

`--schedule` can be repeated (`--schedule "sun 08:00-12:30" --schedule "wed 18:30-20:30"`).
Outside the windows it stops listening and wakes itself when the next one starts.

## Website side

- `POST /api/transcript` (key-protected) receives text; `/live/<campus>` displays it.
- In `/admin`, open the campus and click **Generate key** under *Live transcription*. Each campus has its own key, and the key alone decides which campus the transcriber feeds, so there is no campus setting in the transcriber. **Make new key** revokes the old one.
- The relay keeps text in the server process's memory, so the site must run as a
  long-lived server (`next start`, VPS). It will **not** work on serverless hosting like Vercel.

## Tuning

- Hears noise as speech? Raise `--min-db` (default `-50`, try `-42`). Misses quiet speech? Lower it.
- Best accuracy comes from a clean feed of just the speaker's mic channel from the board, not a room mic, and not during music.
- Words it keeps getting wrong (names, places): add them to `WHISPER_PROMPT`.
- Too slow / "Falling behind": `--model mlx-community/whisper-small.en-mlx`.
- Each phrase appears about 1 s after the speaker pauses (shown in the log as the time Whisper took).

## Start automatically (launchd)

Save as `~/Library/LaunchAgents/church.lifepoint.transcriber.plist`, fix the paths, then
`launchctl load ~/Library/LaunchAgents/church.lifepoint.transcriber.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>church.lifepoint.transcriber</string>
  <key>WorkingDirectory</key><string>/Users/YOU/Lifepoint.church/transcriber</string>
  <key>ProgramArguments</key><array>
    <string>/Users/YOU/Lifepoint.church/transcriber/.venv/bin/python</string>
    <string>transcribe.py</string>
    <string>--schedule</string><string>sun 08:00-12:30</string>
  </array>
  <key>EnvironmentVariables</key><dict><key>HF_HUB_OFFLINE</key><string>1</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/transcriber.log</string>
  <key>StandardErrorPath</key><string>/tmp/transcriber.log</string>
</dict></plist>
```

Also prevent sleep on the Mac mini (System Settings → Energy → "Prevent automatic sleeping").
