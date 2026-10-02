# Safety rules

These rules are part of the product. They are not suggestions.

## The user's file

- Do not delete, overwrite, or rename the failed original until `fileproviderctl evaluate` reports the published sibling `isUploaded` and reports no upload error.
- When that report arrives, move the original into the undo cache. Do not copy it and leave the original in place, and do not delete it with no cache entry.
- The original stays retained without automatic expiry until the final filename also reports uploaded. The 6-hour Undo window starts after that acknowledgment. Restore moves the current file aside inside the cache and moves the original back to its previous path.
- Publish from a finished file staged outside `~/Library/CloudStorage`. Do not stream bytes directly into the Drive folder.
- Prefer an APFS clone on the same volume. Fall back to a full copy only when the clone fails and a copy is still allowed.
- SHA-256 the source bytes and the staged bytes before publication, and compare them. This is not a checksum of the published sibling or of the NAS copy. On mismatch, stop and keep the staged file for inspection.
- Publication, upload acknowledgment, and finalization always read the bytes. A repeated verification check may reuse a digest confirmed earlier in the same process only when the file's full identity, including change time, is unchanged. The kernel moves change time on every write and a writer cannot set it.
- If Synology reports the final filename itself failed to upload, no further copy is made. The replacement stays in place, the original stays archived without expiry, and the file needs a decision (Check Final Name or Undo).
- One published sibling uses the suffix `.__requeued-<yyyyMMdd-HHmmss>` so it cannot be mistaken for the original.
- Automatic repair is off by default and needs explicit opt-in after setup review. A committed source version gets one retry; Check Upload resumes that retry. A preflight deferred before any copy may be checked again. Interrupted operations require explicit recovery.
- Automatic repair never starts on a version whose modification time is before the folder's setup review, or on a version (same inode, size, and modification time, under any name) that already has an operation record. Finding rows can be recreated by Clear History or a rename; these checks use the file and the durable operation records instead. Manual Fix is unaffected.
- After launch, automatic repair waits until a scan finishes in that session. Saved findings alone never start a repair.
- Clear History keeps ignored rows and rows found at setup, so a cleared decision cannot turn into a new automatic candidate.

## What counts as a failure

- Require one complete `fileproviderItems` dictionary from `fileproviderctl evaluate`.
- `uploadingError` is a quoted string. The code `-2005` has to appear as `NSFileProviderErrorDomain` inside that string.
- Exit code 0 does not mean the file is healthy.
- Output the parser does not understand is incompatible and blocks repair. Duplicate safety fields, malformed values, oversized output, and incomplete lists are rejected.
- `isUploading = 1` is not a failure by itself.
- A readable upload error other than `-2005` (for example offline, storage full, or sign-in) is reported on the file and never actionable. It is not treated as unreadable output. An error next to `isUploaded = 1`, or `-2005` without `isUploaded = 0`, contradicts itself and stays incompatible.
- A permanent failure is actionable only when the file is downloaded, explicitly not excluded, and explicitly not paused. Missing repair safety flags stay blocked.
- Two observations at least 60 seconds apart must agree on inode, size, and modification time. A later observation must not demote a finding that is already actionable or waiting for review.
- Files that already failed when monitoring started are `existingNeedsReview`. They are not auto-retried. The user can still press Fix.
- Ignore names containing `_segment_`, a `.__requeued-` token, conflict-copy names, and temporary suffixes.
- A file that is moved or deleted is not a provider failure. Its observation becomes history (Earlier Versions); ignored rows and rows with repair evidence are left as they are. If the whole watched folder is missing, nothing is changed.
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

The path the user confirms is the top of the tree. Scans walk nested folders. New discovery evaluates eligible extensions modified inside the age window. Already known unresolved files keep receiving follow-up outside that window. Files younger than the minimum stable age are listed and scheduled for a later check. They are not dropped with no trace.

## Controls and resource limits

Root configuration is replaced atomically. Each folder has its own editable rules and automatic repair permission. Applying settings preserves Pause; Pause is restored after relaunch. Disabling auto-fix writes a separate permission-revocation barrier before attempting configuration changes, so a store or engine failure cannot silently restore permission.

Provider and writer probes have caller deadlines, diagnostic size limits, and a shared admission cap. Timed-out children keep their slot until exit. The app does not signal them or Synology services. Writer-check errors and unknown modes block publication. Writer state is checked again immediately before publication.

Recovery export streams to a private temporary destination off the UI actor, checks its digest and source identity, and publishes without overwriting. Cancellation removes only the export's own temporary file. Missing or corrupt recovery records remain visible; unique retained payloads are not automatically deleted.
