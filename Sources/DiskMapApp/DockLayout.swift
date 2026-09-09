import Foundation

/// One pane: a view of the scan that can be put wherever the user wants it.
///
/// The seven were two closed sets — pick one picture, pick one table — and the
/// point of a dock is that they stop being alternatives. A pane is a *kind*
/// rather than an instance because every one of these is a view of the same
/// map state; two treemaps would be the same treemap twice.
enum PaneKind: String, Codable, CaseIterable, Identifiable {
    case treemap, sunburst, icicle
    case contents, largest, types, copies

    var id: String { rawValue }

    /// Pictures and tables. Only used to put a newly added pane somewhere
    /// sensible: a table joins the tables.
    var isPicture: Bool {
        switch self {
        case .treemap, .sunburst, .icicle: true
        default: false
        }
    }

    init(_ visualization: Visualization) {
        switch visualization {
        case .treemap: self = .treemap
        case .sunburst: self = .sunburst
        case .icicle: self = .icicle
        }
    }

    init(_ panel: PanelMode) {
        switch panel {
        case .contents: self = .contents
        case .largest: self = .largest
        case .types: self = .types
        case .duplicates: self = .copies
        }
    }

    /// The picture this pane draws, for the three that draw one.
    var visualization: Visualization? {
        switch self {
        case .treemap: .treemap; case .sunburst: .sunburst; case .icicle: .icicle
        default: nil
        }
    }

    /// The table this pane shows, for the four that show one.
    var panel: PanelMode? {
        switch self {
        case .contents: .contents; case .largest: .largest
        case .types: .types;       case .copies: .duplicates
        default: nil
        }
    }

    /// Borrowed from whichever of the two it is, rather than restated here: a
    /// pane that is called one thing in a menu and another on its own tab is
    /// two things as far as the reader is concerned.
    var key: L10n.K { visualization?.key ?? panel?.key ?? .panelContents }

    var icon: String {
        if let visualization { return visualization.symbol }
        switch self {
        case .contents: return "list.bullet.indent"
        case .largest: return "arrow.up.right.square"
        case .types: return "chart.bar"
        default: return "doc.on.doc"
        }
    }
}

enum DockAxis: String, Codable { case horizontal, vertical }

/// Where a dragged pane lands on the pane it is dropped onto: an edge splits,
/// the middle joins that pane's tabs.
enum DockEdge: String, Codable, CaseIterable {
    case leading, trailing, top, bottom

    var axis: DockAxis { self == .leading || self == .trailing ? .horizontal : .vertical }
    /// Whether the dropped pane becomes the first child of the new split.
    var takesFirstPlace: Bool { self == .leading || self == .top }
}

/// A layout tree: either a group of panes sharing one rectangle as tabs, or a
/// rectangle divided in two.
///
/// Indirect because a split holds two more of these. Codable so a layout the
/// user built survives quitting the app — a layout you have to rebuild every
/// morning is a layout nobody builds.
indirect enum DockNode: Codable, Equatable, Identifiable {
    case leaf(id: UUID, panes: [PaneKind], active: PaneKind)
    case split(id: UUID, axis: DockAxis, ratio: Double, first: DockNode, second: DockNode)

    var id: UUID {
        switch self {
        case .leaf(let id, _, _): id
        case .split(let id, _, _, _, _): id
        }
    }

    static func leaf(_ panes: [PaneKind]) -> DockNode {
        .leaf(id: UUID(), panes: panes, active: panes[0])
    }

    var panes: [PaneKind] {
        switch self {
        case .leaf(_, let panes, _): panes
        case .split(_, _, _, let first, let second): first.panes + second.panes
        }
    }
}

/// What the map's area is divided into, and every operation that can change it.
///
/// Kept apart from the views that draw it because the algebra is where the
/// mistakes live: removing the last pane of a group has to collapse the split
/// that held it, a pane must exist in exactly one place, and a ratio dragged
/// past the end has to stop rather than make a rectangle of zero width. All of
/// that is testable without drawing anything, and none of it is testable once
/// it is tangled up in a drag gesture.
struct DockLayout: Codable, Equatable {
    private(set) var root: DockNode

    /// The layout the app opens with, which is the screen it had before there
    /// was a dock: pictures on the left, tables on the right, each group's
    /// members as tabs. Nothing is lost by not touching it.
    static var standard: DockLayout {
        DockLayout(root: .split(id: UUID(), axis: .horizontal, ratio: 0.58,
                                first: .leaf([.treemap, .sunburst, .icicle]),
                                second: .leaf([.contents, .largest, .types, .copies])))
    }

    init(root: DockNode) { self.root = root }

    // MARK: - Reading it

    var panes: [PaneKind] { root.panes }
    func contains(_ kind: PaneKind) -> Bool { panes.contains(kind) }
    var missing: [PaneKind] { PaneKind.allCases.filter { !contains($0) } }

    /// Every group, in the order they appear. The drag machinery needs these to
    /// know what it can be dropped on.
    var leaves: [(id: UUID, panes: [PaneKind], active: PaneKind)] {
        var out: [(UUID, [PaneKind], PaneKind)] = []
        func walk(_ node: DockNode) {
            switch node {
            case .leaf(let id, let panes, let active): out.append((id, panes, active))
            case .split(_, _, _, let a, let b): walk(a); walk(b)
            }
        }
        walk(root)
        return out.map { (id: $0.0, panes: $0.1, active: $0.2) }
    }

    func leafHolding(_ kind: PaneKind) -> UUID? {
        leaves.first { $0.panes.contains(kind) }?.id
    }

    // MARK: - Changing it

    /// Brings a pane forward within its group.
    mutating func activate(_ kind: PaneKind) {
        root = Self.map(root) { node in
            guard case .leaf(let id, let panes, _) = node, panes.contains(kind) else { return node }
            return .leaf(id: id, panes: panes, active: kind)
        }
    }

    /// Adds a pane that is not on screen, next to its own kind: a table joins
    /// the tables. Falling back to the first group rather than refusing, since
    /// a menu item that does nothing is worse than one that puts it somewhere.
    mutating func add(_ kind: PaneKind) {
        guard !contains(kind) else { return activate(kind) }
        let host = leaves.first { $0.panes.contains { $0.isPicture == kind.isPicture } }
            ?? leaves.first
        guard let host else { return }
        insert(kind, into: host.id, edge: nil)
    }

    /// Puts a pane into a group as another tab, or splits that group in two.
    ///
    /// A pane already on screen is brought forward rather than added a second
    /// time. One place per pane is the invariant every other operation here
    /// relies on, and there is a path that breaks it: dropping onto a group
    /// that has since disappeared, in a layout small enough that removing the
    /// dragged pane empties it, falls back to the standard arrangement — which
    /// already holds that pane.
    mutating func insert(_ kind: PaneKind, into leafID: UUID, edge: DockEdge?) {
        guard !contains(kind) else { return activate(kind) }
        root = Self.map(root) { node in
            guard case .leaf(let id, let panes, let active) = node, id == leafID else { return node }
            guard let edge else {
                return .leaf(id: id, panes: panes + [kind], active: kind)
            }
            let existing = DockNode.leaf(id: id, panes: panes, active: active)
            let fresh = DockNode.leaf([kind])
            return .split(id: UUID(), axis: edge.axis, ratio: 0.5,
                          first: edge.takesFirstPlace ? fresh : existing,
                          second: edge.takesFirstPlace ? existing : fresh)
        }
    }

    /// Takes a pane off the screen. A group left with nothing in it goes with
    /// it, and so does the split that held the two of them — otherwise the
    /// layout keeps a divider with an empty rectangle behind it.
    mutating func remove(_ kind: PaneKind) {
        root = Self.prune(Self.map(root) { node in
            guard case .leaf(let id, let panes, let active) = node,
                  panes.contains(kind) else { return node }
            let left = panes.filter { $0 != kind }
            guard !left.isEmpty else { return .leaf(id: id, panes: [], active: active) }
            return .leaf(id: id, panes: left, active: active == kind ? left[0] : active)
        }) ?? Self.standard.root
    }

    /// Drags a pane somewhere else. Removing first means a pane is never in two
    /// places, which is the invariant that makes every other operation simple.
    mutating func move(_ kind: PaneKind, to leafID: UUID, edge: DockEdge?) {
        // Dropping a lone pane back onto its own group would take the group
        // away and put it back somewhere else, which is a lot of movement for
        // a gesture that meant nothing.
        if let source = leafHolding(kind), source == leafID,
           leaves.first(where: { $0.id == leafID })?.panes.count == 1 { return }
        let survivors = leaves
        remove(kind)
        // The group that was dropped onto may have been the one that just
        // vanished, in which case there is nowhere to put this back.
        guard leaves.contains(where: { $0.id == leafID }) else {
            if let first = leaves.first { insert(kind, into: first.id, edge: nil) }
            else if survivors.isEmpty { root = .leaf([kind]) }
            return
        }
        insert(kind, into: leafID, edge: edge)
    }

    /// How much of a split the first side takes. Clamped, because a divider
    /// dragged to the end would otherwise leave a pane that cannot be seen and
    /// cannot be grabbed to bring back.
    mutating func setRatio(_ splitID: UUID, _ ratio: Double) {
        root = Self.map(root) { node in
            guard case .split(let id, let axis, _, let a, let b) = node, id == splitID else {
                return node
            }
            return .split(id: id, axis: axis, ratio: min(0.85, max(0.15, ratio)),
                          first: a, second: b)
        }
    }

    // MARK: - Walking the tree

    /// Rebuilds the tree, applying `body` to every node bottom-up.
    private static func map(_ node: DockNode,
                            _ body: (DockNode) -> DockNode) -> DockNode {
        switch node {
        case .leaf:
            return body(node)
        case .split(let id, let axis, let ratio, let first, let second):
            let rebuilt = DockNode.split(id: id, axis: axis, ratio: ratio,
                                         first: map(first, body), second: map(second, body))
            return body(rebuilt)
        }
    }

    /// Drops empty groups, and collapses any split left with one child.
    private static func prune(_ node: DockNode) -> DockNode? {
        switch node {
        case .leaf(_, let panes, _):
            return panes.isEmpty ? nil : node
        case .split(let id, let axis, let ratio, let first, let second):
            switch (prune(first), prune(second)) {
            case (nil, nil): return nil
            case (let a?, nil): return a
            case (nil, let b?): return b
            case (let a?, let b?):
                return .split(id: id, axis: axis, ratio: ratio, first: a, second: b)
            }
        }
    }

    // MARK: - Surviving a restart

    /// A layout read back from disk, made safe to draw.
    ///
    /// Anything could be in that string: a layout written by an older version,
    /// a hand-edited preference, a pane that no longer exists. Rather than
    /// trusting it, every invariant the operations rely on is re-established —
    /// one place per pane, an active tab that is really in its group, a ratio
    /// that leaves both sides visible — and anything left over is dropped.
    static func sanitised(_ node: DockNode) -> DockLayout {
        var seen: Set<PaneKind> = []
        func clean(_ node: DockNode) -> DockNode? {
            switch node {
            case .leaf(let id, let panes, let active):
                let unique = panes.filter { seen.insert($0).inserted }
                guard !unique.isEmpty else { return nil }
                return .leaf(id: id, panes: unique,
                             active: unique.contains(active) ? active : unique[0])
            case .split(let id, let axis, let ratio, let first, let second):
                switch (clean(first), clean(second)) {
                case (nil, nil): return nil
                case (let a?, nil): return a
                case (nil, let b?): return b
                case (let a?, let b?):
                    return .split(id: id, axis: axis, ratio: min(0.85, max(0.15, ratio)),
                                  first: a, second: b)
                }
            }
        }
        guard let cleaned = clean(node) else { return .standard }
        return DockLayout(root: cleaned)
    }

    static func decoded(from json: String) -> DockLayout {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let node = try? JSONDecoder().decode(DockNode.self, from: data) else {
            return .standard
        }
        return sanitised(node)
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(root) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where a drop lands, worked out from a rectangle and a point.
///
/// Separate from the gesture that produces the point, because "which quarter of
/// this pane is the pointer in" is arithmetic and arithmetic can be tested. The
/// gesture is not.
enum DockGeometry {
    /// How far into the pane an edge zone reaches. Under a third, so the middle
    /// — join this group as a tab — stays the easiest thing to hit, and a pane
    /// dropped near a border still means "put it beside this one".
    static let margin = 0.28

    /// The edge nearest the point, or nil for the middle.
    static func edge(in rect: CGRect, at point: CGPoint) -> DockEdge? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        let distances: [(DockEdge, Double)] = [
            (.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }),
              nearest.1 < margin else { return nil }
        return nearest.0
    }

    /// The area the pane would take, so the drop can be shown before it
    /// happens rather than explained afterwards.
    static func preview(in rect: CGRect, edge: DockEdge?) -> CGRect {
        guard let edge else { return rect }
        switch edge {
        case .leading:  return CGRect(x: rect.minX, y: rect.minY,
                                      width: rect.width / 2, height: rect.height)
        case .trailing: return CGRect(x: rect.midX, y: rect.minY,
                                      width: rect.width / 2, height: rect.height)
        case .top:      return CGRect(x: rect.minX, y: rect.minY,
                                      width: rect.width, height: rect.height / 2)
        case .bottom:   return CGRect(x: rect.minX, y: rect.midY,
                                      width: rect.width, height: rect.height / 2)
        }
    }
}
