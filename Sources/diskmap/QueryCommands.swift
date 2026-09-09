import DiskMapReports
import DiskMapScan
import Foundation

let filesUsage = """
usage: diskmap files <path> [path...] [options]

  Lists files as a flat table, however deep they sit, filtered and sorted.
  The same question the app's All files tab answers, for a script: what is
  over a gigabyte, what has not been touched in two years, where are the
  disk images.

filters:
      --name <text>       the name contains this, ignoring case
      --kind <a,b>        only these kinds: video, image, audio, archive,
                          document, code, application, diskImage,
                          virtualMachine, model, database, cache, folder,
                          other
      --min <n>           at least this big on disk (accepts 500MB, 2GB)
      --max <n>           at most this big
      --newer-than <days> changed within this many days
      --older-than <days> not changed for this many days
      --folders           folders are rows too, sized by their whole subtree

options:
      --sort <key>        name, size, apparent, kind or modified (default size)
      --asc               reverse the order
      --limit <n>         how many rows to return (default 1000, 0 for all)
      --tsv               tab-separated with a header line, not JSON
  -o, --out <file>        write here instead of stdout
      --compact           one line, no indentation
      --quiet             no progress on stderr

  The row count is capped and the totals are not: `matched` says how many
  there were, `shown` how many came back, and the byte totals cover every
  match rather than the rows returned.
"""

func runFiles(_ arguments: [String]) -> Never {
    var args = Arguments(rest: arguments)
    var paths: [String] = []
    var out: String?
    var filter = FileFilter()
    var sort = FileSort.size
    var ascending = false
    var limit = 1_000
    var asTSV = false
    var pretty = true
    var newerThan: Double?
    var olderThan: Double?

    while let arg = args.next() {
        switch arg {
        case "-h", "--help": print(filesUsage); exit(0)
        case "-o", "--out": out = args.value(arg)
        case "--name": filter.text = args.value(arg)
        case "--kind":
            for token in args.value(arg).split(separator: ",") {
                guard let kind = FileCategory.named(String(token)) else {
                    fail("unknown kind \(token)", 1)
                }
                filter.categories.insert(kind)
            }
        case "--min": filter.minBytes = args.size(arg)
        case "--max": filter.maxBytes = args.size(arg)
        case "--newer-than": newerThan = args.days(arg)
        case "--older-than": olderThan = args.days(arg)
        case "--folders": filter.includeFolders = true
        case "--sort":
            let key = args.value(arg)
            guard let parsed = FileSort(rawValue: key) else {
                fail("unknown sort key \(key), expected one of "
                     + FileSort.allCases.map(\.rawValue).joined(separator: ", "), 1)
            }
            sort = parsed
        case "--asc": ascending = true
        case "--limit": limit = args.number(arg)
        case "--tsv": asTSV = true
        case "--compact": pretty = false
        case "--quiet": quiet = true
        default:
            if arg.hasPrefix("-") { fail("unknown option \(arg)", 1) }
            paths.append(arg)
        }
    }

    // Resolved against one clock reading, so two bounds given together cannot
    // describe a window that moved between them.
    let now = Date()
    let seconds = now.timeIntervalSince1970
    if let newerThan { filter.modifiedAfter = Int32(seconds - newerThan * 86_400) }
    if let olderThan { filter.modifiedBefore = Int32(seconds - olderThan * 86_400) }

    let result = scanned(paths)
    // Zero means everything, which is a legitimate thing to ask a pipeline for
    // even when it is millions of lines.
    let rows = limit == 0 ? result.store.count : limit
    let page = FileTable.page(store: result.store, filter: filter,
                              sort: sort, ascending: ascending, limit: rows)
    note("\(page.total) matched, returning \(page.rows.count)")

    if asTSV {
        deliver(tsv(["path", "kind", "physical", "logical", "modified", "marks"],
                    page.rows.map { row in
                        let r = Export.row(row)
                        return [r.path, r.kind, String(r.physical), String(r.logical),
                                isoDate.string(from: r.modified), r.marks.joined(separator: ",")]
                    }), to: out)
        exit(0)
    }
    let doc = Export.table(store: result.store, roots: result.roots, page: page,
                           sort: sort, ascending: ascending, now: now)
    deliver(encoded(doc, prettyPrinted: pretty), to: out)
    exit(0)
}

let findUsage = """
usage: diskmap find <needle> <path> [path...] [options]

  Searches names across the whole scan. The needle may name a path -
  `keep/notes` looks for notes under a folder called keep - and a needle
  that matches nothing outright is read as an abbreviation instead, so
  `rprt` finds `report.pdf`.

options:
      --limit <n>         how many to return (default 300, 0 for all)
      --tsv               tab-separated with a header line, not JSON
  -o, --out <file>        write here instead of stdout
      --compact           one line, no indentation
      --quiet             no progress on stderr

  Each hit says `how` it matched - exact, prefix, substring or subsequence -
  so a caller can tell a name it asked for from one that merely contains it.
"""

func runFind(_ arguments: [String]) -> Never {
    var args = Arguments(rest: arguments)
    var positional: [String] = []
    var out: String?
    var limit = 300
    var asTSV = false
    var pretty = true

    while let arg = args.next() {
        switch arg {
        case "-h", "--help": print(findUsage); exit(0)
        case "-o", "--out": out = args.value(arg)
        case "--limit": limit = args.number(arg)
        case "--tsv": asTSV = true
        case "--compact": pretty = false
        case "--quiet": quiet = true
        default:
            if arg.hasPrefix("-") { fail("unknown option \(arg)", 1) }
            positional.append(arg)
        }
    }

    guard let needle = positional.first else { fail("no needle given", 1) }
    let paths = Array(positional.dropFirst())
    guard !paths.isEmpty else { fail("no paths given", 1) }

    let result = scanned(paths)
    note("searching for \(needle) ...")
    let found = Find.search(store: result.store, needle: needle,
                            limit: limit == 0 ? result.store.count : limit)
    note("\(found.total) matched, returning \(found.items.count)")

    let doc = Export.search(roots: result.roots, needle: needle, results: found)
    if asTSV {
        deliver(tsv(["path", "how", "physical", "logical", "directory"],
                    doc.hits.map { [$0.path, $0.how, String($0.physical),
                                    String($0.logical), $0.directory ? "yes" : "no"] }),
                to: out)
        exit(0)
    }
    deliver(encoded(doc, prettyPrinted: pretty), to: out)
    exit(0)
}
