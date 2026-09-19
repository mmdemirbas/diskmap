import DiskMapCore
import SwiftUI

/// Folders and files below the current folder that hold the same thing,
/// ordered by what deleting the extras would free.
///
/// Both lists are built from metadata alone — no file is read — which is what
/// keeps them as fast as the rest of the app and safe on iCloud placeholders.
/// The header says what the match is based on, because the honest answer is
/// "these look like copies", not "these are copies". Expanding a match offers
/// the deep check that settles it.
struct DuplicatesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            if model.summarizing {
                MatchProgressView(progress: model.reportProgress,
                                  phases: [.measuring, .signing, .folders, .files])
            } else if model.folderMatches.isEmpty && model.duplicates.isEmpty {
                Text(loc[.duplicatesEmpty]).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                list
                if !model.checked.isEmpty {
                    Divider()
                    actionBar
                }
            }
        }
        .acceptsFolders(renderMode: model.renderMode) { model.measureAlso($0) }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                Text(loc[.duplicatesNote]).font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            // The leading number is what deleting the extras would free, not
            // the size of a file. Saying so once beats repeating it per row.
            HStack(spacing: 6) {
                Spacer().frame(width: 10)
                Text(loc[.reclaimable]).frame(width: 66, alignment: .trailing)
                Text(loc[.name])
                Spacer(minLength: 4)
                Text(loc[.panelDuplicates]).frame(width: 56, alignment: .trailing)
                Text(loc[.size]).frame(width: 62, alignment: .trailing)
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 5)
    }

    private var total: Int64 {
        model.folderMatches.reduce(0) { $0 + $1.reclaimable }
            + model.duplicates.reduce(0) { $0 + $1.reclaimable }
    }

    private var summaryRow: some View {
        HStack {
            Spacer()
            Text("\(shortBytes(total)) \(loc[.reclaimable])")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold))
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var list: some View {
        if model.renderMode {
            // Offscreen there is no viewport, so rows would ask for the height
            // of the whole list and push the window open.
            GeometryReader { geo in
                let fits = max(2, Int(geo.size.height / Self.rowHeight) - 3)
                let folders = min(model.folderMatches.count, fits)
                VStack(spacing: 0) {
                    if folders > 0 {
                        sectionHeader(loc[.sectionFolders], model.folderMatches.count)
                        ForEach(model.folderMatches.prefix(folders)) { entry in
                            folderRow(entry)
                            if model.openMatches.contains(entry.id) {
                                details(entry.id, entry.copies, entry.readBytes, folders: true)
                            }
                        }
                    }
                    if folders < fits, !model.duplicates.isEmpty {
                        sectionHeader(loc[.sectionFiles], model.duplicates.count)
                        ForEach(model.duplicates.prefix(fits - folders)) { fileRow($0) }
                    }
                    Spacer(minLength: 0)
                    summaryRow
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !model.folderMatches.isEmpty {
                        Section {
                            ForEach(model.folderMatches) { entry in
                                folderRow(entry)
                                if model.openMatches.contains(entry.id) {
                                    details(entry.id, entry.copies, entry.readBytes, folders: true)
                                }
                            }
                        } header: {
                            sectionHeader(loc[.sectionFolders], model.folderMatches.count)
                        }
                    }
                    if !model.duplicates.isEmpty {
                        Section {
                            ForEach(model.duplicates) { entry in
                                fileRow(entry)
                                if model.openMatches.contains(entry.id) {
                                    details(entry.id, entry.copies, entry.readBytes, folders: false)
                                }
                            }
                        } header: {
                            sectionHeader(loc[.sectionFiles], model.duplicates.count)
                        }
                    }
                    summaryRow
                }
            }
        }
    }

    // MARK: - Rows

    /// One layout for both sections, so the columns line up across them.
    private func row(id: Int64, reclaimable: Int64, name: String, note: String?,
                     copies: Int, each: Int64) -> some View {
        HStack(spacing: 6) {
            Image(systemName: model.openMatches.contains(id) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 10)
            Text(shortBytes(reclaimable))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 66, alignment: .trailing)
            Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            if let note {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(loc.copyCount(copies)).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(shortBytes(each))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.openMatches.contains(id) { model.openMatches.remove(id) }
            else { model.openMatches.insert(id) }
        }
    }

    private func folderRow(_ entry: FolderEntry) -> some View {
        row(id: entry.id, reclaimable: entry.reclaimable, name: entry.name,
            note: entry.exact ? loc[.matchExact]
                              : loc.sharedItems(entry.sharedItems, entry.comparedItems),
            copies: entry.copies.count, each: entry.bytes)
    }

    private func fileRow(_ entry: DuplicateEntry) -> some View {
        row(id: entry.id, reclaimable: entry.reclaimable, name: entry.name, note: nil,
            copies: entry.copies.count, each: entry.bytes)
    }

    // MARK: - Expanded match

    @ViewBuilder private func details(_ id: Int64, _ copies: [PathRef],
                                      _ readBytes: Int64, folders: Bool) -> some View {
        ForEach(copies) { copy in pathRow(copy) }
        verifyRow(id, copies, readBytes, folders)
    }

    /// What is ticked, what it comes to, and the way out. It only appears when
    /// something is ticked, so the panel is not carrying a delete button while
    /// you are only reading.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Text(loc.selectedForRemoval(model.checked.count, shortBytes(model.checkedBytes)))
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 4)
            Button(loc[.clearSelection]) { model.clearChecked() }
                .controlSize(.small).buttonStyle(.borderless)
            Button(loc[.moveSelectedToTrash]) { model.requestBulkTrash() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// One copy. The first is not marked as the one to keep on purpose — this
    /// match is a candidate, so which copy is the real one is your call.
    private func pathRow(_ copy: PathRef) -> some View {
        let ticked = model.checked.contains(copy.id)
        // The last surviving copy cannot be ticked at all. Refusing at the tick
        // says why while the selection is still small enough to understand.
        let neverTouch = !ticked && model.isNeverTouch(copy.id)
        let blocked = neverTouch || (!ticked && model.wouldBeTheLastCopy(copy.id))
        return HStack(spacing: 8) {
            Image(systemName: ticked ? "checkmark.square.fill" : "square")
                .font(.system(size: 11))
                .foregroundStyle(blocked ? AnyShapeStyle(.quaternary)
                                         : AnyShapeStyle(ticked ? Color.accentColor : Color.secondary))
                .frame(width: 13)
                .onTapGesture { if !blocked { model.toggleChecked(copy.id) } }
                .help(neverTouch ? loc[.refuseExcluded] : (blocked ? loc[.keepsOneCopy] : ""))
            Text(copy.path)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
        }
        .padding(.leading, 21).padding(.trailing, 12).padding(.vertical, 3)
        .background(model.selection == copy.id ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(copy.id) }
        .onTapGesture(count: 2) { model.reveal(copy.id) }
        .draggable(model.url(of: copy.id) ?? URL(fileURLWithPath: copy.path))
        .contextMenu {
            Button(loc[.revealInFinder]) { model.reveal(copy.id) }
            Button(loc[.copyPath]) { model.copyPath(copy.id) }
            Divider()
            Button(loc[.moveToTrash]) { model.requestTrash(copy.id) }
        }
    }

    /// The deep check. It reads every byte, so the button says the price and
    /// the run can be stopped.
    @ViewBuilder private func verifyRow(_ id: Int64, _ copies: [PathRef],
                                        _ readBytes: Int64, _ folders: Bool) -> some View {
        let status = model.verifications[id]
        HStack(spacing: 8) {
            if let status, status.running {
                ProgressView(value: Double(status.read),
                             total: Double(max(status.total, 1)))
                    .controlSize(.small).frame(width: 90)
                Text(loc.readSoFar(shortBytes(status.read), shortBytes(status.total)))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button(loc[.cancel]) { model.cancelVerify(id: id) }
                    .controlSize(.small).buttonStyle(.borderless)
            } else if let outcome = status?.outcome {
                verdict(outcome)
                Button(loc[.verifyAgain]) { model.verifyMatch(id: id, nodes: copies.map(\.id)) }
                    .controlSize(.small).buttonStyle(.borderless)
            } else {
                Button(loc[.verify]) { model.verifyMatch(id: id, nodes: copies.map(\.id)) }
                    .controlSize(.small)
                Text(loc.readsBytes(shortBytes(readBytes)))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Button(loc[.selectExtras]) { model.checkExtras(copies) }
                    .controlSize(.small).buttonStyle(.borderless)
                // Two folders that look alike is where the question "what is
                // actually different about them" starts, so the way to ask it
                // belongs here rather than three menus away.
                if folders, copies.count == 2 {
                    Button(loc[.compareRun]) {
                        model.openCompare(left: copies[0].path, right: copies[1].path)
                    }
                    .controlSize(.small).buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 34).padding(.trailing, 12).padding(.top, 2).padding(.bottom, 7)
    }

    @ViewBuilder private func verdict(_ outcome: VerifyOutcome) -> some View {
        if outcome.cancelled {
            label("pause.circle", .secondary, loc[.verifyStopped])
        } else if outcome.identical {
            label("checkmark.seal.fill", .green, loc[.verifyIdentical])
        } else if outcome.distinct > 1 {
            label("xmark.circle.fill", .orange, loc.verifyDiffer(outcome.distinct))
        } else {
            // Digests agree, but something was left unread, so "identical" is
            // more than the check actually established.
            label("questionmark.circle", .orange,
                  loc.verifyPartial(outcome.unread + outcome.skipped))
        }
    }

    private func label(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint)
            Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

}
