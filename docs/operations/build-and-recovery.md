---
title: Build, validation, and sleep recovery
status: current
language: en
owner: byrvr
last-updated: 2026-10-17
audience: both
scope: system
related:
  - ../architecture/wake-modes.md
---

# Installation, build, and validation

The [latest GitHub release](https://github.com/byrvr/AwakeEye/releases/latest) provides `AwakeEye-0.3.0-macos-arm64.zip` and `SHA256SUMS`. The binary supports Apple Silicon and macOS 12 or newer; no Intel binary is currently published. Unzip the archive and move `AwakeEye.app` to `/Applications`. Quit CoffeeBull before opening AwakeEye; they share their bundle ID, preferences, and helper.

Release builds are ad-hoc signed with Hardened Runtime, not Developer ID signed or notarized. macOS may block the first launch; users who trust the release can follow Apple's [instructions for opening an app from an unidentified developer](https://support.apple.com/102445). Red Bull helper setup requires the installed app to be at `/Applications/AwakeEye.app`.

Run [`scripts/build-local.sh`](../../scripts/build-local.sh). It compiles and signs the constrained helper, bakes its digest into the app, builds AwakeEye, packages the helper as a resource, and locally signs the app with Hardened Runtime. The default export is `dist/AwakeEye.app`. `AWAKEEYE_BUILD_DIR` and `AWAKEEYE_OUTPUT_DIR` override build/export paths; the legacy `COFFEEBULL_BUILD_DIR` and `COFFEEBULL_OUTPUT_DIR` variables remain fallback aliases. The unused upstream updater is disabled and its external framework is removed.

Selecting Red Bull performs one-time native administrator setup. Setup installs `/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.Helper` and `/Library/LaunchDaemons/app.byrvr.CoffeeBull.Helper.plist`; the helper socket is `/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.sock`. These technical identifiers remain unchanged from CoffeeBull. App restarts preserve setup. A rebuilt app may need approval again because this local build pins its executable hash.

Run [`scripts/package-release.sh`](../../scripts/package-release.sh) to package the built app as `AwakeEye-0.3.0-macos-arm64.zip` and produce `SHA256SUMS` in `dist/releases` by default. It also accepts an app path and release directory as its two positional arguments. Verify the archive checksum after downloading it:

```sh
shasum -a 256 -c SHA256SUMS
```

Run safe regression checks before live testing:

```sh
./scripts/test-timer-lifetime.sh
./scripts/test-watchdog.sh
./scripts/test-helper-client.sh
```

Tests use mocked power operations and do not change the Mac sleep policy. For live validation, activate Red Bull once and approve setup, then stop/restart it repeatedly and after relaunching AwakeEye. Routine toggles must not show another password dialog. Check `pmset -g` for `SleepDisabled 1` while active and `0` after stop. Test crash recovery and daemon restart, and perform a physical lid-close test on the target Mac.

The CoffeeBull 0.2.0 local installation was checked on 2026-10-13: three Red Bull stop/start cycles completed without another prompt; an unapproved process was rejected; killing the app restored `SleepDisabled 0`; relaunching and activating Red Bull required no new approval; switching to Coffee restored normal sleep. This is historical validation of 0.2.0, not a claim of live 0.3.0 testing. A physical lid-close session and live daemon restart remain untested.

# Recovery and removal

If the helper reports a reset failure, stop AwakeEye and run:

```sh
sudo pmset -a disablesleep 0
pmset -g
```

The helper retains its ownership marker until it confirms reset; restarting its daemon retries recovery. The current marker is `/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.active`. Never remove it while a lease is active.

To remove the helper after quitting AwakeEye (and any older CoffeeBull instance), first restore normal sleep, then stop its daemon and remove only its own installed files:

```sh
sudo pmset -a disablesleep 0
sudo launchctl bootout system/app.byrvr.CoffeeBull.Helper
sudo rm /Library/LaunchDaemons/app.byrvr.CoffeeBull.Helper.plist
sudo rm /Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.Helper
```

Coffee leaves an external sleep override in effect. Red Bull takes ownership and resets the flag when its session ends. The override affects battery and charger and blocks manual Sleep; keep the running Mac ventilated.
