# Disk Map

A disk space analyzer for macOS, in the spirit of TreeSize. Native Swift, no
sandbox, built to report numbers you can act on.

## Why it exists

Finder's "available space" is not free space. Finder shows
`volumeAvailableCapacityForImportantUsage`, which counts *purgeable* content —
evictable iCloud files, caches, local snapshots — as if it were already free.
On the machine this was built on:

| | |
|---|---|
| Capacity | 8.00 TB |
| Finder says available | **7.25 TB** |
| Actually writable now | **1.14 TB** |
| Purgeable, counted as free by Finder | **6.12 TB** |

Disk Map shows all of these side by side, and explains every byte it cannot
attribute to a file rather than rounding the difference away.

## Three ways a disk analyzer lies, and what this does instead

**Apparent size vs. bytes on disk.** Summing file sizes over the home folder on
this machine gives 15.24 TB — on an 8 TB disk. The scanner records *allocated*
size (`ATTR_FILE_ALLOCSIZE`) as the primary metric, which is what actually
changes when you delete something. Apparent size is shown next to it.

**iCloud placeholders.** 1.43 million files here are dataless stubs: they report
a size but occupy zero bytes locally. Deleting them frees nothing. They are
detected via `SF_DATALESS`, counted as zero, and flagged in the UI. The scanner
never opens a file, so browsing never triggers a download.

**Hard links and firmlinks.** Extra links to one inode are counted once.
Scanning `/` naively walks `/Users`, `/Applications` and `/private` twice,
because they are firmlinks onto the Data volume; those paths are excluded.

## Install

```sh
./install.sh
```

That is the whole thing, and it does not prompt for a password. It checks the
toolchain, creates a code-signing certificate if you do not have one, builds,
installs to `/Applications`, then opens the Privacy pane and a Finder window so
you can drag the app in to grant Full Disk Access. It ends with an explicit
`Installed` or `Failed` block, naming the identity it actually signed with.

```
./install.sh --dev       run from ./build without installing
./install.sh --no-open   skip opening the Settings and Finder windows
```

`make install`, `make dev` and `make test` wrap the same steps; `make help`
lists them. Every script takes `--help` and documents what it touches:

```sh
./install.sh --help          ./uninstall.sh --help
Scripts/build-app.sh --help  Scripts/make-signing-cert.sh --help
```

Two things the installer handles that are easy to get wrong by hand:

- **The certificate.** Full Disk Access is granted to a *signed identity*. An
  ad-hoc signature changes on every build, so macOS treats each rebuild as a
  different app and drops the grant. The installer creates a stable local
  certificate once, valid for ten years.
- **Full Disk Access itself.** Without it, parts of the disk stay invisible and
  the totals come up short. The status bar says so explicitly, with a button
  that opens the right settings pane, rather than quietly under-reporting.

## Uninstall

```sh
./uninstall.sh
```

It prints exactly what it found, waits for confirmation, then removes the app,
its preferences, the keychain certificate and the Full Disk Access grant. Run it
from anywhere in the repo; it is safe to run twice.

```
./uninstall.sh --dry-run     show the plan and change nothing
./uninstall.sh --yes         skip the confirmation
./uninstall.sh --keep-cert   leave the certificate, e.g. before reinstalling
./uninstall.sh --build       also delete this repo's build artifacts
```

By default it leaves the repo's `.build` and `build` directories alone: those
belong to the checkout, not to the machine, and `make clean` covers them.

Two things it does that deleting the `.app` by hand does not:

- **Resets the TCC grant** (`tccutil reset SystemPolicyAllFiles`). Otherwise a
  dead entry stays in System Settings, pointing at an app that no longer exists.
- **Drops the preferences domain as well as the plist.** `cfprefsd` caches
  preferences in memory and writes the file back after you delete it, so
  removing the plist alone does not stick.

### Two macOS details worth knowing

`security import` cannot read a PKCS#12 written with current OpenSSL defaults,
and fails outright on an empty password: the certificate has to be exported with
`-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1` and a real password.

`security find-identity -v` lists only *trusted* identities, so a self-signed
certificate never appears there even though `codesign` signs with it happily.
Detection has to use the listing without `-v`. Because of that, no trust
settings need changing, which is why the install needs no password.

A third: the pre-Ventura Privacy pane URL
(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`)
opens **no window at all** on macOS 13 and later, while `open` still reports
success. The current identifier is `com.apple.settings.PrivacySecurity.extension`.

## Appearance and language

Light and dark are both first-class; the treemap uses a separate palette for
each rather than the same colours at a different opacity. English and Turkish
ship in the app, switchable from the toolbar or the menu bar without a restart,
and independently of the system language. Numbers follow the language you pick,
so sizes read `1.5 GB` in English and `1,5 GB` in Turkish.

## Choosing what to measure

A whole volume, one folder, or **several folders measured as one total** —
useful when the thing you care about is spread across `~/Downloads`,
`~/Movies` and an external drive.

- **Drag folders onto the window.** On the start screen they queue up; on a
  result they start a new scan.
- **Choose Folders…** opens the standard picker with multiple selection on.
- Duplicates, symlinks pointing at a folder already chosen, and any folder
  **already inside another chosen folder** are dropped, with the reason shown.
  Keeping a folder and its parent would count the child's bytes twice, and a
  disk analyser reporting more than the disk holds is worse than useless.
- A folder on another volume mounted *below* a chosen folder is not treated as
  nested, because the scan does not cross mount points and so never reaches it.
- Hard links are counted once even when the two names live under different
  chosen folders.

When several folders are measured together the breadcrumb root reads
"3 locations", and each folder appears as a top-level block in the treemap.
The scan total is not compared against the volume's used space in that case:
subtracting a few folders from a whole disk yields a precise, meaningless
number.

## Views

Four ways to look at the same scan, because they answer different questions.

- **Treemap.** Area is bytes, so the biggest rectangle is the thing worth
  deleting. Best for "what is taking the space".
- **Sunburst.** One ring per level, arc length proportional to size. A treemap
  spends every pixel on area and buries depth; here depth *is* the radius, so a
  long chain of nested folders shows as a spoke instead of vanishing into a
  block. Best for "what shape is this tree".
- **Largest files.** The biggest files anywhere below the current folder, with
  their paths. The tree table answers "what is in this folder"; this answers
  "what should I delete", which is usually one huge file six levels down.
- **By type / by age.** Where the space went by kind of file, and by how long
  ago it was touched, with a line like *"29.3 GB untouched for over two years"*.

Colours mean one of two things, switchable from the toolbar menu: **by type**
(video, model, database, code…) or **by age**, a cool-to-warm ramp so a folder
nobody has opened in years reads as one warm block. Age colouring works on both
the treemap and the sunburst.

Considered and not built, with reasons: an **icicle/flame** layout adds a third
geometry for little that the treemap and sunburst do not already cover;
**duplicate detection** needs content hashing, which is a different kind of
work from a metadata scan; **scan comparison over time** needs persisted
snapshots. Any of the three is a reasonable next step.

## Using it

- **Tree table.** Folders open in place with the disclosure triangle, so you can
  compare two branches without losing your position. Indentation is applied
  *after* the size and share columns, so those stay in one straight track
  however deep you go and can still be scanned down the page.
- **Navigation.** Back and Forward (`⌘[` / `⌘]`) retrace where you have been,
  `⌘↑` goes to the enclosing folder, the breadcrumb jumps to any ancestor in one
  click, and double-clicking empty space in the treemap goes back out.
- **Treemap** — area is bytes on disk. The biggest rectangle is the thing worth
  deleting. Folder frames and headers show which folder owns a block.
- **Double-click** a folder to descend, breadcrumb or ⌘↑ to go back up.
- **⇧⌘R** reveals the selection in Finder. **⌘⌫** moves it to the Trash — the
  real Trash, so Finder's *Put Back* works. **⌘Z** undoes it.
- **Live** — FSEvents keeps the tree in step with the disk. Every event is
  reduced to "relist one directory", reusing untouched subtrees, so an update
  costs the entries in that folder rather than a rescan.
- **On disk / Apparent** toggle switches the metric everywhere at once.

## How it works

| Piece | Approach |
|---|---|
| Traversal | `getattrlistbulk(2)`, one syscall per batch of entries instead of `readdir` + `stat` per file |
| Parallelism | Work-stealing directory queue, saturates at 8–12 threads |
| Storage | Structure-of-arrays, 32-bit node ids, contiguous child blocks — no `nextSibling` pointer |
| Aggregation | Children always have a higher index than their parent, so subtree totals are one reverse pass |
| Layout | Squarified treemap, recursion stops where a cell is too small to see |

### Measured on this machine

| | |
|---|---|
| Throughput | ~155k entries/s at 12 threads (38k/s single-threaded) |
| Home folder | 48.7 s cold, 761 MB peak footprint |
| Volume projection | ~77 s for 12M inodes |

Numbers are from an M-series Mac with an 8 TB APFS volume; they scope to that
machine, not to hardware generally.

## Cost, measured

A full scan of an 8 TB startup disk holding 11.6 million files:

| | |
|---|---|
| Time | 66-70 s (~166k entries/s, 12 threads) |
| Peak memory | 0.69 GB, max RSS 0.78 GB |
| Tree in memory | 568 MB — 49 bytes per node |
| CPU split | **user 12.7 s, sys 288 s** |

That last row is the one that decides where optimisation is worth doing: 96% of
the CPU is the kernel reading directories. Rewriting the Swift side could move
about 4%, so the effort went into memory instead, where three changes took peak
usage from 1.32 GB to 0.69 GB without dropping a single file:

- **Scan straight into the destination store.** Scanning each volume into its
  own store and grafting it afterwards kept two full copies alive at the
  moment of the copy.
- **Size the arrays once**, from the volumes' own used-inode counts, instead of
  growing 11.6M nodes geometrically and leaving 350 MB of slack behind.
- **Intern names.** 11.6M nodes carry only 3.4M distinct names — `Contents`,
  `Resources`, `package.json` recur endlessly — so storing each once cut the
  name blob from 238 MB to 105 MB.

Run `dmbench scan <path>` for the same breakdown on any tree.

## Known limits

- **APFS clones cannot be detected** through any public API. Cloned blocks are
  counted once by the volume but can appear under several names, so they land in
  the "unaccounted" line of the reconciliation panel rather than being silently
  absorbed.
- Directory metadata blocks are not counted (`ATTR_DIR_ALLOCSIZE` is not
  requested); this also shows up as unaccounted.
- Live updates leave orphaned nodes behind on heavy churn. Memory grows slowly;
  a rescan compacts.
- A scan can be cancelled, but a cancelled scan is discarded rather than shown
  as a partial tree, because a partial total would read as a real one.

## Development

```sh
swift test                                   # 60 tests, including FSEvents end-to-end
.build/release/dmbench volume                # capacity report
.build/release/dmbench validate <path>       # cross-check bulk attrs against lstat
.build/release/dmbench scan <path> [path...] # throughput and reconciliation
```

`dmbench validate` exists because `getattrlistbulk` returns a packed buffer whose
field order is load-bearing; it compares inode, type, logical and physical size
against `lstat` for every entry in a directory.

The UI renders offscreen without a window server or Screen Recording permission:

```sh
DISKMAP_RENDER="<path>|1400|900|/tmp/ui.png||dark|tr" build/DiskMap.app/Contents/MacOS/DiskMap
```

The trailing fields are optional: `subdir`, then `light|dark`, then `en|tr`.

AppKit-backed controls (buttons, pickers, `HSplitView`) draw as placeholders in
that mode; everything drawn by SwiftUI itself is faithful.
