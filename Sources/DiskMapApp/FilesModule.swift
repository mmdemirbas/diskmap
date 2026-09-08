import Combine
import DiskMapCore
import SwiftUI

/// *Everything at once* — the flat table, as state rather than as a screen.
///
/// It holds what the user picked, and turns that into the `FileFilter` the
/// index can answer. The translation lives here rather than in the view because
/// a band like "older than a year" is a decision about what people mean, not a
/// detail of how it is drawn — and because the offscreen renderer has to be
/// able to set it without going through a menu.
@MainActor
final class FilesModule: ObservableObject {
    /// Presets rather than a number to type. A field wanting bytes is a field
    /// wanting to be got wrong, and these are the sizes people actually ask
    /// about when they are looking for space.
    enum SizeBand: String, CaseIterable, Identifiable {
        case any, tiny, mb1, mb10, mb100, gb1
        var id: String { rawValue }

        /// Inclusive bounds in bytes; 0 means unbounded on that side.
        var bounds: (min: Int64, max: Int64) {
            switch self {
            case .any:   (0, 0)
            case .tiny:  (0, 1 << 20)
            case .mb1:   (1 << 20, 0)
            case .mb10:  (10 << 20, 0)
            case .mb100: (100 << 20, 0)
            case .gb1:   (1 << 30, 0)
            }
        }

        var key: L10n.K {
            switch self {
            case .any: .anySize;    case .tiny: .underOneMB
            case .mb1: .atLeast1MB; case .mb10: .atLeast10MB
            case .mb100: .atLeast100MB; case .gb1: .atLeast1GB
            }
        }
    }

    /// The same idea for dates, and in both directions: "what did I touch this
    /// week" and "what have I not touched in two years" are both questions
    /// somebody clearing space has.
    enum TimeBand: String, CaseIterable, Identifiable {
        case any, week, month, year, overAYear, overTwoYears
        var id: String { rawValue }

        /// Days from now. `recent` counts back from today; `stale` counts the
        /// other way, everything older than that.
        var days: (recent: Double?, stale: Double?) {
            switch self {
            case .any:          (nil, nil)
            case .week:         (7, nil)
            case .month:        (30, nil)
            case .year:         (365, nil)
            case .overAYear:    (nil, 365)
            case .overTwoYears: (nil, 730)
            }
        }

        var key: L10n.K {
            switch self {
            case .any: .anyTime;        case .week: .lastWeek
            case .month: .lastMonth;    case .year: .lastYear
            case .overAYear: .olderThanAYear; case .overTwoYears: .olderThanTwoYears
            }
        }
    }

    @Published private(set) var page = FileTablePage()
    @Published private(set) var loading = false

    @Published var sort: FileSort = .size
    @Published var ascending = false

    @Published var text = ""
    @Published var categories: Set<FileCategory> = []
    @Published var sizeBand: SizeBand = .any
    @Published var timeBand: TimeBand = .any
    @Published var includeFolders = false

    /// How many rows are asked for. It grows on request rather than standing as
    /// a ceiling: a list that stops at a thousand and offers no way past it is
    /// a truncation pretending to be an answer.
    @Published private(set) var limit = pageSize
    static let pageSize = 500

    private var task: Task<Void, Never>?

    var isFiltered: Bool {
        !text.isEmpty || !categories.isEmpty || sizeBand != .any || timeBand != .any
    }

    /// What the index is asked for. Recomputed rather than stored, so a band
    /// like "last week" means the week ending now and not the week that was
    /// current when the menu was opened.
    var filter: FileFilter {
        var out = FileFilter()
        out.text = text.trimmingCharacters(in: .whitespaces)
        out.categories = categories
        out.includeFolders = includeFolders
        (out.minBytes, out.maxBytes) = sizeBand.bounds
        let now = Date().timeIntervalSince1970
        let (recent, stale) = timeBand.days
        if let recent { out.modifiedAfter = Int32(now - recent * 86_400) }
        if let stale { out.modifiedBefore = Int32(now - stale * 86_400) }
        return out
    }

    /// Clicking the column that is already sorted reverses it; clicking another
    /// one starts it the way that column is usually read — names from A, sizes
    /// and dates from the top, since nobody opens a disk analyser to find their
    /// smallest file.
    func sortBy(_ key: FileSort, in tree: LiveTree?) {
        if sort == key {
            ascending.toggle()
        } else {
            sort = key
            ascending = key == .name
        }
        reset(in: tree)
    }

    /// Back to the first page. Any change to what is being asked for invalidates
    /// the rows already fetched, so growing the list past them would be growing
    /// it past rows that are no longer in the answer.
    func reset(in tree: LiveTree?) {
        limit = Self.pageSize
        reload(in: tree)
    }

    func showMore(in tree: LiveTree?) {
        limit += Self.pageSize
        reload(in: tree)
    }

    func reload(in tree: LiveTree?) {
        guard let tree else { return clear() }
        loading = true
        let filter = self.filter
        let (sort, ascending, limit) = (self.sort, self.ascending, self.limit)
        task?.cancel()
        task = Task { [weak self] in
            // A pass over ten million nodes costs a tenth of a second, which is
            // fine once and wasteful on every keystroke. Waiting for the typing
            // to settle is cheaper than cancelling work already started — the
            // same reason the search debounces.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                tree.withStore {
                    FileTable.page(store: $0, filter: filter, sort: sort,
                                   ascending: ascending, limit: limit)
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.page = outcome
            self.loading = false
        }
    }

    /// The offscreen renderer has no async phase, so it fills the table in one
    /// call rather than starting a task and drawing an empty screen.
    func reloadSynchronously(in tree: LiveTree) {
        page = tree.withStore {
            FileTable.page(store: $0, filter: filter, sort: sort,
                           ascending: ascending, limit: limit)
        }
        loading = false
    }

    /// Dropped when the tree underneath is replaced: a row names a node, and
    /// nodes from a previous scan mean nothing to this one.
    func clear() {
        task?.cancel()
        page = FileTablePage()
        loading = false
        limit = Self.pageSize
    }
}
