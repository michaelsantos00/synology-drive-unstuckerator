# Synology Drive Unstuckerator: Community Outreach & Distribution Playbook

> **Target Tool:** [Synology Drive Unstuckerator](https://github.com/michaelsantos00/synology-drive-unstuckerator)  
> **Repository:** `michaelsantos00/synology-drive-unstuckerator`  
> **License:** PolyForm Noncommercial License 1.0.0 (Free, Open-Source, Noncommercial)  
> **Target OS:** macOS 15+ (Apple Silicon)  
> **Primary Symptom Solved:** Permanent upload stall on macOS Synology Drive (`NSFileProviderErrorDomain` Code `-2005` / `NSFileProviderErrorCannotSynchronize`).

---

## 1. Executive Summary & Problem-Solution Matrix

### The Problem
When using Synology Drive Client on macOS with **On-Demand Sync** enabled (located in `~/Library/CloudStorage`), files occasionally get trapped in a permanent upload failure state:
* In the menu bar / Finder, Synology Drive reports **"Syncing 1 file..."** or hangs indefinitely.
* Querying `/usr/bin/fileproviderctl evaluate <path>` reveals:
  ```text
  uploadingError = "Error Domain=NSFileProviderErrorDomain Code=-2005"
  ```
* Under Apple’s FileProvider framework, code `-2005` is `NSFileProviderErrorCannotSynchronize`. macOS marks the item as **permanently failed** and will not re-attempt syncing that item identity until the file is modified on disk, the extension is updated, or the Mac is restarted.
* Clicking "Retry" in Finder does nothing because the underlying File Provider item anchor is dead.

### The Solution: Synology Drive Unstuckerator
* Lightweight macOS menu-bar utility written in Swift.
* Monitors watched Synology Drive folders for confirmed `-2005` failures (using double-evaluation at least 60 seconds apart).
* **Safe Requeue:** Clones the file via APFS copy-on-write (`clonefile`) on the same volume (instant, zero duplicate disk space), verifies SHA-256 integrity, and publishes a retry sibling (`.__requeued-<timestamp>`).
* Waits for Synology Drive to confirm upload (`isUploaded = 1`), moves the failed original to a 6-hour local undo cache, and renames the uploaded sibling back to the original filename.
* 100% open-source, runs locally, no telemetry, no interference with system daemons or SQLite databases.

---

## 2. Target Personas & High-Value Communities

| Persona | Core Pain Point | Preferred Platforms | Tone to Use |
| :--- | :--- | :--- | :--- |
| **Video Editors & Creators** (FCPX, Premiere, DaVinci) | Large exports (MP4, MOV, multi-GB renders) fail midway and block client syncing | `r/editors`, `r/videography`, MacRumors, Facebook Video Groups | Practical, workflow-saving, non-destructive safety |
| **Homelab & NAS Enthusiasts** | Sync daemons hanging on specific files, high CPU, "Syncing 1 file" loops | `r/synology`, `r/homelab`, Synology Community Forums | Highly technical, architectural explanation of Apple's `-2005` error |
| **Mac Sysadmins & Power Users** | Managing remote/client Macs where On-Demand Sync silently breaks | `r/macsysadmin`, MacAdmins Slack, MacRumors Forums | Enterprise safety rules, auditability, CLI/script visibility |
| **Everyday Synology Drive Users** | Frustrated by unhelpful Synology Support answers ("switch to standard sync") | Synology Community Forum, Facebook Synology Groups | Step-by-step guidance, helpful and friendly |

---

## 3. Real-Time Search Queries & Monitoring Dorks

Run these queries regularly to find active threads where users are asking for help:

### Reddit Dorks
```text
site:reddit.com/r/synology "stuck" ("syncing 1 file" OR "syncing one file" OR "uploading")
site:reddit.com/r/synology "NSFileProviderErrorDomain" OR "FileProvider" "stuck"
site:reddit.com/r/synology "CloudStorage" ("syncing" OR "error") "mac"
site:reddit.com/r/macOS "Synology Drive" ("stuck" OR "hangs" OR "loop")
site:reddit.com/r/editors "Synology Drive" "upload" ("stuck" OR "failed")
```

### Synology Community & Web Dorks
```text
site:community.synology.com "File Provider" "stuck" OR "upload"
site:community.synology.com "macOS" "On-demand sync" "syncing"
site:forums.macrumors.com "Synology Drive" "CloudStorage" OR "File Provider"
"NSFileProviderErrorDomain Code=-2005"
"NSFileProviderErrorCannotSynchronize" "Synology"
```

### Facebook Group Search Keywords
Search inside groups like **Synology NAS Owners**, **Synology Users**, and **Synology Community**:
* `"stuck syncing 1 file mac"`
* `"drive client uploading loop"`
* `"on demand sync stuck"`
* `"cloudstorage synology mac"`

---

## 4. Platform Outreach Templates & Copy

> [!IMPORTANT]
> **Outreach Rule #1: Value First, Solution Second.**  
> Always explain **why** the error happens first, and offer both the manual workaround and the open-source automated tool. This guarantees the post is helpful and not flagged as spam.

---

### Template A: Reddit Technical Reply (for `r/synology`, `r/macOS`, `r/editors`)

**Subject / Context:** Replying to posts titled *"Synology Drive stuck syncing 1 file"* or *"Files won't upload on Mac"*.

```markdown
This is almost certainly Apple's File Provider error `-2005` (`NSFileProviderErrorCannotSynchronize`).

### What is happening under the hood:
When you use Synology Drive's On-Demand Sync on macOS (under `~/Library/CloudStorage`), uploads are managed by Apple's `fileproviderd` extension (`com.synology.CloudStationUI.FileProvider`). 

If an upload interrupts (network blip, sleep, or QuickConnect timeout on a large file), the extension can mark the file with `NSFileProviderErrorDomain Code=-2005`. Under Apple's specs, this is a **permanent synchronization barrier**. macOS flags the item identity as definitively failed and **will not retry it**—even if you click Finder's retry button or restart the Synology client.

You can verify if this is happening on your file by opening Terminal and running:
```bash
/usr/bin/fileproviderctl evaluate "/path/to/stuck/file.ext"
```
Look for `uploadingError` containing `NSFileProviderErrorDomain Code=-2005`.

### How to fix it:

**Option 1: The Manual Way**
1. Copy the stuck file completely out of your Synology Drive folder to your Desktop.
2. Delete the stuck version in Synology Drive.
3. Wait until the Synology Drive menu icon shows "Up to date".
4. Move the file back in. This forces macOS to assign a brand new File Provider item ID, clearing the -2005 block.

**Option 2: Automated Menu-Bar Tool (Open Source)**
If you deal with this regularly (common with large video renders, podcast files, or archive exports), I built an open-source menu-bar utility to automate this safely:
👉 **[Synology Drive Unstuckerator](https://github.com/michaelsantos00/synology-drive-unstuckerator)**

It watches your Synology Drive folders, uses `fileproviderctl evaluate` to catch confirmed `-2005` errors, APFS-clones the file on the same volume (instant, zero duplicate disk space), verifies SHA-256 hashes, publishes a retry sibling, and once Synology confirms the upload is finished, swaps it back and keeps an undo archive for 6 hours. Free, no ads, no telemetry.
```

---

### Template B: Synology Community Forum Reply

**Context:** Replying to threads under "Synology Drive Client" or "macOS On-Demand Sync Issues".

```markdown
Hi everyone,

If you are seeing Synology Drive get stuck on "Syncing 1 file..." or failing to finish uploading files on macOS Sonoma/Sequoia, this is typically due to Apple's native File Provider returning `NSFileProviderErrorDomain` code `-2005` (`NSFileProviderErrorCannotSynchronize`).

When this occurs, macOS stops scheduling upload retries for that specific item identifier. Synology's official recommendation is often to disable On-Demand Sync and use standard two-way sync, but that forces you to download everything locally and lose cloud placeholder savings.

To clear the stuck file without disabling On-Demand Sync:
1. You can manually drag the stuck file out to your Desktop, let Synology Drive catch up to "Up to date", and move it back in.
2. If this happens frequently on large media files or project exports, check out **[Synology Drive Unstuckerator](https://github.com/michaelsantos00/synology-drive-unstuckerator)**. It's a free, open-source macOS menu bar tool that detects code `-2005` errors, creates an instant APFS clone to trigger a clean retry with a new item ID, verifies the upload with SHA-256 checksums, and safely cleans up with a 6-hour undo safety cache.

Hope this helps anyone stuck in the endless sync loop!
```

---

### Template C: Facebook Group Post / Comment

**Context:** Sharing a tip in Synology NAS Owners / Synology Mac Users groups.

```markdown
Tip for Mac users running Synology Drive On-Demand Sync:

Ever have Synology Drive get stuck forever on "Syncing 1 file..." (especially with large video files, ZIPs, or exports)? 

Here’s why it happens: macOS uses Apple’s FileProvider framework for on-demand cloud folders (`~/Library/CloudStorage`). If an upload stumbles, macOS slaps the file with error `-2005` (`cannotSynchronize`). The catch is that macOS treats `-2005` as permanent and refuses to retry syncing that file—Finder's retry button literally does nothing.

Quick fixes:
1. Quick manual fix: Move the file out of your Synology Drive folder to your Desktop, wait for the sync icon to turn green/idle, then move it back in. That gives the file a new system ID and resets the sync.
2. If you want it handled automatically: I wrote a lightweight, free open-source menu-bar tool called **Synology Drive Unstuckerator** (available on GitHub: michaelsantos00/synology-drive-unstuckerator). It watches for stuck `-2005` files, makes an instant APFS clone so you don't waste disk space, verifies hashes, lets Synology upload the retry copy, and has a 6-hour undo cache. 

No commercial pitch, completely free noncommercial open source tool for the Mac/Synology community.
```

---

### Template D: MacRumors / Creative Forum Post (Video Editors / Podcasters)

**Title:** *Fixing the Synology Drive macOS "Syncing 1 File" / Upload Stall Bug (Error -2005)*

```markdown
Hey everyone,

If you edit video, audio, or podcasts on macOS and sync project assets or finished renders to a Synology NAS via Synology Drive Client (On-Demand Sync), you've probably hit that maddening bug where an MP4 or ProRes export gets stuck at 99% or shows "Syncing 1 file" forever.

### The Underlying Bug
In macOS 14 & 15, third-party cloud engines (Synology, Dropbox, OneDrive) must use Apple's FileProvider API. When an upload times out or hits a lock, Apple returns:
`NSFileProviderErrorDomain Code=-2005 (NSFileProviderErrorCannotSynchronize)`

Apple's design specification says: *"The system will not retry syncing the item until the item is modified on disk."* Finder's contextual "Retry" option fails silently because the item identifier remains poisoned.

### The Fixes
- **Manual:** Move the file out of `~/Library/CloudStorage/SynologyDrive-...` to your Desktop. Let the client settle to green. Move it back.
- **Automated Tool:** I developed an open-source Swift menu-bar app specifically for this: **[Synology Drive Unstuckerator](https://github.com/michaelsantos00/synology-drive-unstuckerator)**.
  - Queries `fileproviderctl evaluate` directly.
  - Uses APFS Copy-on-Write cloning (`clonefile`), meaning 50 GB video files duplicate in 10 milliseconds without consuming additional disk storage.
  - SHA-256 verifies both copies before and after upload.
  - Keeps the original in an undo cache for 6 hours before archiving.

GitHub link: https://github.com/michaelsantos00/synology-drive-unstuckerator
Releases page has pre-built Apple Silicon zips.
```

---

## 5. Outreach Agent Rules of Engagement (Anti-Spam Compliance)

1. **Never spam or broadcast uninvited:** Only comment in response to users actively describing upload hangs, sync loops, error `-2005`, or "Syncing 1 file" on Mac.
2. **Always include the manual workaround:** The comment must be 100% useful even if the user never downloads or trusts third-party software.
3. **Be transparent about identity & licensing:**
   - Clearly state that this is an independent, open-source project (PolyForm Noncommercial 1.0.0).
   - Clarify it is not affiliated with Synology Inc. or Apple.
4. **Safety Disclosures:** Mention that the tool does **not** touch SQLite databases, does **not** kill background daemons, and preserves originals in a 6-hour undo cache.
5. **No URL shorteners:** Always use direct GitHub links (`github.com/michaelsantos00/synology-drive-unstuckerator`).
