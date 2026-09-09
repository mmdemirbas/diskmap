import DiskMapCore
import SwiftUI

/// Every file in the scan, on one screen, with every property it has beside it.
///
/// The map answers "where did the space go" by drawing it, and the tree table
/// answers "what is inside this folder" by making you walk down to it. Neither
/// answers "show me all my disk images, biggest first" or "what have I not
/// opened since 2023" without a lot of clicking, and those are questions people
/// arrive with. This is the screen where the whole disk is one list and the
/// column headings are the question.
///
/// It fills the window rather than being held to a reading measure: seven
/// columns is what "all properties at the same time" costs, and squeezing them
/// into 1100 points would be the same as not showing them.
struct FilesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    private static let rowHeight: CGFloat = 22

    /// One column track per field, the same numbers in the header and in every
    /// row. Name and folder share what is left, so both are readable at any
    /// window width and neither ever moves against the other.
    private enum W {
        static let kind: CGFloat = 96
        /// Fixed rather than sharing the surplus with the folder. Both flexible
        /// meant an even split, which left half the name column empty while the
        /// path beside it was cut to a stump — and the path is the longer thing
        /// by far. Wide enough for a real filename; everything over it goes to
        /// the column that can always use more.
        static let name: CGFloat = 320
        static let size: CGFloat = 82
        static let date: CGFloat = 86
        static let marks: CGFloat = 46
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            columnHeader
            Divider()
            rows
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same as the map: dropping a folder onto a screen that shows a scan
        // means measure that too.
        .dropDestination(for: URL.self) { urls, _ in model.measureAlso(urls) }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if model.files.page.rows.isEmpty { model.reloadFiles() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(loc[.tabFiles]).font(.system(size: 15, weight: .semibold))
            Text(loc[.filesSubtitle])
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Narrowing it down

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField(loc[.filterByName], text: $model.filesText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onChange(of: model.filesText) { _, _ in model.resetFiles() }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            .frame(width: 190)

            kindMenu

            Picker("", selection: $model.filesSize) {
                ForEach(FilesModule.SizeBand.allCases) { band in
                    Text(loc[band.key]).tag(band)
                }
            }
            .labelsHidden().frame(width: 132)
            .onChange(of: model.filesSize) { _, _ in model.resetFiles() }
            .help(loc[.filterBySize])

            Picker("", selection: $model.filesTime) {
                ForEach(FilesModule.TimeBand.allCases) { band in
                    Text(loc[band.key]).tag(band)
                }
            }
            .labelsHidden().frame(width: 150)
            .onChange(of: model.filesTime) { _, _ in model.resetFiles() }
            .help(loc[.filterByDate])

            Picker("", selection: $model.filesQuestion) {
                ForEach(ContentQuestion.allCases) { question in
                    Text(loc[question.key]).tag(question)
                }
            }
            .labelsHidden().frame(width: 176)
            .help(loc[.filterByContent])

            Toggle(loc[.includeFolders], isOn: $model.filesShowFolders)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .onChange(of: model.filesShowFolders) { _, _ in model.resetFiles() }

            Spacer(minLength: 4)

            // Reserved rather than conditional: a button that appears once a
            // filter is on would shift the whole bar under the pointer at the
            // moment the pointer is in it.
            Button(loc[.clearFilters]) { model.clearFileFilters() }
                .controlSize(.small)
                .disabled(!model.files.isFiltered)
                .opacity(model.files.isFiltered ? 1 : 0)
                .accessibilityHidden(!model.files.isFiltered)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    /// Several kinds at once, because "video or image" is the question people
    /// have. A picker would make them ask it twice.
    private var kindMenu: some View {
        Menu {
            Button(loc[.everyKind]) { model.filesKinds = []; model.resetFiles() }
            Divider()
            ForEach(FileCategory.allCases, id: \.rawValue) { category in
                Toggle(category.localizedLabel, isOn: Binding(
                    get: { model.filesKinds.contains(category) },
                    set: { on in
                        if on { model.filesKinds.insert(category) }
                        else { model.filesKinds.remove(category) }
                        model.resetFiles()
                    }))
            }
        } label: {
            Text(model.filesKinds.isEmpty
                 ? loc[.everyKind]
                 : loc.kindsChosen(model.filesKinds.count))
                .font(.system(size: 11)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 118)
        .help(loc[.filterByKind])
    }

    // MARK: - The table

    private var columnHeader: some View {
        HStack(spacing: 8) {
            sortable(.kind, loc[.kind], width: W.kind, alignment: .leading)
            sortable(.name, loc[.name], width: W.name, alignment: .leading)
            Text(loc[.folder]).frame(maxWidth: .infinity, alignment: .leading)
            sortable(.size, loc[.onDisk], width: W.size, alignment: .trailing)
            sortable(.apparent, loc[.apparent], width: W.size, alignment: .trailing)
            sortable(.modified, loc[.modified], width: W.date, alignment: .trailing)
            Text(loc[.marks]).frame(width: W.marks, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    /// A heading that is also the control for it. The arrow holds its place on
    /// every column whether or not that column is the one sorted, so clicking
    /// one heading never moves the others out from under the pointer.
    private func sortable(_ key: FileSort, _ title: String,
                          width: CGFloat?, alignment: Alignment) -> some View {
        let active = model.files.sort == key
        return Button {
            model.sortFiles(by: key)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(model.files.ascending ? 0 : 180))
                    .opacity(active ? 1 : 0)
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .frame(width: width, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    @ViewBuilder private var rows: some View {
        if model.files.page.rows.isEmpty {
            VStack(spacing: 6) {
                Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
                // Said out loud rather than left as an empty list: no answers
                // available and nothing matching are opposite conclusions.
                if model.files.indexUnavailable {
                    Text(loc[.indexHasNothingHere])
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.renderMode {
            // A GeometryReader claims the space it is given rather than asking
            // for the height of its content, so rows cannot push the footer out
            // of frame where there is no scroll view.
            GeometryReader { geo in
                let fits = max(1, Int(geo.size.height / Self.rowHeight))
                VStack(spacing: 0) {
                    ForEach(model.files.page.rows.prefix(fits)) { row in rowView(row) }
                    Spacer(minLength: 0)
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.files.page.rows) { row in rowView(row) }
                }
            }
        }
    }

    private var emptyMessage: String {
        if model.files.askingIndex || model.files.waitingForTheIndex { return loc[.askingTheIndex] }
        if model.files.loading { return loc[.computing] }
        return model.files.isFiltered ? loc[.noMatches] : loc[.emptyFolder]
    }

    private func rowView(_ row: FileRow) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: row.isDirectory ? "folder.fill" : row.category.glyph)
                    .font(.system(size: 10))
                    .foregroundStyle(row.category.color(scheme))
                    .frame(width: 13)
                Text(row.category.localizedLabel)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(width: W.kind)

            // Truncated in the middle: a name that is cut keeps both the
            // part that says what it is and the part that says which one.
            Text(row.name).font(.system(size: 12))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: W.name, alignment: .leading)

            // Truncated from the head: the end of a path is what says which of
            // eleven files called `config.json` this one is.
            Text(row.folder).font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(shortBytes(row.physical))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(row.physical == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: W.size, alignment: .trailing)

            Text(shortBytes(row.logical))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: W.size, alignment: .trailing)

            Text(loc.shortDate(row.mtime))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: W.date, alignment: .trailing)

            marks(row).frame(width: W.marks, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
        .frame(height: Self.rowHeight)
        .background(model.selection == row.node ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.focus(node: row.node) }
        .onTapGesture { model.select(row.node) }
        // A table of every file that cannot be dragged into another window is
        // a table you have to leave to use. What the drop does is the other
        // application's business; nothing here moves or deletes anything.
        .draggable(model.url(of: row.node) ?? URL(fileURLWithPath: row.path))
        .contextMenu { menu(row) }
    }

    /// What the size alone does not say: a file that is only in iCloud, a
    /// second link to bytes already counted, one the disk is compressing, one
    /// nothing here can read.
    private func marks(_ row: FileRow) -> some View {
        HStack(spacing: 3) {
            if row.flags.contains(.dataless) {
                Image(systemName: "icloud").foregroundStyle(.tertiary).help(loc[.icloudZero])
            }
            if row.flags.contains(.hardlinkDuplicate) {
                Image(systemName: "link").foregroundStyle(.tertiary).help(loc[.hardlinkMark])
            }
            if row.flags.contains(.symlink) {
                Image(systemName: "arrow.turn.up.right").foregroundStyle(.tertiary)
                    .help(loc[.symlinkMark])
            }
            if row.flags.contains(.compressed) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(.tertiary).help(loc[.compressedMark])
            }
            if row.flags.contains(.unreadable) {
                Image(systemName: "lock.fill").foregroundStyle(Palette.warning(scheme))
                    .help(loc[.unreadableMark])
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9))
    }

    @ViewBuilder private func menu(_ row: FileRow) -> some View {
        Button(loc[.showInMap]) { model.focus(node: row.node) }
        Button(loc[.revealInFinder]) { model.reveal(row.node) }
        Button(loc[.copyPath]) { model.copyPath(row.node) }
        Divider()
        Button(loc[.moveToTrash]) { model.requestTrash(row.node) }
    }

    // MARK: - What it is a slice of

    private var footer: some View {
        HStack(spacing: 10) {
            // The rows on screen are never the whole answer, and the bytes are
            // counted over everything that matched rather than over what fits.
            Text(loc.filesShown(model.files.page.rows.count, model.files.page.total,
                                shortBytes(model.files.page.totalPhysical)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.files.loading {
                Text(loc[.computing]).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            // Reserved, not conditional: it disappears on the last page, and a
            // button that vanishes shifts everything beside it.
            Button(loc.showMoreRows(FilesModule.pageSize)) { model.showMoreFiles() }
                .controlSize(.small)
                .disabled(model.files.page.rows.count >= model.files.page.total)
                .opacity(model.files.page.rows.count >= model.files.page.total ? 0 : 1)
            Button(loc[.close]) { model.close(.files) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
