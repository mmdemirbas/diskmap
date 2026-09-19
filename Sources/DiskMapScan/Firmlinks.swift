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

    /// The same swap on bytes. Both halves of every pair are ASCII mount points
    /// macOS chose, so nothing is decoded — the tail may be a name that cannot
    /// be.
    public static func onDataVolume(_ path: RawPath) -> RawPath? {
        for (link, data) in pairs {
            let head = Array(link.utf8)
            guard path.bytes.count >= head.count, Array(path.bytes.prefix(head.count)) == head,
                  path.bytes.count == head.count || path.bytes[head.count] == RawPath.separator
            else { continue }
            return RawPath(bytes: Array(data.utf8) + path.bytes.dropFirst(head.count))
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

    /// The same swap on raw bytes. Both sides of every pair are ASCII — they
    /// are mount points macOS chose — so this is a prefix swap and nothing is
    /// decoded, which matters because the tail may be a name that cannot be.
    public static func displayPath(_ path: RawPath) -> RawPath {
        let bytes = path.bytes
        for (link, data) in pairs {
            let head = Array(data.utf8)
            guard bytes.count >= head.count, Array(bytes.prefix(head.count)) == head,
                  bytes.count == head.count || bytes[head.count] == 0x2F else { continue }
            return RawPath(bytes: Array(link.utf8) + bytes.dropFirst(head.count))
        }
        return path
    }
}
