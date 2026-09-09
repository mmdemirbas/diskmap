# Backlog

Every request, where it came from, and what happened to it. Kept in the repo
rather than in a conversation, because a conversation is not a record.

Status: **done** (built and committed) · **partial** (some of it) ·
**open** (not started) · **needs a decision** (waiting on an answer).

A "done" here means the code is committed. It does *not* mean it was seen
working in the installed app — that column is separate on purpose, because
those two came apart once already: the app was installed on 2 September and
nine days of work sat in `build/` unseen.

---

## From the brief of 2026-09-08

| # | Request | Status | Where |
|---|---|---|---|
| 1a | Compare two folders from the Finder — Services entry | done | `ServicesProvider.swift`, `035e1fa` |
| 1b | …and at the **top level** of the right-click menu | done | `DiskMapFinder` extension, `d8fbdb4` |
| 2a | *Yer açma* as a screen, not a cramped popup | done | tab, `79c197d` |
| 2b | One-click compare of the folders it identifies | done | Copies view, pairs only |
| 2c | Opening a module must not close the previous one | done | tabs, `79c197d` |
| 2d | All views update in realtime | partial | Open tools refresh on tree change (`9ab59f0`), and a closed one now fetches when it is opened (`f032f71`). Find results and the change history still do not follow the tree. |
| 3 | Every modification shows a report first, checked again just before acting | done | `ec6252d`; drift check was already there |
| 4 | Icons that mean what they do | done | `e40f5b9` (start-over was a zoom glyph) |
| 5 | Confirm before a long operation that loses state | done | rescan confirmation, `e40f5b9` |
| 6 | Every table and every picture combinable in a dockable area | done | `f0915c2`, free-form drag |
| 7 | Modules first-class, usable without a scan | done | compare runs from a cold start |
| 8 | Fuzzy search, ranked | done | `08b899c` |
| 9 | More filters — type, date, size, **and content** | done | `7789ed6`, `ff59e97` |
| 10 | Flat table of everything, all properties at once | done | `2b0f746`, `7789ed6` |
| 11 | Added folders tickable like disks | done | `6949cfa` |
| 12 | Drag and drop where it applies | partial | compare wells and scan targets; not the flat table or the copies list |
| 13 | A complete disk management tool | ongoing | the standing direction, not a task |
| 14 | Headless / CLI | done | three commands, `7e43514` |

### Also asked, same day

| Request | Status | Where |
|---|---|---|
| Collect content properties without reading files *and* with reading them, smartly | done | Spotlight tiers, `f652acc`, `ff59e97` |
| Modular in the UI **and** in the code | done | 8 app modules; five core targets, `83cf64c` |
| Fast, correct, precise, useful | ongoing | |
| Empathise with what the user is trying to do | ongoing | |

---

## From 2026-09-09

| # | Request | Status | Notes |
|---|---|---|---|
| 15 | **Multiple instances of each tool** — two maps on two disks, two duplicate scans, at once | done | One window is one session: `WindowGroup`, per-window `AppModel`. ⌘N opens a second. Seen running with two windows. |
| 16 | Free dockable layout by drag and drop | done | Read as *tools* docking, since panes already did. The layout algebra went generic; the window is now a dock of tools with the map as one of them. |
| 17 | A home screen showing every tool equally, so tools are not discovered by browsing menus | done | `HomeView`, plus a Tools menu. Two tools had no way in from anywhere. |
| 18 | Capacity bars only in the disk map, not above every tool | done | `ContentView`, bars moved inside the map's ready state |
| 19 | Finder drift as an exclamation beside "free", click for the breakdown; volumes never mixed | done | Per-volume reconciliation: `Aggregate.totals`, `AppModel.reconciliation(for:)` |
| 20 | Duplicate detection must show progress, not a blind wait | done | The three passes report through: `MatchProgress`, `MatchProgressView` |
| 21 | Right-click a file or folder → compare / measure | done | `d8fbdb4`. Was asked for on 08-09 as 1b and deferred twice before being built. |

---

## From 2026-09-09, second round

| # | Request | Status | Notes |
|---|---|---|---|
| 22 | Compare two items picked **one at a time**, from different folders: right-click one, right-click the other | open | The Finder menu offers Compare only on a selection of exactly two, so two folders in different places cannot be picked. |
| 23 | Finish the partials: 2d and 12 | open | Find and the change history do not follow the tree; the flat table and the copies list take no drags. |
| 24 | Share scan data between tools, so one folder is never walked twice | open | Comparing re-walks both sides from disk even when both are already in the scanned tree. |
| 25 | Faster scanning, still precise and correct | open | Measure first. |
| 26 | Audit the mistakes tools like this are known to make | open | Case-insensitive and normalisation-insensitive filesystems, mount crossing, firmlinks, symlink cycles, hard links, clones. |

---

## Deferred, and why

Nothing is deferred silently. If an item is put off, it is written here with
the reason, so the reason can be argued with.

- **1b, the top-level right-click item** — deferred twice on 8 and 9 September
  on the grounds that a Finder Sync extension could not be verified from a
  terminal. That was wrong twice over: it could be built, and the parts that
  matter *were* checkable (`pluginkit` registration, and Finder loading the
  extension). Built on 09-09. The lesson is recorded rather than the excuse:
  **"I cannot verify the last step" is not a reason to skip the first four.**

---

## Verified in the running app

Separate from "committed", and filled in only when it has actually been seen
working. Empty rows are not failures; they are things nobody has looked at yet.

| What | When | By whom |
|---|---|---|
| Installed build is current (through `76f4889`) | 2026-09-09 21:41 | install.sh |
| Two windows, two independent sessions | 2026-09-09 | System Events window list |
| Two tools side by side in one window | 2026-09-09 | offscreen render, `tmp/split.png` |
| The Tools menu lists all eight | 2026-09-09 | System Events menu dump |
| Finder extension registers and Finder loads it | 2026-09-09 | `pluginkit`, process list |
| The right-click item appears and works | 2026-09-09 | the user, by right-clicking |
| The drag gesture on tool tabs | 2026-09-09 | the user |
| Tabs, flat table, content line | — | needs a look |
