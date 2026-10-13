---
title: Build, validation, and sleep recovery
status: current
language: en
owner: byrvr
last-updated: 2026-10-13
audience: both
scope: system
related:
  - ../architecture/wake-modes.md
---

# Build and validation

Run [`scripts/build-local.sh`](../../scripts/build-local.sh). It compiles and signs the constrained helper, bakes its digest into the app, builds CoffeeBull, packages the helper as a resource, and locally signs the app with Hardened Runtime. `COFFEEBULL_BUILD_DIR` and `COFFEEBULL_OUTPUT_DIR` override build/export paths. The unused upstream updater is disabled and its external framework is removed.

Install the app at `/Applications/CoffeeBull.app`. Selecting Red Bull performs one-time native administrator setup. Setup installs `/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.Helper` and `/Library/LaunchDaemons/app.byrvr.CoffeeBull.Helper.plist`; the helper socket is `/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.sock`. App restarts preserve setup. A rebuilt app may need approval again because this local build pins its executable hash.

Run safe regression checks before live testing:

```sh
./scripts/test-timer-lifetime.sh
./scripts/test-watchdog.sh
./scripts/test-helper-client.sh
```

Tests use mocked power operations and do not change the Mac sleep policy. For live validation, activate Red Bull once and approve setup, then stop/restart it repeatedly and after relaunching CoffeeBull. Routine toggles must not show another password dialog. Check `pmset -g` for `SleepDisabled 1` while active and `0` after stop. Test crash recovery and daemon restart, and perform a physical lid-close test on the target Mac.

The 0.2.0 local installation was checked on 2026-10-13: three Red Bull stop/start cycles completed without another prompt; an unapproved process was rejected; killing the app restored `SleepDisabled 0`; relaunching and activating Red Bull required no new approval; switching to Coffee restored normal sleep. A physical lid-close session and live daemon restart remain untested.

# Recovery and removal

If the helper reports a reset failure, stop CoffeeBull and run:

```sh
sudo pmset -a disablesleep 0
pmset -g
```

The helper retains its ownership marker until it confirms reset; restarting its daemon retries recovery. The current marker is `/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.active`. Never remove it while a lease is active.

To remove the helper after quitting CoffeeBull, first restore normal sleep, then stop its daemon and remove only its own installed files:

```sh
sudo pmset -a disablesleep 0
sudo launchctl bootout system/app.byrvr.CoffeeBull.Helper
sudo rm /Library/LaunchDaemons/app.byrvr.CoffeeBull.Helper.plist
sudo rm /Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.Helper
```

Coffee leaves an external sleep override in effect. Red Bull takes ownership and resets the flag when its session ends. The override affects battery and charger and blocks manual Sleep; keep the running Mac ventilated.
