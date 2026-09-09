// The core, as one import.
//
// The scan, the metadata layer, the actions, the comparison and the reports are
// five targets rather than one so that the direction between them is a compile
// error rather than a code-review habit: the scan may depend on nothing, and
// everything may depend on the scan.
//
// This target holds no code. It exists so that a screen — which legitimately
// uses all five — writes one import instead of five, and so that the split can
// be re-cut later without touching thirty files. Anything that should *not*
// reach all five imports the targets it needs directly, which is the whole
// point: `diskmap`, the command line, links the scan and the reports and
// cannot call the Trash even by accident.
@_exported import DiskMapScan
@_exported import DiskMapMeta
@_exported import DiskMapActions
@_exported import DiskMapCompare
@_exported import DiskMapReports
