# How fast the walk is, and why it is not faster

Measured on 2026-09-09, on a ten-core machine (8 performance, 2 efficiency),
APFS on internal SSD, against `~/dev`: **3,185,717 nodes — 427,451 directories,
2,752,040 files, 6,209 symlinks, 249 GB.** Every figure below is the best of
three warm runs. Cold and warm differ by under 10%, which is itself a finding:
this walk is not waiting for the disk.

Reproduce with `dmbench scan <path>`, thread count via `DM_THREADS`.

## Where the time goes

| | |
|---|---|
| `du -sh` on the same tree, warm | 55.0 s |
| This scanner, one thread | 54.9 s |
| This scanner, default threads | 12.5 s |

One thread costs what `du` costs, which is what a walk of this tree costs when
nothing is overlapped. The whole of our advantage is parallelism.

Sampled at 12 threads, as a share of the threads that were doing anything:

| | |
|---|---|
| `getattrlistbulk` | 69% |
| `open` | 19% |
| lock waits | 12% |
| everything we wrote | under 1% |

The code is not the cost. The syscalls are, and there is one `open` and at
least two `getattrlistbulk` calls per directory.

## Thread count

Workers sit in the kernel, so one thread per core leaves the machine waiting.

| Threads | Elapsed |
|---|---|
| 1 | 54.9 s |
| 2 | 35.9 s |
| 4 | 17.6 s |
| 8 | 13.6 s |
| 10 | 12.9 s |
| 16 | 12.5 s |
| 24 | 12.4 s |
| 32 | 12.1 s |
| 40 | 12.1 s |

The default is `min(16, cores × 2)` — where the curve went flat, rather than
where the cores ran out. Worth 3% over one-per-core on this machine, and more
on a machine with fewer cores.

## Two ideas that were measured and dropped

Both are the obvious next moves, both are written up here so nobody spends
another afternoon on them.

**`openat` from the parent's descriptor instead of `open` on the absolute
path.** The reasoning is sound — resolving one component instead of ten — and
the measurement says it does not matter: 21.4 µs against 22.4 µs per open at
depth ten, a 4% difference on 19% of the time, so under 1% overall. macOS
resolves cached path components far too cheaply for the saving to show. It
would have cost a descriptor budget, a fallback path, and a new way to leak
descriptors on cancellation. `Scripts/measurements/open-vs-openat.swift`.

**Skipping the `getattrlistbulk` call that only reports the end.** Half of all
calls return zero entries — 427k of 854k — so removing them looks like halving
the call count. Measured over 2,000 small directories: 39.6 ms with the ending
call, 37.8 ms without. 4%. The cost is per directory opened, not per call.
Avoiding it would have meant trusting `ATTR_DIR_ENTRYCOUNT` to decide when to
stop reading, and a directory listing truncated by a filesystem that reports
that number loosely is silent data loss — a wrong total, with nothing on screen
saying so. `Scripts/measurements/bulk-eof-cost.swift`.

**Skipping empty directories** using the same attribute was dropped for a
duller reason: 11,609 of 427,451 directories are empty here, 2.7%.

## Not walking the same folder twice

The walk is at its floor. The saving left is not doing it.

Comparing two folders walked both of them from disk, even when the app had
already measured them — which is the ordinary case, because the folders being
compared are usually on the disk being looked at. A comparison now asks the
scan first. Measured on two folders of a few thousand nodes each:

| | |
|---|---|
| Both sides walked | 0.93 s |
| Both sides read from the scan | 0.10 s |
| One side read, one walked | 0.66 s |

Reproduce with `dmbench comparereuse <left> <right>`, which runs it both ways
and checks the two answers against each other field by field.

### When the scan is not good enough to stand in

The saving is only worth having if the answer cannot change, so the offer is
refused far more often than it strictly has to be.

- **The tree is not being watched.** Then its age is unknown. The map is
  allowed to be a little behind; a screen people delete from is not.
- **Anything inside was not walked** — an excluded path, a mount point the scan
  did not cross, a directory it could not open. The copy would be a folder full
  of missing files, and every one of them would be reported as a difference.
  Checked over the whole subtree, because the missing part can be ten levels
  down.
- **Anything inside is an extra link to an inode.** This is the subtle one. A
  scan counts an inode's bytes once, at the first link it meets, and zeroes
  every later one — right for the disk being measured, wrong for a folder
  lifted out of it. If the first link was in some other folder, the copy
  carries a zero where a walk of that folder alone carries the real size. It is
  not recorded where the first link was, so any extra link is refused. This is
  what refuses a folder in an rsync `--link-dest` backup set, and refusing is
  the right answer there: the links are *between* the two folders being
  compared, so a walk of each alone genuinely counts different bytes.

A refused side is walked, which is what happened before. The check itself is a
pass over the subtree in memory.
