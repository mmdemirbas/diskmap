import DiskMapCore
import SwiftUI

/// The honest capacity bar.
///
/// Finder reports `volumeAvailableCapacityForImportantUsage`, which counts
/// purgeable content as free. Purgeable is drawn as its own band rather than
/// folded into either side, so the gap between "free" and "Finder says free"
/// is visible instead of implied.
struct CapacityBar: View {
    let volume: VolumeInfo
    var onExplain: () -> Void

    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    /// Purgeable is a slice *of* used, not a fourth region of the disk.
    private var segments: [(color: Color, bytes: Int64, label: String)] {
        let purgeable = max(0, min(volume.purgeable, volume.used))
        return [
            (Palette.used(scheme), volume.used - purgeable, loc[.inUse]),
            (Palette.purgeable(scheme), purgeable, loc[.purgeable]),
            (Palette.free(scheme), max(0, volume.trueAvailable), loc[.free]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(volume.name).font(.system(size: 15, weight: .semibold))
                Text(volume.path).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text(loc.usedOfTotal(shortBytes(volume.used), shortBytes(volume.total)))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle().fill(seg.color)
                            .frame(width: width(seg.bytes, in: geo.size.width))
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
                        Text(loc.finderClaim(shortBytes(volume.finderAvailable),
                                             shortBytes(volume.trueAvailable)))
                            .fontWeight(.medium)
                        Text(loc[.why]).underline()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.warning(scheme))
                }
                .buttonStyle(.plain)
                .help(loc[.capacityHelp])
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func width(_ bytes: Int64, in total: CGFloat) -> CGFloat {
        let fraction = CGFloat(bytes) / CGFloat(max(volume.total, 1))
        return max(0, total * fraction)
    }
}

/// Explains every byte the scan could not attribute to a file, rather than
/// quietly rounding the difference away.
struct ReconciliationSheet: View {
    let volume: VolumeInfo
    let reconciliation: Reconciliation?
    let stats: ScanStats?

    @ObservedObject private var loc = L10n.shared
    @Environment(\.dismiss) private var dismiss

    private func row(_ label: String, _ value: String, _ note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 230, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc[.whereSpaceIs]).font(.title2.weight(.semibold)).padding(.bottom, 4)
            Text(loc[.whereSpaceIsSubtitle])
                .font(.callout).foregroundStyle(.secondary).padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 7) {
                row(loc[.capacity], shortBytes(volume.total))
                row(loc[.used], shortBytes(volume.used))
                row(loc[.freeReally], shortBytes(volume.trueAvailable), loc[.writableNow])
                row(loc[.freeFinder], shortBytes(volume.finderAvailable), loc[.includesPurgeable])
                Divider().padding(.vertical, 4)
                row(loc[.purgeable], shortBytes(volume.purgeable), loc[.purgeableNote])
            }
            .padding(.bottom, 18)

            if let r = reconciliation {
                Text(loc[.scanVsFilesystem]).font(.headline).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 7) {
                    row(loc[.volumeReportsUsed], shortBytes(r.volumeUsed))
                    row(loc[.scanAttributed], shortBytes(r.scannedPhysical))
                    row(loc[.unaccounted], shortBytes(r.unaccounted),
                        percentString(r.unaccountedFraction))
                }
                .padding(.bottom, 10)
                ForEach(Array(localizedExplanations(r).enumerated()), id: \.offset) { _, e in
                    Label(e, systemImage: "info.circle").font(.callout)
                        .foregroundStyle(.secondary).padding(.bottom, 3)
                }
            }

            if let s = stats, s.datalessCount > 0 {
                Divider().padding(.vertical, 12)
                Label(loc.datalessNote(s.datalessCount, shortBytes(s.datalessLogical)),
                      systemImage: "icloud.and.arrow.down")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let s = stats, s.hardlinkDuplicates > 0 {
                Label(loc.hardlinkNote(s.hardlinkDuplicates, shortBytes(s.hardlinkDuplicateLogical)),
                      systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }

            Spacer(minLength: 16)
            HStack {
                Spacer()
                Button(loc[.done]) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 660, height: 580)
    }

    /// The core builds these in English; translate at the presentation layer so
    /// the model stays free of UI language.
    private func localizedExplanations(_ r: Reconciliation) -> [String] {
        guard loc.active == .tr else { return r.explanations }
        var out: [String] = []
        if r.snapshotCount > 0 {
            out.append("\(r.snapshotCount) APFS anlık görüntüsü, silinmiş dosyaların bloklarını tutuyor.")
        }
        if r.unreadableDirectories > 0 {
            out.append("\(r.unreadableDirectories) klasör okunamadı. Görmek için Tam Disk Erişimi verin.")
        }
        if r.unaccounted > 0 {
            out.append("APFS klonları blokları paylaşır; klonlanmış baytlar disk tarafından bir kez sayılır ama birden çok adla görünebilir.")
        }
        if !r.scanRootIsWholeVolume {
            out.append("Tarama diskin tamamını değil, bir alt klasörü kapsadı.")
        }
        return out
    }
}
