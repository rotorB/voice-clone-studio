#!/bin/zsh
set -euo pipefail

MODULE_DIR="${0:A:h}"
"$MODULE_DIR/build-app.command"

SOURCE_APP="$MODULE_DIR/dist/Voice clone Studio.app"
INSTALL_DIR="${VOICE_CLONE_INSTALL_DIR:-/Applications}"
TARGET_APP="$INSTALL_DIR/Voice clone Studio.app"
LEGACY_APP="$HOME/Applications/Voice clone Studio.app"

stop_matching() {
  local pattern="$1"
  local process_ids
  process_ids=($(pgrep -f "$pattern" 2>/dev/null || true))
  (( ${#process_ids} == 0 )) && return
  kill $process_ids 2>/dev/null || true
  for _ in {1..30}; do
    local alive=0
    for process_id in $process_ids; do
      kill -0 "$process_id" 2>/dev/null && alive=1
    done
    (( alive == 0 )) && return
    sleep 0.1
  done
  kill -9 $process_ids 2>/dev/null || true
}

mkdir -p "$INSTALL_DIR"
stop_matching "^${TARGET_APP}/Contents/MacOS/VoiceCloneStudio$"
stop_matching "${TARGET_APP}/Contents/Resources/backend/native_backend.py"
if [[ "$LEGACY_APP" != "$TARGET_APP" ]]; then
  stop_matching "^${LEGACY_APP}/Contents/MacOS/VoiceCloneStudio$"
  stop_matching "${LEGACY_APP}/Contents/Resources/backend/native_backend.py"
fi
# A leftover `swift run` build holds the single-instance lock, which would make the
# freshly installed app quit on launch without saying anything.
stop_matching "\.build/arm64-apple-macosx/(debug|release)/VoiceCloneStudio$"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"

# Keep one canonical bundle so Launch Services cannot revive an older per-user copy.
if [[ "$LEGACY_APP" != "$TARGET_APP" && -d "$LEGACY_APP" ]]; then
  LEGACY_BACKUP="$HOME/.Trash/Voice clone Studio (previous user install)-$(date +%Y%m%d-%H%M%S).app"
  mv "$LEGACY_APP" "$LEGACY_BACKUP"
  echo "The previous per-user copy was moved to Trash: $LEGACY_BACKUP"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$TARGET_APP"
open "$TARGET_APP"

echo "Voice clone Studio installed: $TARGET_APP"
