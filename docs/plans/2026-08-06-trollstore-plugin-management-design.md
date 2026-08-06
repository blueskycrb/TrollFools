# TrollStore Plugin Management Design

## Goals

The TrollStore integration must support three complete workflows per installed app:

1. Pause or enable an injected plugin without deleting its persisted copy.
2. Download a plugin from an HTTP or HTTPS direct URL and inject it through the same path as a locally selected file.
3. Restore every enabled, manually injected plugin when TrollStore next becomes active after an app update.

## State Model

`/var/mobile/Library/TrollFools/Profiles` remains the source of truth for desired plugin state. An enabled plugin is present in the target app and should be restored after an update. A paused plugin remains in TrollFools persistent storage but has `enabled = false`, so reconciliation must not inject it. Removing a plugin deletes both its persistent copy and profile entry.

The CLI owns state transitions so the standalone app and TrollStore cannot diverge. A new plugin-state command performs the physical inject or eject operation and updates the profile only after the operation succeeds.

## TrollStore UI

The app action sheet gains a `Download and Inject` command. It accepts a direct HTTP or HTTPS URL, validates the response and supported plugin type, stages the downloaded file, then invokes the existing persistent `inject` command. The per-app plugin manager shows each plugin's current status. Selecting a plugin opens a second action sheet containing `Pause` or `Enable`, plus a destructive `Remove` command.

## Automatic Restoration

Opening or returning to TrollStore runs `reconcile`. Reconciliation reports profile failures through the CLI exit status instead of always returning success. TrollStore retries failed reconciliation after short delays so LaunchServices and newly replaced app bundles can settle. Successful manual and downloaded injections already persist assets and record enabled profile entries, so both participate in restoration.

## Verification

CI must compile the CLI and integration dylib, rebuild the patched TrollStore archive, and confirm the required executables are signed and present. Static checks must confirm the new CLI command, URL action, pause/enable actions, and reconciliation retry strings are embedded in the output.
