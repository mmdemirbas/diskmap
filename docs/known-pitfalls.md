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
| **Hard links** | One file's bytes counted once per link | The first link met keeps the bytes, later ones are flagged and count zero. Totals are identical at one thread and at sixteen (**run**). The live update used to lose this: a rebuilt folder listed a flagged link as a plain file and counted it again, and a folder that appeared with a link inside counted it too. The scan's inode table now outlives the scan; a relist keeps a link's state, a new link is a duplicate while the tree shows a keeper, and when the keeper is deleted — alone or with its folder — another link takes the bytes over, since the file is still on disk (**run**, `testARelistDoesNotCountAHardLinkTwice`) |
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

## Names that are not text

A filename is bytes: any bytes except a slash and a zero. On APFS they also
happen to be valid UTF-8, because APFS refuses anything else at creation —
`mkdir` with a 0xFF in the name returns EILSEQ (**run**). The volumes where
that does not hold are the ones people keep backups on: a share served by Samba
or NFS from Linux, an ext4 volume through FUSE, an archive unpacked by
something that did not care.

Turning such a name into a `String` puts U+FFFD where the awkward bytes were,
and the damage cannot be undone: a path rebuilt from it names nothing. The walk
would fail to open that folder and count it and everything beneath it as
unreadable — a whole subtree missing from the total, under a permissions
warning, on a tool whose one job is to add up correctly.

So paths are carried as bytes (`RawPath`) from the directory listing to the
`open`, and turned into text only to be shown to somebody:

- The **walk** builds each child path from the listing's bytes (**src**).
- **Paths out of the store** are rebuilt from the stored name bytes, which is
  what the store always held. `path(_:)` is that shown to a person; `url(_:)`
  is that made actionable, built with
  `URL(fileURLWithFileSystemRepresentation:)` rather than
  `URL(fileURLWithPath:)`, which takes a `String` and would lose it again.
- **Every action** — reveal, Trash, drag — goes from a node id to a URL through
  that one funnel, at the moment of acting, rather than carrying a path
  through a `String` in a plan (**run**, `RawPathTests`). The drift check that
  guards the Trash reads the URL's bytes too, not `url.path`, so it looks at
  the same file the move will.
- **The comparison and the sync plan** carry relative paths as bytes from the
  two stores' name spans. A sync step's source and target are `RawPath`, and
  the runner's every call — copy, trash, rename, the drift check — takes them
  as bytes. The deep check opens files by bytes and orders them by bytes, so
  two folders holding the same files digest in the same order whatever their
  names decode to. Exercised end to end on names outside ASCII, which is the
  same road (**run**, `testAMirrorWorksOnNamesOutsideASCII`).
- **Live updates** take the path from FSEvents as the C string the callback is
  given, not as a `CFString`, and relist on bytes: the lookup, the listing,
  the set of names already known, the re-append and the scan of a folder that
  appeared since — all on the bytes the volume returned. The re-append used to
  go through a decoded `String`, which on a findable parent would have written
  an unreadable child's name back into the store as U+FFFD. Now the store
  holds what the disk reports even where that differs from what the caller
  typed: Foundation decomposes "ö" on the way to disk, and the relist keeps
  the decomposed form (**run**, `testARelistKeepsNamesAsTheListingGaveThem`).
  A folder measured on its own by the live path counts what a whole scan
  counts (**run**, `testASubtreeScanCountsWhatAWholeScanCounts`).

The name cannot be created on this machine, so the tests put the bytes into the
store directly, which is what a share serving them would have handed the walk.
One test asserts the volume still refuses, so that if it ever stops the gap in
coverage is announced rather than silent.

## Believing the tree still matches the disk

A live tree is a promise: what the map shows is what is there now. The walk
is exercised on every scan; the update path runs only when the disk moves,
and all but one of its tests called `refresh` by hand rather than letting
FSEvents drive it. The one that did wrote a *file* into a watched folder.
The first to make a *folder* with files in it and wait for the stream found
three defects in the path a new folder takes, all older than this audit
(**run**, `testTheWatcherCarriesNamesThroughToTheStore`):

- **An event for a new folder names the folder**, which the store has never
  seen. Reducing it to "relist that folder" found no node and did nothing;
  the folder and everything in it stayed out of the tree until something
  else touched its parent. A batch is now resolved to the nearest folder
  the store holds, whose relist measures the new one as a fresh subtree
  (`testAFolderTheStoreHasNeverSeenIsReachedThroughItsParent`).
- **A parent's relist does not cover a changed subfolder.** The old batch
  rule dropped every directory inside another in the same batch, on the
  theory that the parent's relist covered it. It does not: a known
  subfolder is reattached as it was. A folder and its subfolder changing
  within one debounce window lost the subfolder's change until its next
  event (`testAChangedSubfolderIsNotCoveredByItsParentsRelist`).
- **A fresh subtree grafted mid-rebuild broke the parent's child run.**
  `children(node)` is one contiguous run of ids; grafting the new folder's
  nodes while the run was still being appended put them inside it, so the
  parent listed the subtree's nodes as its own and every sibling appended
  after fell out of the tree — reachable by nothing, counted in the total.
  Which sibling depended on APFS listing order, which is by name hash. And
  `graft` linked every node it copied except the one it grafted under, so
  the new folder carried its size and listed nothing. Subtrees now go in
  after the run, and the folder's own children are linked
  (`testAFolderThatAppearsWithContentsListsThem`, with a structural check
  that every live node sits in its parent's run and every run holds only
  its own).

The class, not the instance: any code that appends into a store while
another append is in progress breaks the run. The scan takes the lock for a
whole directory's block; the relist now does the same.

**Against the only oracle there is.** Each of the above was one shape of
change, written down with its expectation. `LiveTreeFuzzTests` makes shapes
up — twelve seeds, sixty batches each, one to four random changes per batch
(create, resize, delete, rename, move, folder appears with contents, folder
deleted, folder renamed, file replaced by folder, folder replaced by file,
symlink made, symlink re-pointed) — hands the tree the events the watcher
would report, and after every batch compares what the tree shows against a
fresh scan of the same folder, node for node. It found one more on its
first run (**run**): a file replaced by a folder of the same name entered
the tree empty, because "is this name already known" was asked without
asking what it was known *as*. A name held as a file does not make the
folder known.

**The name table.** Names are interned through an open-addressed table
sized from a hint, and the table never grew. A folder that appeared with
more distinct names than the hint — 4,096 for a live update, 262,144 for a
comparison side — filled it, and the next new name probed for an empty slot
without end (**run**, the test ran 150 s to the alarm on the old table).
The table doubles when half full now, and stops interning past 2^26 slots
rather than stop returning. A related waste, not a hang: the capacity
estimate took the volume's used-inode count for every root, so scanning a
folder of a hundred files reserved for ten million and zeroed a name table
sized for the disk, and a large folder's progress bar stood near zero
because its denominator was the disk. Taken only for a root that is a
volume now.

## Known and accepted

- **Directory inodes** are not counted as bytes of their own. `du` does count
  them; the difference is a few kilobytes per thousand directories.
- **A network or FUSE volume** may report attributes this walk trusts —
  `ATTR_FILE_ALLOCSIZE` in particular — more loosely than a local one.
