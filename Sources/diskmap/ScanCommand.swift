import DiskMapReports
import DiskMapScan
import Foundation

let scanUsage = """
usage: diskmap scan <path> [path...] [options]
       diskmap <path> [path...] [options]

  Measures the paths as one total and writes a JSON document to stdout.
  A path may be a folder or a whole disk, and any number of either can be
  given; a path inside another is dropped rather than counted twice.

options:
  -o, --out <file>        write here instead of stdout
      --min-folder <n>    omit folders smaller than n bytes (default 10000000)
                          accepts 500MB, 2GB
      --top-files <n>     how many of the largest files to list (default 1000)
      --duplicates        include duplicate files and folders (slower)
      --suggestions       include cleanup suggestions (slower)
      --compact           one line, no indentation
      --quiet             no progress on stderr
"""

func runScan(_ arguments: [String]) -> Never {
    var args = Arguments(rest: arguments)
    var paths: [String] = []
    var out: String?
    var options = Export.Options()

    while let arg = args.next() {
        switch arg {
        case "-h", "--help": print(scanUsage); exit(0)
        case "-o", "--out": out = args.value(arg)
        case "--min-folder": options.folderMinimumBytes = args.size(arg)
        case "--top-files": options.largestFiles = args.number(arg)
        case "--duplicates": options.includeDuplicates = true
        case "--suggestions": options.includeSuggestions = true
        case "--compact": options.prettyPrinted = false
        case "--quiet": quiet = true
        default:
            if arg.hasPrefix("-") { fail("unknown option \(arg)", 1) }
            paths.append(arg)
        }
    }

    let result = scanned(paths)
    let volumes = Array(Set(result.roots.compactMap(volumeMountPoint)))
        .sorted().compactMap(VolumeInfo.forPath)
    var doc = Export.document(store: result.store, stats: result.stats,
                              volumes: volumes, options: options)

    if options.includeDuplicates || options.includeSuggestions {
        note("looking for copies ...")
        let signatures = FolderMatches.signatures(result.store)
        let folders = FolderMatches.find(store: result.store, root: 0, precomputed: signatures)
        let files = Duplicates.find(store: result.store, root: 0, insideMatched: folders)
        if options.includeDuplicates {
            Export.addCopies(to: &doc, store: result.store,
                             folderMatches: folders, fileGroups: files)
        }
        if options.includeSuggestions {
            note("looking for easy space ...")
            Export.addSuggestions(to: &doc, store: result.store, suggestions: Cleanup.suggest(
                store: result.store, root: 0,
                folderCopies: folders.map(\.nodes), fileCopies: files.map(\.nodes)))
        }
    }

    deliver(encoded(doc, prettyPrinted: options.prettyPrinted), to: out)
    exit(0)
}
