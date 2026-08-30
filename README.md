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
Scripts/make-signing-cert.sh      # once: stable identity so Full Disk Access sticks
Scripts/build-app.sh "DiskMap Local Signing"
open build/DiskMap.app
```

Without the certificate, `Scripts/build-app.sh` ad-hoc signs, and macOS treats
every rebuild as a new app — you would re-grant Full Disk Access each time.

**Grant Full Disk Access** to `build/DiskMap.app` in System Settings → Privacy &
Security. Without it, parts of the disk are invisible and the totals come up
short; the status bar says so explicitly rather than quietly under-reporting.

## Using it

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

## Known limits

- **APFS clones cannot be detected** through any public API. Cloned blocks are
  counted once by the volume but can appear under several names, so they land in
  the "unaccounted" line of the reconciliation panel rather than being silently
  absorbed.
- Directory metadata blocks are not counted (`ATTR_DIR_ALLOCSIZE` is not
  requested); this also shows up as unaccounted.
- Live updates leave orphaned nodes behind on heavy churn. Memory grows slowly;
  a rescan compacts.

## Development

```sh
swift test                                   # 9 tests, including FSEvents end-to-end
.build/release/dmbench volume                # capacity report
.build/release/dmbench validate <path>       # cross-check bulk attrs against lstat
.build/release/dmbench scan <path>           # throughput and reconciliation
```

`dmbench validate` exists because `getattrlistbulk` returns a packed buffer whose
field order is load-bearing; it compares inode, type, logical and physical size
against `lstat` for every entry in a directory.

The UI renders offscreen without a window server or Screen Recording permission:

```sh
DISKMAP_RENDER="<path>|1400|900|/tmp/ui.png" build/DiskMap.app/Contents/MacOS/DiskMap
```

AppKit-backed controls (buttons, pickers, `HSplitView`) draw as placeholders in
that mode; everything drawn by SwiftUI itself is faithful.
