<p align="center"><img src="docs/icon.png" width="96" alt="parrot"></p>

# Parrot

A fully local meeting recorder and transcriber. Parrot records your mic and the call's audio as separate tracks, transcribes them on-device, and writes a timestamped `me` / `them` transcript. Nothing leaves the machine.

## 1. Install

```sh
./scripts/build-macos-app          # builds macos/.build/Parrot.app
sudo ./scripts/install-macos       # → /Applications/Parrot.app + /usr/local/bin/parrot
open /Applications/Parrot.app      # or launch Parrot from Launchpad / Spotlight
```

Parrot is a menu-bar-only app (no Dock tile). Turn on **Launch at login** from
its menu so it comes back after a reboot. Requires macOS 15+. Apple Silicon is
recommended for transcription speed.

## 2. Usage

1. Click the feather in the menu bar and choose **Start recording**. First use asks for microphone and system audio permissions.
2. Choose **Stop recording** when the meeting ends. Transcription starts automatically.
3. The transcript lands in `~/Recordings/<yyyy.MM.dd-HHmm>/transcript.md`, next to the audio.

See the [macOS documentation](macos/README.md) for configuration, the CLI, and troubleshooting.

## 3. Platforms

| Platform | Status | Documentation |
|---|---|---|
| macOS 15+ | Working | [macOS](macos/README.md) |
| Windows 11 | Capture probe planned | [Windows](windows/README.md) |
| Linux | Capture probe proposed | [Linux](linux/README.md) |

Each platform is a native, independent implementation. They share the session layout, transcript format, and test fixtures, not source code. See [docs/architecture.md](docs/architecture.md).

## 4. License

[MIT](LICENSE).
