# Changelog

## 0.2.0 - 2026-10-13

- Renamed the project from Quill to Parrot: package, executable, bundle id
  (`com.suujia.parrot`), config path (`~/.config/parrot/config.json`, with a
  one-release fallback to the old `~/.config/quill/config.json`), scripts,
  logs (`/tmp/parrot.*.log`), and docs. Session folders and transcript formats
  are unchanged.
- Shipped macOS Parrot as a real menu-bar app bundle: `scripts/build-macos-app`
  assembles `Parrot.app` (icon, Info.plist with `LSUIElement`, ad-hoc
  hardened-runtime signature) and `scripts/install-macos` installs it into
  `/Applications` with `/usr/local/bin/parrot` symlinked into the bundle.
- Replaced the hand-written LaunchAgent with `SMAppService.mainApp`, so Parrot
  appears in Login Items; added a "Launch at login" menu toggle with approval
  guidance, and kept a crash-restarting LaunchAgent behind
  `install --launch-at-login --keep-alive`.
- Made Parrot behave like a persistent app: single instance per bundle id,
  reopening pops the menu-bar menu, quit/logout stops a live session cleanly,
  and notifications go through `UNUserNotificationCenter` from the bundle.
- Fixed starting a recording with no microphone device crashing the app
  instead of reporting the failure.

## 0.1.3 - 2026-08-04

- Fixed macOS route changes silently truncating capture: both tracks now have
  callback-progress health monitoring, route-change observation, and automated
  recovery that restarts a stalled track on the current audio route into a new
  numbered segment without touching audio already written.
- Introduced session metadata schema v2 (`tracks[].segments[]` with monotonic
  session-clock offsets, interruption records, and a
  complete/recovered/incomplete status); v1 sessions remain transcribable.
- Made the menu bar and notifications surface recovering, degraded, and
  incomplete capture instead of always showing a healthy recording, and
  carried the capture status into the readable transcript header.
- Added a deterministic macOS test suite covering the health state machine,
  recovery orchestration, stop races, schema compatibility, and
  offset-preserving transcript merges.
- Organized Quill as a multiplatform repository with native macOS, Windows,
  and Linux platform roots, stable macOS build scripts, and an explicit shared
  architecture boundary.

## 0.1.2 - 2026-08-02

- Made Windows WAV checkpoints durably order PCM and header updates so an
  interrupted recording remains decodable without declaring unwritten audio.
- Added subprocess crash tests that abort at every checkpoint boundary and
  verify the resulting files with an independent WAV decoder.

## 0.1.1 - 2026-08-02

- Fixed Windows capture startup so recording is reported only after the WAV
  file and WASAPI stream are ready.
- Resolved audio renderer processes to their user-facing application roots
  without broadening capture into shell, terminal, or service processes.
- Made process-loopback recording stop with a diagnostic when its target exits
  instead of silently continuing against an obsolete PID.
