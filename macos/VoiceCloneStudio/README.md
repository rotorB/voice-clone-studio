# Voice Clone Studio for macOS

This module builds a native SwiftUI menu-bar application for local Qwen3-ASR and Qwen3-TTS inference. The application bundle contains Python 3.11, the MLX backend, and runtime dependencies. Model weights remain in the user's Hugging Face cache.

## Build and install

From the repository root:

```bash
./macos/VoiceCloneStudio/install.command
```

The app installs to `/Applications/Voice clone Studio.app` by default. Set `VOICE_CLONE_INSTALL_DIR` to choose another destination.

Ad-hoc signing is used unless `VOICE_CLONE_SIGN_IDENTITY` is supplied. Keep personal signing identities outside version control:

```bash
VOICE_CLONE_SIGN_IDENTITY="<your signing identity>" \
  ./macos/VoiceCloneStudio/install.command
```

## Permissions

macOS requests microphone permission for recording and Screen & System Audio Recording permission for system-audio capture. An ad-hoc signature may cause permissions to be requested again after rebuilding. A stable personal signing identity avoids that behavior.

## Runtime data

The native application stores audio, transcripts, logs, references, and the local voice library under:

```text
~/Library/Application Support/Voice clone Studio/
```

None of that runtime data belongs in Git.

## Tests

```bash
swift test --package-path macos/VoiceCloneStudio
```
