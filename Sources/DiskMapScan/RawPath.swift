import Foundation

/// A path as the bytes the filesystem gave us, never as text.
///
/// A filename is bytes. Any bytes, except a slash and a zero. On an APFS volume
/// they also happen to be valid UTF-8, because APFS refuses anything else at
/// creation — `mkdir` with a 0xFF in the name returns EILSEQ, checked by trying
/// it. The volumes where that does not hold are exactly the ones people keep
/// their backups on: a share served by Samba or NFS from a Linux box, an ext4
/// volume through FUSE, an archive unpacked by a tool that did not care.
///
/// Turning such a name into a `String` replaces the offending bytes with U+FFFD
/// and the damage is not recoverable: a path rebuilt from it names nothing. The
/// folder then fails to open, and it and everything beneath it is counted as
/// unreadable — a whole subtree missing from the total, with a permissions
/// warning as the only clue, on a disk analyser whose one job is to add up
/// correctly.
///
/// So paths that reach a syscall are carried as bytes from the directory
/// listing to the `open`, and turned into text only to be shown to somebody.
public struct RawPath: Hashable, Sendable {
    public private(set) var bytes: [UInt8]

    public init(_ text: String) { bytes = Array(text.utf8) }
    public init(bytes: [UInt8]) { self.bytes = bytes }

    /// From a file URL, which keeps the bytes `URL.path` would lose.
    public init(url: URL) {
        bytes = url.withUnsafeFileSystemRepresentation { rep in
            guard let rep else { return [] }
            return Array(UnsafeBufferPointer(
                start: UnsafeRawPointer(rep).assumingMemoryBound(to: UInt8.self),
                count: strlen(rep)))
        }
    }

    public var isEmpty: Bool { bytes.isEmpty }
    public var isRoot: Bool { bytes == [Self.separator] }

    public static let separator: UInt8 = 0x2F  // "/"

    /// This path with one more component on the end.
    ///
    /// The root is the special case, as it is in every path join: "/" already
    /// ends in a separator, and "//usr" is a path the standard allows an
    /// implementation to treat as its own thing.
    public func appending<C: Collection>(_ name: C) -> RawPath where C.Element == UInt8 {
        var out = bytes
        if !isRoot { out.append(Self.separator) }
        out.append(contentsOf: name)
        return RawPath(bytes: out)
    }

    /// The components, without the empty ones a leading or doubled separator
    /// would produce.
    public var components: [ArraySlice<UInt8>] {
        bytes.split(separator: Self.separator, omittingEmptySubsequences: true)
    }

    /// The last component, or nothing for the root.
    public var lastComponent: ArraySlice<UInt8> { components.last ?? [] }

    /// This path with text stuck on the end of its last component — a staging
    /// name beside the file it will replace. Text, because the suffix is ours
    /// and is always ASCII; the path it is stuck onto need not be.
    public func appendingSuffix(_ suffix: String) -> RawPath {
        RawPath(bytes: bytes + Array(suffix.utf8))
    }

    /// The folder this is in.
    public var parent: RawPath {
        guard let cut = bytes.lastIndex(of: Self.separator) else { return RawPath("") }
        return cut == 0 ? RawPath("/") : RawPath(bytes: Array(bytes[..<cut]))
    }

    /// True when this is `container` or sits beneath it. Compares against
    /// "container/" so `/Users/md/dev` does not swallow `/Users/md/development`.
    public func isInside(_ container: RawPath) -> Bool {
        if bytes == container.bytes { return true }
        let head = container.isRoot ? container.bytes : container.bytes + [Self.separator]
        return bytes.count > head.count && Array(bytes.prefix(head.count)) == head
    }

    /// For a syscall. Zero-terminated, and never allocated as a String on the
    /// way — that round trip is the whole thing this type exists to avoid.
    public func withCString<T>(_ body: (UnsafePointer<CChar>) -> T) -> T {
        var terminated = bytes
        terminated.append(0)
        return terminated.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: CChar.self, capacity: terminated.count, body)
        }
    }

    /// A `URL` that keeps the bytes. `URL(fileURLWithPath:)` takes a String and
    /// would lose them again; this is the API that does not.
    public func url(isDirectory: Bool) -> URL {
        withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: isDirectory,
                          relativeTo: nil) }
    }

    /// For a person: a label, never a path. Lossy on purpose — a name that
    /// cannot be written down is still worth showing, with the parts that
    /// cannot be shown marked as such, which is what U+FFFD is for.
    public var display: String { String(decoding: bytes, as: UTF8.self) }
}

extension RawPath: CustomStringConvertible {
    public var description: String { display }
}
