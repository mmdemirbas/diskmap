import SwiftUI

/// The five tools, as things you open rather than things you are shown.
///
/// Each of these was a modal sheet, which meant opening one closed whatever
/// was already there and none of them survived being left. A tab does not have
/// that property, which is the whole point of the change.
///
/// Not everything that appears over the window belongs here. The never-touch
/// list is a settings dialog, and the confirmation before the Trash is a
/// decision point — making that one non-modal would let the tree move while it
/// is being read, which is the drift the safety review spent eight passes
/// closing. Both stay sheets on purpose.
enum ModuleTab: String, Identifiable, Hashable, CaseIterable {
    case map, space, duplicates, compare, search, changes

    var id: String { rawValue }

    /// The map is the scan itself. Everything else is opened and closed.
    var isClosable: Bool { self != .map }

    /// Compare walks the two folders it is given and reads nothing else, so it
    /// is the one tool that works before anything has been scanned.
    var needsAScan: Bool { self != .compare }

    var icon: String {
        switch self {
        case .map: "square.grid.2x2.fill"
        case .space: "sparkles"
        case .duplicates: "doc.on.doc"
        case .compare: "arrow.left.arrow.right"
        case .search: "magnifyingglass"
        case .changes: "clock.arrow.circlepath"
        }
    }

    var key: L10n.K {
        switch self {
        case .map: .tabMap
        case .space: .freeUpSpace
        case .duplicates: .tabDuplicates
        case .compare: .tabCompare
        case .search: .tabSearch
        case .changes: .whatChanged
        }
    }
}

/// One row of tabs, always present so that opening the first tool does not
/// push everything below it down by the height of a bar that was not there a
/// moment ago.
struct TabStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.openTabs) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabButton(_ tab: ModuleTab) -> some View {
        let active = model.activeTab == tab
        return HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .frame(width: 14)
            Text(loc[tab.key])
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
            // Holds its space on every tab, so the row does not reflow as the
            // pointer moves along it and the labels do not shift under a click.
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
                .opacity(tab.isClosable ? 1 : 0)
                .onTapGesture { if tab.isClosable { model.close(tab) } }
                .help(loc[.closeTab])
                .accessibilityHidden(!tab.isClosable)
        }
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(active ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(active ? Color.accentColor.opacity(0.45) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.activeTab = tab }
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}
