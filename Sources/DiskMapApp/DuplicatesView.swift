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
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(loc[.computing]).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.folderMatches.isEmpty && model.duplicates.isEmpty {
                Text(loc[.duplicatesEmpty]).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                list
            }
        }
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
                            if model.openMatches.contains(entry.id) { details(entry.id, entry.copies) }
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
                                if model.openMatches.contains(entry.id) { details(entry.id, entry.copies) }
                            }
                        } header: {
                            sectionHeader(loc[.sectionFolders], model.folderMatches.count)
                        }
                    }
                    if !model.duplicates.isEmpty {
                        Section {
                            ForEach(model.duplicates) { entry in
                                fileRow(entry)
                                if model.openMatches.contains(entry.id) { details(entry.id, entry.copies) }
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

    @ViewBuilder private func details(_ id: Int64, _ copies: [PathRef]) -> some View {
        ForEach(copies) { copy in pathRow(copy) }
        verifyRow(id, copies)
    }

    /// One copy. The first is not marked as the one to keep on purpose — this
    /// match is a candidate, so which copy is the real one is your call.
    private func pathRow(_ copy: PathRef) -> some View {
        HStack(spacing: 8) {
            Text(copy.path)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
        }
        .padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 3)
        .background(model.selection == copy.id ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.select(copy.id) }
        .onTapGesture(count: 2) { model.reveal(copy.id) }
        .contextMenu {
            Button(loc[.revealInFinder]) { model.reveal(copy.id) }
            Button(loc[.copyPath]) { model.copyPath(copy.id) }
            Divider()
            Button(loc[.moveToTrash]) { model.requestTrash(copy.id) }
        }
    }

    /// The deep check. It reads every byte, so the button says the price and
    /// the run can be stopped.
    @ViewBuilder private func verifyRow(_ id: Int64, _ copies: [PathRef]) -> some View {
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
                Text(loc.readsBytes(shortBytes(readCost(id, copies))))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
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

    private func readCost(_ id: Int64, _ copies: [PathRef]) -> Int64 {
        if let entry = model.folderMatches.first(where: { $0.id == id }) { return entry.readBytes }
        if let entry = model.duplicates.first(where: { $0.id == id }) {
            return entry.bytes * Int64(entry.copies.count)
        }
        return 0
    }
}
