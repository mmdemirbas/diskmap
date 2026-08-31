import Foundation

/// On modern macOS the read-only System volume exposes the Data volume's
/// directories under a second set of names (`/Users`, `/Applications`, ...).
/// They are the same bytes reached two ways.
///
/// Two consequences, and both matter:
///
/// 1. Walking both from `/` counts most of the disk twice, so the firmlinked
///    paths are excluded when scanning `/`.
/// 2. A tree rooted at `/System/Volumes/Data` stores
///    `/System/Volumes/Data/Users/md`, but FSEvents, Finder and the user all
///    say `/Users/md`. Without translation, live updates match nothing and
///    "Reveal in Finder" hands over a path nobody recognises.
public enum Firmlinks {
    /// "/Users" -> "/System/Volumes/Data/Users", longest link path first so a
    /// nested firmlink such as /usr/local wins over any shorter prefix.
    private static let pairs: [(link: String, data: String)] = {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> (String, String)? in
            let columns = line.split(separator: "\t")
            guard columns.count >= 2 else { return nil }
            let link = String(columns[0]), target = String(columns[1])
            guard link.hasPrefix("/"), !target.isEmpty else { return nil }
            return (link, "/System/Volumes/Data/" + target)
        }
        .sorted { $0.0.count > $1.0.count }
    }()

    public static func mountPaths() -> Set<String> { Set(pairs.map(\.link)) }

    /// `/Users/md` -> `/System/Volumes/Data/Users/md`, or nil if not firmlinked.
    public static func onDataVolume(_ path: String) -> String? {
        for (link, data) in pairs where path == link || path.hasPrefix(link + "/") {
            return data + path.dropFirst(link.count)
        }
        return nil
    }

    /// `/System/Volumes/Data/Users/md` -> `/Users/md`, the name everything else
    /// on the system uses.
    public static func displayPath(_ path: String) -> String {
        for (link, data) in pairs where path == data || path.hasPrefix(data + "/") {
            return link + path.dropFirst(data.count)
        }
        return path
    }
}
