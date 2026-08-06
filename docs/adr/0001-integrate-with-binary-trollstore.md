# ADR-0001: Integrate TrollFools with the binary TrollStore build

## Status

Accepted

## Context

The target `TrollStore_2.1.1_0702.tar` is a heavily modified TrollStore build. It includes app downgrade, decryption, package, plugin, source, customization, and maintenance features, but its matching source code is not publicly available. Rebuilding from official TrollStore 2.1.1 would discard those features. Shipping TrollFools as a second app would not satisfy the requirement that injection be available inside TrollStore.

The integration must preserve the original application binary as much as possible, run on arm64 iOS 14 and later, reuse the current `InjectorV3` implementation, and remain removable by reinstalling the unmodified archive.

## Decision

Build `TrollFoolsIntegration.dylib`, load it from the existing TrollStore executable, and hook only `TSAppTableViewController`'s existing `showActionsForAppAtIndexPath:` entry. The module adds injection, plugin management, and auto-inject-folder commands to each app's action menu.

The module invokes a separately signed `trollfoolscli` with argument arrays. The CLI owns the injection behavior and reuses `InjectorV3`, persistence, profile storage, framework fallback, and automatic reconciliation code from TrollFools. External files are validated and copied to an isolated staging directory before the privileged CLI runs.

The packaging script uses the official TrollStore `fastPathSign` implementation after adding the dylib load command. The original tar remains an external build input and is not committed.

## Consequences

### Positive

- Preserves the unavailable 0702 modifications.
- Keeps injection logic in the maintained TrollFools codebase.
- Limits runtime hooking to one known Objective-C method.
- Supports rollback by reinstalling the original 0702 archive.

### Negative

- A future binary that removes or renames `showActionsForAppAtIndexPath:` needs a new adapter.
- The integration cannot be source-level tested against the unpublished TrollStore changes.
- Final device validation is still required because Windows cannot execute iOS arm64 products.

### Neutral

- TrollFools data remains under `/var/mobile/Library/TrollFools` and its iCloud Drive auto-inject directory.

## Alternatives Considered

**Rebuild from official TrollStore 2.1.1**

Rejected because it loses the target build's unrelated features and UI.

**Bundle or launch the standalone TrollFools app**

Rejected because it is not an in-app integration and creates two independent lifecycles.

**Replace the existing injection methods through binary patching**

Rejected because private implementation details and calling conventions cannot be validated without source or symbols.

## References

- https://github.com/blueskycrb/TrollFools
- https://github.com/opa334/TrollStore
- https://github.com/tyilo/insert_dylib
