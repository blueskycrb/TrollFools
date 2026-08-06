# TrollStore 0702 Integration

This directory builds the current TrollFools injection engine into the binary-only `TrollStore_2.1.1_0702.tar` release without rebuilding its unpublished modifications.

The resulting TrollStore app adds two actions to each installed app menu:

- Inject with TrollFools
- Manage TrollFools plugins

Automatic reconciliation runs when TrollStore launches or becomes active. Injection assets and profiles use the same `/var/mobile/Library/TrollFools` paths as the standalone app. No local auto-inject folder is created or scanned.

## Build

The build requires macOS, Xcode 15.4, Homebrew `openssl@3`, and `pkg-config`.

```bash
integration/build-patched-trollstore.sh \
  /path/to/TrollStore_2.1.1_0702.tar \
  /path/to/TrollStore_2.1.1_0702_TrollFools.tar
```

The GitHub Actions workflow reads the base archive from a draft release asset so the third-party binary is not committed to the repository.

## Rollback

Install the original `TrollStore_2.1.1_0702.tar` through the TrollStore update flow. Existing persisted TrollFools plugins remain in `/var/mobile/Library/TrollFools` until removed manually or through the integrated plugin manager.
