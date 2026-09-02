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
> holds these bytes too*. Eleven separate defects let that sentence be true on
> screen and false on disk.
>
> - Seven of them would have moved a file the user had only one copy of. All go to the Trash, so all were recoverable — but none announced themselves.
> - The most likely one to fire in daily use is Turkish filenames: the same name spelled two ways read as two files, and a mirror trashed one of them.
> - All eleven are fixed, each with a test that fails without the fix. The suite went from 264 to 281.

This is a **findings report**, not a guide. The opening two sections build the
one idea the rest depends on; from "The eleven" onward it is a catalog, meant
to be scanned and returned to rather than read through.

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

## The eleven {#findings}

Sorted by what it would have cost. "Loses a file" means an item that existed on
one side only was moved to the Trash — recoverable with *Put Back*, but
unannounced.

```oku-table
{"headers":["#","Defect","What it would have done","Cost","Stopped by"],"rows":[["1","Names were paired by comparing raw bytes","A name spelled two ways — precomposed `ş` on one side, `s` plus a combining cedilla on the other — read as two files, one missing from each side. A mirror trashed the one on the target side.","Loses a file","Folding the name the way the volume folds it, with a fallback to raw bytes in any folder where folding would make two names equal"],["2","A symlink was compared by the length of the path it holds","Two links pointing at completely different places matched, and `removeLeftDuplicates` trashed one. The content check could not contradict it: it reads regular files, so it never opens a link.","Loses a file","Links match on where they point"],["3","A symlink facing a regular file matched on length","A 12-byte link and a 12-byte file were called identical.","Loses a file","A link facing a file is a kind clash"],["4","The runner never re-checked its target","Between a plan appearing on screen and the button being pressed, anything can change on disk. A 400-byte file replaced by a different 90 KB file was trashed anyway, and the run reported zero failures.","Loses a file","Each step records the kind, length and date it saw, and refuses if that is no longer what is there"],["5","Removing a whole side never saw the content check's disagreements","The planner had no parameter for them and the screen had no way to send them. So a side the check had just proved was *not* a duplicate could still be trashed whole.","Loses a file","The parameter exists, the screen sends it, and one disagreement refuses the whole direction"],["6","A file the check could not open counted as agreeing","`unreadable` was collected and then dropped on the floor. A permission-denied file was removed as a proven duplicate.","Loses a file","Unreadable items are kept and counted on the plan"],["7","A cancelled content check counted as a finished one","Stopping the check after two files out of ten thousand still marked the comparison verified, and the plan said the contents were read and agree.","Loses a file","A cancelled check is not a check; removing a whole side refuses on it"],["8","A cancelled comparison could be planned from","Cancelling the walk returns a result rather than an error, and the sheet fills in. The folders it never reached are absent, and a mirror reads absent as *remove from the other side*.","Loses a file","Every direction that removes something refuses on it; copies still go ahead"],["9","A replacement trashed the old file before writing the new one","A copy that failed left the path empty — the original in the Trash, nothing standing where it was.","Empty path","The replacement is written beside the target first and moved into place after"],["10","A copy's size was the space it occupies, not the size of the file","Two names for one file occupy the space once. The plan promised 120 KB and wrote 240 KB, and *will this fit* was answering about the wrong number.","Wrong number","Removals are still counted in space freed; copies are counted in file size"],["11","An ejected disk was rebuilt on the boot disk","A mount point that has gone away is an ordinary empty folder. The runner created every intermediate directory and copied the tree there, and called it a clean run.","Fills the wrong disk","The plan records which volume each folder was on; the run stops outright if either has moved"]]}
```

Two more were found and are **not** defects in the same sense — they made the
app worse at its job without risking anything:

- Ignore patterns did not reach the identical-collapse, because the signatures came from the duplicate finder, which knows nothing about them. A folder differing only by `.DS_Store` stayed *differs* — exactly backwards, since hiding that name is why the pattern exists. Space-freeing then offered the files inside one at a time instead of the folder as a unit.
- Nothing warned that a folder matching *only* because something was ignored still holds that ignored name, and takes it along when the folder is removed.

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
| A cancelled sync leaves the steps it finished | Every step is individually complete, and everything removed is in the Trash, but there is no undo of a partial run beyond *Put Back*. |

## How this was verified {#verification}

Each defect was written as a failing test before it was fixed, in
[SyncSafetyTests.swift](#f/Tests/DiskMapCoreTests/SyncSafetyTests.swift) —
sixteen cases whose subject is not behaviour anybody asked for but the shapes on
disk that make a metadata comparison lie.

Two of them skip rather than pass when the environment cannot produce the shape:
the permission case skips for a user who can read anything, and the spelling case
skips on a volume that normalises names. A skip is reported, not silent.

The plan screen was rendered headlessly against a folder pair built to light up
several cautions at once, and read rather than assumed: the folder that differed
only by `.DS_Store` collapsed, and the differing symlink appeared as a Replace.

```oku-table
{"headers":["Check","Before","After"],"rows":[["Tests executed","264","281"],["Failures","0","0"],["Skipped","1","1"],["Files that may call a delete API","0","0"]]}
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
The scanner's own edge cases, since the comparison now inherits everything it
gets wrong: firmlinks, mount points crossed mid-walk, and files whose size
changes while they are being read. None of those were exercised here.
