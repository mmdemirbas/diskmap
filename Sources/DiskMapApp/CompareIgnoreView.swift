import DiskMapCore
import SwiftUI

/// The names a comparison never looks at.
///
/// Separate from the never-touch list, which is about deletion: this is about
/// what two folders are even asked to agree on. `.DS_Store` differs in every
/// directory macOS has ever opened, and a comparison that reports it is a
/// comparison nobody reads to the end.
///
/// Changing anything here re-runs the comparison rather than leaving a result
/// on screen that the current settings would not produce.
struct CompareIgnoreView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(loc[.compareIgnoreTitle]).font(.system(size: 14, weight: .semibold))
            Text(loc[.compareIgnoreExplained]).font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField(loc[.compareIgnorePlaceholder], text: $draft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .focused($focused)
                    .onSubmit { add() }
                Button(loc[.compareIgnoreAdd]) { add() }
                    .controlSize(.small).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func add() {
        model.addIgnorePattern(draft)
        draft = ""
        focused = true
    }

    @ViewBuilder private var list: some View {
        if model.compareIgnore.isEmpty {
            Text(loc[.compareIgnoreNone]).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            viewportScroller(renderMode: model.renderMode) {
                LazyVStack(spacing: 0) {
                    ForEach(model.compareIgnore, id: \.self) { pattern in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                                .frame(width: 14)
                            Text(pattern).font(.system(size: 12, design: .monospaced))
                            Spacer(minLength: 8)
                            Button { model.removeIgnorePattern(pattern) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).frame(height: 28)
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(loc[.compareIgnoreReset]) { model.resetIgnorePatterns() }
                .controlSize(.small)
            Spacer(minLength: 8)
            Button(loc[.done]) { model.showCompareIgnore = false }
                .controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(height: 52)
    }
}
