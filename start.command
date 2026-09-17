#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
export PYTHONUNBUFFERED=1

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "A native ARM64 terminal is required; MLX does not run through Rosetta."
  read -k 1 "?Press any key to exit…"
  exit 1
fi

uv sync --python /opt/homebrew/bin/python3.11
uv run python app.py
