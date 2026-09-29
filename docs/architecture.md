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
Manual Fix
   plan → stage outside CloudStorage → hash → publish sibling → poll
        │
        ▼
RetryFinalizer, only after isUploaded and no upload error
   archive original to Undo/ → rename sibling to the original name
```

## Modules

- `FileProvider/` parses NeXT-style `evaluate` text and the aggregate dump summary. The parser never repairs a file.
- `Validation/` decides which names are eligible, which extensions the user enabled, and when two observations confirm a failure.
- `Monitoring/` owns FSEvents, the recursive metadata walk, follow-up timers for files that are still too new, and the only production `Process` that may launch `fileproviderctl`.
- `Persistence/` is a SwiftData repository. Finding identity tolerates about a second of modification-date rounding.
- `Requeue/` plans an attempt, clones or copies, hashes, polls, finalizes, and stores the undo archive.

The UI reads snapshots from the repository. It does not parse `fileproviderctl` output itself.

## Menu-bar app

`LSUIElement` is set, so the running app stays in the menu bar instead of taking a Dock tile. The bundle still has an application icon. That icon is what Finder shows and what the open menu uses at the top. The menu-bar glyph is a separate template drawing of a D with a check, so it follows the menu bar's light or dark style.

Buttons use Liquid Glass on macOS 26 and later. Color is reserved for two roles: an action (Scan, Fix, Undo) and a destructive control (Reset, Quit). Other controls are untinted glass. On macOS 15 the same roles use a solid fallback.

## Tests

`swift test` covers the parser against a captured `evaluate` transcript, confirmation (including "do not demote an actionable finding"), the planner, the executor with a fake command runner, the finalizer, and the undo archive. Tests do not talk to a live File Provider.
