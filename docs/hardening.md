# Repair hardening

This implements the first tranche from the September 29 review. It has not been verified against live Synology uploads or NAS-side Undo behavior.

## Guarantees enforced locally

- A repair commits the source path, inode, size, modification time, and SHA-256. It records the staged/retry digest and identity separately. Resume never substitutes today's original for the committed version.
- Publication intent is saved before the move. The actual published identity is saved afterward. A storage error stops further filesystem side effects.
- Provider evaluation is bracketed by retry-version checks. An upload response with a mismatched document size or changed retry cannot authorize finalization. Both files are hashed again under file coordination before archive/replacement.
- Moves use same-volume `renamex_np` with `RENAME_EXCL`; an occupied destination is never overwritten. Interruptions around archive/rename require explicit recovery review.
- One path lease covers monitoring, repair, and Undo, including suspension points. Production leases also use an advisory file lock shared by app instances. Pending operation records block new Fix operations after relaunch. Scan and Clear history preserve operation ownership.
- Evaluation errors after publication leave the operation published with a verification error. Upload acknowledgement is not Fixed. Success follows verified final placement and a saved completed record.
- Undo validates both the archived bytes and the current occupant. Changed or unknown occupants are retained in place. Parked copies have separate manifests and no automatic expiry. Purge checks the current replacement and archive digests again; uncertainty retains the archive.

File coordination protects against cooperating writers. Arbitrary processes that bypass coordination can still race filesystem operations; these checks are not a filesystem snapshot or proof of NAS durability.

## Recovery and migration

Operation records are independent of the findings store. Startup loads recovery evidence before attempting watched roots. Incomplete pre-publication and archive/rename phases become Recovery; the app does not automatically finish a rename simply because the original is absent. A complete published record can be verified again using Check upload.

Recovery Details offers two explicit choices: keep the current original, or restore the verified archived original to an empty path. Remaining retry/staged payloads are moved into retained recovery storage, never deleted; completion of the user's choice releases operation ownership and creates a fresh observing row with no retry path. The closed operation keeps the old evidence, so the same unchanged file can be confirmed and repaired again. A changed-occupant Undo refusal performs no moves and leaves the completed operation and original expiry intact. Unknown/corrupt journal files remain visible in Recovery and block mutations, while readable history and monitoring continue.

Older pending retries lack digests and acknowledgements bound to a version. They go to Recovery without publishing another copy. Legacy Undo manifests are retained but cannot automatically displace an occupied path. Legacy Fixed rows with distinct original/retry paths are migrated to Recovery. Existing valid completed records and recovery/Undo finding IDs survive Clear history.

Activity → Recovery exposes archive size, retention, file locations, and export. Manage retained files deliberately in Finder after examining/exporting them. The app does not automatically expire unresolved unique payloads. The free-space gate uses the filesystem's available capacity, which already includes retained storage; displayed file sizes are logical sizes and may exceed APFS physical usage.

## Interface changes

- Compact Attention / Checking / Repairing / Recent groups with stable filename order.
- Watched folder, last successful scan, and seven-day discovery coverage in the header.
- Reachable searchable Activity and file Details, and Recovery locations even when the source path is absent.
- Truthful publication/verification/finalization state, without invented upload percentages.
- Clear history and Quit in the secondary menu. Cached Undo availability avoids scanning manifests in every rendered row.

## Growing exports and opt-in auto-fix

Unconfirmed observations with the same path and inode now update as an export grows. Confirmed versions and repair evidence retain their identities. Each scan retires obsolete observations before the stability wait, including duplicates saved by earlier builds. Old snapshots remain in history; media files are not deduplicated or deleted. Follow-up checks are coalesced by path. Store-change notifications run after releasing the scan lease so an automatic repair can acquire it.

Fix remains visible while unavailable and the queue shows its block reason. Settings includes a persisted, off-by-default auto-fix option; the menu shows its state. Automatic repairs run one at a time, only for opted-in roots with acknowledged baselines and newly actionable versions with two confirmations and no previous attempt or repair evidence. The executor independently checks those conditions and the live provider, writer, source-version, storage, and integrity gates. Permission is checked again after hashing before publication. Pause/disable retains an unpublished staged copy for explicit recovery; an already published operation continues verification. Existing baseline failures and interrupted retries require manual action. Startup uses the complete session callback set, including automatic repair.

## Verification and remaining work

`swift test --scratch-path /private/tmp/unstuckerator-hardening-build` runs the core suite and app integration tests. File fixtures use temporary directories; SwiftData is in memory or explicitly redirected. Tests do not open the production support store or run `fileproviderctl`.

Moves flush through a read-only file descriptor, so read-only originals and clones can still be renamed. For new operations, expiry is armed only after final-name acknowledgment. An expiry-setting failure is a retention warning, not a reversal to Recovery. Invalid recovery choices leave the existing phase unchanged.

The first implementation review identified recovery dead ends, lock ordering, busy-scan propagation, metadata-only changes, corrupt records, and upgrade gaps; these were addressed with explicit recovery choices and additional regressions.

Regression coverage includes changed-source resume, same-length retry modification, acknowledgement/version mismatch, polling failure, journal checkpoint failures, failed rename, pending repair scans, Reset ownership, legacy retries, Undo with a newer edit, expiry, unavailable-root history, post-Undo repairs, explicit recovery resolution, busy-scan continuation, metadata-only changes, corrupt-journal inventory, and transient expiry errors.

The September 30 pass adds strict complete parsing and explicit repair flags, atomic root replacement, hydrated per-folder editors, durable automatic permission revocation, pause preservation/restoration, older known-failure reconciliation, FSEvents gap handling, saved offline-root recovery, bounded command admission/output/deadlines, incremental path queries, event paging, journal decode caching, background cancellable archive export, final-name acknowledgment, and native compact menu/Activity/Details views. Timed-out children retain their admission slot until exit; they are not signaled. Production performance profiling and healthy-result caching remain measurement-driven follow-up opportunities. Live disposable-file Synology checks (including Undo's effect on the NAS), full VoiceOver/keyboard acceptance, and large-queue usability are separate release acceptance steps.

## Review notes

Two independent reviews examined the implementation. Their concrete recovery, locking, scan, migration, read-only-file, hash, and expiry findings were addressed and regression-tested. The final fixes were verified locally; the reviews did not run tests or verify Synology.

One conservative policy remains intentional: a changed original modification time requires recovery review even if its bytes might be unchanged. The original commitment is not silently refreshed. One review recommended accepting a timestamp-only change after hashing; this implementation keeps the approved stricter source-version rule and provides explicit recovery with renewed observation. Change-time-only provider metadata updates are handled separately without rejecting matching bytes.

## October 1 review

A second pass audited the engine, the repair pipeline, concurrency, and the interface. Ten findings were reproduced in scratch experiments before changes. No path was found that deletes or overwrites the user's file.

Fixed, each with a regression test:

- Auto-fix could pick up a version the user had not cleared for it once its finding row was recreated: Clear History erased ignored and setup rows, a rename created a new row, and Keep Current Original reset the attempt count. Auto-fix now also requires the file's modification time to be after the setup review and no operation record for the same inode, size, and modification time under any name. Clear History keeps ignored and setup rows.
- A moved or deleted watched file became a permanent "cannot read" block that was logged again on every reconcile and set the app's status to an error. It now becomes history once. An offline watched folder changes nothing.
- A metadata-only change (change time) during staging was reported as a hash mismatch and used the version's attempt. Staging now compares inode, size, and modification time, as finalization already did; the bytes are proven by the hashes.
- After Undo, the restored original kept a resolved row with repair evidence, so it was no longer monitored and Fix was disabled. Undo now records a fresh observation, as Keep Current Original does. That version still cannot be fixed automatically again.
- A startup scan that lost a race (a settings change, another scan) paused monitoring for the session. Monitoring now continues; auto-fix waits until a scan finishes in the session instead.
- Background verification checked the two most recently updated operations every minute, so a third could starve, and it logged an activity row on every pass. It now rotates, backs off from 1 to 10 minutes while nothing changes, and logs only changes.
- Every file event took the per-path lease before the path rules, so temporary and ineligible files left a lock file each and triggered a store refresh. Path rules now run first.
- Activity grew without limit (a scan row every 5 minutes). Scan rows now age out after 7 days and other rows after 180 days.
- Notifications re-announced every saved failure and every past repair at each launch. They now announce changes only.
- Journal, manifest, and restore I/O in the session callbacks ran on the main actor. It now runs on the concurrent pool. Engine hooks are installed before restore begins.
- Accessibility: notices read as text rather than unlabeled groups; Scan Now and Stop are one button so focus survives; scan completion, setup success, and new errors are announced while the app is in use; buttons repeated per row name their file; menu rows expose their context-menu actions; colored small text became tinted icons beside plain text.

Second round, also with regression tests:

- A readable upload error other than `-2005` (offline, storage full, sign-in) was treated as unreadable output: the row became "Could not read", the app status turned to an error, and a Fix in progress stopped polling. It is now its own classification, reported on the row, never actionable, and waited out while verifying a retry.
- A permanent failure on the final filename showed the file as placed (Recent). The operation now records it, the file returns to Attention with Check Final Name and Undo, and a notification says so. No further copy is made.
- The four-slot command cap failed immediately, so a burst of file events marked files "Could not read". A check now waits up to 15 seconds for a slot. The same check already running still fails at once.
- Each background verification re-read the original and the retry in full. A repeated check now reuses a digest confirmed in this process when the file's full identity, including change time, is unchanged. Publication, acknowledgment, and finalization still read the bytes.
- Lock files were never removed. A lease now removes its file on release, and a new holder confirms the path still names the file it locked. Unheld files left by earlier builds are removed at launch.
- Errors from event-driven checks were kept in a field nothing read. They are now recorded in Activity.
- Acknowledging a folder's setup review saved a copy of the whole folder read before an `await`, so rules applied meanwhile could be overwritten. Only the review date is written now.
- A store snapshot read before a repair started could put the row back to its pre-repair state and announce the failure again. Rows with a repair in progress keep their live state until the repair reports.

An independent review of this round found no path that lets a repair proceed when it should not and no way to wedge a repair. Its findings were fixed: Undo is offered as soon as background verification archives an original; a retry that keeps reporting another upload error hands off to the background checks after a minute instead of holding the repair for an hour, and the message clears when the error does; a final-name failure keeps its explanation through a check that cannot finish and is cleared only by a healthy upload state; while a repair, Undo, or recovery runs, its row changes only through that operation; and rows with another upload error are no longer described as confirming the stuck-upload failure.

Left as is, by policy: a timed-out `fileproviderctl` or `lsof` child keeps its slot until it exits and is not signaled. With waiting admission, other checks are delayed rather than failed, but four hung children still hold every slot.
