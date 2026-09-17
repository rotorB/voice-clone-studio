#!/bin/zsh
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew was not found. Install BlackHole 2ch from https://existential.audio/blackhole/"
  read -r "?Press Enter to exit…"
  exit 1
fi

if [[ -d /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver ]]; then
  echo "BlackHole 2ch is already installed."
else
  brew install blackhole-2ch
fi

echo "Opening Audio MIDI Setup. Create a Multi-Output Device if needed."
open -a "Audio MIDI Setup"
read -r "?Done. Press Enter to exit…"
