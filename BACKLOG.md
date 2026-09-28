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

## From the App Store comparison, 2026-09-28

Three App Store apps share the name; `docs/competitors-2026-09.md` sets what
they advertise against what this does. Quick Look and a Home folder target
were taken the same day (`3dae18c`, `b955bb7`), then from its ranked list:
refusing to trash the folders macOS depends on and refusing up front on a
volume with no Trash (`d699035`), Quick Look following the selection
(`15bd3bc`), the number of levels drawn (`d4993fa`), a legend highlight in
place of a hiding filter (`98ba94f`) and Reduce Motion (`97995ce`).

Open, and each needs a decision before it is built:

- **One delete queue across views** (5). The ticks are one set per session
  already, but the copy report clears it on every reload and guards "the
  last copy" around that; a queue any view adds to changes those rules on
  the deletion path.
- **VoiceOver on the map pictures** (rest of 6). The canvases expose no
  accessibility elements; the list beside them is readable. Needs a way to
  verify with VoiceOver before it is claimed.
- **Packages as one item** (7). Needs a default: Finder-style closed, or
  today's open.
- Colour by depth (9) and compress (10): low value, not planned.

## From the brief of 2026-09-08

| # | Request | Status | Where |
|---|---|---|---|
| 1a | Compare two folders from the Finder — Services entry | done | `ServicesProvider.swift`, `035e1fa` |
| 1b | …and at the **top level** of the right-click menu | done | `DiskMapFinder` extension, `d8fbdb4` |
| 2a | *Yer açma* as a screen, not a cramped popup | done | tab, `79c197d` |
| 2b | One-click compare of the folders it identifies | done | Copies view, pairs only |
| 2c | Opening a module must not close the previous one | done | tabs, `79c197d` |
| 2d | All views update in realtime | done | Open tools refresh on tree change; a closed one fetches when opened; the search and the change history follow it too (`52e0c76`). |
| 3 | Every modification shows a report first, checked again just before acting | done | `ec6252d`; drift check was already there |
| 4 | Icons that mean what they do | done | `e40f5b9` (start-over was a zoom glyph) |
| 5 | Confirm before a long operation that loses state | done | rescan confirmation, `e40f5b9` |
| 6 | Every table and every picture combinable in a dockable area | done | `f0915c2`, free-form drag |
| 7 | Modules first-class, usable without a scan | done | compare runs from a cold start |
| 8 | Fuzzy search, ranked | done | `08b899c` |
| 9 | More filters — type, date, size, **and content** | done | `7789ed6`, `ff59e97` |
| 10 | Flat table of everything, all properties at once | done | `2b0f746`, `7789ed6` |
| 11 | Added folders tickable like disks | done | `6949cfa` |
| 12 | Drag and drop where it applies | done | Compare wells, scan targets, the map, the flat table and the copies list. Rows drag out as file URLs. |
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
| 22 | Compare two items picked **one at a time**, from different folders: right-click one, right-click the other | done | `AppModel.offerToCompare`; the Finder item is offered on any selection now. |
| 23 | Finish the partials: 2d and 12 | done | `52e0c76`, and drops plus row drags on both lists. |
| 24 | Share scan data between tools, so one folder is never walked twice | done | `NodeStore.subtree`, `ScanReuse`. A comparison asks the scan first; ~9x on folders it can answer. Refuses where the copy would not be the same answer. |
| 25 | Faster scanning, still precise and correct | done | Measured first: `docs/scanning-speed.md`. The walk is at the syscall floor — 4.3x faster than `du`, and one thread costs what `du` costs. Thread count raised to where the curve flattens; two obvious ideas measured and dropped. |
| 27 | Names that are not valid UTF-8 must not lose a subtree | done | `RawPath`: the walk, the store, every action, the comparison, the sync runner, the deep check and the live update carry bytes end to end; FSEvents paths are taken as C strings, and a relist writes back what the listing gave. The first test that lets FSEvents drive the tree found three older defects in how a new folder enters it — fixed, in `docs/known-pitfalls.md` under "Believing the tree still matches the disk". |
| 26 | Audit the mistakes tools like this are known to make | done | `docs/known-pitfalls.md`. One real gap found and fixed: the copy hunt matched names by raw bytes on volumes that fold case. |

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
| Installed build is current (through `7977e44`, hard links resolved from disk) | 2026-09-19 | install.sh; window seen `onscreen=1` via CGWindowList |
| Installed build is current (through `d699035`: hard-link pass off the lock, network bytes on disk, Quick Look, Home target, Trash refusals) | 2026-09-28 | install.sh, no warnings; window seen `onscreen=1` via CGWindowList. Quick Look, the Home button and the refusals not yet tried by hand |
| Installed build is current (through `97995ce`: map levels, legend highlight, Quick Look following the selection, Reduce Motion) | 2026-09-28 | install.sh, no warnings; window seen `onscreen=1` via CGWindowList. Checklist for trying it by hand: `atolye/raporlar/2026-09-28-diskmap-manual-checks.md` |
| Two windows, two independent sessions | 2026-09-09, again 2026-09-19 | CGWindowList by owner name. System Events `process "DiskMap"` finds the process but not its windows; the owner name is the bundle name, "Disk Map" |
| Two tools side by side in one window | 2026-09-09 | offscreen render, `tmp/split.png` |
| The Tools menu lists all eight | 2026-09-09 | System Events menu dump |
| Finder extension registers and Finder loads it | 2026-09-09 | `pluginkit`, process list |
| The right-click item appears and works | 2026-09-09 | the user, by right-clicking |
| The drag gesture on tool tabs | 2026-09-09 | the user |
| Tests hardened: live tree, sync, copies, scan structure checked against fresh-scan oracles across hundreds of randomised seeds | 2026-09-19 | `swift test` (500 tests); fuzz suites run to 500 seeds by hand |
| Tabs, flat table, content line | 2026-09-19 | offscreen renders `tmp/look-files.png`, `tmp/look-content.png`. The first look showed a warning glyph over the whole table: the renderer painting the tool-sized drop target, which draws nothing in a window. Fixed in render mode (`acceptsFolders(renderMode:)`) and guarded like `ScrollView`. Not yet seen by a person |
