import DiskMapCore
import SwiftUI

/// Area is proportional to bytes on disk, so the biggest rectangle is always
/// the thing worth deleting. Folder frames and headers show which folder owns a
/// block, so nesting stays readable without expanding a tree.
struct TreemapView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    @State private var hovered: Int32?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: !model.renderMode) { ctx, size in
                // In render mode there is no async pass, so lay out inline.
                let layout = model.cachedLayout(for: size)
                    ?? (model.renderMode ? model.computeLayoutSync(size: size) : model.layoutCache.any())
                if let layout { draw(layout, in: &ctx) }
            }
            .id(model.layoutToken)
            .background(Color(nsColor: .underPageBackgroundColor))
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, new in canvasSize = new }
            .task(id: model.layoutKey(size: geo.size)) {
                // Debounce: a window drag emits a size on every frame, and each
                // one would otherwise start a full layout.
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                await model.relayout(size: geo.size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = hit(p)
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 2) { p in
                // Double-clicking empty space goes back out, mirroring the way
                // double-clicking a folder goes in.
                if let n = hit(p) {
                    if model.tree?.withStore({ $0.isDirectory(n) }) == true { model.enter(n) }
                } else {
                    model.goUp()
                }
            }
            .onTapGesture(count: 1) { p in model.select(hit(p)) }
            .contextMenu { menu(for: hovered ?? model.selection) }
            .overlay(alignment: .topLeading) { tooltip }
            .overlay { if model.rows.isEmpty { emptyState } }
            .onChange(of: model.filterText) { _, _ in hovered = nil }
        }
    }

    private var currentLayout: TreemapLayout? {
        model.cachedLayout(for: canvasSize) ?? model.layoutCache.any()
    }

    private func hit(_ point: CGPoint) -> Int32? {
        guard let layout = currentLayout else { return nil }
        var best: Int32?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for c in layout.cells where c.node >= 0 && c.rect.contains(point) {
            let a = c.rect.width * c.rect.height
            if a < bestArea { bestArea = a; best = c.node }
        }
        return best
    }

    // MARK: - Drawing

    private func draw(_ layout: TreemapLayout, in ctx: inout GraphicsContext) {
        let info = layout.info

        // Pass 1: the areas. Colour says what kind of thing it is.
        for cell in layout.cells {
            let r = cell.rect
            guard r.width > 0.7, r.height > 0.7 else { continue }
            let path = Path(roundedRect: r, cornerRadius: min(3, min(r.width, r.height) / 4))

            guard cell.node >= 0, let meta = info[cell.node] else {
                ctx.fill(path, with: .color(.gray.opacity(0.16)))   // aggregated tail
                if cell.aggregatedCount > 0, r.width > 90, r.height > 18 {
                    ctx.draw(ctx.resolve(Text(loc.moreItems(cell.aggregatedCount))
                        .font(.system(size: 9)).foregroundStyle(.secondary)),
                        at: CGPoint(x: r.minX + 5, y: r.midY), anchor: .leading)
                }
                continue
            }

            var base = model.colourMode == .age ? meta.age.color(scheme)
                                                : meta.category.color(scheme)
            if meta.flags.contains(.dataless) { base = base.opacity(0.30) }
            let lift = min(Double(cell.depth) * 0.05, 0.25)
            ctx.fill(path, with: .color(base.opacity(meta.isDirectory ? 0.26 : 0.62 + lift)))
            guard !meta.isDirectory else { continue }

            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [.white.opacity(scheme == .dark ? 0.14 : 0.20), .clear]),
                startPoint: CGPoint(x: r.minX, y: r.minY),
                endPoint: CGPoint(x: r.minX, y: r.maxY)))
            if r.width > 3, r.height > 3 {
                ctx.stroke(path, with: .color(.black.opacity(0.20)), lineWidth: 0.5)
            }
            if r.width > 58, r.height > 20 {
                var clipped = ctx
                clipped.clip(to: path)
                clipped.draw(ctx.resolve(Text(meta.name)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)),
                    at: CGPoint(x: r.minX + 5, y: r.minY + 9), anchor: .leading)
                if r.height > 32 {
                    clipped.draw(ctx.resolve(Text(shortBytes(meta.bytes))
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.85))),
                        at: CGPoint(x: r.minX + 5, y: r.minY + 22), anchor: .leading)
                }
            }
        }

        // Pass 2: folder frames and names, over their contents.
        for cell in layout.cells where cell.isDirectory && cell.depth <= 2 {
            let r = cell.rect
            guard r.width > 26, r.height > 20, cell.node >= 0, let meta = info[cell.node] else { continue }
            let path = Path(roundedRect: r, cornerRadius: 4)
            ctx.stroke(path, with: .color(Palette.folderStroke(scheme)),
                       lineWidth: cell.depth == 1 ? 1.5 : 1)
            ctx.stroke(Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 4),
                       with: .color(.white.opacity(0.20)), lineWidth: 0.75)

            guard cell.depth < 2, r.height > 46, r.width > 70 else { continue }
            let header = CGRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 14)
            ctx.fill(Path(roundedRect: header, cornerRadius: 3), with: .color(.black.opacity(0.48)))
            var clipped = ctx
            clipped.clip(to: Path(roundedRect: header, cornerRadius: 3))
            clipped.draw(ctx.resolve(Text("\(meta.name)  \(shortBytes(meta.bytes))")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)),
                at: CGPoint(x: header.minX + 5, y: header.midY), anchor: .leading)
        }

        // Selection and hover last, so neither gets painted over.
        for cell in layout.cells where cell.node == model.selection || cell.node == hovered {
            let path = Path(roundedRect: cell.rect, cornerRadius: 3)
            if cell.node == model.selection {
                ctx.stroke(path, with: .color(.white), lineWidth: 2.5)
                ctx.stroke(path, with: .color(.black.opacity(0.8)), lineWidth: 1)
            } else {
                ctx.fill(path, with: .color(.white.opacity(0.20)))
            }
        }
    }

    // MARK: - Overlays

    @ViewBuilder private var tooltip: some View {
        if let h = hovered, let meta = currentLayout?.info[h] {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(shortBytes(meta.bytes)).font(.system(size: 11, design: .monospaced))
                    Text(model.colourMode == .age ? meta.age.localizedLabel
                                                  : meta.category.localizedLabel)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if meta.flags.contains(.dataless) {
                        Label(loc[.icloudZero], systemImage: "icloud")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            .padding(10)
            .allowsHitTesting(false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.filterText.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(model.filterText.isEmpty ? loc[.emptyFolder] : loc[.noMatches])
                .foregroundStyle(.secondary)
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
