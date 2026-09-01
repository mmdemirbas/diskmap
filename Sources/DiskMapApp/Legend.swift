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
    var renderMode = false

    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 26

    var body: some View {
        viewportScroller(renderMode: renderMode, axis: .horizontal) {
            HStack(spacing: 12) {
                switch mode {
                case .type:
                    // Ordered as the categoriser assigns them, so the same
                    // colour is always in the same place in the row.
                    ForEach(FileCategory.allCases, id: \.rawValue) { category in
                        swatch(category.color(scheme), category.localizedLabel)
                    }
                case .age:
                    // Newest to oldest: the row is a scale, so it reads in the
                    // direction the values run.
                    ForEach(AgeBucket.allCases, id: \.rawValue) { bucket in
                        swatch(bucket.color(scheme), bucket.localizedLabel)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }
}
