import SwiftUI

/// Holds a tool's content to a width you can read a row across.
///
/// These screens were sheets, sized by whoever presented them, and became tabs
/// that fill the window. Filling the window is the point — the old sheet was
/// too small — but a row stretched to two thousand points puts its name at one
/// edge and its size at the other, and the eye has to cross the whole screen
/// to pair them up. That is the alignment rule failing at large sizes rather
/// than at small ones.
///
/// So: the tool gets the window, and the content gets a measure. Below the
/// measure it fills, above it it centres, and the background is the tool's
/// either way so nothing looks like a floating card.
struct ReadableColumn<Content: View>: View {
    var maxWidth: CGFloat = 1100
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content.frame(maxWidth: maxWidth)
            Spacer(minLength: 0)
        }
    }
}
