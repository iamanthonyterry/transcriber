# Lifepoint Transcriber

Native macOS menu-bar app for the Mac mini. It listens to an audio input, transcribes English locally
with Whisper ([WhisperKit](https://github.com/argmaxinc/WhisperKit), Apple Neural Engine / GPU) and sends each
phrase to the website, where `/live/<campus>` shows it. Transcription needs **no internet**; only sending the
text does (it queues and catches up if the connection drops).

## Install

1. Download `Transcriber-<version>.zip` from the [latest release](https://github.com/iamanthonyterry/transcriber/releases/latest), unzip, drag **Transcriber** to Applications and open it. (Signed and notarized, so there's no right-click dance.)
2. macOS asks for microphone access the first time it listens: click Allow.
3. Click the menu-bar icon → **Website settings…** → **Sign in with website…**. Your browser opens the website's sign-in (the same emailed link as the admin); pick the campus this Mac's transcript goes to and you're connected. **Change campus…** repeats it. (Under *Advanced* you can still point at another site or paste a campus key by hand.)
4. First run downloads the speech model (~630 MB) and prepares it for the Neural Engine, which takes a few minutes **once**. After that it starts in seconds and works offline.

A Mac that was set up with the old Python app picks up its settings automatically.

**Fully offline setup:** copy a model folder to `~/Library/Application Support/Transcriber/Models/openai_whisper-large-v3-v20240930_turbo_632MB` (it contains `AudioEncoder.mlmodelc` etc.) before first launch and nothing is downloaded.

## Using it

- 🎙 icon = idle, 🟡 = starting or waiting for the schedule, 🔴 = listening, 🟠 = listening but the feed is silent or clipping.
- **Audio inputs** (one submenu each): pick the board's interface and the channel carrying the pastor's mic. Add more inputs in Settings; each one can *Send to website*, *Trigger OSC*, or both.
- An input remembers its exact device. If that device is unplugged the app waits for it (it never switches to another microphone) and carries on when it is back.
- **Save a copy** can also write subtitle files (`.srt` and `.vtt`, one pair per language, timed from the start of the session) and record the audio (`.m4a`, about 20 MB an hour) that the subtitles line up with.
- **Only Sundays 8:00–12:30**: the app switches itself on and off.
- **Website settings…**: website sign-in / campus, *Start listening when the app opens*, *Open at login*, and tuning:
  - **Corrections** (`heard => correct`, one per line) fix names and places Whisper keeps misspelling, e.g. `Life Point => Lifepoint`.
  - **Names and terms**: words Whisper should expect (this week's speaker, the series title, local place names), separated by commas or lines. It hears them correctly instead of fixing them afterwards. About ten names fit; a long list adds up to half a second of delay. With the schedule set to Planning Center, *Expect this plan's names* adds the speakers, series and title of today's (or the next) plan after your own list.
  - **Skip music, singing and noise**: only talking is transcribed (talking over music still is). Turn it off if real speech is being left out.
  - **Warn after silence**: the icon turns orange and a notification appears when the website's input has been silent that long (off by default; set it longer than your music if the mic is muted during worship). Clipping always warns.
  - **Noise gate** (dB): hears noise as speech? Raise it (try −42). Misses quiet speech? Lower it.
  - **OSC**: send an OSC message (UDP, e.g. to QLab on port 53000) when a phrase is heard. Only inputs with *Trigger OSC* on send them, so a separate mic can drive cues without going to the website. Guards against accidental cues: an optional *wake word* (a phrase only fires right after it), a cooldown before the same phrase can fire again, **Voice cues** in the menu bar to switch them all off without stopping the transcript, and **Recent cues** showing what fired and what was ignored.
- Best accuracy comes from a clean feed of just the speaker's mic channel from the board, not a room mic.

For the Mac mini, turn on *Start listening when the app opens* and *Open at login*, and in System Settings → Energy enable "Prevent automatic sleeping". Then it comes back by itself after reboots and updates.

## Updates

The app updates itself ([Sparkle](https://sparkle-project.org)) from GitHub Releases: it checks every 4 hours, downloads in the
background, and installs when the transcriber is stopped. If it's running, the menu shows **Restart to Update**
so a live service is never interrupted. **Check for Updates…** forces a check.

## Releasing (developer)

Needs Xcode, the Developer ID certificate, the `AC_PASSWORD` notarytool profile and the Sparkle key in the login keychain (all shared with Canopy).

```bash
./release.sh 2.0.1            # build, sign, notarize, zip, appcast into build/
./release.sh 2.0.1 --publish  # …and tag, push and create the GitHub release (zip + appcast.xml)
```

`swift build` / `swift run` work for development; `./build_app.sh` makes a signed `build/Transcriber.app`.
Test the pipeline without a mixer: `build/Transcriber.app/Contents/MacOS/Transcriber --transcribe-file some.wav` (prints phrases, sends nothing; add `--vocabulary "Name, Term"` to try names and terms).

## Website side

- `POST /api/transcript` (key-protected) receives text; `/live/<campus>` displays it.
- The relay keeps text in the server process's memory, so the site must run as a long-lived server (`next start`, VPS), not serverless hosting like Vercel.
