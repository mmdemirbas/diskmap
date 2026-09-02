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
        .frame(width: 980, height: 700)
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
            DiffColumnHeader(model: model)
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
            VStack(spacing: 4) {
                Button { model.swapCompareSides() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless).help(loc[.compareSwap])
                recents
            }
            .frame(width: 30).padding(.top, 16)
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

    /// The pairs compared before. A sync is a thing you do again next week, and
    /// typing both sides in again is the part nobody does.
    private var recents: some View {
        Menu {
            if model.comparePairs.isEmpty {
                Text(loc[.compareNoRecent])
            } else {
                ForEach(model.comparePairs, id: \.left) { pair in
                    Button("\((pair.left as NSString).lastPathComponent)  ⇄  \((pair.right as NSString).lastPathComponent)") {
                        model.openCompare(left: pair.left, right: pair.right)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 26)
        .help(loc[.compareRecent])
    }

    /// The picture, then the key, then the one sentence that matters most.
    /// Fixed height whatever state it is in.
    private var summaryBand: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiffBar(summary: model.folderComparison?.summary)
                .frame(height: 14)
            chips.frame(height: 18)
            HStack(spacing: 10) {
                headline
                // Only when a filter is narrowing the list. In the default
                // state the row count and the difference count agree closely
                // enough that saying both is noise.
                if narrowed {
                    Text(loc.rowsShown(model.compareRows.count + model.compareRowsOmitted))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).fixedSize()
                }
                // A filter nobody can see is a filter that lies, so what the
                // ignore patterns kept out is said next to the counts they are
                // missing from.
                if let ignored = model.folderComparison?.summary.ignored, ignored > 0 {
                    Text(loc.compareIgnoredCount(ignored))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).fixedSize()
                        .help(model.compareIgnore.joined(separator: "  "))
                }
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(height: 98)
    }

    /// The key is the filter.
    ///
    /// A separate row of filter controls would say the same words twice and
    /// cost a band of chrome; a swatch that already names a class and counts it
    /// is the natural place to ask for only that class. The two spanning chips
    /// are set apart from the five kinds, because they overlap them and a row
    /// of seven equals would imply they did not.
    private var chips: some View {
        viewportScroller(renderMode: model.renderMode, axis: .horizontal) {
            HStack(spacing: 6) {
                chip(.differences)
                chip(.all)
                Divider().frame(height: 12).padding(.horizontal, 3)
                chip(.identical)
                chip(.differs)
                chip(.onlyLeft)
                chip(.onlyRight)
                chip(.typeClash)
                Spacer(minLength: 0)
            }
            .frame(height: 18)
        }
    }

    private func chip(_ filter: CompareFilter) -> some View {
        let count = model.compareCount(filter)
        let chosen = model.compareFilter == filter
        return HStack(spacing: 5) {
            if let kind = filter.kind {
                RoundedRectangle(cornerRadius: 2).fill(kind.color(scheme))
                    .frame(width: 8, height: 8)
            }
            Text(loc[filter.key]).font(.system(size: 10, weight: chosen ? .semibold : .regular))
            Text(count.map { "\($0)" } ?? "–")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(chosen ? Color.accentColor.opacity(0.22) : Color.clear))
        .opacity(count == 0 && !chosen ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            model.compareFilter = filter
            model.rebuildCompareRows()
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

    private var narrowed: Bool {
        model.folderComparison != nil
            && (model.compareFilter != .differences || model.dateFilter != .any)
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
            HStack(spacing: 8) {
                // A menu rather than seven segments: they are not seven equals,
                // they are two questions — carry content across, or free space.
                Picker("", selection: $model.syncDirection) {
                    ForEach(SyncDirection.groups, id: \.0) { group in
                        Section(loc[group.0]) {
                            ForEach(group.1) { d in
                                Label(loc[d.key], systemImage: d.symbol).tag(d)
                            }
                        }
                    }
                }
                .labelsHidden().frame(width: 240)
                .disabled(model.folderComparison == nil)
                Picker("", selection: $model.dateFilter) {
                    ForEach(DateFilter.allCases) { d in Text(loc[d.key]).tag(d) }
                }
                .labelsHidden().frame(width: 148)
                .onChange(of: model.dateFilter) { _, _ in model.rebuildCompareRows() }
                .help(loc[.columnDate])
                comparisonSettings
                Spacer(minLength: 0)
                Button(loc[.selectAll]) { model.includeEveryDecision() }
                    .controlSize(.small).buttonStyle(.borderless)
                Button(loc[.selectNone]) { model.includeNoDecision() }
                    .controlSize(.small).buttonStyle(.borderless)
                Text(includedLabel).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).fixedSize()
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

    private var includedLabel: String {
        guard let total = model.folderComparison?.entries.count, total > 0 else { return " " }
        return loc.compareIncluded(model.compareIncludedCount, total)
    }

    /// What the comparison is told to leave out, and how exact to be about
    /// dates. Both change the answer, so both sit one click from the answer
    /// rather than in a preferences window.
    private var comparisonSettings: some View {
        Menu {
            Picker(loc[.columnDate], selection: $model.compareDateTolerance) {
                Text(loc[.dateExact]).tag(0)
                Text(loc[.dateNearest2]).tag(2)
                Text(loc[.dateNearestHour]).tag(3600)
            }
            .onChange(of: model.compareDateTolerance) { _, _ in model.runComparison() }
            Divider()
            Button(loc[.compareIgnoreButton]) { model.showCompareIgnore = true }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help(loc[.dateToleranceHelp])
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
                    // The line this whole direction stands or falls on: what is
                    // being removed is being removed because something else is
                    // believed to hold the same bytes.
                    if plan.direction.freesSpace {
                        if plan.contentWasChecked {
                            caution(.green, "checkmark.seal.fill", loc[.compareContentChecked])
                        } else {
                            // The warning carries the way out of it. Telling
                            // somebody to check the contents and leaving them
                            // to find the button is how a warning gets ignored.
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Palette.warning(scheme)).frame(width: 12)
                                Text(loc[.compareContentNotChecked])
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                                Button(loc[.compareCheckFirst]) {
                                    model.backToComparison()
                                    model.verifyComparison()
                                }
                                .controlSize(.small).buttonStyle(.borderless)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    // A pattern hides a name from the comparison; it does not
                    // hide it from the Trash. Nothing matched those names, so
                    // no other copy of them is being kept.
                    if plan.removesIgnoredItems > 0 {
                        caution(Palette.warning(scheme), "eye.slash",
                                loc.compareRemovesIgnored(plan.removesIgnoredItems))
                    }
                    if !plan.keptBecauseContentDiffers.isEmpty {
                        caution(.green, "shield.lefthalf.filled",
                                loc.compareKeptDiffering(plan.keptBecauseContentDiffers.count))
                    }
                    if !plan.keptBecauseUnreadable.isEmpty {
                        caution(Palette.warning(scheme), "lock.slash",
                                loc.compareKeptUnreadable(plan.keptBecauseUnreadable.count))
                    }
                    if plan.skipped > 0 {
                        caution(.secondary, "minus.square", loc.compareSkipped(plan.skipped))
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

    /// The one folder everything happens in, when there is one. A merge touches
    /// both, so it names neither.
    private func targetLabel(_ plan: SyncPlan) -> String {
        switch plan.direction.target {
        case .left: plan.left
        case .right: plan.right
        case nil: ""
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

/// In, out, or partly in.
///
/// Three states rather than two because a folder row stands for everything
/// under it: a checkbox that could only say yes or no would have to lie about
/// the folder where you unticked one file.
struct TickBox: View {
    let state: AppModel.RowInclusion
    var onTap: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(state == .none ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(Color.accentColor))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }

    private var symbol: String {
        switch state {
        case .all: "checkmark.square.fill"
        case .none: "square"
        case .some: "minus.square.fill"
        }
    }
}

/// One geometry, shared by the column header and every row, so the two cannot
/// drift apart. A header whose columns do not sit over the values under them is
/// worse than no header at all.
enum DiffColumns {
    static let tick: CGFloat = 20
    static let gutter: CGFloat = 28
    static let size: CGFloat = 76
    static let date: CGFloat = 74
    static let icon: CGFloat = 13
    static let pad: CGFloat = 9
}

/// What each column holds, written once above the two panes.
struct DiffColumnHeader: View {
    @ObservedObject private var loc = L10n.shared

    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            // The master tick, at the same x as every row's, so the column
            // reads as one thing rather than as a control and a list.
            TickBox(state: masterState) { toggleEverything() }
                .frame(width: DiffColumns.tick)
            pane()
            Spacer().frame(width: DiffColumns.gutter)
            pane()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 20)
    }

    private var masterState: AppModel.RowInclusion {
        guard let total = model.folderComparison?.entries.count, total > 0 else { return .all }
        let out = model.compareSkipped.count
        if out == 0 { return .all }
        return out == total ? .none : .some
    }

    private func toggleEverything() {
        if masterState == .all { model.includeNoDecision() } else { model.includeEveryDecision() }
    }

    /// No Left/Right label here. It would have to sit over the icon column,
    /// where it is both too narrow to fit the word and in the wrong place; the
    /// two path pickers a few points above already say which side is which, and
    /// they do not scroll away.
    private func pane() -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: DiffColumns.icon)
            Text(loc[.name])
            Spacer(minLength: 6)
            Text(loc[.size]).frame(width: DiffColumns.size, alignment: .trailing)
            Text(loc[.columnDate]).frame(width: DiffColumns.date, alignment: .trailing)
        }
        .padding(.horizontal, DiffColumns.pad)
        .frame(maxWidth: .infinity)
    }
}

/// The two folders, one down each side, as a tree you can open.
///
/// Extracted from the sheet so a test can draw it on its own: a list that
/// renders nothing offscreen is a bug this codebase has shipped seven times,
/// and it is invisible in a capture of the whole sheet because the header above
/// it still draws.
///
/// Rows are pairs, so the two sides open together — there is no state in which
/// the left is showing a folder's contents and the right is not. Both panes
/// carry the triangle anyway: whichever side you are reading, the way in is
/// under your pointer rather than across the row.
struct DiffRowList: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    static let rowHeight: CGFloat = 30
    private static let indent: CGFloat = 13

    @ViewBuilder var body: some View {
        if model.compareRows.isEmpty || model.folderComparison == nil {
            Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let tree = model.folderComparison?.tree {
            viewportScroller(renderMode: model.renderMode) {
                LazyVStack(spacing: 0) {
                    ForEach(model.compareRows.prefix(visibleRows), id: \.self) { id in
                        row(tree, id)
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

    /// Three different empty screens, and saying which one this is saves the
    /// reader from concluding the folders match when they only picked a filter
    /// nothing falls into.
    private var emptyMessage: String {
        guard let comparison = model.folderComparison else { return loc[.comparePickBoth] }
        if comparison.summary.inSync { return loc[.compareInSync] }
        return loc[.nothingMatchesFilter]
    }

    /// Offscreen there is no viewport to clip against, so the whole list would
    /// be drawn to be thrown away.
    var visibleRows: Int { model.renderMode ? 11 : model.compareRows.count }

    func row(_ tree: DiffTree, _ id: Int32) -> some View {
        HStack(spacing: 0) {
            TickBox(state: model.compareInclusion(tree, id)) {
                model.toggleCompareInclusion(tree, id)
            }
            .frame(width: DiffColumns.tick)
            pane(tree, id, .left)
            Text(tree.kind(id).relation)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tree.kind(id).color(scheme))
                .frame(width: DiffColumns.gutter)
            pane(tree, id, .right)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggle(tree, id) }
        .contextMenu { menu(tree, id) }
    }

    /// One side of one row. Absent is drawn as a filled gap rather than left
    /// blank: a row with nothing on the right and a row that has scrolled past
    /// the end look the same otherwise.
    func pane(_ tree: DiffTree, _ id: Int32, _ side: Side) -> some View {
        let present = tree.isPresent(id, on: side)
        let newest = tree.newerSide(id) == side
        let items = tree.items(id, on: side)
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.045))
                .opacity(present ? 0 : 1)
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(tree.depth(id)) * Self.indent)
                disclosure(tree, id, side)
                Image(systemName: tree.isDirectory(id, on: side) ? "folder.fill" : "doc")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: DiffColumns.icon)
                Text(tree.name(id)).font(.system(size: 11.5))
                    .lineLimit(1).truncationMode(.middle)
                if tree.isDirectory(id, on: side), items > 0 {
                    Text("· \(loc.itemCount(items))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(shortBytes(tree.bytes(id, on: side)))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: DiffColumns.size, alignment: .trailing)
                // The newer of the two dates is the one carrying the answer to
                // "which of these did I work on last", so it is the one that is
                // legible; the other stays quiet.
                Text(loc.shortDate(tree.modified(id, on: side)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(newest ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: DiffColumns.date, alignment: .trailing)
            }
            .padding(.horizontal, DiffColumns.pad)
            .opacity(present ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Reserved whether or not there is anything to open, so the names below a
    /// folder line up with the names beside it.
    ///
    /// Shown per side rather than per row: where a folder faces a file, only
    /// the folder has anything to open, and a triangle beside the file would be
    /// claiming otherwise.
    @ViewBuilder private func disclosure(_ tree: DiffTree, _ id: Int32,
                                         _ side: Side) -> some View {
        let node = tree.node(id, on: side)
        let can = tree.isExpandable(id) && node >= 0
            && tree.store(side).isDirectory(node)
            && tree.store(side).childCount[Int(node)] > 0
        Image(systemName: model.isCompareExpanded(id) ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 11)
            .opacity(can ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture { if can { toggle(tree, id) } }
    }

    private func toggle(_ tree: DiffTree, _ id: Int32) {
        guard tree.isExpandable(id) else { return }
        model.toggleCompareExpanded(id)
    }

    @ViewBuilder func menu(_ tree: DiffTree, _ id: Int32) -> some View {
        if tree.isExpandable(id) {
            Button(model.isCompareExpanded(id) ? loc[.collapseFolder] : loc[.expandFolder]) {
                toggle(tree, id)
            }
            Divider()
        }
        if tree.isPresent(id, on: .left) {
            Button("\(loc[.revealInFinder]) — \(loc[.compareLeftSide])") { reveal(tree, id, .left) }
        }
        if tree.isPresent(id, on: .right) {
            Button("\(loc[.revealInFinder]) — \(loc[.compareRightSide])") { reveal(tree, id, .right) }
        }
    }

    func reveal(_ tree: DiffTree, _ id: Int32, _ side: Side) {
        guard let comparison = model.folderComparison else { return }
        let path = comparison.path(tree.relativePath(id), on: side)
        FileActions.revealInFinder([URL(fileURLWithPath: path)])
    }
}
