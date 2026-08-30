import DiskMapCore
import SwiftUI

/// Area is proportional to bytes on disk, so the biggest rectangle is always
/// the thing worth deleting. Nesting shows which folder it sits in without
/// making the reader expand a tree.
struct TreemapView: View {
    @ObservedObject var model: AppModel

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
            .task(id: model.layoutKey(size: geo.size)) { await model.relayout(size: geo.size) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = hit(p)
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 2) { p in
                if let n = hit(p), model.tree?.withStore({ $0.isDirectory(n) }) == true { model.enter(n) }
            }
            .onTapGesture(count: 1) { p in model.select(hit(p)) }
            .contextMenu { menu(for: hovered ?? model.selection) }
            .overlay(alignment: .topLeading) { tooltip }
            .overlay { if model.rows.isEmpty { emptyState } }
        }
    }


    private func hit(_ point: CGPoint) -> Int32? {
        guard let layout = model.cachedLayout(for: canvasSize) ?? model.layoutCache.any() else { return nil }
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

        // Pass 1: the areas themselves. Colour says what kind of file it is.
        for cell in layout.cells {
            let r = cell.rect
            guard r.width > 0.7, r.height > 0.7 else { continue }
            let path = Path(roundedRect: r, cornerRadius: min(3, min(r.width, r.height) / 4))

            guard cell.node >= 0, let meta = info[cell.node] else {
                ctx.fill(path, with: .color(.gray.opacity(0.16)))   // aggregated tail
                continue
            }

            var base = meta.category.color
            if meta.flags.contains(.dataless) { base = base.opacity(0.30) }
            let lift = min(Double(cell.depth) * 0.05, 0.25)
            ctx.fill(path, with: .color(base.opacity(meta.isDirectory ? 0.28 : 0.62 + lift)))
            if !meta.isDirectory {
                ctx.fill(path, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.18), .clear]),
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
        }

        // Pass 2: folder frames and their names, drawn over the contents so the
        // structure stays readable however deep the nesting goes.
        for cell in layout.cells where cell.isDirectory && cell.depth <= 2 {
            let r = cell.rect
            guard r.width > 26, r.height > 20, cell.node >= 0, let meta = info[cell.node] else { continue }
            let path = Path(roundedRect: r, cornerRadius: 4)
            ctx.stroke(path, with: .color(.black.opacity(cell.depth == 1 ? 0.55 : 0.35)),
                       lineWidth: cell.depth == 1 ? 1.5 : 1)
            ctx.stroke(Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 4),
                       with: .color(.white.opacity(0.22)), lineWidth: 0.75)

            guard cell.depth < 2, r.height > 46, r.width > 70 else { continue }
            let header = CGRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 14)
            ctx.fill(Path(roundedRect: header, cornerRadius: 3), with: .color(.black.opacity(0.45)))
            var clipped = ctx
            clipped.clip(to: Path(roundedRect: header, cornerRadius: 3))
            clipped.draw(ctx.resolve(Text("\(meta.name)  \(shortBytes(meta.bytes))")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)),
                at: CGPoint(x: header.minX + 5, y: header.midY), anchor: .leading)
        }

        // Selection and hover last, so neither is painted over.
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
        if let h = hovered, let meta = (model.cachedLayout(for: canvasSize) ?? model.layoutCache.any())?.info[h] {
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(shortBytes(meta.bytes)).font(.system(size: 11, design: .monospaced))
                    Text(meta.category.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    if meta.flags.contains(.dataless) {
                        Label("iCloud, 0 bytes here", systemImage: "icloud")
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
            Image(systemName: "square.grid.2x2").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("This folder is empty").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func menu(for node: Int32?) -> some View {
        if let n = node, let meta = (model.cachedLayout(for: canvasSize) ?? model.layoutCache.any())?.info[n] {
            Text(meta.name)
            Divider()
            if meta.isDirectory {
                Button("Open in Disk Map") { model.enter(n) }
            }
            Button("Reveal in Finder") { model.reveal(n) }
            Button("Copy Path") { model.copyPath(n) }
            Divider()
            Button("Move to Trash") { model.moveToTrash(n) }
        }
    }
}
