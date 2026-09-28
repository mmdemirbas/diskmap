import DiskMapCore
import SwiftUI

/// What the colours mean.
///
/// The picture was coloured by file type or by age with nothing anywhere
/// saying so, which makes a treemap decorative: a reader can see that two
/// regions differ without being able to say how. The key sits under the
/// visualization it explains rather than in a help topic, and it changes with
/// the colour mode because there is no sense in showing a reader the scale
/// they are not looking at.
///
/// Fixed height, and the row scrolls sideways rather than wrapping, so
/// switching mode or resizing the window never moves the picture above it.
struct Legend: View {
    let mode: ColourMode
    /// A swatch clicked here greys out everything else in the pictures;
    /// clicked again, it lets go. Every swatch carries the same padding
    /// whether picked or not, so picking one moves nothing.
    @Binding var highlight: MapHighlight?
    var renderMode = false

    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 26

    var body: some View {
        viewportScroller(renderMode: renderMode, axis: .horizontal) {
            HStack(spacing: 6) {
                switch mode {
                case .type:
                    // Ordered as the categoriser assigns them, so the same
                    // colour is always in the same place in the row.
                    ForEach(FileCategory.allCases, id: \.rawValue) { category in
                        swatch(category.color(scheme), category.localizedLabel, .category(category))
                    }
                case .age:
                    // Newest to oldest: the row is a scale, so it reads in the
                    // direction the values run.
                    ForEach(AgeBucket.allCases, id: \.rawValue) { bucket in
                        swatch(bucket.color(scheme), bucket.localizedLabel, .age(bucket))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
        // Flat, not a translucent system colour: a dynamic NSColor blended at
        // partial opacity resolves to something else entirely here.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func swatch(_ color: Color, _ label: String, _ value: MapHighlight) -> some View {
        let picked = highlight == value
        let faded = highlight != nil && !picked
        return Button { highlight = picked ? nil : value } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(label).font(.system(size: 10))
                    .foregroundStyle(picked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(picked ? Color.accentColor.opacity(0.18) : Color.clear))
            .opacity(faded ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(picked ? loc[.legendShowAll] : loc.legendHighlight(label))
        .fixedSize()
    }
}
