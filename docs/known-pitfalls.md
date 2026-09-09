# The mistakes tools like this make, and what this one does

A disk analyser that reports a number larger than the disk, a duplicate finder
that offers to delete the only copy, a folder comparison that calls two
identical files different — these are not exotic failures. They are the
ordinary ones, and each has a specific cause. This is the list, what the code
does about each, and how that was established.

Evidence is marked: **run** means it was executed and observed, **src** means
the mechanism was read in the source. Nothing here is marked from memory.

## Counting the same bytes twice

| Trap | What happens if you get it wrong | Here |
|---|---|---|
| **Following symlinks** | A link to a parent makes the walk loop, or a link to another tree counts it again | Links are recorded and never descended into: only entries that are directories *and* not symlinks are queued (**src**, `Scanner.swift`) |
| **Crossing mount points** | Another disk's contents added to this disk's total | Refused two ways, because one is not enough: by device number, and by matching the path against the mount table. `st_dev` cannot separate APFS volumes inside one container (**src**) |
| **APFS firmlinks** | `/Users`, `/Applications` and friends appear under `/` *and* on the Data volume; walking `/` counts most of the disk twice | The firmlinked paths are excluded when the root is `/`, and "the startup disk" expands to both volumes, which are separate devices (**src**, `RootSet.expandStartupVolume`) |
| **Hard links** | One file's bytes counted once per link | The first link met keeps the bytes, later ones are flagged and count zero. Totals are identical at one thread and at sixteen (**run**) |
| **Nested scan targets** | Choosing a folder and its parent counts the folder twice | A target inside another chosen target is dropped, with a reason the screen can show (**src**, `RootRejection.containedIn`) |

Cross-checked against the system: `du -sk` on a 3,203-node tree reports
13,336,576 bytes; this scanner reports 13.3 MB of the same tree, with no hard
links to disagree about (**run**).

## Reporting a size that is not the size

| Trap | Here |
|---|---|
| **Apparent vs allocated** | Both are kept per node, and the screen has a switch. A sparse file and a clone are the cases where they differ most (**src**) |
| **iCloud placeholders** | A dataless file has an apparent size and no bytes on this disk. Flagged, counted as zero physical, and shown with a cloud mark. Never opened — reading one would download it (**src**) |
| **Resource forks and extended attributes** | Counted: the walk asks for `ATTR_FILE_TOTALSIZE` and `ATTR_FILE_ALLOCSIZE`, which are all forks rather than the data fork alone (**src**) |
| **Filesystem compression** | Flagged. The allocated size is what the volume reports, which for a decmpfs file is the compressed extent (**src**) |
| **Paths longer than the system will accept** | `open` refuses past `PATH_MAX`, but nothing stops a tree from being *built* past it — npm, git and rsync all create directories with relative steps. Seen at 2,453 bytes. Handled rather than reported as unreadable (**src**) |
| **Directories that cannot be read** | Counted and surfaced, not silently skipped: without Full Disk Access every total on screen is an understatement, and the status bar says so (**src**) |

## Calling two files different when the filesystem calls them the same

This is the one that was wrong.

macOS volumes are case-insensitive by default, and treat a name composed two
ways as one name. So `Photo.jpg` in one folder and `photo.jpg` in another are,
to the filesystem, the same name — and to anyone hunting for copies, obviously
the same file twice.

- The **folder comparison** already folded case and normalised, and fell back
  to raw bytes when two names in one folder fold together, which can only
  happen on a volume that tells them apart (**src**).
- The **copy hunt** did not. Both halves of it — the file-level match on name
  and size, and the folder signature — compared raw bytes, so every one of
  those pairs was walked past. Fixed, with the rule written once in `NameKey`
  and used by both (**run**, `NameFoldingTests`).

The folding costs nothing measurable: the file pass over 2.45M nodes takes
0.02s and the folder signatures 0.34s. Plain ASCII names, which is nearly all
of them, fold a byte at a time with no allocation; only a name with a byte of
0x80 or more takes the slow road, where normalisation has something to do.

## Deleting the wrong thing

The standing rule for this project is that nothing may be lost by mistake.

| Trap | Here |
|---|---|
| **Deleting rather than trashing** | The only deletion in the app is `trashItem`. Nothing calls `unlink` or `removeItem` on anything the user owns; the two `removeItem` calls in the codebase prune its own snapshot and log files (**src**) |
| **Removing the last copy** | A tick that would empty a set of copies is refused, and the row says why (**src**) |
| **Acting on a stale list** | Every modification shows a report first and is checked again against the disk immediately before acting (**src**, `TrashDriftTests`) |
| **A comparison built from stale data** | A comparison may be answered from the scan only while the tree is being watched, and never when the scan did not walk all of it. See `docs/scanning-speed.md` (**run**) |

## Known and accepted

- **Directory inodes** are not counted as bytes of their own. `du` does count
  them; the difference is a few kilobytes per thousand directories.
- **A network or FUSE volume** may report attributes this walk trusts —
  `ATTR_FILE_ALLOCSIZE` in particular — more loosely than a local one.
- **A name that is not valid UTF-8** would break the path rebuilt for opening a
  subdirectory. APFS refuses such a name at creation, checked by trying it; a
  network share serving one is the case this does not cover (**run**).
