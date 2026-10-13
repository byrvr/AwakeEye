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

Run [`scripts/build-local.sh`](../../scripts/build-local.sh) from the repository. It builds the `KeepingYouAwake (Direct)` scheme as CoffeeBull, copies the app to `dist/`, and signs it locally. `COFFEEBULL_BUILD_DIR` and `COFFEEBULL_OUTPUT_DIR` override these paths. The app uses its own bundle identity and disables the upstream updater.

Verify a local build before enabling Red Bull:

1. Launch the app and check the Coffee/Red Bull menu and mode icons.
2. Start and stop Coffee and exercise a short duration.
3. Cancel a Red Bull authentication prompt; it must remain inactive or return to an already active Coffee session.
4. On a ventilated surface, authorize Red Bull and check `pmset -g` for `SleepDisabled 1`.
5. Stop Red Bull and check for `SleepDisabled 0`. Repeat with a short duration and with app termination.
6. Perform a physical lid-close test to confirm continued execution and network access on the target Mac.

Steps 4–6 change the live sleep policy and should be performed deliberately. Compilation and mocked watchdog tests verify code paths without changing the Mac's sleep settings.

Run `bash scripts/test-watchdog.sh` for the safe watchdog tests. They generate the script from the production Objective-C source, substitute mock power/process commands and temporary paths, and cover session exit, watchdog termination, identity mismatch, enable failure, activation races, concurrent-session refusal, and failed-cleanup retries. They do not request administrator access or change the Mac's sleep policy.

# Recovery

If cleanup fails, CoffeeBull displays **Sleep Restore Failed** in its menu and keeps that warning visible even if Coffee continues running. Red Bull refuses to start while its previous session has not finished cleanup. Stopping or expiring a session shows the failure once; quitting logs it without interrupting shutdown.

To recover, first quit **all CoffeeBull instances**. Then restore normal sleep:

```sh
sudo pmset -a disablesleep 0
pmset -g
```

Confirm that `pmset -g` reports `SleepDisabled 0`. Only after all instances are stopped and normal sleep is restored, remove the empty session lock:

```sh
sudo rmdir /private/tmp/keepingyouawake-redbull.lock
```

If the lock does not exist, skip this step. `rmdir` removes only an empty directory; if it reports that the directory is not empty, leave it in place and investigate before restarting Red Bull. Do not remove the lock while any CoffeeBull instance is running. After successful recovery, reopen CoffeeBull.

An external `pmset` override remains in effect while Coffee is selected. Red Bull's global override also blocks manual Sleep and applies on battery, so keep the Mac ventilated and connected to power for long sessions.
