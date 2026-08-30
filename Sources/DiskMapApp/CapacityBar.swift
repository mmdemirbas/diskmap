import DiskMapCore
import SwiftUI

/// The honest capacity bar.
///
/// Finder reports `volumeAvailableCapacityForImportantUsage`, which counts
/// purgeable content as free. This shows the same disk split three ways, with
/// purgeable drawn as its own segment rather than folded into either side, so
/// the gap between "free" and "Finder says free" is visible instead of implied.
struct CapacityBar: View {
    let volume: VolumeInfo
    var onExplain: () -> Void

    /// Purgeable space is occupied disk that macOS believes it may reclaim, so
    /// it is a slice *of* used, not a fourth region. Splitting it out shows how
    /// much of the disk is genuinely committed.
    private var segments: [(color: Color, bytes: Int64, label: String)] {
        let purgeable = max(0, min(volume.purgeable, volume.used))
        return [
            (Palette.used, volume.used - purgeable, "In use"),
            (Palette.purgeable, purgeable, "Purgeable"),
            (Palette.free, max(0, volume.trueAvailable), "Free"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(volume.name).font(.system(size: 15, weight: .semibold))
                Text(volume.path).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text("\(shortBytes(volume.used)) of \(shortBytes(volume.total)) used")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle().fill(seg.color)
                            .frame(width: max(0, geo.size.width
                                              * CGFloat(seg.bytes) / CGFloat(max(volume.total, 1))))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 18)

            HStack(spacing: 16) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(seg.color).frame(width: 9, height: 9)
                        Text("\(seg.label) \(shortBytes(seg.bytes))").font(.system(size: 11))
                    }
                }
                Spacer()
            }
            .foregroundStyle(.secondary)

            if volume.purgeable > 1_000_000_000 {
                Button(action: onExplain) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Finder says \(shortBytes(volume.finderAvailable)) free. Only \(shortBytes(volume.trueAvailable)) really is.")
                            .fontWeight(.medium)
                        Text("Why?").underline()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warning)
                }
                .buttonStyle(.plain)
                .help("Finder counts purgeable space as available. Click for the breakdown.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Explains every byte the scan could not attribute to a file, rather than
/// quietly rounding the difference away.
struct ReconciliationSheet: View {
    let volume: VolumeInfo
    let reconciliation: Reconciliation?
    let stats: ScanStats?
    @Environment(\.dismiss) private var dismiss

    private func row(_ label: String, _ value: String, _ note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 210, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Where the space actually is")
                .font(.title2.weight(.semibold)).padding(.bottom, 4)
            Text("macOS reports several different numbers for the same disk. These are all of them.")
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 7) {
                row("Capacity", shortBytes(volume.total))
                row("Used", shortBytes(volume.used))
                row("Free, really", shortBytes(volume.trueAvailable), "you can write this much now")
                row("Free, as Finder shows", shortBytes(volume.finderAvailable), "includes purgeable")
                Divider().padding(.vertical, 4)
                row("Purgeable", shortBytes(volume.purgeable),
                    "evictable iCloud files, caches, snapshots")
            }
            .padding(.bottom, 18)

            if let r = reconciliation {
                Text("Scan vs. filesystem").font(.headline).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 7) {
                    row("Volume reports used", shortBytes(r.volumeUsed))
                    row("Scan attributed to files", shortBytes(r.scannedPhysical))
                    row("Unaccounted", shortBytes(r.unaccounted), percentString(r.unaccountedFraction))
                }
                .padding(.bottom, 10)
                ForEach(Array(r.explanations.enumerated()), id: \.offset) { _, e in
                    Label(e, systemImage: "info.circle").font(.callout)
                        .foregroundStyle(.secondary).padding(.bottom, 3)
                }
            }

            if let s = stats, s.datalessCount > 0 {
                Divider().padding(.vertical, 12)
                Label("\(s.datalessCount.formatted()) files are iCloud placeholders: \(shortBytes(s.datalessLogical)) of apparent size, 0 bytes on this disk. Deleting them frees nothing.",
                      systemImage: "icloud.and.arrow.down")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let s = stats, s.hardlinkDuplicates > 0 {
                Label("\(s.hardlinkDuplicates.formatted()) hard links point at files already counted: \(shortBytes(s.hardlinkDuplicateLogical)) that only exists once.",
                      systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }

            Spacer(minLength: 16)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 560)
    }
}
