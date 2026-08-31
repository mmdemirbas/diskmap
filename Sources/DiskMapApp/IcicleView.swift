import DiskMapCore
import SwiftUI

/// Stacked bars, one row per level of the tree.
///
/// The treemap is the best use of area and the sunburst is the best use of a
/// square window, but both make you judge two dimensions at once. Here every
/// bar has the same height, so size is length and nothing else, and folders at
/// the same depth line up as a row you can read across.
struct IcicleView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    @State private var hovered: Int32?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: !model.renderMode) { ctx, size in
                let layout = model.cachedIcicle(for: size)
                    ?? (model.renderMode ? model.computeIcicleSync(size: size)
                                         : model.icicleCache.any())
                if let layout { draw(layout, in: &ctx) }
            }
            .id(model.layoutToken)
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
            .task(id: model.layoutKey(size: geo.size)) {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                await model.relayout(size: geo.size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = hit(p)?.node
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 2) { p in
                // The top bar is the folder you are in, so opening it goes out.
                if let cell = hit(p), cell.depth > 0,
                   model.tree?.withStore({ $0.isDirectory(cell.node) }) == true {
                    model.enter(cell.node)
                } else {
                    model.goUp()
                }
            }
            .onTapGesture(count: 1) { p in model.select(hit(p)?.node) }
            .contextMenu { menu(for: hovered ?? model.selection) }
            .overlay(alignment: .topLeading) { tooltip }
        }
    }

    private var currentLayout: IcicleLayout? {
        model.cachedIcicle(for: canvasSize) ?? model.icicleCache.any()
    }

    private func hit(_ point: CGPoint) -> IcicleCell? {
        guard let layout = currentLayout else { return nil }
        return Icicle.hitTest(layout.cells, point: point)
    }

    private func fill(_ meta: CellInfo) -> Color {
        model.colourMode == .age ? meta.age.color(scheme) : meta.category.color(scheme)
    }

    private func draw(_ layout: IcicleLayout, in ctx: inout GraphicsContext) {
        for cell in layout.cells {
            // A one-pixel gap on two sides is what separates neighbours; a
            // stroke would eat the whole bar once bars get thin.
            let body = CGRect(x: cell.rect.minX, y: cell.rect.minY,
                              width: max(0.5, cell.rect.width - 1),
                              height: cell.rect.height - 1)
            let path = Path(roundedRect: body, cornerRadius: min(2, body.width / 2))

            guard cell.node >= 0, let meta = layout.info[cell.node] else {
                ctx.fill(path, with: .color(.gray.opacity(0.18)))
                continue
            }
            var base = fill(meta)
            if meta.flags.contains(.dataless) { base = base.opacity(0.32) }
            ctx.fill(path, with: .color(base.opacity(meta.isDirectory ? 0.80 : 0.95)))

            if cell.node == model.selection {
                ctx.stroke(path, with: .color(.white), lineWidth: 2)
                ctx.stroke(path, with: .color(.black.opacity(0.7)), lineWidth: 0.8)
            } else if cell.node == hovered {
                ctx.fill(path, with: .color(.white.opacity(0.22)))
            }

            // Labels are clipped to their own bar, so a name never runs across
            // the folder next to it.
            if body.width > 44 {
                ctx.drawLayer { layer in
                    layer.clip(to: Path(body.insetBy(dx: 4, dy: 0)))
                    layer.draw(layer.resolve(Text(meta.name)
                        .font(.system(size: 10, weight: cell.depth == 0 ? .semibold : .regular))
                        .foregroundStyle(.white)),
                        at: CGPoint(x: body.minX + 5, y: body.midY), anchor: .leading)
                }
            }
        }
    }

    @ViewBuilder private var tooltip: some View {
        if let h = hovered, let meta = currentLayout?.info[h] {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(shortBytes(meta.bytes)).font(.system(size: 11, design: .monospaced))
                    Text(model.colourMode == .age ? meta.age.localizedLabel
                                                  : meta.category.localizedLabel)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            .padding(10)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func menu(for node: Int32?) -> some View {
        Button(loc[.enclosingFolder]) { model.goUp() }
            .disabled(model.currentDirectory == 0)
        Divider()
        if let n = node, let meta = currentLayout?.info[n] {
            Text(meta.name)
            if meta.isDirectory { Button(loc[.openHere]) { model.enter(n) } }
            Button(loc[.revealInFinder]) { model.reveal(n) }
            Button(loc[.copyPath]) { model.copyPath(n) }
            Divider()
            Button(loc[.moveToTrash]) { model.requestTrash(n) }
        }
    }
}
