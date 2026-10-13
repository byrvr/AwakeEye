---
title: Wake modes and cleanup
status: current
language: en
owner: byrvr
last-updated: 2026-10-12
audience: both
scope: system
related:
  - ../operations/build-and-recovery.md
---

# Wake modes and cleanup

[KYAAppController](../../KeepingYouAwake/KYAAppController/KYAAppController.m) owns the selected mode and the current sleep timer. The menu displays Coffee or Red Bull and active status. Launch starts in Coffee; selecting a mode activates it, and switching preserves a timed session's deadline. Authentication time counts toward an existing deadline.

Coffee uses the upstream `KYASleepWakeTimer` and its `caffeinate` process. Red Bull additionally uses [KYAClosedLidSession](../../KeepingYouAwake/KYAClosedLidSession.m), which creates a lease process watching the app's PID. A native administrator prompt authorizes a fixed privileged shell script; it verifies the lease identity and starts a watchdog before enabling `pmset -a disablesleep 1`.

The watchdog waits for the lease's process-exit event and resets `disablesleep` to 0 when the lease ends. Controller deactivation terminates the lease. App exit or crash also releases it through `caffeinate -w`. The watchdog acknowledges activation and cleanup; a new session waits for cleanup of its previous session to avoid a late reset stopping the new one.

Cancelled authentication leaves Red Bull inactive. Stopping, timer expiry, applicable battery settings, user switching, and quitting use the same cleanup path. Fresh timer instances isolate asynchronous callbacks from the preceding session.

The sleep flag is systemwide and persists independently of the app. Coffee does not reset an override established elsewhere. Starting Red Bull explicitly takes ownership and cleanup sets the flag to 0, including if it was already 1. The watchdog is a temporary process, with no installed root helper or launch daemon. If its cleanup fails, use the recovery command in the operations guide. Multiple tools changing the global flag can interfere with each other.
