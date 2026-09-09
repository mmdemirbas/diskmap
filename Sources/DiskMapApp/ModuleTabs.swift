import SwiftUI

/// The tools, as things you open rather than things you are shown.
///
/// Each of these was a modal sheet, which meant opening one closed whatever
/// was already there and none of them survived being left. A tab does not have
/// that property, which is the whole point of the change.
///
/// Not everything that appears over the window belongs here. The never-touch
/// list is a settings dialog, and the confirmation before the Trash is a
/// decision point — making that one non-modal would let the tree move while it
/// is being read, which is the drift the safety review spent eight passes
/// closing. Both stay sheets on purpose.
enum ModuleTab: String, Identifiable, Hashable, CaseIterable {
    case home, map, files, space, duplicates, compare, search, changes

    var id: String { rawValue }

    /// Home is the list of tools and the map is the scan itself. Everything
    /// else is opened and closed.
    var isClosable: Bool { self != .map && self != .home }

    /// Compare walks the two folders it is given and reads nothing else, so it
    /// is the one tool that works before anything has been scanned. Home reads
    /// nothing at all.
    var needsAScan: Bool { self != .compare && self != .home }

    /// The tools Home offers, which is everything except Home itself.
    static var tools: [ModuleTab] { allCases.filter { $0 != .home } }

    /// One line saying what the tool answers. Home shows these; a tab strip has
    /// no room for them.
    var blurb: L10n.K {
        switch self {
        case .home: .tabHome
        case .map: .blurbMap
        case .files: .blurbFiles
        case .space: .blurbSpace
        case .duplicates: .blurbDuplicates
        case .compare: .blurbCompare
        case .search: .blurbSearch
        case .changes: .blurbChanges
        }
    }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2"
        case .map: "square.grid.2x2.fill"
        case .files: "tablecells"
        case .space: "sparkles"
        case .duplicates: "doc.on.doc"
        case .compare: "arrow.left.arrow.right"
        case .search: "magnifyingglass"
        case .changes: "clock.arrow.circlepath"
        }
    }

    /// One modifier for the whole set, a mnemonic letter per tool. Uniform on
    /// purpose: a menu where three items have shortcuts and five do not reads
    /// as five that were forgotten.
    var shortcut: KeyEquivalent {
        switch self {
        case .home: "h"
        case .map: "m"
        case .files: "t"
        case .space: "k"
        case .duplicates: "p"
        case .compare: "c"
        case .search: "f"
        case .changes: "d"
        }
    }

    var key: L10n.K {
        switch self {
        case .home: .tabHome
        case .map: .tabMap
        case .files: .tabFiles
        case .space: .freeUpSpace
        case .duplicates: .tabDuplicates
        case .compare: .tabCompare
        case .search: .tabSearch
        case .changes: .whatChanged
        }
    }
}
