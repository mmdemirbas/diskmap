import DiskMapCore
import Foundation

/// The integration point: measure some paths, print the result as JSON.
///
/// The app is for looking at a disk. This is for a program that wants the same
/// numbers — a dashboard, a nightly report, a CI check that fails when build
/// output passes some size. Everything it prints is documented in
/// docs/export-schema.md and carries a schema version, so a consumer can refuse
/// a document it does not understand rather than misread one.
let usage = """
usage: diskmap <path> [path...] [options]

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

exit codes:
  0 success   1 bad usage   2 nothing could be measured   3 write failed
"""

func bytes(_ text: String) -> Int64? {
    let upper = text.uppercased()
    let units: [(String, Int64)] = [("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)]
    for (suffix, scale) in units where upper.hasSuffix(suffix) {
        guard let n = Double(upper.dropLast(suffix.count)) else { return nil }
        return Int64(n * Double(scale))
    }
    return Int64(upper)
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data(("diskmap: " + message + "\n").utf8))
    exit(code)
}

var paths: [String] = []
var out: String?
var options = Export.Options()
var quiet = false

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}
while let arg = args.first {
    args.removeFirst()
    func value(_ name: String) -> String {
        guard let v = args.first else { fail("\(name) needs a value", 1) }
        args.removeFirst()
        return v
    }
    switch arg {
    case "-o", "--out": out = value(arg)
    case "--min-folder":
        guard let n = bytes(value(arg)) else { fail("--min-folder needs a size", 1) }
        options.folderMinimumBytes = n
    case "--top-files":
        guard let n = Int(value(arg)) else { fail("--top-files needs a number", 1) }
        options.largestFiles = max(0, n)
    case "--duplicates": options.includeDuplicates = true
    case "--suggestions": options.includeSuggestions = true
    case "--compact": options.prettyPrinted = false
    case "--quiet": quiet = true
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)", 1) }
        paths.append(arg)
    }
}
guard !paths.isEmpty else { fail("no paths given", 1) }

func note(_ text: String) {
    guard !quiet else { return }
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let normalized = RootSet.normalize(paths)
for rejected in normalized.rejected {
    note("skipped \(rejected.path): \(rejected.reason.explanation)")
}
guard !normalized.isEmpty else { fail("nothing to measure", 2) }

note("measuring \(normalized.roots.joined(separator: ", ")) ...")
let result = DiskScanner().scan(ScanOptions(roots: normalized.roots))
guard result.store.count > 1 else { fail("nothing could be read", 2) }

let volumes = Array(Set(result.roots.compactMap(volumeMountPoint)))
    .sorted().compactMap(VolumeInfo.forPath)
var doc = Export.document(store: result.store, stats: result.stats,
                          volumes: volumes, options: options)

if options.includeDuplicates {
    note("looking for copies ...")
    let signatures = FolderMatches.signatures(result.store)
    let folders = FolderMatches.find(store: result.store, root: 0, precomputed: signatures)
    let files = Duplicates.find(store: result.store, root: 0, insideMatched: folders)
    Export.addCopies(to: &doc, store: result.store, folderMatches: folders, fileGroups: files)
}
if options.includeSuggestions {
    note("looking for easy space ...")
    let signatures = FolderMatches.signatures(result.store)
    let folders = FolderMatches.find(store: result.store, root: 0, precomputed: signatures)
    let files = Duplicates.find(store: result.store, root: 0, insideMatched: folders)
    Export.addSuggestions(to: &doc, store: result.store, suggestions: Cleanup.suggest(
        store: result.store, root: 0,
        folderCopies: folders.map(\.nodes), fileCopies: files.map(\.nodes)))
}

let data: Data
do {
    data = try Export.encode(doc, prettyPrinted: options.prettyPrinted)
} catch {
    fail("could not encode the result: \(error)", 3)
}

if let out {
    do {
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        note("wrote \(out) (\(formatBytes(Int64(data.count))))")
    } catch {
        fail("could not write \(out): \(error.localizedDescription)", 3)
    }
} else {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
