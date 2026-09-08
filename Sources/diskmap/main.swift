import DiskMapCore
import Foundation

/// The integration point: everything the app can answer, without the app.
///
/// The window is for looking at a disk. This is for a program that wants the
/// same numbers — a dashboard, a nightly report, a CI check that fails when
/// build output passes some size — and for the times a person would rather
/// pipe than click. Each command writes JSON by default, documented in
/// docs/export-schema.md and carrying a schema version, so a consumer can
/// refuse a document it does not understand rather than misread one.
///
/// Nothing here deletes, moves or trashes anything, and that is deliberate
/// rather than unfinished: every destructive path in the app goes through a
/// report that is checked again immediately before it acts. A flag on a
/// command line cannot be checked against what the user meant, so the commands
/// stop at telling you what is there.
let usage = """
usage: diskmap <command> [options]
       diskmap <path> [path...] [options]      the same as: diskmap scan

commands:
  scan   <path>...           measure the paths and write the whole report
  files  <path>...           list files as a flat table, filtered and sorted
  find   <needle> <path>...  search names across the scan
  help                       this

  Each command takes --help of its own. Every command scans first: there is
  no stored index, so the cost of a question is the cost of the scan plus
  the question.

exit codes:
  0 success   1 bad usage   2 nothing could be measured   3 write failed
"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty { print(usage); exit(1) }

switch arguments[0] {
case "help", "-h", "--help": print(usage); exit(0)
case "scan": runScan(Array(arguments.dropFirst()))
case "files": runFiles(Array(arguments.dropFirst()))
case "find": runFind(Array(arguments.dropFirst()))
default:
    // A path where a command was expected is the old form of this tool, and it
    // still means what it always meant. A folder that happens to be named
    // after a command is the one ambiguity: spell it `./files` and it is a
    // path again.
    runScan(arguments)
}
