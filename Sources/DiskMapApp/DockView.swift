import AppKit
import DiskMapCore
import SwiftUI

/// How wide the grab area between two panes is.
private let dividerWidth: CGFloat = 7

/// What a dock can do to the thing it is arranging.
///
/// The layout is a value and the dock draws it; something else owns it and
/// decides what a change means. The map refreshes its reports when a pane
/// moves, the window does not — so the operations arrive as five closures
/// rather than being written into the view.
struct DockActions<Item: DockItem> {
    var activate: (Item) -> Void
    var close: (Item) -> Void
    var add: (Item, UUID) -> Void
    var move: (Item, UUID, DockEdge?) -> Void
    var ratio: (UUID, Double) -> Void
}

/// An area divided the way the user divided it.
///
/// Two things use it. Inside the map, seven views that used to be two closed
/// sets — pick one picture, pick one table. Inside the window, the tools
/// themselves. Either way: drag a tab onto the middle of another group to join
/// it, or onto an edge to split that group in two. Drag a divider to change the
/// share. Close what you do not want and add it back from the `+`.
///
/// The drag is a plain `DragGesture` rather than the system's drag-and-drop.
/// Two reasons, and the second is the one that decided it. A drop destination
/// tells you *that* it is being hovered, not where, so the exact half a pane
/// would take could not be shown before the drop — it could only be explained
/// afterwards, by having done it. And an AppKit drag session cannot be drawn by
/// `ImageRenderer`, so the whole screen would become a yellow placeholder and
/// nobody could check it without a window server.
struct DockView<Item: DockItem, Content: View, Footer: View>: View {
    let layout: DockLayout<Item>
    let actions: DockActions<Item>
    /// One coordinate space per dock, so a pane's rectangle and the pointer are
    /// in the same numbers however deeply nested the pane is — and so the dock
    /// inside the map does not answer for the dock around it.
    let space: String
    @ViewBuilder let content: (Item) -> Content
    @ViewBuilder let footer: () -> Footer

    @ObservedObject private var loc = L10n.shared

    @State private var frames: [UUID: CGRect] = [:]
    @State private var dragging: Item?
    @State private var pointer: CGPoint = .zero
    /// The ratio a divider had when the drag on it began. Translation is
    /// measured from there; reading the current ratio each time would compound.
    @State private var ratioAtStart: (split: UUID, ratio: Double)?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                node(layout.root)
                dropPreview
                ghost
            }
            .coordinateSpace(name: space)
            .onPreferenceChange(PaneFrames<Item>.self) { frames = $0 }
            footer()
        }
    }

    // MARK: - The tree

    @ViewBuilder private func node(_ node: DockNode<Item>) -> some View {
        switch node {
        case .leaf(let id, let panes, let active):
            group(id: id, panes: panes, active: active)
        case .split(let id, let axis, let ratio, let first, let second):
            // AnyView breaks the recursion: a view type cannot contain itself,
            // and there are seven panes at most so the erasure costs nothing
            // measurable.
            split(id: id, axis: axis, ratio: ratio,
                  first: AnyView(self.node(first)), second: AnyView(self.node(second)))
        }
    }

    private func split(id: UUID, axis: DockAxis, ratio: Double,
                       first: AnyView, second: AnyView) -> some View {
        GeometryReader { geo in
            let full = axis == .horizontal ? geo.size.width : geo.size.height
            let firstLength = max(0, full * ratio - dividerWidth / 2)
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first.frame(width: axis == .horizontal ? firstLength : nil,
                            height: axis == .vertical ? firstLength : nil)
                divider(id: id, axis: axis, ratio: ratio, full: full)
                second.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }


    private func divider(id: UUID, axis: DockAxis, ratio: Double, full: CGFloat) -> some View {
        DividerHandle(axis: axis, width: dividerWidth)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start: Double
                        if let held = ratioAtStart, held.split == id {
                            start = held.ratio
                        } else {
                            start = ratio
                            ratioAtStart = (id, ratio)
                        }
                        let moved = axis == .horizontal
                            ? value.translation.width : value.translation.height
                        actions.ratio(id, start + Double(moved) / Double(max(full, 1)))
                    }
                    .onEnded { _ in ratioAtStart = nil }
            )
    }

    // MARK: - One group of panes

    private func group(id: UUID, panes: [Item], active: Item) -> some View {
        VStack(spacing: 0) {
            tabs(id: id, panes: panes, active: active)
            Divider()
            content(active)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A pane keeps to its own rectangle. Offscreen a scroll view
                // has no viewport and reports the height of everything in it,
                // so a long list would otherwise draw straight through the
                // pane below it and out of the window.
                .clipped()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .background(GeometryReader { geo in
            Color.clear.preference(key: PaneFrames<Item>.self,
                                   value: [id: geo.frame(in: .named(space))])
        })
    }

    private func tabs(id: UUID, panes: [Item], active: Item) -> some View {
        HStack(spacing: 2) {
            ForEach(panes) { pane in
                tab(pane, in: id, active: pane == active)
            }
            Spacer(minLength: 4)
            addMenu(into: id)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tab(_ pane: Item, in leaf: UUID, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: pane.icon).font(.system(size: 10)).frame(width: 13)
            Text(loc[pane.key]).font(.system(size: 11, weight: active ? .semibold : .regular))
                .lineLimit(1)
            // Holds its place whether or not this tab is the one in front, so
            // the row does not reflow as the pointer moves along it.
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .frame(width: 11, height: 11)
                .contentShape(Rectangle())
                .opacity(active && pane.isClosable ? 1 : 0)
                // Invisible *and* out of reach. It held its place so the row
                // would not reflow, but it kept taking the click: aiming at the
                // right-hand end of a tab that was not in front closed that
                // pane instead of bringing it forward.
                .allowsHitTesting(active && pane.isClosable)
                .onTapGesture { if active, pane.isClosable { actions.close(pane) } }
                .help(loc[.closePane])
                .accessibilityHidden(!(active && pane.isClosable))
        }
        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(active ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(active ? Color.accentColor.opacity(0.4) : .clear))
        .opacity(dragging == pane ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { actions.activate(pane) }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                .onChanged { value in
                    dragging = pane
                    pointer = value.location
                }
                .onEnded { value in
                    defer { dragging = nil }
                    guard let target = target(at: value.location) else { return }
                    actions.move(pane, target.leaf, target.edge)
                }
        )
        .help(loc[.dragToRearrange])
    }

    /// Adds a pane that is not on screen anywhere, into this group.
    private func addMenu(into leaf: UUID) -> some View {
        let missing = layout.missing
        return Menu {
            ForEach(missing) { pane in
                Button { actions.add(pane, leaf) } label: {
                    Label(loc[pane.key], systemImage: pane.icon)
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        // Present and disabled rather than absent: a control that comes and
        // goes moves the whole row of tabs under the pointer.
        .disabled(missing.isEmpty)
        .opacity(missing.isEmpty ? 0.3 : 1)
        .help(loc[.addPane])
    }

    // MARK: - Dragging one somewhere else

    private func target(at point: CGPoint) -> (leaf: UUID, edge: DockEdge?)? {
        guard let hit = frames.first(where: { $0.value.contains(point) }) else { return nil }
        return (hit.key, DockGeometry.edge(in: hit.value, at: point))
    }

    /// The area the pane would take if it were dropped now. Shown before the
    /// drop rather than explained after it.
    @ViewBuilder private var dropPreview: some View {
        if dragging != nil, let target = target(at: pointer),
           let rect = frames[target.leaf] {
            let preview = DockGeometry.preview(in: rect, edge: target.edge)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: preview.width, height: preview.height)
                .position(x: preview.midX, y: preview.midY)
                .allowsHitTesting(false)
        }
    }

    /// What is being dragged, under the pointer, so the gesture has something
    /// to hold on to across the whole window.
    @ViewBuilder private var ghost: some View {
        if let dragging {
            HStack(spacing: 5) {
                Image(systemName: dragging.icon).font(.system(size: 10))
                Text(loc[dragging.key]).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor))
            .position(pointer)
            .allowsHitTesting(false)
        }
    }
}

/// Where each group ended up, in the dock's own coordinates. Collected from the
/// views rather than computed alongside them, so the rectangle a drop is tested
/// against is the rectangle that was actually drawn.
private struct PaneFrames<Item: DockItem>: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The grab area between two panes.
///
/// A view of its own so it can remember whether it pushed a cursor. Pushing on
/// enter and popping on leave is the obvious shape and it leaks: close a pane
/// while the pointer is on the divider beside it and the leave never arrives,
/// so the resize cursor stays over the whole app until something else sets one.
private struct DividerHandle: View {
    let axis: DockAxis
    let width: CGFloat
    @State private var pushed = false

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: axis == .horizontal ? 1 : nil,
                   height: axis == .vertical ? 1 : nil)
            .frame(width: axis == .horizontal ? width : nil,
                   height: axis == .vertical ? width : nil)
            .contentShape(Rectangle())
            // The pointer says what the divider does before it is grabbed.
            .onHover { inside in
                if inside, !pushed {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
    }
}

/// The dock inside the map: seven views of one scan.
///
/// A wrapper rather than a call site, because what a pane *is* — and what has
/// to happen when one moves — belongs next to the map rather than inside a
/// generic layout engine. Every rearrangement refreshes the reports: the pane
/// brought forward by a close may need one that has never been asked for.
struct MapDock: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DockView(layout: model.map.dock,
                 actions: DockActions(activate: model.showPane,
                                      close: model.closePane,
                                      add: model.addPane,
                                      move: model.movePane,
                                      ratio: model.setDockRatio),
                 space: "dock.panes") { pane in
            switch pane {
            case .treemap:  TreemapView(model: model)
            case .sunburst: SunburstView(model: model)
            case .icicle:   IcicleView(model: model)
            case .contents: ContentsList(model: model)
            case .largest:  LargestFilesView(model: model)
            case .types:    TypeBreakdownView(model: model)
            case .copies:   DuplicatesView(model: model)
            }
        } footer: {
            // Only when there is a picture to read it against.
            if model.map.visiblePanes.contains(where: { $0.isPicture }) {
                Divider()
                Legend(mode: model.colourMode, renderMode: model.renderMode)
            }
        }
    }
}
