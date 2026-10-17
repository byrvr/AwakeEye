# AwakeEye

A macOS menu-bar app with two wake modes and an eye icon that shows the current state. Forked from [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake).

| Mode | Behavior |
| --- | --- |
| **Coffee ☕** | Keeps the Mac awake during inactivity using `caffeinate`; follows the display and duration preferences. |
| **Red Bull ⚡** | Also disables system sleep, including lid-close and manual Sleep, on both charger and battery. Requires one-time native macOS administrator setup; routine toggles do not prompt. |

Right-click the menu-bar eye to select a mode. Selecting a mode starts it; left-click the eye to stop or restart it. The eye is crossed out when inactive, open in Coffee, and badged in Red Bull. Every launch starts in Coffee.

Red Bull ends when you stop it, switch to Coffee, reach the selected duration, or quit. Its helper also restores normal sleep after an app crash or helper restart. Keep a running, closed Mac ventilated; battery drain continues.

## Download and install

Download **AwakeEye-0.3.0-macos-arm64.zip** from the [latest release](https://github.com/byrvr/AwakeEye/releases/latest). This release is for **Apple Silicon Macs running macOS 12 or newer**; an Intel download is not currently provided.

1. Quit an existing CoffeeBull installation, if present.
2. Unzip the download and move **AwakeEye.app** to **/Applications**.
3. Open AwakeEye, then select a wake mode from the menu-bar eye. Red Bull needs its one-time macOS administrator approval to install the sleep helper.

The download is ad-hoc signed. It is not Developer ID signed or notarized, so macOS may block its first launch. If you trust the downloaded release, follow Apple's [instructions for opening an app from an unidentified developer](https://support.apple.com/102445). The release includes `SHA256SUMS` to check the downloaded archive.

Regular Red Bull toggles and app restarts do not need a password. Updating this locally signed app may require one new setup approval. The helper accepts only on, off, and status requests from the authorized app build; it stores no password and adds no sudo rule.

AwakeEye preserves CoffeeBull's bundle ID, preferences, and helper identifiers so existing installations can migrate. The old CoffeeBull app should stay closed while using AwakeEye. Upstream automatic updates are disabled.

## Build a copy

Requires Xcode and its command-line tools. From the repository root:

```sh
./scripts/build-local.sh
open dist/AwakeEye.app
```

Install `AwakeEye.app` at `/Applications/AwakeEye.app` before enabling Red Bull. To create the release archive and checksums:

```sh
./scripts/package-release.sh
```

See the [documentation map](docs/INDEX.md) for architecture, validation, packaging, and sleep recovery. The app supports `awakeeye://` URLs and retains `coffeebull://` compatibility.

## Sleep recovery

Coffee leaves an externally established global sleep override in place. Red Bull takes ownership of that setting and restores normal sleep when its session ends. To restore normal sleep manually:

```sh
sudo pmset -a disablesleep 0
```

See [build and recovery](docs/operations/build-and-recovery.md) for helper removal and troubleshooting.

## Attribution and license

AwakeEye is a fork of Marcel Dierkes's [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake), which was inspired by Lighthead Software's Caffeine and uses Apple's `caffeinate` utility. The original project remains available at [keepingyouawake.app](https://keepingyouawake.app/).

Development of this fork takes place at [byrvr/AwakeEye](https://github.com/byrvr/AwakeEye). For contributions to the original project, read its [contribution guidelines](CONTRIBUTING.md).

The project and its provided image assets use the [MIT license](LICENSE), retaining the original copyright and license notice.
