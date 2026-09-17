# Quick start

## Web application

From the repository root:

```bash
./start.command
```

Open <http://127.0.0.1:7860>. The first run creates the Python environment and downloads dependencies. Model weights download only when their features are used.

## Native macOS application

Run:

```bash
./macos/VoiceCloneStudio/install.command
```

The app is installed in `/Applications` by default and appears in the menu bar. macOS may request microphone and Screen & System Audio Recording permissions.

The native app stores runtime data under:

```text
~/Library/Application Support/Voice clone Studio/output/
```

The web app stores runtime output under the ignored local `output/` directory.

## Virtual microphone

Run `./install-virtual-mic.command` to install BlackHole 2ch with Homebrew. Select BlackHole as the Studio output and as the microphone in the destination call application. Create a Multi-Output Device in Audio MIDI Setup if local monitoring is also required.

## Stop the web application

Press `Ctrl+C` in the terminal that runs the server.
