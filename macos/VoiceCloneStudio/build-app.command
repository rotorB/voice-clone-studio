#!/bin/zsh
set -euo pipefail

MODULE_DIR="${0:A:h}"
PROJECT_DIR="${MODULE_DIR:h:h}"
DIST_DIR="$MODULE_DIR/dist"
APP_PATH="$DIST_DIR/Voice clone Studio.app"
RUNTIME_CACHE="$MODULE_DIR/.backend-runtime"
REQUIREMENTS_FILE="$MODULE_DIR/native-requirements.txt"
PYTHON_FRAMEWORK_SOURCE="/opt/homebrew/opt/python@3.11/Frameworks/Python.framework"
SIGN_IDENTITY="${VOICE_CLONE_SIGN_IDENTITY:--}"

cd "$PROJECT_DIR"
REQUIREMENTS_HASH="$(shasum -a 256 "$REQUIREMENTS_FILE" | awk '{print $1}')"
CURRENT_HASH=""
if [[ -f "$RUNTIME_CACHE/requirements.sha256" ]]; then
  CURRENT_HASH="$(<"$RUNTIME_CACHE/requirements.sha256")"
fi
if [[ "$CURRENT_HASH" != "$REQUIREMENTS_HASH" ]]; then
  rm -rf "$RUNTIME_CACHE"
  mkdir -p "$RUNTIME_CACHE/site-packages"
  uv pip install \
    --python /opt/homebrew/bin/python3.11 \
    --target "$RUNTIME_CACHE/site-packages" \
    --requirements "$REQUIREMENTS_FILE"
  print -r -- "$REQUIREMENTS_HASH" > "$RUNTIME_CACHE/requirements.sha256"
fi

if [[ ! -d "$PYTHON_FRAMEWORK_SOURCE" ]]; then
  echo "Python 3.11 framework was not found: $PYTHON_FRAMEWORK_SOURCE"
  exit 1
fi
if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
  echo "The requested code-signing identity was not found: $SIGN_IDENTITY"
  exit 1
fi

cd "$MODULE_DIR"
swift build -c release --arch arm64

rm -rf "$APP_PATH"
mkdir -p \
  "$APP_PATH/Contents/MacOS" \
  "$APP_PATH/Contents/Frameworks" \
  "$APP_PATH/Contents/Resources/backend/site-packages"
cp ".build/arm64-apple-macosx/release/VoiceCloneStudio" "$APP_PATH/Contents/MacOS/VoiceCloneStudio"
cp "Info.plist" "$APP_PATH/Contents/Info.plist"
cp "Assets/VoiceCloneStudio.icns" "$APP_PATH/Contents/Resources/VoiceCloneStudio.icns"
cp "$PROJECT_DIR/app.py" "$APP_PATH/Contents/Resources/backend/app.py"
cp "$PROJECT_DIR/native_backend.py" "$APP_PATH/Contents/Resources/backend/native_backend.py"
ditto "$RUNTIME_CACHE/site-packages" "$APP_PATH/Contents/Resources/backend/site-packages"
ditto "$PYTHON_FRAMEWORK_SOURCE" "$APP_PATH/Contents/Frameworks/Python.framework"

# A signed app bundle must stay immutable at runtime. Python bytecode is not
# needed here and would otherwise tempt the interpreter to create __pycache__.
find "$APP_PATH/Contents/Resources/backend" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$APP_PATH/Contents/Resources/backend" -type f -name '*.py[co]' -delete

BUNDLED_FRAMEWORK="$APP_PATH/Contents/Frameworks/Python.framework"
rm -rf "$BUNDLED_FRAMEWORK/Versions/3.11/_CodeSignature"
rm -f "$BUNDLED_FRAMEWORK/Versions/3.11/lib/python3.11/site-packages"
ln -s 3.11 "$BUNDLED_FRAMEWORK/Versions/Current"
ln -s Versions/Current/Python "$BUNDLED_FRAMEWORK/Python"
ln -s Versions/Current/Headers "$BUNDLED_FRAMEWORK/Headers"
ln -s Versions/Current/Resources "$BUNDLED_FRAMEWORK/Resources"
BUNDLED_PYTHON="$APP_PATH/Contents/Frameworks/Python.framework/Versions/3.11/bin/python3.11"
BUNDLED_LIBRARY="$APP_PATH/Contents/Frameworks/Python.framework/Versions/3.11/Python"
BUNDLED_PYTHON_APP="$APP_PATH/Contents/Frameworks/Python.framework/Versions/3.11/Resources/Python.app"
BUNDLED_INTERPRETER="$BUNDLED_PYTHON_APP/Contents/MacOS/Python"
SOURCE_LIBRARY="$(otool -L "$BUNDLED_PYTHON" | tail -n +2 | awk '/Python.framework.*Python/{print $1; exit}')"
INTERPRETER_SOURCE_LIBRARY="$(otool -L "$BUNDLED_INTERPRETER" | tail -n +2 | awk '/Python.framework.*Python/{print $1; exit}')"
install_name_tool -change "$SOURCE_LIBRARY" "@executable_path/../Python" "$BUNDLED_PYTHON"
install_name_tool -change "$INTERPRETER_SOURCE_LIBRARY" "@rpath/Python.framework/Versions/3.11/Python" "$BUNDLED_INTERPRETER"
install_name_tool -delete_rpath "/opt/homebrew/lib" "$BUNDLED_INTERPRETER" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../../../../../../.." "$BUNDLED_INTERPRETER"
install_name_tool -id "@rpath/Python.framework/Versions/3.11/Python" "$BUNDLED_LIBRARY"
install_name_tool -delete_rpath "/opt/homebrew/lib" "$BUNDLED_LIBRARY" 2>/dev/null || true

# Homebrew's Python extension modules link to a small set of Homebrew dylibs.
# Copy those dylibs into Contents/Frameworks and rewrite every absolute link.
MACHO_LIST="$RUNTIME_CACHE/macho-files.txt"
find "$APP_PATH/Contents/Resources/backend/site-packages" -type f \( -name '*.so' -o -name '*.dylib' \) -print > "$MACHO_LIST"
find "$BUNDLED_FRAMEWORK/Versions/3.11/lib/python3.11/lib-dynload" -type f -name '*.so' >> "$MACHO_LIST"
print -r -- "$BUNDLED_INTERPRETER" "$BUNDLED_PYTHON" "$BUNDLED_LIBRARY" >> "$MACHO_LIST"

while IFS= read -r binary; do
  otool -L "$binary" 2>/dev/null | tail -n +2 | awk '/\/opt\/homebrew.*\.dylib/{print $1}'
done < "$MACHO_LIST" | sort -u | while IFS= read -r dependency; do
  [[ "$dependency" == *"Python.framework/"* ]] && continue
  cp -L "$dependency" "$APP_PATH/Contents/Frameworks/${dependency:t}"
done

find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -type f -name '*.dylib' >> "$MACHO_LIST"
while IFS= read -r binary; do
  patched=0
  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    if [[ "$dependency" == *"Python.framework/"* ]]; then
      install_name_tool -change "$dependency" "@rpath/Python.framework/Versions/3.11/Python" "$binary"
    else
      install_name_tool -change "$dependency" "@rpath/${dependency:t}" "$binary"
    fi
    patched=1
  done < <(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '/\/opt\/homebrew/{print $1}')
  if (( patched )); then
    codesign --force --sign "$SIGN_IDENTITY" "$binary"
  fi
done < "$MACHO_LIST"

for library in "$APP_PATH"/Contents/Frameworks/*.dylib; do
  install_name_tool -id "@rpath/${library:t}" "$library"
  codesign --force --sign "$SIGN_IDENTITY" "$library"
done

codesign --force --sign "$SIGN_IDENTITY" "$BUNDLED_PYTHON"
codesign --force --deep --sign "$SIGN_IDENTITY" "$BUNDLED_PYTHON_APP"
codesign --force --sign "$SIGN_IDENTITY" "$BUNDLED_LIBRARY"
codesign --force --sign "$SIGN_IDENTITY" "$BUNDLED_FRAMEWORK"
codesign --force --deep --entitlements "$MODULE_DIR/VoiceCloneStudio.entitlements" --sign "$SIGN_IDENTITY" "$APP_PATH"

echo "Built: $APP_PATH"
du -sh "$APP_PATH"
open -R "$APP_PATH"
