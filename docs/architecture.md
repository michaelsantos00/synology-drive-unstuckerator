# Architecture

Synology Drive Unstuckerator is a Swift package with three products. The installed app is `Synology Drive Unstuckerator.app`.

| Product | Role |
| --- | --- |
| `DriveMonitorCore` | Parsing, confirmation, watching, persistence, and the fix pipeline. No SwiftUI. |
| `DriveMonitorUI` | Menu-bar UI, settings, notifications, and the manual Fix action. Sources live in `App/`. |
| `Unstuckerator` | Build target for the launcher in `AppLauncher/`. The packaged executable is named Synology Drive Unstuckerator. |

The minimum system is macOS 15. Swift 6 language mode is on for every target. There are no third-party dependencies.

## Pipeline

```
FSEvents + periodic reconcile
        │
        ▼
Candidate rules (extension, age, ignored names)
        │
        ▼
fileproviderctl evaluate  →  FileProviderParser
        │
        ▼
ConfirmationPolicy (two checks, 60 seconds, same inode/size/mtime)
        │
        ▼
SwiftData store (findings, activity, watched roots)
        │
        ▼
Manual Fix or opted-in automatic dispatch
   plan → stage outside CloudStorage → hash → publish sibling → poll
        │
        ▼
RetryFinalizer, only after isUploaded and no upload error
   archive original to Undo/ → rename sibling to the original name
        │
        ▼
Final-name provider acknowledgment → arm 6-hour Undo retention
```

## Modules

- `FileProvider/` parses NeXT-style `evaluate` text and the aggregate dump summary. The parser never repairs a file.
- `Validation/` decides which names are eligible, which extensions the user enabled, and when two observations confirm a failure.
- `Monitoring/` owns FSEvents, a cancellable, batched recursive metadata walk, follow-up timers for files that are still too new, and the only production `Process` that may launch `fileproviderctl`.
- `Persistence/` is a SwiftData repository. Finding identity tolerates about a second of modification-date rounding.
- `Requeue/` plans an attempt, clones or copies, hashes, polls, finalizes, and stores the undo archive.

`AutomaticRepairCoordinator` owns version dispatch and transient preflight cooldown policy. Durable operation records enforce committed ownership across launches. The session runs bounded follow-up for final filename acknowledgment even while new monitoring/repair dispatch is paused.

The UI reads snapshots from the repository. It does not parse `fileproviderctl` output itself.

## Menu-bar app

`LSUIElement` is set, so the running app stays in the menu bar instead of taking a Dock tile. The bundle still has an application icon. That icon is what Finder shows and what the open menu uses at the top. The menu-bar glyph is a separate template drawing of a D with a check, so it follows the menu bar's light or dark style. A small badge is drawn into that template when monitoring is paused or a folder or provider cannot be read; the attention count is shown as text beside it.

Scenes:

- `MenuBarExtra` (window style): state at a glance, notices, up to three files from Attention, Checking, Repairing, or Recent, and Scan Now, Pause, Activity, Settings, and More. Rows open their file in Activity; Fix and Undo stay on the row. The panel never presents sheets.
- `Window` "Activity": a sidebar of queues, Recovery, and history; a sortable `Table` of files or an event log; and an inspector with the selected file's explanation, copies, recovery choices, history, and technical details. Search filters the current list.
- `Window` "Welcome": first-run setup. It opens when no folder is configured after launch, and when the app is opened again while it runs without a folder.
- `Settings`: General, Folders (a list with + and −, drag to add, and a per-folder editor), and Diagnostics.

Activity and Welcome are not restored at login. The menu-bar label is the only view alive from launch, so it hands its `openWindow` action to `AppModel`; requests made earlier are delivered when it appears. Notification clicks and reopening the app route through the same path. File states use one vocabulary (`StatusPresentation.swift`): a symbol and a label for every state, never color alone.

Store updates fetch changed paths and bounded recent event pages. Journal lookups cache decoded records against fresh file identity metadata; mutations always reload the full inventory. Journal, manifest, and restore I/O in the session callbacks runs off the main actor. Saved offline roots are retried during reconciliation and FSEvents gap/root-change flags request a rescan. Path-only rules run before the per-path lease, so ineligible files never take a lock; a lease removes its lock file on release. Command admission waits briefly for a free slot. Repeat verification checks reuse a digest confirmed in the same process when a file's identity, including change time, is unchanged. Activity keeps scan entries for 7 days and other entries for 180 days.

## Tests

`swift test` covers the parser against a captured `evaluate` transcript, confirmation (including "do not demote an actionable finding"), the planner, the executor with a fake command runner, the finalizer, and the undo archive. Tests do not talk to a live File Provider.
