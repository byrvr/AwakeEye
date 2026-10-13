---
title: Wake modes and cleanup
status: current
language: en
owner: byrvr
last-updated: 2026-10-13
audience: both
scope: system
related:
  - ../operations/build-and-recovery.md
---

# Wake modes and cleanup

[KYAAppController](../../KeepingYouAwake/KYAAppController/KYAAppController.m) owns Coffee or Red Bull and the current timer. Launch starts in Coffee; mode switches preserve the current absolute deadline, including authorization time. Awake Eye stays a consistent menu-bar identity: crossed-out when inactive, open in Coffee, badge in Red Bull.

Coffee uses the upstream `caffeinate` timer. Red Bull uses [KYAClosedLidSession](../../KeepingYouAwake/KYAClosedLidSession.m) to communicate with the installed [CoffeeBullHelper](../../Helper/CoffeeBullHelper.m) over a local Unix socket. The first activation performs native administrator setup. Later activations use fixed ON/OFF/STATUS requests without authentication prompts.

The root-owned helper accepts the configured user and exact signed app code hash, using the kernel audit token and Security framework validation. The app verifies that its socket peer is root. Only fixed `pmset` arguments can run; requests cannot supply commands, paths, or arguments. The installer verifies a staged helper against a SHA-256 digest baked into the signed app before installing it.

A helper-owned lease is tied to the authenticated app identity and process lifetime. Stop, expiry, mode change, quit, or crash restores sleep. A persistent root-owned ownership marker allows recovery if the daemon restarts. Without a marker, startup leaves any externally established sleep override alone. Cleanup errors remain visible. The helper refuses competing app instances.

This personal build pins the exact executable hash rather than a trusted publisher identity. Rebuilding or updating the app may therefore need setup authorization once again. The helper runs through launchd; its files and configuration are root-owned. No password, blanket sudo permission, or general-purpose root execution is provided.

Fresh timer instances and guarded callbacks isolate sessions; deallocation only stops the child task and never queues callbacks retaining a destroyed timer.
