# CoffeeBull

A personal fork of [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake), with two menu-bar wake modes.

| Mode | Behavior |
| --- | --- |
| **Coffee ☕** | Keeps the Mac awake during inactivity using `caffeinate`; uses the existing display and duration preferences. |
| **Red Bull ⚡** | Also disables system sleep, including lid-close and manual Sleep, on both charger and battery. Requires one-time native macOS administrator setup; routine toggles do not prompt. |

Right-click the menu-bar icon to select a mode. Selecting a mode starts it; left-click the icon to stop or restart it. Red Bull is temporary: stopping, switching to Coffee, reaching the selected duration, or quitting ends the override. A constrained helper also restores normal sleep if the app crashes or the helper restarts. Every launch defaults to Coffee.

Red Bull takes ownership of the global sleep setting and resets it to normal on cleanup. **Coffee leaves any pre-existing global sleep override in place.** If sleep was already disabled using `pmset`, stop a Red Bull session or run `sudo pmset -a disablesleep 0` to restore normal sleep. Keep an awake, closed Mac ventilated; battery drain continues.

The fork uses the app name **CoffeeBull**, bundle ID `app.byrvr.CoffeeBull`, an Awake Eye icon, and URL scheme `coffeebull://`. Upstream automatic updates are disabled. The original KeepingYouAwake installation and preferences are separate.

The first Red Bull activation installs a root-owned, sleep-only helper after macOS administrator approval. The helper authenticates this exact signed app build and accepts only on, off, and status requests. No password is stored and no sudo rule is added. Approval survives app restarts; rebuilding/updating this locally signed app may require one setup approval again.

## Build a personal copy

Requires Xcode and its command-line tools. From the repository root:

```sh
./scripts/build-local.sh
open dist/CoffeeBull.app
```

This creates a locally signed development app. It is not Developer ID signed or notarized. Red Bull requires a build outside the App Sandbox; the personal fork's entitlements reflect that requirement.

Install the resulting `CoffeeBull.app` in `/Applications` before enabling Red Bull; its one-time helper setup requires that location.

See the [documentation map](docs/INDEX.md) for lifecycle details, validation, and recovery. The original project's background and attribution follow.

## Upstream: KeepingYouAwake

KeepingYouAwake is a small menu bar utility for macOS *(Version 10.13 and newer)* that can prevent your Mac from entering sleep mode for a predefined duration or as long as it is activated.

https://keepingyouawake.app/

### Upstream installation

**[Download the latest version here.](https://github.com/newmarcel/KeepingYouAwake/releases/latest)**

or install it via [cask](http://caskroom.github.io/): `brew install --cask keepingyouawake`.

<img src="./Extras/Screenshot@2x.jpg" width="500" />

## How does it work?

The app is a small wrapper around Apple's `caffeinate` command line utility. All current versions of macOS ship with this tool by default. You can read the manual page [here](https://web.archive.org/web/20140604153141/https://developer.apple.com/library/mac/documentation/Darwin/Reference/ManPages/man8/caffeinate.8.html).

### Does upstream KeepingYouAwake work on a MacBook with a closed lid?

Upstream does not. This fork adds closed-lid support through the separately authorized Red Bull mode described above.

## Is this dangerous?

This utility will not harm your Mac because it is based on an official command line tool by Apple. **BUT** I cannot guarantee anything, so use this tool **AT YOUR OWN RISK**.

## Inspired by Caffeine

*KeepingYouAwake* is inspired by *[Caffeine](https://web.archive.org/web/20240625031548/https://www.lightheadsw.com/caffeine/)* from *Lighthead Software*. I used it for many years, but sadly it hasn't been updated in a while. Eventually in 2014 I decided to build a replacement for myself that was optimized for macOS Yosemite and used the [`caffeinate`](https://web.archive.org/web/20140604153141/https://developer.apple.com/library/mac/documentation/Darwin/Reference/ManPages/man8/caffeinate.8.html) command line tool under the hood.

## Still using old macOS versions?

- [Version 1.6.8](https://github.com/newmarcel/KeepingYouAwake/releases/tag/1.6.8) is the last release that supports macOS Big Sur and older (11.0, 10.15, 10.14, 10.13)
- [Version 1.6.2](https://github.com/newmarcel/KeepingYouAwake/releases/tag/1.6.2) is the last release that supports macOS Sierra (10.12)
- [Version 1.5.2](https://github.com/newmarcel/KeepingYouAwake/releases/tag/1.5.2) is the last release that supports macOS Yosemite (10.10) and El Capitan (10.11)

## Upstream contribution guidelines

For contributions to the original project, read its [Contribution Guidelines](./CONTRIBUTING.md). Development of this personal fork stays in `byrvr/KeepingYouAwake`.

## License

Everything in this project is licensed under the [MIT license](http://opensource.org/licenses/MIT). Provided image assets are also covered by this license.

*Although it's not required please do not redistribute forked versions of the app with the same name and icon. Thanks!*
