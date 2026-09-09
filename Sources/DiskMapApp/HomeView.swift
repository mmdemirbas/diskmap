import DiskMapCore
import SwiftUI

/// The screen the app opens on: every tool it has, shown the same way.
///
/// Before this, the map was the app and the rest were menu entries — and two
/// of them, the flat table and the copies list, had no entry anywhere. A tool
/// nobody can find is a tool that was not built. So each one gets a card of the
/// same size with the same parts: what it is called, what question it answers,
/// and whether it can run yet.
///
/// The cards are not ranked. The map is first because it is the one that
/// produces the scan the others read, not because it matters more.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared

    /// Two columns at the minimum window width, more as it widens. A fixed
    /// minimum rather than a flexible one, so a card never stretches to a shape
    /// its text was not written for.
    private static let card: CGFloat = 320

    var body: some View {
        viewportScroller(renderMode: model.renderMode) {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.card), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(ModuleTab.tools) { card($0) }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc[.homeTitle]).font(.system(size: 17, weight: .semibold))
            Text(loc[.homeSubtitle]).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func card(_ tab: ModuleTab) -> some View {
        let open = model.openTabs.contains(tab)
        let blocked = tab.needsAScan && model.tree == nil

        return Button { model.openTool(tab) } label: {
            HStack(alignment: .top, spacing: 12) {
                // A fixed column, so every title starts at the same x whatever
                // the glyph's width.
                Image(systemName: tab.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(blocked ? AnyShapeStyle(.tertiary)
                                             : AnyShapeStyle(Color.accentColor))
                    .frame(width: 26, alignment: .leading)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(loc[tab.key])
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(loc[tab.blurb])
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Always drawn, so a card does not change height when a
                    // scan lands and the note under it goes away.
                    Text(blocked ? loc[.homeNeedsAScan] : open ? loc[.homeOpen] : " ")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(open ? Color.accentColor.opacity(0.45)
                                   : Color.secondary.opacity(0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A tool that reads a scan still opens without one — it says so itself,
        // and offers the scan. Refusing the click here would be a dead card
        // with no explanation on it.
        .help(loc[tab.blurb])
        .accessibilityLabel("\(loc[tab.key]). \(loc[tab.blurb])")
    }
}
