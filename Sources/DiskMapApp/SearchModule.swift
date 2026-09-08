import Combine
import DiskMapCore
import SwiftUI

/// *Finding one thing* — where is that, over the whole tree.
///
/// Distinct from the filter box, which narrows the folder being browsed and
/// answers "what is in here". Both stay, because they are different questions.
///
/// This is the module that most obviously needs a scan: it searches an index,
/// and without one there is nothing to search. When it becomes a tab it should
/// say so and offer to scan, rather than refusing or appearing empty — an empty
/// result and no index are not the same answer, and only one of them means
/// "nothing matched".
@MainActor
final class SearchModule: ObservableObject {
    @Published var text = ""
    @Published private(set) var results: [FoundItem] = []
    /// How many matched altogether. The list is capped, and a reader must not
    /// take the rows they can see for the whole answer.
    @Published private(set) var total = 0
    @Published private(set) var searching = false

    private var task: Task<Void, Never>?
    private let shown = 300

    /// Two characters is the floor: one letter over a tree of nine million
    /// names is not a search, it is a listing.
    var needsMoreTyping: Bool {
        text.trimmingCharacters(in: .whitespaces).count < 2
    }

    func run(in tree: LiveTree) {
        let needle = text
        guard !needsMoreTyping else {
            clear()
            return
        }
        searching = true
        let limit = shown
        task?.cancel()
        task = Task { [weak self] in
            // A search over nine million names costs about two tenths of a
            // second, which is fine once and wasteful on every keystroke.
            // Waiting for the typing to settle is cheaper than cancelling
            // work that has already started.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                tree.withStore { Find.search(store: $0, needle: needle, limit: limit) }
            }.value
            guard !Task.isCancelled, let self, self.text == needle else { return }
            self.results = outcome.items
            self.total = outcome.total
            self.searching = false
        }
    }

    /// The offscreen renderer has no async phase, so it searches in one call
    /// rather than starting a debounced task and drawing an empty list.
    func runSynchronously(in tree: LiveTree) {
        guard !needsMoreTyping else {
            clear()
            return
        }
        let needle = text
        let outcome = tree.withStore { Find.search(store: $0, needle: needle, limit: shown) }
        results = outcome.items
        total = outcome.total
        searching = false
    }

    func clear() {
        task?.cancel()
        results = []
        total = 0
        searching = false
    }
}
