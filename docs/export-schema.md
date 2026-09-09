---
title: Reading a scan from another program
eyebrow: DiskMap
subtitle: The JSON documents, field by field, and what they deliberately leave out
audience: Anyone integrating with DiskMap
date: 2026-09-01
accent: teal
summary: Three commands, three versioned JSON documents — the whole report, a filtered table of files, and a search. Produced by the `diskmap` command or, for the report, by Export Results in the app. Every one of them says what it left out, so a consumer can tell absence from omission.
documents_history: true
---

## How do I get one?

**From the command line**, for anything automated. `make cli` builds it and
puts it in `~/.local/bin`:

```
diskmap scan ~/Downloads ~/Movies --out report.json
diskmap / --min-folder 500MB --top-files 200 --duplicates
diskmap files ~/Movies --kind video --min 1GB --older-than 365 --tsv
diskmap find rprt ~/dev --limit 20
```

Three commands, each with its own document and its own `--help`:

| Command | Answers | Schema |
|---|---|---|
| `scan <path>...` | where the space went, over the whole tree | `diskmap.export/1` |
| `files <path>...` | which files, filtered and sorted, as a flat list | `diskmap.table/1` |
| `find <needle> <path>...` | where is that, by name | `diskmap.search/1` |

`diskmap <path>...` with no command still means `scan`, which is what it meant
before there were commands. The one ambiguity is a folder named after a
command: write `./files` and it is a path again.

Paths may be folders or whole disks, and any number of either can be given —
they are measured as one total. A path inside another is dropped rather than
counted twice, and the reason is printed on stderr. With no `--out` the document
goes to stdout, so stderr carries progress and stdout carries only JSON.

**Every command scans first.** There is no stored index, so the cost of a
question is the cost of the scan plus the question. Asking three questions
about one disk means three scans; if that matters, use `scan` once and query
its output.

Exit codes: `0` success, `1` bad usage, `2` nothing could be measured, `3` the
write failed.

**From the app**, when a scan is already on screen: File → Export Results…
(⌘E). Cleanup suggestions are included if they have already been worked out;
duplicates are not, because finding them is a second pass over the tree and a
save dialog is the wrong place to spend a minute. Use `--duplicates` for those.

## What is in it?

```json
{
  "schema": "diskmap.export/1",
  "generatedAt": "2026-09-01T15:06:05Z",
  "roots": ["/Users/md/Downloads"],
  "totals": { "physical": 2506752, "logical": 2500000, "files": 2, ... },
  "volumes": [ { "path": "/", "name": "Macintosh HD", ... } ],
  "limits": { "folderMinimumBytes": 10000000, "foldersOmitted": 4211, ... },
  "folders": [ { "path": "...", "physical": 503808, "items": 1, ... } ],
  "largestFiles": [ { "path": "...", "physical": 2002944, ... } ]
}
```

### `schema`

`diskmap.export/N`. **Refuse a major version you do not know** rather than
guessing at it. Version 1 is the current one. The number changes when a field
changes meaning or disappears; new optional fields do not change it.

### `totals`

The scan as a whole.

| Field | Meaning |
|---|---|
| `physical` | Bytes actually occupied on disk |
| `logical` | Apparent size, which can far exceed `physical` |
| `files`, `directories`, `symlinks` | Counts |
| `datalessFiles`, `datalessLogical` | iCloud placeholders. Their apparent size is **not** on this disk, and deleting them frees nothing |
| `hardlinkDuplicates`, `hardlinkDuplicateLogical` | Files reached by a second name and counted once |
| `unreadableDirectories` | Could not be opened, usually for want of Full Disk Access. **Non-zero means every total here is an understatement** |
| `elapsedSeconds` | How long the walk took |
| `cancelled` | True if the walk was stopped early, in which case the totals are partial |

Prefer `physical` for "how much space is this using". `logical` is what the
files claim, and on a disk leaning on iCloud or sparse files the two differ by
terabytes.

### `volumes`

One entry per disk the roots live on.

| Field | Meaning |
|---|---|
| `capacity` | Size of the volume |
| `used` | `capacity − freeWritable` |
| `freeWritable` | What can be written right now |
| `freeAsFinderShows` | What Finder reports, which counts purgeable space as free |
| `purgeable` | `freeAsFinderShows − freeWritable` |

`freeAsFinderShows` is the larger and the less useful number: those bytes are
still occupied and macOS only reclaims them when the disk fills up. If you are
deciding whether a copy will fit, use `freeWritable`.

### `limits` — read this before concluding anything is absent

A full tree is millions of entries, so the document carries the folders that
matter and says so.

| Field | Meaning |
|---|---|
| `folderMinimumBytes` | Folders smaller than this are not listed. Their bytes are still counted in their listed ancestors and in `totals` |
| `foldersListed` / `foldersOmitted` | How many made the cut, and how many did not |
| `largestFilesLimit` / `largestFilesListed` | Asked for, and returned |

**A folder absent from `folders` is not a folder that does not exist.** It is
below the floor. `diskmap --min-folder 0` lists everything, at the cost of a
much larger document.

### `folders` and `largestFiles`

Both are arrays of the same entry shape, largest first.

| Field | Meaning |
|---|---|
| `path` | Absolute path |
| `physical`, `logical` | For a folder, the total of everything beneath it |
| `isDirectory` | |
| `items` | Direct children. Folders only |
| `modified` | Last modification time, ISO 8601 |
| `dataless` | Present and true only for iCloud placeholders |
| `hardlinkDuplicate` | Present and true only for a second name for a file already counted |

`dataless` and `hardlinkDuplicate` are absent rather than false when they do not
apply, so `"dataless" in entry` is the test.

### `duplicateGroups` — only with `--duplicates`

**Absent** when not requested; an empty array means "looked, found none". Same
for `suggestions`.

| Field | Meaning |
|---|---|
| `kind` | `folder` or `file` |
| `exact` | Every name and size matches recursively. A partial folder match is a similarity, not a copy |
| `reclaimable` | Freed by keeping one copy and removing the rest |
| `paths` | Every copy, including the one you would keep |

### `suggestions` — only with `--suggestions`

| Field | Meaning |
|---|---|
| `kind` | `duplicateFolders`, `duplicateFiles`, `buildOutput`, `appCaches`, `installers`, `stale`, `trash` |
| `safety` | `comesBack` (a toolchain rebuilds it), `aCopyRemains`, `yourCall` |
| `bytes`, `itemCount` | What acting on it would free, and over how many items |
| `omitted` | Left out because the list would be too long to review |
| `paths` | The items proposed. Empty for `trash`, which is reported and never proposed for deletion |

**These are proposals, not instructions.** Nothing in DiskMap deletes without a
confirmation naming every path, and an integration should hold to the same
standard.

## `diskmap.table/1` — the `files` command

A flat list of files, however deep they sit, filtered and sorted by whichever
property the question is about. The same thing the app's *All files* tab shows.

```json
{
  "schema": "diskmap.table/1",
  "generatedAt": "2026-09-08T19:30:24Z",
  "roots": ["/Users/md/Movies"],
  "sortedBy": "size", "ascending": false,
  "matched": 3832, "shown": 1000,
  "physical": 5203984384, "logical": 5203102931,
  "rows": [
    {
      "path": "...", "name": "A001.MOV", "folder": "...",
      "kind": "video", "directory": false,
      "physical": 55871078400, "logical": 55871078400,
      "modified": "2026-06-14T16:21:00Z", "marks": []
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `matched` / `shown` | How many there were, and how many came back. **Read `matched`, never `rows.length`** — the list is capped by `--limit` and the answer is not |
| `physical`, `logical` | Over every match, not over the rows returned. Files only, even with `--folders`: a folder's size is its subtree, so counting both would add the same bytes once per level |
| `kind` | A stable token — `video`, `diskImage`, `virtualMachine` — never the translated label. The same tokens `--kind` accepts |
| `marks` | Only what is true of that row: `dataless` (iCloud placeholder, its apparent size is not on this disk), `hardlink` (a second link to bytes counted elsewhere), `symlink`, `compressed`, `unreadable` |

Filters are `--name`, `--kind`, `--min`, `--max`, `--newer-than`,
`--older-than` and `--folders`; ordering is `--sort` and `--asc`. All of them
are answered from the scan's index, so a filter costs one pass over memory and
never opens a file.

`--tsv` writes `path`, `kind`, `physical`, `logical`, `modified`, `marks`
instead, with a header line, for the half of headless use that is a pipeline.

**Fields are escaped.** A macOS filename may contain a tab or a newline, and one
that does would otherwise add a column or a row — `awk -F'\t'` would read the
wrong field for that record and never say so. Backslash becomes `\\`, and tab,
newline and carriage return become `\t`, `\n` and `\r`. Unescape if you need the
real name; ignore it if you only want columns.

```bash
diskmap files / --kind video --min 1GB --older-than 730 --tsv --quiet \
  | awk -F'\t' 'NR>1 { total += $3 } END { print total/1024/1024/1024 " GB" }'
```

## `diskmap.search/1` — the `find` command

```json
{
  "schema": "diskmap.search/1",
  "needle": "rprt",
  "matched": 1, "shown": 1,
  "hits": [
    { "path": "...", "name": "report.pdf", "directory": false,
      "physical": 24576, "logical": 22686, "how": "subsequence" }
  ]
}
```

`how` is the field worth reading: `exact`, `prefix`, `substring` or
`subsequence`. The first three mean the needle is in the name. `subsequence`
means it was not, anywhere, and the letters were read as an abbreviation
instead — `rprt` for `report.pdf`. A caller that wants only real matches should
filter on `how`, not on the count.

A needle with a `/` in it names a path: `keep/notes` looks for `notes` under a
folder called `keep`, and the segments need not be adjacent.

## What it will not do

- **It does not delete, move or copy anything, and there is no flag that makes
  it.** That is deliberate rather than unfinished. Every destructive path in
  the app goes through a report that is checked again immediately before it
  acts, against the disk as it is at that moment; a flag on a command line
  cannot be checked against what the person meant. Removal goes through the
  app, through a confirmation listing every path, and into the Trash where it
  can be put back.
- **It does not follow mount points.** A drive mounted inside a scanned folder
  is a separate budget; pass its path explicitly to include it.
- **It does not stream.** The document is built whole, so `--min-folder 0` on a
  nine-million-node disk produces a very large file. Pick a floor.

## A worked example

Fail a build when a repository's ignored output passes a gigabyte:

```bash
#!/bin/bash
set -euo pipefail
report=$(mktemp)
trap 'rm -f "$report"' EXIT

diskmap "$PWD" --min-folder 100MB --top-files 0 --quiet --out "$report"

# Anything unreadable makes every figure below an understatement.
unreadable=$(jq '.totals.unreadableDirectories' "$report")
[ "$unreadable" -eq 0 ] || echo "warning: $unreadable directories were unreadable"

# The leading [.]? matters: .build and .gradle are the common cases and
# "/build$" quietly matches neither, so the check passes having found nothing.
bytes=$(jq '[.folders[] | select(.path | test("/[.]?(build|target|DerivedData|node_modules)$")) | .physical] | add // 0' "$report")
if [ "$bytes" -gt $((1024 * 1024 * 1024)) ]; then
  echo "build output is $((bytes / 1024 / 1024)) MB"
  exit 1
fi
```

Run against this repository the script reports 363 MB in `.build`, at a
100 MB floor that listed 5 folders and omitted 1,433.

Two things in it are worth copying. The `unreadableDirectories` check, because a
scan without Full Disk Access silently reports less than is there and a
threshold compared against an understated number passes when it should not. And
the `[.]?` in the pattern: the obvious `/build$` matches neither `.build` nor
`.gradle`, so the check finds nothing and passes, which looks exactly like
success.
