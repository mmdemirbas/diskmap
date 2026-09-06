---
title: What could have moved the wrong file
eyebrow: Safety review
subtitle: Eleven defects in DiskMap's folder comparison and sync, found by asking what each one would cost
audience: Maintainer
date: 2026-09-02
summary: A deep review of the compare/plan/run path, the shapes on disk that broke it, and what stops each one now.
documents_history: true
---

> [!TLDR]
> Every destructive direction in the app rests on one sentence: *the other side
> holds these bytes too*. Fifteen separate defects let that sentence be true on
> screen and false on disk.
>
> - Nine of them would have moved a file the user had only one copy of. All go to the Trash, so all were recoverable — but none announced themselves.
> - The most likely one to fire in daily use is Turkish filenames: the same name spelled two ways read as two files, and a mirror trashed one of them. The worst is a mounted disk, which read as an empty folder and passed every gate.
> - All fifteen are fixed, each with a test that fails without the fix. The suite went from 264 to 284.

This is a **findings report**, not a guide. The opening two sections build the
one idea the rest depends on; from "The findings" onward it is a catalog, meant
to be scanned and returned to rather than read through.

It covers two passes over the same code. The first is what a deliberate review
found; the second is what came out of asking the same questions again once the
first round's fixes were in, and is marked as such in the table.

## What was reviewed, and what was not {#scope}

The subject is the path from *choosing two folders* to *bytes moving on disk*:
[FolderDiff.swift](#f/Sources/DiskMapCore/FolderDiff.swift),
[DiffTree.swift](#f/Sources/DiskMapCore/DiffTree.swift) and
[SyncPlan.swift](#f/Sources/DiskMapCore/SyncPlan.swift), plus the screen that
presents them.

```mermaid
flowchart LR
  subgraph reviewed["reviewed"]
    direction LR
    W["walk both sides"] --> M["pair names"] --> C["classify each pair"]
    C --> P["build a plan"] --> R["carry it out"]
  end
  subgraph outside["not reviewed this round"]
    direction TB
    S["the scanner itself"]
    T["Trash and Cleanup"]
    D["duplicate finder"]
  end
  R -.->|"uses"| S
  classDef inside fill:var(--series-1-soft),stroke:var(--series-1),color:var(--text)
  classDef out fill:var(--surface),stroke:var(--border),color:var(--text)
  class W,M,C,P,R inside
  class S,T,D out
```

The scanner, the Trash view and the duplicate finder were touched only where
the comparison reads from them. Performance was not measured. The Turkish
strings were written, not proofread by a second reader. Concurrency was checked
by reading every call site of the diff tree rather than by running a race
detector.

## The sentence everything rests on {#the-sentence}

A comparison of two folders is cheap because it does not read any bytes. It
pairs names, and for each pair it asks whether the two look alike — same kind,
same length. That is enough to draw a screen.

It is **not** enough to delete anything, and the app knows that: the
space-freeing directions carry a content check that reads both sides and
compares SHA-256 hashes. So the chain is supposed to be four links, and every
defect below broke one of them.

```mermaid
flowchart LR
  L0["the walk saw<br/>both folders whole"] --> L1["names pair up"]
  L1 --> L2["metadata says<br/>these look identical"]
  L2 --> L3["the content check<br/>reads the bytes<br/>and agrees"]
  L3 --> L4["one copy may<br/>go to the Trash"]
  L0 --- F0["8"]
  L1 --- F1["1"]
  L2 --- F2["2, 3"]
  L3 --- F3["5, 6, 7"]
  L4 --- F4["4, 9, 10, 11"]
  classDef link fill:var(--series-1-soft),stroke:var(--series-1),color:var(--text)
  classDef broke fill:var(--series-4-soft),stroke:var(--series-4),color:var(--text)
  class L0,L1,L2,L3,L4 link
  class F0,F1,F2,F3,F4 broke
```

*Findings by the link they broke. The chain reads left to right; the numbers
under each link are the entries in the table that follows.*

Some broke the first link, so the wrong two things were compared in the first
place. Some broke the third, so the check reported agreement about a file it
never opened. The last group broke the fourth: the chain was sound, and the
disk had moved on before anyone pressed the button.

> [!IMPORTANT]
> The failure mode is uniform and quiet. Nothing crashes, nothing reports an
> error, and the result screen says the run succeeded. The only evidence is a
> file in the Trash that should not be there.

## The findings {#findings}

Ordered as they were found. "Loses a file" means an item that existed on one
side only was moved to the Trash — recoverable with *Put Back*, but unannounced.
The **Pass** column separates the deliberate first sweep from the second one,
which went back over the same code after the first round's fixes were in.

```oku-table
{"headers": ["#", "Pass", "Defect", "What it would have done", "Cost", "Stopped by"], "rows": [["1", "one", "Names were paired by comparing raw bytes", "A name spelled two ways — precomposed `ş` on one side, `s` plus a combining cedilla on the other — read as two files, one missing from each side. A mirror trashed the one on the target side.", "Loses a file", "Folding the name the way the volume folds it, with a fallback to raw bytes in any folder where folding would make two names equal"], ["2", "one", "A symlink was compared by the length of the path it holds", "Two links pointing at completely different places matched, and `removeLeftDuplicates` trashed one. The content check could not contradict it: it reads regular files, so it never opens a link.", "Loses a file", "Links match on where they point"], ["3", "one", "A symlink facing a regular file matched on length", "A 12-byte link and a 12-byte file were called identical.", "Loses a file", "A link facing a file is a kind clash"], ["4", "one", "The runner never re-checked its target", "Between a plan appearing on screen and the button being pressed, anything can change on disk. A 400-byte file replaced by a different 90 KB file was trashed anyway, and the run reported zero failures.", "Loses a file", "Each step records the kind, length and date it saw, and refuses if that is no longer what is there"], ["5", "one", "Removing a whole side never saw the content check's disagreements", "The planner had no parameter for them and the screen had no way to send them. So a side the check had just proved was *not* a duplicate could still be trashed whole.", "Loses a file", "The parameter exists, the screen sends it, and one disagreement refuses the whole direction"], ["6", "one", "A file the check could not open counted as agreeing", "`unreadable` was collected and then dropped on the floor. A permission-denied file was removed as a proven duplicate.", "Loses a file", "Unreadable items are kept and counted on the plan"], ["7", "one", "A cancelled content check counted as a finished one", "Stopping the check after two files out of ten thousand still marked the comparison verified, and the plan said the contents were read and agree.", "Loses a file", "A cancelled check is not a check; removing a whole side refuses on it"], ["8", "one", "A cancelled comparison could be planned from", "Cancelling the walk returns a result rather than an error, and the sheet fills in. The folders it never reached are absent, and a mirror reads absent as *remove from the other side*.", "Loses a file", "Every direction that removes something refuses on it; copies still go ahead"], ["9", "one", "A replacement trashed the old file before writing the new one", "A copy that failed left the path empty — the original in the Trash, nothing standing where it was.", "Empty path", "The replacement is written beside the target first and moved into place after"], ["10", "one", "A copy's size was the space it occupies, not the size of the file", "Two names for one file occupy the space once. The plan promised 120 KB and wrote 240 KB, and *will this fit* was answering about the wrong number.", "Wrong number", "Removals are still counted in space freed; copies are counted in file size"], ["11", "one", "An ejected disk was rebuilt on the boot disk", "A mount point that has gone away is an ordinary empty folder. The runner created every intermediate directory and copied the tree there, and called it a clean run.", "Fills the wrong disk", "The plan records which volume each folder was on; the run stops outright if either has moved"], ["12", "two", "A mounted disk read as an empty folder", "The walk stops at a mount point on purpose, and nothing downstream knew. Observed with a real image mounted: a 10 MB volume holding a file nobody else has compared **identical** to a folder with nothing in it, `unreadable: 0`, every gate passed. Removing the redundant side would have been offered.", "Loses a file", "Salted per side so it cannot match its opposite number, given a decision of its own so it is on screen, never turned into a step, and taking a whole side refuses outright"], ["13", "two", "The check answers about files; a decision is a folder", "A folder that collapsed as identical is one decision. The guard compared its path against the check's answers, which are file paths, so a file the check disagreed about never matched the folder that would take it to the Trash.", "Loses a file", "The taint climbs: a disagreement anywhere below a decision is a disagreement about the decision"], ["14", "two", "The content check opened iCloud placeholders", "Opening a placeholder is what fetches it. `DeepVerify` had always stepped around them with that comment attached; `FolderDiff.verify` enumerated with `FileManager` and did not — so checking a folder pair holding an iCloud library would have downloaded the library to answer a question about duplicates.", "Downloads a library", "Skipped and counted, and skipped is not settled: a placeholder is never removed as a proven duplicate"], ["15", "two", "The comparison screen said the contents were verified", "Whenever nothing had disagreed — including when the check could not open a file, left a placeholder in iCloud, or was stopped part-way. The same sentence as finding 7, one screen earlier.", "Wrong claim", "The badge asks whether the check settled everything, not whether anything disagreed"]]}
```

Two more were found and are **not** defects in the same sense — they made the
app worse at its job without risking anything:

- Ignore patterns did not reach the identical-collapse, because the signatures came from the duplicate finder, which knows nothing about them. A folder differing only by `.DS_Store` stayed *differs* — exactly backwards, since hiding that name is why the pattern exists. Space-freeing then offered the files inside one at a time instead of the folder as a unit.
- Nothing warned that a folder matching *only* because something was ignored still holds that ignored name, and takes it along when the folder is removed.

## What the second pass changed {#second-pass}

Four of the fifteen came out of going back over the same code with the first
round's fixes in place. Three of them share a cause worth naming: **the planner
was being handed a selection of what the content check found, rather than the
finding.**

```mermaid
flowchart LR
  subgraph before["what the planner was told"]
    direction TB
    b1["differing"] --> bp["plan()"]
    b2["unreadable"] -.->|"arrived one round late"| bp
    b3["cancelled"] -.->|"arrived one round late"| bp
    b4["not downloaded"] -.->|"did not exist yet"| bp
  end
  subgraph now["what it is told now"]
    direction TB
    n1["the whole VerifyDifferences"] --> np["plan()"]
    np --> nq["did it settle everything?"]
  end
  classDef miss fill:var(--series-4-soft),stroke:var(--series-4),color:var(--text)
  classDef ok fill:var(--series-3-soft),stroke:var(--series-3),color:var(--text)
  class b2,b3,b4 miss
  class n1,nq ok
```

Each category was added to the call as it was discovered, so each new one had to
be remembered at every call site — and twice it was not. The planner now takes
the result itself and asks one question of it: *did the check settle
everything?* A category added later cannot be forgotten, because there is
nothing to remember.

The other two are about the same sentence appearing in two places. "The contents
were read and agree" was fixed on the plan screen in the first pass and left
wrong on the comparison screen, where the badge went green whenever nothing had
disagreed. And the taint bug is the same shape one level down: a folder is what
gets removed, a file is what the check reports, and nothing connected them.

> [!NOTE]
> Finding 12 is the only one in either pass found by running the thing rather
> than by reading it or by writing a test first. A 10 MB image was mounted
> inside one of the two folders, and the comparison called it identical to an
> empty folder. Reading the code would have said the mount point is skipped; it
> would not have said that skipped folders collapse into each other.

## The gates a destructive step passes now {#gates}

Four of the eleven fixes added a gate. This is where they sit relative to the
ones that were already there.

```mermaid
flowchart TB
  cmp["comparison finished"] --> g1{"complete, not cancelled?"}
  g1 -->|no| stop1["refuse the direction"]
  g1 -->|yes| g2{"every folder readable?"}
  g2 -->|no| stop2["refuse"]
  g2 -->|yes| g3{"inside both folders, not a volume root, not on the never-touch list?"}
  g3 -->|no| stop3["refuse"]
  g3 -->|yes| g4{"content check settled every item?"}
  g4 -->|"differs / unreadable"| keep["keep that item, say so on the plan"]
  g4 -->|yes| plan["plan on screen"]
  plan --> btn(["the button"])
  btn --> g5{"both folders still there, still on the same disk?"}
  g5 -->|no| stop4["stop the whole run"]
  g5 -->|yes| g6{"is the target still what the plan described?"}
  g6 -->|no| stop5["fail that step"]
  g6 -->|yes| act["move to the Trash, never delete"]
  classDef new fill:var(--series-2-soft),stroke:var(--series-2),color:var(--text)
  classDef old fill:var(--surface),stroke:var(--border),color:var(--text)
  classDef halt fill:var(--series-4-soft),stroke:var(--series-4),color:var(--text)
  class g1,g4,g5,g6 new
  class cmp,g2,g3,plan,btn,act old
  class stop1,stop2,stop3,stop4,stop5,keep halt
```

The four shaded gates are new. The two after the button matter most: everything
before them describes the disk as it was when the comparison ran, and a plan a
person is reading is a plan the disk has had time to move away from.

## Three worth the detail {#detail}

### Why Turkish filenames were the likeliest to bite {#spelling}

macOS folds two things when it looks a name up: case, and the two ways a letter
with a mark can be written. It does **not** fold them when it stores the name —
whatever bytes it was handed are the bytes on disk.

That matters because the two sides of a comparison usually did not arrive the
same way. Foundation decomposes every path it is handed, so a folder this app
copied holds `s` + combining cedilla. A folder that arrived from a zip, an
rsync or another system holds the single `ş`. Same name to every person and
every `open(2)` on the volume; eleven bytes against ten to `memcmp`.

```oku-info-tip
{"summary":"The probe, and what it printed before the fix","content":["Written through POSIX, because neither `URL` nor `FileManager` can create a precomposed name — both run the path through the file-system representation, which decomposes it. That is the same reason the two spellings meet in the first place.",{"k":"code","src":"try writeRaw(left,  \"sef\\u{015F}e.txt\", bytes: 700, fill: 7)   // ş\ntry writeRaw(right, \"sefs\\u{0327}e.txt\", bytes: 700, fill: 7)   // s + ̧\n\nlet c = try compare()\nXCTAssertEqual(c.summary.onlyLeft, 0)","lang":"swift"},"The failure message named the same file twice, once on each side:",{"k":"code","src":"XCTAssertEqual failed: (\"1\") is not equal to (\"0\") -\none file spelled two ways is being counted as two files:\nonlyRight sefşe.txt, onlyLeft sefşe.txt","lang":"text"}]}
```

The fix folds the name for the merge and falls back to raw bytes in any folder
where folding would make two names equal — because a volume that folds names
could never have held both, so such a folder is on one that does not, and there
the two really are different files.

### The window in a replacement {#replace}

```mermaid
flowchart LR
  subgraph before["before"]
    direction TB
    b1["trash the old file"] --> b2["path is empty"] --> b3["copy the new one"]
    b2 -.->|"copy fails"| b4["path stays empty"]
  end
  subgraph now["now"]
    direction TB
    n1["write beside the target"] --> n2["trash the old file"] --> n3["rename into place"]
    n1 -.->|"copy fails"| n4["original untouched"]
  end
  classDef bad fill:var(--series-4-soft),stroke:var(--series-4),color:var(--text)
  classDef good fill:var(--series-3-soft),stroke:var(--series-3),color:var(--text)
  class b4 bad
  class n4 good
```

The old version was always recoverable from the Trash, so this was never
unrecoverable — but "your file is in the Trash and its replacement was never
written" is not a state the app should be able to reach on a full disk.

### What the re-check actually compares {#drift}

```oku-annotated-code
{"src":"private static func drift(_ step: SyncStep) -> String? {\n    var info = stat()\n    guard lstat(step.target, &info) == 0 else { return nil }          // (1)\n    let isFolder = (info.st_mode & S_IFMT) == S_IFDIR\n    if isFolder != step.targetIsFolder {                              // (2)\n        return isFolder\n            ? \"a folder is there now, not the file the plan described\"\n            : \"a file is there now, not the folder the plan described\"\n    }\n    if !isFolder, step.targetBytes >= 0, info.st_size != step.targetBytes {\n        return \"its size changed after the plan was made, so compare again\"\n    }\n    if Int32(truncatingIfNeeded: info.st_mtimespec.tv_sec) != step.targetModified {\n        return \"it changed after the plan was made, so compare again\"   // (3)\n    }\n    return nil\n}","lang":"swift","annotations":[{"id":1,"content":"A missing target is not drift. Nothing is there to lose, and the trash step treats it as a step with nothing to do.","lines":"3"},{"id":2,"content":"<code>lstat</code>, not <code>stat</code> — a symlink that replaced a file has to read as a kind change, not as whatever it points at.","lines":"4-9"},{"id":3,"content":"Strict on directories too. Opening a folder in Finder writes <code>.DS_Store</code> and moves its date, so a removal can fail with this message even though the pattern list ignores that name. That is a true statement about the folder, and the message says to compare again.","lines":"13-15"}]}
```

## What the folding cost, and what it gave back {#cost}

Merging on the folded name rather than on raw bytes is finding 1's fix, and it
is not free: it has to decide, per folder, whether two names that look different
are the same name. The first version built a comparison key for every child of
every folder, which cost a fifth of a comparison — 60,000 files a side, against
the commit before the review.

```oku-chart
{"type":"bar","rows":[{"label":"mixed names — before the review","value":0.39},{"label":"mixed names — keys everywhere","value":0.47},{"label":"mixed names — now","value":0.40},{"label":"ASCII only — before the review","value":0.37},{"label":"ASCII only — keys everywhere","value":0.46},{"label":"ASCII only — now","value":0.28}]}
```

*Seconds, lowest of five runs, warm cache. Lower is better.*

The cost was identical for Turkish names and for pure ASCII, which ruled out the
composed-form conversion and pointed at the allocation: two arrays per node, in
a tree built around 39 bytes per node. Folding now happens in three ways,
cheapest first — plain ASCII case folds through a comparator and allocates
nothing, only a folder holding a byte over `0x7f` builds keys, and a folder
where two names fold together drops to raw bytes.

That also turned up a redundant sort the first version had hidden: the child
list was sorted on raw bytes and then sorted again on the folded key. Removing
it is why the ASCII case is now faster than before any of this started.

```oku-info-tip
{"summary":"A step that was tried and made it worse","content":["Sorting `(node, key)` pairs directly instead of sorting an index permutation looked like it would remove two array allocations per folder. It cost 0.47s → 0.68s: every swap in the sort moves an array reference and pays ARC for it, which is more than the allocations saved.","Recorded because the reasoning was plausible and the measurement disagreed — the same shape of mistake as measuring the composed-form conversion that turned out not to be the cost."]}
```

## What is still true after the fixes {#remaining}

None of these are defects. They are the edges the current design has, stated so
that nobody has to rediscover them.

| Limitation | Why it is where it is |
|---|---|
| A folder removed as a duplicate takes its ignored names with it | A pattern hides a name from the *comparison*, not from the Trash. The plan now warns when a removal covers one, but does not prevent it — the alternative is refusing to collapse folders over a `.DS_Store`, which is the behaviour the pattern exists to avoid. |
| Directory identity is a 64-bit hash | Two different subtrees colliding is around one in 10^19 per pair. Files are compared exactly; only folders go through the hash, and only to decide whether to walk into them. |
| The re-check is size, kind and date — not content | A file rewritten inside the same second, to the same length, passes it. Catching that means re-hashing at run time, which is the content check again. |
| "Will this fit" overstates on the same volume | APFS clones a same-volume copy, so it writes almost nothing while the forecast counts the full size. Overstating is the safe direction; understating is how a disk fills. |
| The content check reads everything or nothing | There is no sampled mode. On a large pair it is a long read, and stopping it now correctly counts as not having run it. |
| A folder holding another mounted disk is shown but never acted on | Not compared, so not copied, replaced or removed either — and taking a whole side refuses outright, since that would take the folder the disk is mounted on. Comparing what is on that disk means pointing the two sides at it directly. |
| A file already in iCloud is never checked | Reading one is what downloads it, so it is counted rather than fetched. It is also never removed as a duplicate, which means a folder full of placeholders cannot be freed by this route at all. |
| The fallback for a volume that tells case apart has no test | Producing one needs a case-sensitive volume, and creating one hangs on this machine rather than failing. It guards against a volume the suite cannot make. |
| A cancelled sync leaves the steps it finished | Every step is individually complete, and everything removed is in the Trash, but there is no undo of a partial run beyond *Put Back*. |

## How this was verified {#verification}

Each defect was written as a failing test before it was fixed, in
[SyncSafetyTests.swift](#f/Tests/DiskMapCoreTests/SyncSafetyTests.swift) —
twenty cases whose subject is not behaviour anybody asked for but the shapes on
disk that make a metadata comparison lie.

Some skip rather than pass when the environment cannot produce the shape: the
permission case skips for a user who can read anything, the spelling case skips
on a volume that normalises names, and the mounted-disk case skips where a disk
image cannot be created. A skip is reported, not silent.

One test was written and then deleted rather than left skipping. It needed a
case-sensitive volume, and `hdiutil` does not fail when asked for one here — it
blocks forever, which took the whole suite with it. The reason that path cannot
be tested is now written beside the path.

The plan screen was rendered headlessly against a folder pair built to light up
several cautions at once, and read rather than assumed: the folder that differed
only by `.DS_Store` collapsed, and the differing symlink appeared as a Replace.

```oku-table
{"headers":["Check","Before","After"],"rows":[["Tests executed","264","284"],["Failures","0","0"],["Skipped","1","2"],["Files that may call a delete API","0","0"]]}
```

The last row is a source-grep test, not a claim: `removeItem`, `unlink`, `rmdir`
and `remove(atPath:)` are forbidden by name in the files that carry out sync,
comparison and cleanup. Everything leaves through `trashItem`, including the
half-written replacement the new staging path might have to get rid of.

## Questions this raises {#faq}

**Was anything lost?**
Nothing this review found was unrecoverable. Every path that removes something
goes through the Trash, and that was true before this round. The defects
determined *which* file went there, not whether it could come back.

**Which of the eleven was most likely to fire in practice?**
The name spelling one, by a distance. It needs no unusual setup — a folder with
Turkish names that arrived from two different places is enough, and both the
comparison screen and a mirror would have acted on it.

**Should the re-check be relaxed on folders?**
It can produce a false refusal: browsing a folder in Finder writes `.DS_Store`
and moves the folder's date, so a removal planned a minute earlier now fails.
The refusal is truthful — the folder did change — and the cost of the two
outcomes is not symmetric. A false refusal costs a second comparison; a false
pass moves a folder whose contents changed. It is left strict.

**What would the next round look at?**
The scanner itself, since the comparison inherits everything it gets wrong —
finding 12 is exactly that shape, and it was the scanner's deliberate behaviour
plus the comparison's ignorance of it. Firmlinks and files whose size changes
mid-read were not exercised in either pass.

**Was the second pass worth running?**
It found four, one of which — the mounted disk — is as severe as anything in the
first. Two of the four were in code the first pass had just written. That is the
argument for the pass, and also the caution about it: a fix is new code, and new
code has not been reviewed.
