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

/// One horizontal band of a bar whose width encodes bytes.
private struct Band: Identifiable {
    let id: Int
    var bytes: Int64
    var color: Color
    var label: String
    /// Ruled rather than solid, for a quantity that is occupied but counted as
    /// free by somebody. The rule takes the colour the same bytes have in the
    /// bar above, which is the only thing tying the two rows together.
    var hatch: Color?
}

/// A bar whose full width is always `scale`, so two bars stacked above each
/// other can be read against one another by length alone.
private struct ProportionBar: View {
    var bands: [Band]
    var scale: Int64
    var height: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(bands) { band in
                    ZStack {
                        Rectangle().fill(band.color)
                        if let hatch = band.hatch {
                            Hatching().stroke(hatch.opacity(0.55), lineWidth: 1)
                            Rectangle().strokeBorder(hatch.opacity(0.8),
                                                     style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                    }
                    .frame(width: max(0, geo.size.width * CGFloat(band.bytes) / CGFloat(max(scale, 1))))
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: height)
    }
}

/// Diagonal rule, for the band that two systems disagree about.
///
/// Sparse on purpose. Ruled densely it reads as a third kind of material
/// sitting between "in use" and "free", when what it means is "free, according
/// to one of them" — so the fill has to stay the free colour and the rule has
/// to stay a mark on top of it.
private struct Hatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 14
        }
        return path
    }
}

/// Explains every byte the scan could not attribute to a file, rather than
/// quietly rounding the difference away.
///
/// The disagreement between Finder and the disk is a relationship between two
/// lengths, so it is drawn as two bars on one scale rather than described in a
/// column of numbers: the free end of Finder's bar is longer than the disk's by
/// exactly the purgeable amount, and the picture makes that a single glance
/// instead of a subtraction. The exact figures are kept underneath, because a
/// bar answers "how much of it" and never "how many bytes".
struct ReconciliationSheet: View {
    let volume: VolumeInfo
    let reconciliation: Reconciliation?
    let stats: ScanStats?
    /// A ScrollView measures zero height offscreen, so an ImageRenderer
    /// capture of this sheet is a title over a blank page. Every scroller in
    /// the app goes through the shared fallback for that reason.
    var renderMode = false

    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    /// Purgeable is a slice of what is in use, never a fourth region of the
    /// disk, so both bars below sum to exactly the capacity.
    private var purgeable: Int64 { max(0, min(volume.purgeable, volume.used)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc[.whereSpaceIs]).font(.title2.weight(.semibold))
            Text(loc[.whereSpaceIsSubtitle])
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3).padding(.bottom, 18)

            viewportScroller(renderMode: renderMode) {
                VStack(alignment: .leading, spacing: 22) {
                    twoAnswers
                    if let r = reconciliation { scanCoverage(r) }
                    numbers
                    footnotes
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 2)
            }

            Divider().padding(.vertical, 12)
            HStack {
                Spacer()
                Button(loc[.done]) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680, height: 700)
        // Its own, like every other sheet here. Leaning on the presenter for a
        // background means dark-mode text on whatever happens to be behind it,
        // which is white, which is nothing at all.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - The disagreement, as two lengths

    private var twoAnswers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc[.sameDiskTwoAnswers]).font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                labelledBar(loc[.theDiskSays], [
                    Band(id: 0, bytes: volume.used - purgeable,
                         color: Palette.used(scheme), label: loc[.inUseNotPurgeable]),
                    Band(id: 1, bytes: purgeable,
                         color: Palette.purgeable(scheme), label: loc[.purgeable]),
                    Band(id: 2, bytes: max(0, volume.trueAvailable),
                         color: Palette.free(scheme), label: loc[.free]),
                ], trailing: shortBytes(volume.trueAvailable))

                labelledBar(loc[.finderSays], [
                    Band(id: 0, bytes: volume.used - purgeable,
                         color: Palette.used(scheme), label: loc[.inUseNotPurgeable]),
                    Band(id: 1, bytes: purgeable, color: Palette.free(scheme),
                         label: loc[.finderCountsAsFree], hatch: Palette.purgeable(scheme)),
                    Band(id: 2, bytes: max(0, volume.trueAvailable),
                         color: Palette.free(scheme), label: loc[.free]),
                ], trailing: shortBytes(volume.finderAvailable))
            }

            // Three unexplained colours are not a figure. The key sits under
            // the bars it describes, indented to the same column they start at.
            HStack(spacing: 14) {
                key(Palette.used(scheme), loc[.inUseNotPurgeable],
                    shortBytes(volume.used - purgeable))
                key(Palette.purgeable(scheme), loc[.purgeable], shortBytes(purgeable))
                key(Palette.free(scheme), loc[.free], shortBytes(volume.trueAvailable))
                Spacer(minLength: 0)
            }
            .padding(.leading, 94)

            // The caption carries the finding; the bars carry the evidence.
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.impossibleSum(shortBytes(volume.finderAvailable),
                                       shortBytes(volume.used),
                                       shortBytes(volume.finderAvailable + volume.used),
                                       shortBytes(volume.total)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.warning(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.purgeable(scheme)).frame(width: 10, height: 10)
                        .padding(.top, 3)
                    Text(loc[.theGapIsPurgeable])
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
    }

    /// One row: a fixed-width name, the bar, and the number the row is about,
    /// so the two rows line up on all three and can be scanned down a column.
    private func labelledBar(_ name: String, _ bands: [Band],
                             trailing: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            ProportionBar(bands: bands, scale: volume.total)
            Text(trailing).font(.system(size: 11, design: .monospaced))
                .frame(width: 74, alignment: .trailing)
        }
    }

    // MARK: - What the walk actually reached

    @ViewBuilder private func scanCoverage(_ r: Reconciliation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc[.whatTheScanReached]).font(.headline)

            if r.comparesToVolume {
                HStack(spacing: 10) {
                    Text(loc[.used]).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                    ProportionBar(bands: [
                        Band(id: 0, bytes: max(0, r.scannedPhysical),
                             color: Palette.used(scheme), label: loc[.measuredByScan]),
                        Band(id: 1, bytes: max(0, r.unaccounted),
                             color: Palette.warning(scheme), label: loc[.notAttributed]),
                    ], scale: max(r.volumeUsed, r.scannedPhysical), height: 22)
                    Text(shortBytes(r.volumeUsed))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 74, alignment: .trailing)
                }

                HStack(spacing: 16) {
                    key(Palette.used(scheme), loc[.measuredByScan], shortBytes(r.scannedPhysical))
                    if r.unaccounted > 0 {
                        key(Palette.warning(scheme), loc[.notAttributed],
                            "\(shortBytes(r.unaccounted)) · \(percentString(r.unaccountedFraction))")
                    }
                    Spacer()
                }
                .padding(.leading, 94)

                // Every reason sits directly under the band it explains.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(localizedExplanations(r).enumerated()), id: \.offset) { _, e in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                                .padding(.top, 2)
                            Text(e).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 94).padding(.top, 2)
            } else {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                        .foregroundStyle(.tertiary).padding(.top, 1)
                    Text(loc[.foldersOnlyNote]).font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func key(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    // MARK: - The figures themselves

    /// A bar answers "how much of it"; it never answers "how many bytes".
    private var numbers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc[.theNumbers]).font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                row(loc[.capacity], shortBytes(volume.total))
                row(loc[.used], shortBytes(volume.used))
                row(loc[.freeReally], shortBytes(volume.trueAvailable), loc[.writableNow])
                row(loc[.freeFinder], shortBytes(volume.finderAvailable), loc[.includesPurgeable])
                row(loc[.purgeable], shortBytes(volume.purgeable), loc[.purgeableNote])
            }
        }
    }

    private func row(_ label: String, _ value: String, _ note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 12))
                .frame(width: 196, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced))
                .frame(width: 96, alignment: .trailing)
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var footnotes: some View {
        if let s = stats, s.datalessCount > 0 || s.hardlinkDuplicates > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if s.datalessCount > 0 {
                    Label(loc.datalessNote(s.datalessCount, shortBytes(s.datalessLogical)),
                          systemImage: "icloud.and.arrow.down")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if s.hardlinkDuplicates > 0 {
                    Label(loc.hardlinkNote(s.hardlinkDuplicates, shortBytes(s.hardlinkDuplicateLogical)),
                          systemImage: "link")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The core builds these in English; translate at the presentation layer so
    /// the model stays free of UI language.
    private func localizedExplanations(_ r: Reconciliation) -> [String] {
        guard r.comparesToVolume else { return [loc[.foldersOnlyNote]] }
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
        return out
    }
}
