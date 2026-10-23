# Development and troubleshooting

[Back to README](../README.md)

## Installation

The prebuilt package requires macOS 13 or later and Apple Silicon (M-series chips). Unzip `Wink-0.1.0-macos-arm64.zip` and drag `Wink.app` into Applications.

Wink is not notarized by Apple. If macOS blocks it, verify the download source, then choose **System Settings → Privacy & Security → Open Anyway**. See [Apple’s guide](https://support.apple.com/102445).

## Build and verify

Requires macOS 13 or later and Swift 5.9 or later. Run from the project directory:

```sh
swift test
bash scripts/check-ui.sh
bash scripts/build.sh
open build/Wink.app
```

- `swift test` checks core state, recovery transactions, and failure paths.
- `scripts/check-ui.sh` compiles the production AppKit controls and checks clicks, mascot feedback, shortcut recording, schedules, and time wheels in English and Chinese. It requires a macOS graphical session, uses isolated state, and writes output to `.tmp/ui-check/`.
- `scripts/build.sh` builds an ad-hoc signed `build/Wink.app` for the host architecture.

Create a release package for the host architecture:

```sh
bash scripts/package-release.sh
```

The ZIP and SHA-256 checksum are written to `build/releases/`. The script builds in a fresh directory without replacing a running development app. It refuses to overwrite an existing release package. The app includes the MIT license and is not notarized by Apple.

## Automated releases

GitHub Actions runs core tests, English and Chinese AppKit checks, packaging, and archive verification on an Apple Silicon runner for pushes to `main` and pull requests. Build artifacts are retained for 14 days.

To publish a version, update the version and build number in `scripts/build.sh` and the fallback values in `Sources/Wink/AppInfo.swift`, then add `docs/releases/vX.Y.Z.md`. Commit and push the changes, then push the matching `vX.Y.Z` tag. After all checks pass, the workflow publishes a Release with the ZIP and SHA-256 checksum. Tags must match the app version; existing releases are not overwritten. No Apple signing certificate is configured, so the app remains ad-hoc signed and unnotarized.

CI checks do not exercise physical display blackout, hot-plug behavior, or Gatekeeper prompts after downloading.

## Display checks

Inspect displays without changing them:

```sh
build/Wink.app/Contents/MacOS/Wink --probe
```

**The following test blacks out physical screens for about 10 seconds.** Quit the menu bar app first. The test restores the displays and compares their Gamma data with the original snapshots:

```sh
build/Wink.app/Contents/MacOS/Wink --cycle-test
```

## Recovery

Use the backup shortcut Control + Option + Command + R or **Restore Display** in the menu. Control + Option + Command + B is an additional toggle shortcut.

Wink restores displays before a normal exit. If recovery fails, it keeps the app running and preserves the records for retrying. Force-quitting cannot guarantee immediate restoration; reopening Wink attempts pending recovery. Records for disconnected displays remain until reconnection, without blocking recovery of other displays or normal exit.

If Wink has exited but restoration is still needed, run:

```sh
build/Wink.app/Contents/MacOS/Wink --restore
```

For an installed app, use `"/Applications/Wink.app/Contents/MacOS/Wink" --restore`. Records are stored in `~/Library/Application Support/ScreenPause/restore.json`. Each display's record is cleared only after restoration and successful readback. Disconnected or failed displays retain their records; the file is removed when all records are cleared. Do not delete pending recovery records manually.

## Behavior and compatibility

- Click the mascot or menu bar icon, or press Control + Option + B, to toggle blackout. Right-click the menu bar icon to open the panel, settings, or restore and quit. Closing the window leaves Wink running in the background.
- Use the gear to change the shortcut, enable launch at login, or set a schedule. A shortcut must include Command, Option, or Control. Press Esc to cancel recording; right-click the shortcut to restore its default. If macOS requests approval for launch at login, follow the prompt to System Settings.
- Wink adjusts Gamma tables without changing hardware brightness, adding black overlays, or locking the screen. LCD backlights may remain on. Compatibility with HDR, screensavers, screen locking, and other color-adjustment tools has not been fully verified.
- During blackout, Wink requests prevention of idle display sleep and releases that request on restore. It attempts restoration if it detects external Gamma changes. MonitorControl can remain installed; simultaneous use depends on its automatic dimming behavior.
- Display connections preserve the current target and schedule. Known displays reuse their original Gamma snapshots on reconnection. Newly connected displays have their original Gamma saved before blackout. Quartz configuration notifications pause fade writes during reconfiguration, followed by a brief period of reapplying the blackout target before strict verification resumes. The system may briefly light up screens before notifications arrive.
- Online displays whose Gamma cannot yet be read are retried independently. Persistent read failures retain recovery records without automatically restoring healthy displays. When no blackout or recovery is pending, Wink does not poll Gamma tables.
- Scheduling supports one period with at least one selected day and different start and end times. Defaults are 12:00–13:30, every day, with scheduling disabled. Selecting all seven days means every day.
- Valid schedule changes save automatically. An end time earlier than the start time means the following day. Scheduling runs only while Wink is running and the Mac is awake.
- Time and weekday formatting follow the system region; execution follows the local time zone. Overnight periods belong to their starting day: Friday 23:00–01:30 ends on Saturday morning.
- Automatic blackout pauses while settings are expanded and visible. The main panel may stay open after settings collapse. While running, Wink typically handles schedule boundaries within about one second. Starting Wink during an active period attempts blackout. Restoring early skips that period, including after a restart.
- A scheduled end restores only a blackout started by that schedule. It does not take over manual blackout. System sleep or detected external Gamma changes trigger a restoration attempt and skip the current period. Wink does not wake the computer.
- Shortcut conflict detection covers system registration conflicts, not every app's internal shortcuts. Failed registration keeps the previous shortcut. Migration changes only the old default Option + Space to Control + Option + B; custom combinations remain unchanged.
- Launch at login uses `SMAppService` and is disabled by default. While waiting for system approval, the switch indicates that registration was requested; switching it off cancels the request. Keep the app in a stable location before enabling it.

## Code and resources

| Directory | Contents |
| --- | --- |
| `Sources/ScreenCore/` | Displays, Gamma recovery, scheduling, and command protocol |
| `Sources/Wink/` | AppKit UI, menu bar, shortcuts, and app entry point |
| `Tests/ScreenCoreTests/` | Core logic tests |
| `Tests/WinkUI/main.swift` | Isolated native control regression checks |
| `Sources/ScreenCore/Resources/` | English and Simplified Chinese localization |
| `Sources/Wink/Resources/` | `mascot-wink.png` icon and `mascot-body.png` body |

The app chooses English or Chinese from system language preferences and falls back to English. The mascot's eyes use separate vector paths; the build script generates `.icns` using `sips` and `iconutil`.

Display adjustment uses `CGGetDisplayTransferByTable` and `CGSetDisplayTransferByTable`; see [MonitorControl's Gamma dimming implementation](https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Model/Display.swift).

The bundle ID is `local.liyin.screenpause`, and the application support directory is `ScreenPause`. Changes to these identifiers require migration of settings and recovery records.

Use English for public documentation and code comments. Keep the Chinese README in `README.zh-CN.md` and UI translations in localization resources.
