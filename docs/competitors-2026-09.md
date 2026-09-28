# The other "DiskMap" apps on the Mac App Store

Checked 2026-09-28. A reference document: what three App Store apps with
this name advertise, set against what DiskMap does, and what was taken from
them. Read top to bottom only if you want the whole comparison; the
recommendations are at the end.

## Sources and what they can support

For each app: the listing's description and release notes, read through
Apple's public search API (`itunes.apple.com/search`, US store), and every
screenshot on the listing, looked at in full size (2880×1800). None of the
three was installed or run. So every competitor entry below is **what the
developer claims or shows**, not a verified behaviour, and a feature missing
from a listing is not evidence the app lacks it.

The DiskMap column is from the source (an inventory of `Sources/` with file
references, taken the same day), not from its README.

| App | Developer | Price | Version, date | On the store since |
|---|---|---|---|---|
| [DiskMap - Disk space analysis](https://apps.apple.com/us/app/diskmap-disk-space-analysis/id6801155511) | Tianjin Huayue Wanlian Technology | Free | 1.0.2, 2026-09-06 | 2026-08-20 |
| [Disk Map: Visualize Disk Usage](https://apps.apple.com/us/app/disk-map-visualize-disk-usage/id715464874) | FIPLAB Ltd | $5.99 | 2.81, 2026-02-16 | 2013-10-20 |
| [DiskMap AI: Find Large Files](https://apps.apple.com/us/app/diskmap-ai-find-large-files/id6779129301) | Security Tech OU | Free, subscription | 4.0, 2026-08-31 | 2026-06-12 |

None of the three had user ratings in the US store.

**Why the names matter.** This app's bundle name is "Disk Map". FIPLAB has
sold an app titled "Disk Map: …" since 2013, and two newer apps use
"DiskMap". Publishing on the App Store under this name would meet that; it
does not affect a direct download.

## What each one is

- **Tianjin's DiskMap** is a nested treemap in the Disk Inventory X style:
  every folder a labelled box, "name - size" in its header, cells coloured by
  kind. Toolbar: home, back and forward, fewer and more levels shown, rescan,
  stop, new scan. Its latest notes add keyboard shortcuts for the number of
  levels shown and a "Super Right-Click" entry to start it from the Finder.
  Both screenshots are the same picture.
- **FIPLAB's Disk Map** is the mature one: a nested treemap with a breadcrumb
  bar, Quick Look, a delete queue with Put Back, compress to archive,
  permanent delete as an option, and scan-time ignores (extensions, folders,
  a minimum size). Ten colour themes, colouring by size, folder depth,
  modified or created date, with a legend. Filters by kind (images, videos,
  audio, documents, archives, applications, files over 100 MB), toggles for
  hidden and iCloud-only files, warnings before permanently deleting iCloud
  files or anything on a network drive.
- **DiskMap AI** is a sunburst with a "largest items" list, a "by type"
  breakdown, and a cleanup queue you drag items into, then empty to the Trash
  in one step. Light, dark and system appearance; two category palettes;
  switches for hidden files and for showing package contents. A first-run
  tour, a list of folder permissions (it is sandboxed). Its 4.0 notes claim
  what DiskMap already does — stays on one disk, counts hard links once, a
  real progress figure — plus VoiceOver labels on the map, Reduce Motion, and
  refusing to queue system folders. Nothing on the listing or the screenshots
  shows what the "AI" does.

## Side by side

**P** present, **—** not shown or not advertised, **~** partly. For the
three competitors this is the listing, not a test.

| Capability | DiskMap | Tianjin | FIPLAB | DiskMap AI |
|---|---|---|---|---|
| Treemap, nested with folder headers | P | P | P | — |
| Sunburst | P (and icicle) | — | — | P |
| Breadcrumb, back and forward | P | ~ (back/forward) | P | ~ |
| Change how many levels are drawn | **P, added 2026-09-28** (1–12, Cmd-= and Cmd--) | P, with shortcuts | — | — |
| Colour by kind | P (14 kinds) | P | — | ~ (lists only; the sunburst is a rainbow) |
| Colour by age | P (6 bands) | — | P (modified, created) | — |
| Colour by depth, several themes | — | — | P (10 themes) | ~ (2 palettes) |
| Legend | P | — | P | — |
| Filter the map by kind or size | ~ (All files table only) | — | P | — |
| Hidden files toggle | — (always counted) | — | P | P |
| Package contents toggle | — (always opened) | — | — | P |
| Scan-time ignores (extension, folder, min size) | — (on purpose, see below) | — | P | — |
| **Quick Look** | **P, added 2026-09-28** | — | P | P |
| Reveal in Finder | P | — | P | P |
| Move to Trash, with undo | P (Cmd-Z, Put Back works) | — | P | P |
| Permanent delete | — (on purpose) | — | P | P (asks twice) |
| One queue of items to delete, across views | ~ (ticks in Copies and Free up space) | — | P | P |
| Compress to archive | — | — | P | — |
| Warn before deleting on a network volume | **P, added 2026-09-28** (refused before the confirmation when the volume has no Trash) | — | P | — |
| Refuse to delete system folders | **P, added 2026-09-28** (the folders themselves; their contents stay removable) | — | — | P |
| Largest items list, size by type | P | — | — | P |
| Scan several disks or folders as one total | P | — | — | — |
| **Home folder as a start target** | **P, added 2026-09-28** | — | — | P |
| Drop a folder on the window | P | — | — | P |
| Start from the Finder's context menu | P (Finder extension, Services) | P | — | — |
| Live updates after the scan | P (FSEvents) | — | ~ (Reload button) | — |
| Hard links counted once | P | — | — | P (4.0) |
| Stays on one volume | P | — | — | P (4.0) |
| Scan total reconciled with the volume (purgeable, snapshots) | P | — | — | — |
| Duplicate files and duplicate folders | P, with content verify | — | — | ~ ("duplicate downloads") |
| Compare two folders, sync them | P | — | — | — |
| Cleanup rules (caches, build folders) | P | — | — | ~ ("bloated caches") |
| What changed since the last scan | P | — | — | — |
| Find by name, flat sortable table, details panel | P | — | — | ~ (largest list) |
| Names that are not UTF-8, network shares measured right | P (2026-09-28) | — | — | — |
| Export | P (JSON, CLI with TSV) | — | — | — |
| VoiceOver on the map, Reduce Motion | — | — | — | P |
| First-run tour | — (Full Disk Access prompt only) | — | — | P |
| Languages | English, Turkish | Chinese UI in screenshots | English | English |

## What was taken from them

Four gaps were bounded and clearly worth closing the same day:

- **Quick Look.** FIPLAB and DiskMap AI both let you look at a file before
  deleting it; DiskMap could only reveal it in the Finder. Now: Cmd-Y in the
  Scan menu, the space bar, and a button in the Details panel. An iCloud-only
  file is not previewed, because previewing downloads it.
- **Home folder as a target** (DiskMap AI's start screen). A button beside
  "Add More…". It exposed a wrong label: one folder ticked read "Scan Whole
  Disk"; it now reads "Scan 1 Location" unless the one target is a disk.
- **Refusing the folders macOS depends on** (DiskMap AI): `/System`,
  `/Library`, `/Applications`, `/usr` and the like, every account's home
  folder, its Library, Desktop, Documents, Downloads, Movies, Music,
  Pictures, Public, and in Library its Keychains, iCloud Drive, cloud drives,
  app containers, Application Support and Preferences. Exact paths only; a
  home scan can still clear out everything inside them. Before this, only
  scan roots and the never-touch list were refused.
- **No Trash, said first** (FIPLAB warns about network drives). A volume
  with no Trash is now refused at planning, by name, before the
  confirmation; on the NFS share checked the same day the Trash failed only
  after the user had confirmed.

## Not taken, on purpose

- **Permanent delete.** Every removal goes through the Trash with undo; the
  README states it as a rule ("nothing is deleted, ever"). FIPLAB's own warnings
  about permanently deleting iCloud and network files are the cost of having
  the option.
- **Scan-time ignores that change the totals** (extensions, folders, minimum
  size). A total that silently leaves files out is wrong about the one number
  the app exists to get right. A view-time filter that says what it hides
  would not have that problem; see below.
- **Hiding hidden files from the totals.** DiskMap AI's own settings say its
  numbers are only right with hidden files shown.

## Recommendations

Ordered by what the user gets for the effort. The first two were done the
same day (above); the rest are not started.

| # | What | Seen in | Effort | Why |
|---|---|---|---|---|
| 1 | **Done.** Refuse to trash the folders macOS depends on (`/System`, `/Library`, `/usr`, `~/Library` itself, the home folder itself), with the reason in the confirmation | DiskMap AI | Small | Today only scan roots and the never-touch list are refused; trashing `~/Library` from a home scan is one confirmation away |
| 2 | **Done.** Say before a Trash on a volume with no Trash (network shares, some external disks) that nothing will be moved, instead of failing after the confirmation | FIPLAB (as a warning) | Small | The share checked on 2026-09-28 refuses every Trash; the user learns it only after confirming |
| 3 | A filter on the map by kind and by size band, shown as a filter (the map says what it hides) | FIPLAB | Medium | The All files table already has these filters; the map has only a name filter |
| 4 | **Done.** More or fewer levels drawn, with shortcuts | Tianjin | Small–medium | Depth is fixed at 6; deep trees of small files get noisy |
| 5 | One delete queue that any view can add to, reviewed in one sheet | FIPLAB, DiskMap AI | Medium | Ticks exist per tool (Copies, Free up space) but not across the map, the table and Find |
| 6 | VoiceOver labels for map cells and rings; honour Reduce Motion | DiskMap AI | Large | The only accessibility label in the app is on the home view |
| 7 | Treat `.app` and other packages as one item, with a switch | DiskMap AI | Medium | Navigation only; totals unchanged |
| 8 | **Done.** Quick Look follows the selection while its panel is open | Finder | Small | Today the panel keeps the file it opened with |
| 9 | Colour by depth; more palettes | FIPLAB | Small | Cosmetic; lowest value here |
| 10 | Compress to archive | FIPLAB | Small | Frees little on the files that fill disks — video, photos and archives are compressed already |
