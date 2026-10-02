#!/bin/bash
# Builds a self-contained "Lifepoint Transcriber.app" (Python, libraries and the Whisper
# model all inside) that runs offline on any Apple Silicon Mac. Run on a Mac with internet.
# Needs roughly 6 GB of free disk space while building.
set -euo pipefail
cd "$(dirname "$0")"

[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt

# 1. Fetch the model once (cached in ~/.cache/huggingface)
SRC=$(.venv/bin/python -c 'from huggingface_hub import snapshot_download as s; print(s("mlx-community/whisper-large-v3-turbo"))')

# 2. Build the standalone app
rm -rf build dist
.venv/bin/python setup.py py2app
rm -rf build

# 3. py2app mangles MLX (a "namespace package" with native GPU libraries), so install the
#    original package folder as-is and drop py2app's stubs for it.
APP="dist/Lifepoint Transcriber.app"
PYV=$(.venv/bin/python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
LIB="$APP/Contents/Resources/lib"
zip -q -d "$LIB/python${PYV/./}.zip" 'mlx/*' || true
rm -rf "$LIB/python$PYV/lib-dynload/mlx"
rsync -a --exclude include --exclude share --exclude cmake --exclude __pycache__ \
  ".venv/lib/python$PYV/site-packages/mlx" "$LIB/python$PYV/"

# Likewise the microphone library (libportaudio) can't be loaded from inside the zip.
zip -q -d "$LIB/python${PYV/./}.zip" '_sounddevice_data/*' || true
rsync -a --exclude __pycache__ ".venv/lib/python$PYV/site-packages/_sounddevice_data" "$LIB/python$PYV/"

# 4a. Zip the app WITHOUT the model for auto-updates (the updater keeps the model already installed)
(cd dist && ditto -c -k --keepParent "Lifepoint Transcriber.app" "Transcriber-update.zip")

# 4. Put the model inside (cp -c makes a copy-on-write clone: instant, no extra disk space)
mkdir -p "$APP/Contents/Resources/model"
cp -c -L "$SRC/weights.safetensors" "$SRC/config.json" "$APP/Contents/Resources/model/"

# 5. Zip the full app (with model) for first installs on another computer
(cd dist && ditto -c -k --keepParent "Lifepoint Transcriber.app" "Transcriber.zip")
echo
echo "Done: dist/Transcriber.zip (first install) and dist/Transcriber-update.zip (auto-update)"
