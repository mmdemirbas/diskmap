import CoreGraphics
import Foundation

public struct IcicleCell: Sendable {
    public let node: Int32
    public let depth: Int
    public let rect: CGRect
    public let aggregatedCount: Int
}

/// Stacked horizontal bars, one row per level, width proportional to size.
///
/// The same data as a treemap laid out on one axis instead of two. That costs
/// area efficiency and buys reading order: rows line up, so sibling folders at
/// the same depth can be compared by length directly, and a path reads top to
/// bottom as a column of bars. It is the flame-graph shape, which is a familiar
/// way to look at a hierarchy where one dimension is a quantity.
public enum Icicle {
    public static let rowHeight: CGFloat = 22

    public static func layout(store: NodeStore, root: Int32, in rect: CGRect,
                              usePhysicalSize: Bool = true,
                              minWidth: CGFloat = 2,
                              includeAtRoot: ((Int32) -> Bool)? = nil) -> [IcicleCell] {
        guard rect.width > 8, rect.height >= rowHeight else { return [] }
        // Depth is bounded by the space available rather than a fixed number,
        // so the view fills the window instead of leaving rows empty.
        let maxRows = max(1, Int(rect.height / rowHeight))

        var out: [IcicleCell] = []
        out.reserveCapacity(2048)
        out.append(IcicleCell(node: root, depth: 0,
                              rect: CGRect(x: rect.minX, y: rect.minY,
                                           width: rect.width, height: rowHeight),
                              aggregatedCount: 0))

        let sizes = usePhysicalSize ? store.totalPhysical : store.totalLogical
        var frontier: [(node: Int32, depth: Int, x: CGFloat, width: CGFloat)] =
            [(root, 0, rect.minX, rect.width)]

        while let frame = frontier.popLast() {
            let nextDepth = frame.depth + 1
            guard nextDepth < maxRows, frame.width >= minWidth else { continue }

            var kids: [Int32] = []
            for c in store.children(frame.node) where !store.flagSet(c).contains(.removed) {
                if frame.depth == 0, let include = includeAtRoot, !include(c) { continue }
                if sizes[Int(c)] > 0 { kids.append(c) }
            }
            guard !kids.isEmpty else { continue }

            var total = 0.0
            for c in kids { total += Double(sizes[Int(c)]) }
            guard total > 0 else { continue }

            // Anything narrower than a hairline joins one trailing block rather
            // than disappearing, so a row always spans its parent exactly.
            let minBytes = Double(minWidth) / Double(frame.width) * total
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

            let y = rect.minY + CGFloat(nextDepth) * rowHeight
            var x = frame.x
            for c in visible {
                let width = CGFloat(Double(sizes[Int(c)]) / total) * frame.width
                out.append(IcicleCell(node: c, depth: nextDepth,
                                      rect: CGRect(x: x, y: y, width: width, height: rowHeight),
                                      aggregatedCount: 0))
                if store.isDirectory(c) { frontier.append((c, nextDepth, x, width)) }
                x += width
            }
            if tailCount > 0, tailBytes > 0 {
                let width = min(frame.x + frame.width - x, CGFloat(tailBytes / total) * frame.width)
                if width > 0 {
                    out.append(IcicleCell(node: -1, depth: nextDepth,
                                          rect: CGRect(x: x, y: y, width: width, height: rowHeight),
                                          aggregatedCount: tailCount))
                }
            }
        }
        return out
    }

    public static func hitTest(_ cells: [IcicleCell], point: CGPoint) -> IcicleCell? {
        for cell in cells where cell.node >= 0 && cell.rect.contains(point) { return cell }
        return nil
    }
}
