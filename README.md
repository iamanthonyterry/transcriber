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

- 🎙 icon = idle, 🟡 = starting or waiting for the schedule, 🔴 = listening.
- **Audio input / Input channel**: pick the board's interface and the channel carrying the pastor's mic.
- **Only Sundays 8:00–12:30**: the app switches itself on and off.
- **Website settings…**: website sign-in / campus, *Start listening when the app opens*, *Open at login*, and tuning:
  - **Corrections** (`heard => correct`, one per line) fix names and places Whisper keeps misspelling, e.g. `Life Point => Lifepoint`.
  - **Noise gate** (dB): hears noise as speech? Raise it (try −42). Misses quiet speech? Lower it.
- Best accuracy comes from a clean feed of just the speaker's mic channel from the board, not a room mic, and not during music.

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
Test the pipeline without a mixer: `build/Transcriber.app/Contents/MacOS/Transcriber --transcribe-file some.wav` (prints phrases, sends nothing).

## Website side

- `POST /api/transcript` (key-protected) receives text; `/live/<campus>` displays it.
- The relay keeps text in the server process's memory, so the site must run as a long-lived server (`next start`, VPS), not serverless hosting like Vercel.
