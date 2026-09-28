import CoreServices
import Foundation
import DiskMapScan

/// What a file says about itself once something has already read it.
///
/// The scan never opens a file, which is why it walks eleven million nodes in
/// under two minutes. "How wide is this image", "when was this footage shot",
/// "how long is this recording" are not in directory metadata, and reading them
/// the obvious way — opening every file — would stop the scan being a scan.
///
/// On a Mac most of it has already been read: Spotlight indexed it when the
/// file was written. Asking the index is not opening the file, and at about a
/// millisecond and a half it is fast enough to answer for whatever is on
/// screen. What it is *not* fast enough for is a sweep: a million files one at
/// a time is around twenty-six minutes, so a whole-tree question has to be
/// asked of the index as a query instead.
public struct ContentProperties: Sendable, Equatable {
    /// Uniform type identifier — `public.jpeg`, not "JPEG image".
    public var contentType: String?
    /// When the *content* was made, which for a photo is when it was taken and
    /// not when it was copied onto this disk.
    public var created: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var durationSeconds: Double?
    public var codecs: [String] = []
    public var authors: [String] = []

    /// Whether the index knows this file at all.
    ///
    /// This is the difference between "nothing to say about this file" and "no
    /// answers available here", and they must never look the same on screen. A
    /// volume with indexing switched off answers for nothing, and a panel full
    /// of blanks would read as a file with no properties rather than as a
    /// question nobody asked.
    public var indexed = false

    /// True when the index knew the file but had none of the properties above,
    /// which is the normal case for a text file or an archive.
    public var isEmpty: Bool {
        created == nil && pixelWidth == nil && pixelHeight == nil
            && durationSeconds == nil && codecs.isEmpty && authors.isEmpty
    }

    public init() {}
}

/// Reading the index, one file at a time.
///
/// For what is on screen — a selection, a panel, a handful of rows. Anything
/// that asks about a whole tree belongs in a query against the index rather
/// than a loop around this.
public enum Spotlight {
    /// The attributes a size analyser actually wants: what kind of thing this
    /// is, when its content was made, and the shape of a picture or the length
    /// of a recording.
    public static func properties(ofFile path: String) -> ContentProperties {
        var out = ContentProperties()
        guard let item = MDItemCreate(nil, path as CFString) else { return out }

        // Content type is the tell for whether this file is in the index at
        // all: Spotlight knows the type of everything it has seen, whatever
        // else it does or does not hold.
        out.contentType = string(item, kMDItemContentType)
        out.indexed = out.contentType != nil

        out.created = MDItemCopyAttribute(item, kMDItemContentCreationDate) as? Date
        out.pixelWidth = number(item, kMDItemPixelWidth)
        out.pixelHeight = number(item, kMDItemPixelHeight)
        if let seconds = MDItemCopyAttribute(item, kMDItemDurationSeconds) as? NSNumber {
            out.durationSeconds = seconds.doubleValue
        }
        out.codecs = strings(item, kMDItemCodecs)
        out.authors = strings(item, kMDItemAuthors)
        return out
    }

    private static func string(_ item: MDItem, _ key: CFString) -> String? {
        MDItemCopyAttribute(item, key) as? String
    }

    private static func number(_ item: MDItem, _ key: CFString) -> Int? {
        (MDItemCopyAttribute(item, key) as? NSNumber)?.intValue
    }

    private static func strings(_ item: MDItem, _ key: CFString) -> [String] {
        (MDItemCopyAttribute(item, key) as? [String]) ?? []
    }
}

/// Answers already fetched, keyed on what would make them wrong.
///
/// `(device, inode, modified, size)` rather than the path: a path is not an
/// identity — it can be renamed onto another file — and an mtime alone is not a
/// change, since two files at the same path can differ while sharing one. The
/// key has to be able to see everything the value depends on, which is the
/// lesson the signature cache learned the hard way.
public final class ContentCache: @unchecked Sendable {
    private struct Key: Hashable {
        var device: Int32
        var inode: UInt64
        var modified: Int64
        var size: Int64
    }

    private let lock = NSLock()
    private var values: [Key: ContentProperties] = [:]
    /// Insertion order, so the cap drops the oldest rather than an arbitrary
    /// entry. A handful of thousands is plenty for anything on screen.
    private var order: [Key] = []
    private let limit: Int
    private let fetch: @Sendable (String) -> ContentProperties

    public init(limit: Int = 4096,
                fetch: @escaping @Sendable (String) -> ContentProperties = { Spotlight.properties(ofFile: $0) }) {
        self.limit = limit
        self.fetch = fetch
    }

    /// Nil when there is no file there at all — which is a different answer
    /// from a file the index has nothing to say about.
    public func properties(ofFile path: String) -> ContentProperties? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let key = Key(device: status.st_dev, inode: status.st_ino,
                      modified: Int64(status.st_mtimespec.tv_sec), size: status.st_size)

        lock.lock()
        if let hit = values[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // Fetched outside the lock: it is a millisecond and a half of somebody
        // else's work, and holding a lock across it would serialise every other
        // reader behind it.
        let fresh = fetch(path)

        lock.lock()
        if values[key] == nil {
            values[key] = fresh
            order.append(key)
            while order.count > limit {
                values.removeValue(forKey: order.removeFirst())
            }
        }
        lock.unlock()
        return fresh
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
        order.removeAll()
    }
}
