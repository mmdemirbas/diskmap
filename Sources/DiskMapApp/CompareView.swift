import DiskMapCore
import SwiftUI

/// Two folders, side by side, and a way to make one match the other.
///
/// Three pages behind one fixed frame — what they hold, what would happen, what
/// did happen — rather than a stack of sheets: every page is the same size, so
/// moving between them moves nothing on screen.
///
/// The order is deliberate and never skipped. You look at the difference, then
/// you read the plan, then something is written. Nothing on the first two pages
/// touches the disk.
struct CompareView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    private static let stepRowHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.comparePage {
            case .diff: diffPage
            case .plan: planPage
            case .result: resultPage
            }
        }
        .frame(width: 900, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(loc[.compareTitle]).font(.system(size: 15, weight: .semibold))
            // Said once, at the top, because everything below is only as true
            // as this rule is.
            Text(loc[.compareSubtitle]).font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 10)
    }

    // MARK: - Page one: what the two folders hold

    private var diffPage: some View {
        VStack(spacing: 0) {
            pickers
            Divider()
            summaryBand
            Divider()
            DiffRowList(model: model)
            Divider()
            diffFooter
        }
    }

    private var pickers: some View {
        HStack(alignment: .top, spacing: 10) {
            picker(.left, model.compareLeft,
                   bytes: model.folderComparison?.leftTotal,
                   items: model.folderComparison?.leftItems)
            Button { model.swapCompareSides() } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless).help(loc[.compareSwap])
            .frame(width: 26).padding(.top, 20)
            picker(.right, model.compareRight,
                   bytes: model.folderComparison?.rightTotal,
                   items: model.folderComparison?.rightItems)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(height: 84)
    }

    private func picker(_ side: Side, _ path: String,
                        bytes: Int64?, items: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(side == .left ? loc[.compareLeftSide] : loc[.compareRightSide])
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(loc[.compareChoose]) { model.chooseCompareSide(side) }
                    .controlSize(.small)
            }
            Text(path.isEmpty ? loc[.comparePickBoth] : path)
                .font(.system(size: 11))
                .foregroundStyle(path.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1).truncationMode(.head)
            // Reserved: the figures appear once the walk finishes, and a row
            // that appears would push the list under it down.
            Text(bytes.map { loc.compareSideSummary(shortBytes($0), items ?? 0) } ?? " ")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The picture, then the counts, then the one sentence that matters most.
    /// Fixed height whatever state it is in.
    private var summaryBand: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiffBar(summary: model.folderComparison?.summary)
                .frame(height: 14)
            HStack(spacing: 14) {
                ForEach(DiffKind.allCases, id: \.rawValue) { kind in
                    swatch(kind)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 14)
            headline.frame(height: 22)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(height: 94)
    }

    private func swatch(_ kind: DiffKind) -> some View {
        let count = counts(kind)
        return HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(kind.color(scheme))
                .frame(width: 9, height: 9)
            Text(kind.localizedLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(count.map { "\($0)" } ?? "–")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .fixedSize()
        .opacity(count == 0 ? 0.4 : 1)
    }

    private func counts(_ kind: DiffKind) -> Int? {
        guard let s = model.folderComparison?.summary else { return nil }
        switch kind {
        case .identical: return s.identical
        case .differs: return s.differing
        case .onlyLeft: return s.onlyLeft
        case .onlyRight: return s.onlyRight
        case .typeClash: return s.typeClashes
        }
    }

    /// One line, and the most useful one available. A copy that has become
    /// redundant is the answer the user came for, so it outranks everything
    /// else — and it only ever appears when the other folder really does hold
    /// everything this one does.
    @ViewBuilder private var headline: some View {
        if model.comparing {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(loc[.compareWorking]).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if let refusal = model.compareRefusal, model.syncPlan == nil {
            mark("exclamationmark.triangle.fill", Palette.warning(scheme), localizedRefusal(refusal))
        } else if let comparison = model.folderComparison {
            if comparison.unreadable > 0 {
                mark("lock.fill", Palette.warning(scheme), loc[.compareUnreadableWarning])
            } else if comparison.summary.inSync {
                // Identical folders make either one removable; the offer names
                // the right, which is the one just picked.
                redundancyOffer(.right, loc[.compareInSync], "checkmark.seal.fill", .green)
            } else if let side = redundantSide {
                redundancyOffer(side, loc.compareHoldsNothingExtra(side),
                                "arrow.down.left.circle.fill", DiffKind.identical.color(scheme))
            } else {
                mark("arrow.left.arrow.right", .secondary,
                     loc.differencesFound(comparison.summary.differences))
            }
        } else {
            Text(loc[.comparePickBoth]).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    /// The side that holds nothing the other does not, preferring the right
    /// when both are true — two identical folders make either removable, and
    /// offering the one you picked second is the smaller surprise.
    private var redundantSide: Side? {
        guard model.folderComparison != nil else { return nil }
        if model.isRedundant(.right) { return .right }
        if model.isRedundant(.left) { return .left }
        return nil
    }

    private func redundancyOffer(_ side: Side, _ finding: String,
                                 _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
            Text(finding).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            Button(loc.compareTrashThisCopy(side)) { model.previewRemoveRedundant(side) }
            .controlSize(.small)
            .help(loc[.compareRedundantHint])
        }
    }

    private func mark(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Choosing what to do

    private var diffFooter: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Picker("", selection: $model.syncDirection) {
                    ForEach(SyncDirection.allCases) { d in
                        Label(loc[d.key], systemImage: d.symbol).tag(d)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                .disabled(model.folderComparison == nil)
                Toggle(loc[.compareShowMatching], isOn: $model.showMatchingToo)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .onChange(of: model.showMatchingToo) { _, _ in model.rebuildCompareRows() }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text(loc[model.syncDirection.whyKey])
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                verifyControl
                Button(loc[.comparePreview]) { model.previewSync() }
                    .controlSize(.small)
                    .disabled(model.folderComparison == nil || model.comparing)
                Button(loc[.close]) { model.closeCompare() }
                    .controlSize(.small).keyboardShortcut(.cancelAction)
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(height: 84)
    }

    /// The escalation from "nothing says they differ" to "the bytes agree".
    @ViewBuilder private var verifyControl: some View {
        if model.compareVerifying {
            ProgressView().controlSize(.small)
            Text(shortBytes(model.compareVerifyBytes))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Button(loc[.cancel]) { model.cancelCompareVerify() }
                .controlSize(.small).buttonStyle(.borderless)
        } else if let result = model.compareVerification {
            // The verdict, with what was read to reach it one hover away: a
            // check that says "they agree" without saying how much it looked at
            // is a claim rather than a result.
            Group {
                if result.differing.isEmpty {
                    mark("checkmark.seal.fill", .green, loc[.compareVerified])
                } else {
                    mark("xmark.circle.fill", Palette.warning(scheme),
                         loc.compareContentDiffers(result.differing.count))
                }
            }
            .fixedSize()
            .help(loc.compareVerifyRead(result.pairsChecked, shortBytes(result.bytesRead)))
        } else {
            Button(loc[.compareVerifyContents]) { model.verifyComparison() }
                .controlSize(.small)
                .disabled(model.folderComparison == nil)
        }
    }

    // MARK: - Page two: what would happen

    @ViewBuilder private var planPage: some View {
        if let plan = model.syncPlan {
            VStack(spacing: 0) {
                planHeader(plan)
                Divider()
                stepList(plan)
                Divider()
                planFooter(plan)
            }
        } else {
            Text(loc[.compareNothingWritten]).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func planHeader(_ plan: SyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(loc[.compareWhatWillHappen]).font(.system(size: 13, weight: .semibold))
                tally(.copy, plan.copies)
                tally(.replace, plan.replacements)
                tally(.remove, plan.removals)
                Spacer(minLength: 0)
                Text(loc.syncWillWrite(shortBytes(plan.bytesToWrite), shortBytes(plan.bytesToTrash)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(height: 18)
            // Fixed height, scrolled rather than grown: the number of warnings
            // depends on the plan and the list under them must not move.
            viewportScroller(renderMode: model.renderMode) {
                VStack(alignment: .leading, spacing: 4) {
                    // First, because it answers "where is this happening" and
                    // every line under it is about that folder.
                    if plan.direction != .merge {
                        caution(.secondary, "folder",
                                "\(loc[.compareTargetFolder]) \(targetLabel(plan))")
                    }
                    if !plan.fits {
                        caution(Palette.warning(scheme), "externaldrive.badge.exclamationmark",
                                loc[.compareNotEnoughRoom])
                    }
                    ForEach(Array(plan.providers).sorted(), id: \.self) { provider in
                        caution(Palette.warning(scheme), "icloud.and.arrow.up",
                                "\(provider): \(loc[.alsoDeletedFromService])")
                    }
                    if plan.datalessCopies > 0 {
                        caution(.secondary, "icloud.and.arrow.down", loc[.compareDownloadsFromCloud])
                    }
                    if !plan.unresolved.isEmpty {
                        caution(.secondary, "questionmark.circle",
                                "\(loc.compareUnresolvedCount(plan.unresolved.count)) — \(loc[.compareUnresolved])")
                    }
                    caution(.secondary, "arrow.uturn.backward", loc[.trashIsRecoverable])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 54)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(height: 106)
    }

    private func tally(_ action: SyncAction, _ n: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: action.symbol).font(.system(size: 10))
                .foregroundStyle(action.color(scheme))
            Text("\(action.localizedLabel) \(n)").font(.system(size: 11))
        }
        .opacity(n == 0 ? 0.35 : 1)
    }

    private func caution(_ tint: Color, _ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(tint)
                .frame(width: 12)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private func stepList(_ plan: SyncPlan) -> some View {
        viewportScroller(renderMode: model.renderMode) {
            LazyVStack(spacing: 0) {
                ForEach(plan.steps.prefix(model.renderMode ? 9 : plan.steps.count)) { step in
                    stepRow(step)
                    Divider()
                }
            }
        }
    }

    private func stepRow(_ step: SyncStep) -> some View {
        HStack(spacing: 8) {
            Image(systemName: step.action.symbol).font(.system(size: 10))
                .foregroundStyle(step.action.color(scheme)).frame(width: 14)
            Text(step.action.localizedLabel).font(.system(size: 11, weight: .medium))
                .frame(width: 72, alignment: .leading)
            Text(shortBytes(step.bytes))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 78, alignment: .trailing)
            Text(step.relativePath.isEmpty ? (step.target as NSString).lastPathComponent
                                           : step.relativePath)
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(step.syncProvider ?? "").font(.system(size: 9)).foregroundStyle(.tertiary)
                .lineLimit(1).frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.stepRowHeight)
    }

    private func planFooter(_ plan: SyncPlan) -> some View {
        HStack(spacing: 10) {
            Button(loc[.goBack]) { model.backToComparison() }
                .controlSize(.small)
            Text(loc.stepCount(plan.steps.count))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(loc[.compareApply]) { model.runSync() }
                .controlSize(.small).keyboardShortcut(.defaultAction)
            Button(loc[.close]) { model.closeCompare() }
                .controlSize(.small).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(height: 52)
    }

    private func targetLabel(_ plan: SyncPlan) -> String {
        switch plan.direction {
        case .mirrorLeftToRight: plan.right
        case .mirrorRightToLeft: plan.left
        case .merge: ""
        }
    }

    // MARK: - Page three: what did happen

    private var resultPage: some View {
        VStack(spacing: 0) {
            resultHeader
            Divider()
            failureList
            Divider()
            resultFooter
        }
    }

    @ViewBuilder private var resultHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.syncRunning, let progress = model.syncProgress {
                HStack(spacing: 10) {
                    ProgressView(value: Double(progress.stepsDone),
                                 total: Double(max(progress.stepsTotal, 1)))
                        .frame(width: 220)
                    Text(loc.syncFinished(progress.stepsDone, progress.stepsTotal))
                        .font(.system(size: 11, design: .monospaced))
                    Spacer(minLength: 0)
                    Button(loc[.cancel]) { model.cancelSync() }.controlSize(.small)
                }
                .frame(height: 20)
                Text(progress.currentPath).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let outcome = model.syncOutcome {
                HStack(spacing: 9) {
                    Image(systemName: outcome.succeeded ? "checkmark.seal.fill"
                                                        : "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(outcome.succeeded ? Color.green : Palette.warning(scheme))
                    Text(outcome.cancelled ? loc[.syncStopped] : loc[.done])
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(loc.syncWrote(shortBytes(outcome.bytesWritten),
                                       shortBytes(outcome.bytesTrashed)))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .frame(height: 20)
                Text(outcome.failures.isEmpty
                     ? loc[.trashIsRecoverable]
                     : loc.syncFailedSteps(outcome.failures.count))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(loc[.compareWorking]).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(height: 76)
    }

    @ViewBuilder private var failureList: some View {
        if let outcome = model.syncOutcome, !outcome.failures.isEmpty {
            viewportScroller(renderMode: model.renderMode) {
                LazyVStack(spacing: 0) {
                    ForEach(outcome.failures.prefix(model.renderMode ? 9 : outcome.failures.count)) { failure in
                        HStack(spacing: 8) {
                            Image(systemName: failure.action.symbol).font(.system(size: 10))
                                .foregroundStyle(Palette.warning(scheme)).frame(width: 14)
                            Text(failure.relativePath).font(.system(size: 11))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(failure.message).font(.system(size: 10))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 16).frame(height: Self.stepRowHeight)
                        Divider()
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(loc[.trashIsRecoverable]).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resultFooter: some View {
        HStack(spacing: 10) {
            Button(loc[.syncShowInTrash]) { model.revealTrashedBySync() }
                .controlSize(.small)
                .disabled(model.syncOutcome?.trashed.isEmpty ?? true)
            Button(loc[.compareAgain]) { model.backToComparison(); model.runComparison() }
                .controlSize(.small)
                .disabled(model.syncRunning)
            Spacer(minLength: 8)
            Button(loc[.close]) { model.closeCompare() }
                .controlSize(.small).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(height: 52)
    }
}

/// The four ways two folders disagree, drawn to scale.
///
/// One bar rather than four numbers because the question underneath is "how
/// much of this is the same", and a proportion answers it before any of the
/// figures are read. Each class that exists at all keeps a visible sliver: a
/// single differing file among four hundred gigabytes is exactly the case
/// somebody opened this screen to find.
struct DiffBar: View {
    let summary: DiffSummary?
    @Environment(\.colorScheme) private var scheme

    private static let minimumSliver: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let widths = widths(in: geo.size.width)
            HStack(spacing: 1) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.kind.color(scheme)).frame(width: part.width)
                }
                if widths.isEmpty {
                    Rectangle().fill(Palette.free(scheme))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func widths(in total: CGFloat) -> [(kind: DiffKind, width: CGFloat)] {
        guard let summary, total > 0 else { return [] }
        let parts: [(DiffKind, Int64)] = [
            (.identical, summary.identicalBytes), (.differs, summary.differingBytes),
            (.onlyLeft, summary.onlyLeftBytes), (.onlyRight, summary.onlyRightBytes),
        ].filter { $0.1 > 0 }
        let sum = parts.reduce(Int64(0)) { $0 + $1.1 }
        guard sum > 0 else { return [] }

        // Every class present gets its sliver first; the rest is shared out in
        // proportion, so the bar still adds up to the width it was given.
        let reserved = Self.minimumSliver * CGFloat(parts.count)
        let free = max(0, total - reserved - CGFloat(parts.count - 1))
        return parts.map { kind, bytes in
            (kind, Self.minimumSliver + free * CGFloat(Double(bytes) / Double(sum)))
        }
    }
}

/// The rows themselves, extracted so a test can draw them on their own.
///
/// A list that renders nothing offscreen is a bug this codebase has shipped
/// seven times, and it is invisible in a capture of the whole sheet because the
/// header above it still draws. Rendering the list alone is the only way to ask
/// the question directly.
struct DiffRowList: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    static let rowHeight: CGFloat = 34

    @ViewBuilder var body: some View {
        if model.compareRows.isEmpty {
            Text(model.folderComparison == nil ? loc[.comparePickBoth] : loc[.compareInSync])
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            viewportScroller(renderMode: model.renderMode) {
                LazyVStack(spacing: 0) {
                    ForEach(model.compareRows.prefix(visibleRows)) { entry in
                        row(entry)
                        Divider()
                    }
                    if model.compareRowsOmitted > 0 {
                        Text(loc.moreRows(model.compareRowsOmitted))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }
        }
    }

    /// Offscreen there is no viewport to clip against, so the whole list would
    /// be drawn to be thrown away.
    var visibleRows: Int { model.renderMode ? 9 : model.compareRows.count }

    func row(_ entry: DiffEntry) -> some View {
        HStack(spacing: 8) {
            Circle().fill(entry.kind.color(scheme)).frame(width: 7, height: 7)
            // Each side carries its own type mark. A folder on one side facing
            // a file on the other is the one row where a single icon would be
            // wrong about half of what it is describing.
            sideCell(entry, .left)
            Text(entry.kind.relation)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(entry.kind.color(scheme))
                .frame(width: 22)
            sideCell(entry, .right)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(parentPath(entry)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text(trailingNote(entry)).font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).frame(width: 108, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            if entry.leftBytes > 0 || entry.kind == .onlyLeft {
                Button("\(loc[.revealInFinder]) — \(loc[.compareLeftSide])") { reveal(entry, .left) }
            }
            if entry.rightBytes > 0 || entry.kind == .onlyRight {
                Button("\(loc[.revealInFinder]) — \(loc[.compareRightSide])") { reveal(entry, .right) }
            }
        }
    }

    func reveal(_ entry: DiffEntry, _ side: Side) {
        guard let comparison = model.folderComparison else { return }
        FileActions.revealInFinder([URL(fileURLWithPath: comparison.path(entry.relativePath, on: side))])
    }

    /// The type mark and the size, in one fixed-width cell so the numbers line
    /// up down the column whatever the row holds. Both mirror-image: the left
    /// reads outward-in, the right inward-out.
    func sideCell(_ entry: DiffEntry, _ side: Side) -> some View {
        let present = entry.isPresent(on: side)
        let bytes = entry.bytes(on: side)
        return HStack(spacing: 5) {
            if side == .right { size(bytes, present) }
            Image(systemName: entry.isDirectory(on: side) ? "folder.fill" : "doc")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .frame(width: 11)
                .opacity(present ? 1 : 0)
            if side == .left { size(bytes, present) }
        }
        .frame(width: 92, alignment: side == .left ? .trailing : .leading)
    }

    func size(_ bytes: Int64, _ present: Bool) -> some View {
        Text(present ? shortBytes(bytes) : "—")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(present ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
    }

    /// A space rather than nothing for a top-level item: an empty Text has no
    /// height, so its row's name would sit lower than every other row's.
    func parentPath(_ entry: DiffEntry) -> String {
        let parent = (entry.relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? " " : parent
    }

    /// The one extra fact worth the width: how big a one-sided folder is in
    /// items, and for two files that disagree, which one was written last.
    func trailingNote(_ entry: DiffEntry) -> String {
        if entry.isDirectory, entry.kind != .identical { return loc.itemCount(entry.items) }
        guard let newer = entry.newerSide else { return "" }
        return (newer == .left ? "◀ " : "▶ ")
            + (newer == .left ? loc[.compareLeftSide] : loc[.compareRightSide])
    }
}
