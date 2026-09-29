# Safety rules

These rules are part of the product. They are not suggestions.

## The user's file

- Do not delete, overwrite, or rename the failed original until `fileproviderctl evaluate` reports the published sibling `isUploaded` and reports no upload error.
- When that report arrives, move the original into the undo cache. Do not copy it and leave the original in place, and do not delete it with no cache entry.
- The undo cache keeps the original for 6 hours. Restore moves the current file aside inside the cache and moves the original back to its previous path.
- Publish from a finished file staged outside `~/Library/CloudStorage`. Do not stream bytes directly into the Drive folder.
- Prefer an APFS clone on the same volume. Fall back to a full copy only when the clone fails and a copy is still allowed.
- SHA-256 the source bytes and the staged bytes before publication, and compare them. This is not a checksum of the published sibling or of the NAS copy. On mismatch, stop and keep the staged file for inspection.
- One published sibling uses the suffix `.__requeued-<yyyyMMdd-HHmmss>` so it cannot be mistaken for the original.
- A second Fix of a file that is still a confirmed failure is allowed. Automatic requeue is not available in the current build; monitoring and detection are automatic, the repair starts when the user presses Fix.

## What counts as a failure

- Read only the first `fileproviderItems` dictionary from `fileproviderctl evaluate`.
- `uploadingError` is a quoted string. The code `-2005` has to appear as `NSFileProviderErrorDomain` inside that string.
- Exit code 0 does not mean the file is healthy.
- Output the parser does not understand is incompatible. Incompatible output blocks automatic retry.
- `isUploading = 1` is not a failure by itself.
- A permanent failure is actionable only when the file is downloaded, not excluded, and not paused.
- Two observations at least 60 seconds apart must agree on inode, size, and modification time. A later observation must not demote a finding that is already actionable or waiting for review.
- Files that already failed when monitoring started are `existingNeedsReview`. They are not auto-retried. The user can still press Fix.
- Ignore names containing `_segment_`, a `.__requeued-` token, conflict-copy names, and temporary suffixes.
- Dump output from `fileproviderctl dump` is aggregate and obfuscated. It must not choose a file to repair.

## Processes and commands

- The only File Provider command the app may run is `/usr/bin/fileproviderctl` with the arguments `evaluate` and one path. Arguments are passed as an array. Paths are never interpolated into a shell string.
- Do not run `fileproviderctl repair` or `fileproviderctl check`.
- Do not signal `fileproviderd`, `cloud-drive-eventd`, or any Synology process. `cloud-drive-eventd` is setuid root.
- Do not edit Synology's SQLite databases or File Provider caches.
- Do not add this source repository as a watched root.

## Disk space

- Refuse a publication on insufficient space. That check cannot be disabled.
- When the same-volume clone check passed, the required headroom is the reserve (20 GiB, floored at 1 GiB), because a clone does not need a second full copy of the bytes.
- Otherwise (no validated clone) require at least the greater of twice the source size and the source size plus the reserve.
- Cross-volume staging is blocked outright.
- Warn when free space is under 100 GiB. The warning does not by itself block a clone that passed the checks above.

## Scope of a watched root

The path the user confirms is the top of the tree. Scans walk nested folders. Only eligible extensions modified inside the age window are sent to `fileproviderctl`. Files younger than the minimum stable age are listed and scheduled for a later check. They are not dropped with no trace.
