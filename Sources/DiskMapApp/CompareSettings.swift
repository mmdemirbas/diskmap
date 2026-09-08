import Combine
import DiskMapCore
import SwiftUI

/// What a comparison is told to leave out, how exact to be about dates, and
/// which pairs of folders have been compared before.
///
/// Separate from the comparison itself because these outlive it. Once a
/// comparison is a tab rather than a sheet there can be several open at once,
/// and the ignore list is not the property of any one of them — it is the same
/// list in all of them, and it persists across launches.
///
/// `@AppStorage` reads and writes `UserDefaults` but does not announce itself
/// to an `ObservableObject`, so the setters here say so by hand. That was true
/// of this state before the move; it is written down now rather than
/// rediscovered.
@MainActor
final class CompareSettings: ObservableObject {
    @AppStorage("compareIgnore") private var storedIgnore = CompareOptions.noise
        .joined(separator: "\n")
    @AppStorage("compareDateTolerance") var dateTolerance = 0
    @AppStorage("comparePairs") private var storedPairs = ""

    var ignore: [String] {
        get { storedIgnore.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        set { objectWillChange.send(); storedIgnore = newValue.joined(separator: "\n") }
    }

    var options: CompareOptions {
        CompareOptions(ignore: ignore, dateTolerance: Int32(dateTolerance))
    }

    /// True when the list actually changed, which is the caller's cue to work
    /// the answer out again rather than leave one standing that the current
    /// settings would not produce.
    @discardableResult
    func add(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !ignore.contains(trimmed) else { return false }
        ignore = ignore + [trimmed]
        return true
    }

    @discardableResult
    func remove(_ pattern: String) -> Bool {
        let before = ignore
        ignore = before.filter { $0 != pattern }
        return ignore.count != before.count
    }

    func reset() {
        ignore = CompareOptions.noise
    }

    /// Folder pairs compared before, newest first. A sync is a thing you do
    /// again next week, and retyping both sides is the part nobody does.
    var pairs: [(left: String, right: String)] {
        storedPairs.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    func remember(_ left: String, _ right: String) {
        var kept = pairs.filter { !($0.left == left && $0.right == right) }
        kept.insert((left, right), at: 0)
        storedPairs = kept.prefix(8).map { "\($0.left)\t\($0.right)" }.joined(separator: "\n")
    }
}
