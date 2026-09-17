# Voice Clone Studio

Voice Clone Studio is a local Apple Silicon application for voice design, zero-shot voice cloning, speech recognition, and low-latency voice transformation with Qwen3 models and MLX.

The project includes two interfaces:

- a Gradio web application on `127.0.0.1:7860` with a local WebSocket service on port `7861`;
- a native SwiftUI menu-bar application with an embedded Python runtime and a local backend on port `7862`.

## Privacy and consent

All inference runs locally. Model weights are downloaded to the Hugging Face cache on first use. Generated audio, voice references, transcripts, saved voices, recordings, and model files are runtime data and are intentionally excluded from Git.

Use only voices that you own or have permission to process. Clearly disclose synthetic audio when appropriate. See [PRIVACY.md](PRIVACY.md) for the repository data policy.

## Requirements

- Apple Silicon Mac
- macOS 14 or later for the native app
- Python 3.11
- [uv](https://docs.astral.sh/uv/)
- `ffmpeg`
- Swift 6 toolchain for native builds

## Web application

Run:

```bash
./start.command
```

Then open <http://127.0.0.1:7860>.

The web application provides voice design, reference transcription, zero-shot cloning, a sample editor, speaker-region heuristics, text-to-voice generation, and live voice processing.

## Native macOS application

Build and install:

```bash
./macos/VoiceCloneStudio/install.command
```

The app installs to `/Applications/Voice clone Studio.app` by default. Override the destination with `VOICE_CLONE_INSTALL_DIR`.

Builds use ad-hoc signing by default. To use your own stable Apple Development identity, pass it at build time without storing it in the repository:

```bash
VOICE_CLONE_SIGN_IDENTITY="<your signing identity>" \
  ./macos/VoiceCloneStudio/install.command
```

## Models

- `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit`
- `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit`
- `mlx-community/Qwen3-ASR-0.6B-8bit`

Model weights are not included in the repository.

## Verification

```bash
python3 scripts/privacy_check.py
python3 -m py_compile app.py native_backend.py
swift test --package-path macos/VoiceCloneStudio
```

The privacy check rejects tracked audio, voice data, model files, secret material, personal machine paths, workplace identifiers, and Cyrillic repository text.
