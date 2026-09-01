import DiskMapCore
import SwiftUI

/// Where is that folder?
///
/// The filter box narrows the level being browsed. This searches the whole
/// tree, and its results are not a report: picking one opens the folder it
/// lives in and puts the selection on it, because being handed a path and left
/// to navigate there by hand is the same work twice.
struct FindView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 700, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(loc[.findPlaceholder], text: $model.findText)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($focused)
                .onSubmit { model.runFind() }
                .onChange(of: model.findText) { _, _ in model.runFind() }
            if !model.findText.isEmpty {
                Button { model.findText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .task { focused = true }
    }

    @ViewBuilder private var results: some View {
        if model.findResults.isEmpty {
            VStack(spacing: 6) {
                Text(emptyMessage).font(.callout).foregroundStyle(.secondary)
                Text(loc[.findHint]).font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            viewportScroller(renderMode: model.renderMode) {
                LazyVStack(spacing: 0) {
                    ForEach(model.findResults) { item in
                        row(item)
                        Divider()
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if model.findSearching { return loc[.computing] }
        if model.findText.trimmingCharacters(in: .whitespaces).count < 2 {
            return loc[.findPlaceholder]
        }
        return loc[.findNothing]
    }

    private func row(_ item: FoundItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory
                                 ? FileCategory.folder.color(scheme)
                                 : Categorizer.of(name: name(item), isDirectory: false).color(scheme))
                .frame(width: 15)
            Text(shortBytes(item.physical))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 72, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(item)).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(item.path).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Button(loc[.showIt]) { model.focus(item) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.focus(item) }
    }

    private func name(_ item: FoundItem) -> String {
        (item.path as NSString).lastPathComponent
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Never let the list imply it is the whole answer.
            Text(model.findTotal > model.findResults.count
                 ? loc.showingOfMatches(model.findResults.count, model.findTotal)
                 : loc.matchCount(model.findTotal))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(loc[.close]) { model.showFind = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
