#!/bin/sh
# Installs GlassVinyl's karaoke tools into ~/Library/Application Support/GlassVinyl/stems:
# a Python environment with audio-separator (vocal removal) and yt-dlp (song download).
# Needs uv (brew install uv) or Python 3.10+, plus ffmpeg (brew install ffmpeg).
# The vocal-removal model (about 900 MB) downloads on first use.
set -e
DIR="$HOME/Library/Application Support/GlassVinyl/stems"
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
PACKAGES='audio-separator[cpu] audioread yt-dlp'
mkdir -p "$DIR"
cd "$DIR"

if command -v uv >/dev/null 2>&1; then
  echo "Creating Python environment with uv…"
  uv venv --allow-existing --python 3.12 venv
  echo "Installing audio-separator and yt-dlp…"
  uv pip install --python venv/bin/python $PACKAGES
else
  PYTHON=""
  for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON="$candidate"; break; fi
  done
  if [ -z "$PYTHON" ]; then
    echo "Needs uv or Python 3.10+. Install uv with: brew install uv"
    exit 1
  fi
  echo "Creating Python environment with $PYTHON…"
  "$PYTHON" -m venv venv
  echo "Installing audio-separator and yt-dlp…"
  venv/bin/pip install --quiet --upgrade pip
  venv/bin/pip install --quiet $PACKAGES
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Installed, but ffmpeg is missing. Install it with: brew install ffmpeg"
  exit 2
fi
echo "Karaoke tools installed."
