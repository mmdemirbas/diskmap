import DiskMapCore
import SwiftUI

/// Concentric rings, one per level, arc length proportional to size.
///
/// Where the treemap spends every pixel on area, this spends the radius on
/// depth. A long chain of nested folders that a treemap flattens into one block
/// shows here as a spoke running out from the middle.
struct SunburstView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loc = L10n.shared
    @Environment(\.colorScheme) private var scheme

    @State private var hovered: Int32?
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Canvas(rendersAsynchronously: !model.renderMode) { ctx, size in
                let layout = model.cachedSunburst(for: size)
                    ?? (model.renderMode ? model.computeSunburstSync(size: size)
                                         : model.sunburstCache.any())
                if let layout { draw(layout, in: &ctx, size: size) }
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
                case .active(let p): hovered = hit(p, in: geo.size)?.node
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 2) { p in
                // The middle disc is the folder you are in, so clicking it goes out.
                if let segment = hit(p, in: geo.size), segment.node >= 0,
                   model.tree?.withStore({ $0.isDirectory(segment.node) }) == true {
                    model.enter(segment.node)
                } else {
                    model.goUp()
                }
            }
            .onTapGesture(count: 1) { p in
                let segment = hit(p, in: geo.size)
                model.select(segment.flatMap { $0.node >= 0 ? $0.node : nil })
            }
            .contextMenu { menu(for: hovered ?? model.selection) }
            .overlay(alignment: .topLeading) { tooltip }
        }
    }

    private var currentLayout: SunburstLayout? {
        model.cachedSunburst(for: canvasSize) ?? model.sunburstCache.any()
    }

    private func centre(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func hit(_ point: CGPoint, in size: CGSize) -> SunburstSegment? {
        guard let layout = currentLayout else { return nil }
        return Sunburst.hitTest(layout.segments, point: point, centre: centre(size))
    }

    private func fill(_ meta: CellInfo) -> Color {
        model.colourMode == .age ? meta.age.color(scheme) : meta.category.color(scheme)
    }

    /// An annular sector. Angles run clockwise from twelve o'clock, so each is
    /// turned a quarter turn back to match the drawing convention.
    private func wedge(_ segment: SunburstSegment, centre: CGPoint) -> Path {
        var path = Path()
        let from = Angle(radians: segment.startAngle - .pi / 2)
        let to = Angle(radians: segment.endAngle - .pi / 2)
        path.addArc(center: centre, radius: segment.outerRadius,
                    startAngle: from, endAngle: to, clockwise: false)
        path.addArc(center: centre, radius: max(segment.innerRadius, 0.01),
                    startAngle: to, endAngle: from, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func draw(_ layout: SunburstLayout, in ctx: inout GraphicsContext, size: CGSize) {
        let c = centre(size)
        for segment in layout.segments where segment.depth > 0 {
            let path = wedge(segment, centre: c)
            guard segment.node >= 0, let meta = layout.info[segment.node] else {
                ctx.fill(path, with: .color(.gray.opacity(0.16)))
                continue
            }
            var base = fill(meta)
            if meta.flags.contains(.dataless) { base = base.opacity(0.32) }
            // Rings fade slightly outward so depth reads even within one colour.
            let fade = 1.0 - min(Double(segment.depth) * 0.045, 0.24)
            ctx.fill(path, with: .color(base.opacity((meta.isDirectory ? 0.78 : 0.95) * fade)))
            if segment.sweep > 0.02 {
                ctx.stroke(path, with: .color(.black.opacity(scheme == .dark ? 0.45 : 0.25)),
                           lineWidth: 0.6)
            }

            // Only label arcs with room for a word, and only near the middle
            // where the ring is short enough to read horizontally.
            if segment.depth <= 2, segment.sweep > 0.30 {
                let radius = (segment.innerRadius + segment.outerRadius) / 2
                let point = CGPoint(x: c.x + CGFloat(sin(segment.midAngle) * radius),
                                    y: c.y - CGFloat(cos(segment.midAngle) * radius))
                ctx.draw(ctx.resolve(Text(meta.name)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white)),
                    at: point, anchor: .center)
            }
        }

        // Selection and hover last so nothing paints over them.
        for segment in layout.segments where segment.depth > 0
        && (segment.node == model.selection || segment.node == hovered) {
            let path = wedge(segment, centre: c)
            if segment.node == model.selection {
                ctx.stroke(path, with: .color(.white), lineWidth: 2.5)
                ctx.stroke(path, with: .color(.black.opacity(0.75)), lineWidth: 1)
            } else {
                ctx.fill(path, with: .color(.white.opacity(0.22)))
            }
        }

        drawHub(layout, in: &ctx, centre: c)
    }

    /// The middle disc names the folder the wheel is showing.
    private func drawHub(_ layout: SunburstLayout, in ctx: inout GraphicsContext, centre c: CGPoint) {
        guard let hub = layout.segments.first(where: { $0.depth == 0 }) else { return }
        let disc = Path(ellipseIn: CGRect(x: c.x - hub.outerRadius, y: c.y - hub.outerRadius,
                                          width: hub.outerRadius * 2, height: hub.outerRadius * 2))
        ctx.fill(disc, with: .color(Color(nsColor: .controlBackgroundColor)))
        ctx.stroke(disc, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

        let name = model.breadcrumb.last?.name ?? ""
        // The hub has room for a folder name, not a whole path.
        let label = name.isEmpty ? model.rootLabel
            : (name.hasPrefix("/") ? ((name as NSString).lastPathComponent) : name)
        if hub.outerRadius > 34 {
            ctx.draw(ctx.resolve(Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)),
                at: CGPoint(x: c.x, y: c.y - 7), anchor: .center)
            ctx.draw(ctx.resolve(Text(shortBytes(model.currentDirectoryBytes)).font(.system(size: 10))
                .foregroundStyle(.secondary)),
                at: CGPoint(x: c.x, y: c.y + 8), anchor: .center)
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
