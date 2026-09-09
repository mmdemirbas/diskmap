import CoreGraphics
import Foundation

public struct SunburstSegment: Sendable {
    public let node: Int32
    public let depth: Int
    /// Radians, clockwise from twelve o'clock.
    public let startAngle: Double
    public let endAngle: Double
    public let innerRadius: Double
    public let outerRadius: Double
    public let aggregatedCount: Int

    public var sweep: Double { endAngle - startAngle }
    public var midAngle: Double { (startAngle + endAngle) / 2 }
}

/// Concentric rings: one ring per level, arc length proportional to size.
///
/// The complement to a treemap rather than a replacement. A treemap uses the
/// area well but buries depth: a folder five levels down looks much like one at
/// the top. Here depth is the radius, so the shape of the hierarchy is the
/// thing you see first, and a deep chain of single-child folders is obvious.
public enum Sunburst {
    public static func layout(store: NodeStore, root: Int32, in rect: CGRect,
                              usePhysicalSize: Bool = true,
                              maxDepth: Int = 7,
                              minSweep: Double = 0.008,
                              includeAtRoot: ((Int32) -> Bool)? = nil) -> [SunburstSegment] {
        let radius = Double(min(rect.width, rect.height)) / 2
        guard radius > 8 else { return [] }
        // The middle disc is the folder you are in; rings fan out from it.
        let hub = radius * 0.16
        let ringWidth = (radius - hub) / Double(maxDepth)

        var out: [SunburstSegment] = []
        out.reserveCapacity(2048)
        out.append(SunburstSegment(node: root, depth: 0, startAngle: 0, endAngle: 2 * .pi,
                                   innerRadius: 0, outerRadius: hub, aggregatedCount: 0))

        let sizes = usePhysicalSize ? store.totalPhysical : store.totalLogical
        var frontier: [(node: Int32, depth: Int, start: Double, end: Double)] =
            [(root, 0, 0, 2 * .pi)]

        while let frame = frontier.popLast() {
            guard frame.depth < maxDepth else { continue }
            let span = frame.end - frame.start
            guard span > minSweep else { continue }

            var kids: [Int32] = []
            for c in store.children(frame.node) where !store.flagSet(c).contains(.removed) {
                if frame.depth == 0, let include = includeAtRoot, !include(c) { continue }
                if sizes[Int(c)] > 0 { kids.append(c) }
            }
            guard !kids.isEmpty else { continue }

            var total = 0.0
            for c in kids { total += Double(sizes[Int(c)]) }
            guard total > 0 else { continue }

            // Anything thinner than a hairline is folded into one trailing arc
            // rather than dropped, so a ring always accounts for its whole span.
            let minBytes = minSweep / span * total
            var visible: [Int32] = []
            var tailBytes = 0.0
            var tailCount = 0
            var largestBelow: Int32 = -1
            for c in kids {
                let bytes = Double(sizes[Int(c)])
                if bytes < minBytes {
                    tailBytes += bytes
                    tailCount += 1
                    if largestBelow < 0 || bytes > Double(sizes[Int(largestBelow)]) { largestBelow = c }
                } else {
                    visible.append(c)
                }
            }
            if visible.isEmpty, largestBelow >= 0 {
                visible.append(largestBelow)
                tailBytes -= Double(sizes[Int(largestBelow)])
                tailCount -= 1
            }
            visible.sort { sizes[Int($0)] > sizes[Int($1)] }

            let inner = hub + Double(frame.depth) * ringWidth
            let outer = inner + ringWidth
            var angle = frame.start
            for c in visible {
                let sweep = Double(sizes[Int(c)]) / total * span
                let end = angle + sweep
                out.append(SunburstSegment(node: c, depth: frame.depth + 1,
                                           startAngle: angle, endAngle: end,
                                           innerRadius: inner, outerRadius: outer,
                                           aggregatedCount: 0))
                if store.isDirectory(c) { frontier.append((c, frame.depth + 1, angle, end)) }
                angle = end
            }
            if tailCount > 0, tailBytes > 0 {
                let end = min(frame.end, angle + tailBytes / total * span)
                out.append(SunburstSegment(node: -1, depth: frame.depth + 1,
                                           startAngle: angle, endAngle: end,
                                           innerRadius: inner, outerRadius: outer,
                                           aggregatedCount: tailCount))
            }
        }
        return out
    }

    /// The segment under a point, or nil outside the wheel. Angles run
    /// clockwise from twelve o'clock to match how the rings are drawn.
    public static func hitTest(_ segments: [SunburstSegment], point: CGPoint,
                               centre: CGPoint) -> SunburstSegment? {
        let dx = Double(point.x - centre.x), dy = Double(point.y - centre.y)
        let radius = (dx * dx + dy * dy).squareRoot()
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        for segment in segments where segment.node >= 0 {
            if radius >= segment.innerRadius, radius < segment.outerRadius,
               angle >= segment.startAngle, angle < segment.endAngle {
                return segment
            }
        }
        return nil
    }
}
